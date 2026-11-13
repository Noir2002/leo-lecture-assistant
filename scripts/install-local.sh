#!/bin/zsh

set -euo pipefail

app_name="Leo Lecture Assistant.app"
bundle_id="com.leo.lectureassistant"
script_dir="${0:A:h}"
project_root="${script_dir:h}"
launch_after_install=1

if [[ "${1:-}" == "--no-launch" ]]; then
    launch_after_install=0
elif [[ $# -gt 0 ]]; then
    print -u2 "Usage: ./scripts/install-local.sh [--no-launch]"
    exit 64
fi

if [[ ! -d "${project_root}/v2s.xcodeproj" ]]; then
    print -u2 "Could not locate v2s.xcodeproj below ${project_root}"
    exit 66
fi

if [[ ! -x /usr/bin/xcodebuild ]] || ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    print -u2 "Xcode command-line tools are not available."
    exit 69
fi

user_home="${HOME:?HOME is not set}"
install_root="${user_home}/Applications"
destination="${install_root}/${app_name}"
backup_root="${install_root}/Leo Lecture Assistant Backups"

if [[ "${install_root}" != /* || "${install_root}" == "/" || "${install_root}" == "${user_home}" ]]; then
    print -u2 "Refusing unsafe install root: ${install_root}"
    exit 65
fi
if [[ -L "${install_root}" ]]; then
    print -u2 "Refusing symlinked install root: ${install_root}"
    exit 65
fi

temporary_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/leo-lecture-install.XXXXXX")"
derived_data="${temporary_root}/DerivedData"
staged_app="${temporary_root}/${app_name}"
build_log="${temporary_root}/xcodebuild.log"

cleanup() {
    [[ -d "${temporary_root}" ]] && /bin/rm -rf -- "${temporary_root}"
}
trap cleanup EXIT INT TERM

print "Building Leo Lecture Assistant (Release)…"
if ! /usr/bin/xcodebuild \
    -project "${project_root}/v2s.xcodeproj" \
    -scheme v2s \
    -configuration Release \
    -derivedDataPath "${derived_data}" \
    CODE_SIGNING_ALLOWED=NO \
    clean build >"${build_log}" 2>&1; then
    print -u2 "Release build failed. Last output:"
    /usr/bin/tail -40 "${build_log}" >&2
    exit 70
fi

built_app="${derived_data}/Build/Products/Release/${app_name}"
if [[ ! -d "${built_app}" ]]; then
    print -u2 "Release product was not found at ${built_app}"
    exit 66
fi

/usr/bin/ditto "${built_app}" "${staged_app}"
/usr/bin/codesign --force --deep --sign - --identifier "${bundle_id}" "${staged_app}"
/usr/bin/codesign --verify --deep --strict "${staged_app}"

/bin/mkdir -p "${install_root}"
if [[ -e "${destination}" ]]; then
    /bin/mkdir -p "${backup_root}"
    timestamp="$(/bin/date +%Y%m%d-%H%M%S)"
    backup="${backup_root}/Leo Lecture Assistant-${timestamp}.app"
    print "Backing up the previous app to ${backup}"
    /bin/mv -- "${destination}" "${backup}"
fi

/usr/bin/ditto "${staged_app}" "${destination}"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f -R -trusted "${destination}" >/dev/null 2>&1 || true

if [[ ${launch_after_install} -eq 1 ]]; then
    /usr/bin/osascript -e 'tell application id "com.leo.lectureassistant" to quit' >/dev/null 2>&1 || true
    for _ in {1..20}; do
        if ! /usr/bin/pgrep -f '/Leo Lecture Assistant.app/Contents/MacOS/Leo Lecture Assistant' >/dev/null 2>&1; then
            break
        fi
        /bin/sleep 0.1
    done
    /usr/bin/open -n "${destination}"
fi

print ""
print "LEO LECTURE ASSISTANT INSTALLED"
print "App: ${destination}"
print "Build: PASS"
print "Signature: LOCAL AD-HOC"
print "Launched: $([[ ${launch_after_install} -eq 1 ]] && print YES || print NO)"
