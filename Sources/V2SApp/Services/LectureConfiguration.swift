import Foundation

enum CourseRegistryError: Error, Equatable {
    case empty
    case duplicateCode(String)
    case invalidCourse(String)
    case selectedCourseMissing(String)
}

struct CourseRegistry: Sendable {
    let courses: [CourseDefinition]

    init(courses: [CourseDefinition]) throws {
        guard courses.isEmpty == false else { throw CourseRegistryError.empty }
        var codes = Set<String>()
        for course in courses {
            guard course.code.isEmpty == false,
                  course.officialTitle.isEmpty == false,
                  course.domain.isEmpty == false,
                  course.vaultPath.hasPrefix("10_Courses/"),
                  course.vaultPath.contains("..") == false,
                  course.glossaryPath.hasPrefix("/") == false,
                  course.glossaryPath.contains("..") == false else {
                throw CourseRegistryError.invalidCourse(course.code)
            }
            guard codes.insert(course.code).inserted else {
                throw CourseRegistryError.duplicateCode(course.code)
            }
        }
        self.courses = courses
    }

    func course(code: String) throws -> CourseDefinition {
        guard let value = courses.first(where: { $0.code == code }) else {
            throw CourseRegistryError.selectedCourseMissing(code)
        }
        return value
    }
}

final class LeoConfigurationStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LeoLectureAssistant", isDirectory: true)
            self.fileURL = root.appendingPathComponent("config.json")
        }
    }

    func load() -> LeoConfiguration {
        guard let data = try? Data(contentsOf: fileURL),
              var config = try? JSONDecoder().decode(LeoConfiguration.self, from: data),
              (try? CourseRegistry(courses: config.courses)) != nil else {
            var initial = LeoConfiguration.default
            if let discovered = try? VaultDiscoveryService().discover(), discovered.count == 1 {
                initial.vaultPath = discovered[0].path
            }
            save(initial)
            return initial
        }

        let retiredCodes: Set<String> = ["IFT-6002", "GLO-7006"]
        let retired = config.courses.filter {
            retiredCodes.contains($0.code) && $0.vaultPath == "10_Courses/2026-Autumn/\($0.code)"
        }
        if retired.isEmpty == false {
            let obsoleteCodes = Set(retired.map(\.code))
            config.courses.removeAll { obsoleteCodes.contains($0.code) }
            let currentCodes = Set(config.courses.map(\.code))
            config.courses += LeoConfiguration.defaultCourses.filter { currentCodes.contains($0.code) == false }
        }
        if (try? CourseRegistry(courses: config.courses).course(code: config.selectedCourse)) == nil {
            config.selectedCourse = config.courses.first?.code ?? LeoConfiguration.default.selectedCourse
        }
        return config
    }

    func save(_ config: LeoConfiguration) {
        do {
            _ = try CourseRegistry(courses: config.courses)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: fileURL, options: [.atomic])
        } catch {
            fputs("Failed to save Leo configuration: \(error)\n", stderr)
        }
    }
}

struct VaultDiscoveryService {
    static let requiredMarkers = ["AGENTS.md", "Home.md", "10_Courses", "20_Concepts", "50_Maps"]
    private let fileManager: FileManager
    private let home: URL

    init(fileManager: FileManager = .default, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.fileManager = fileManager
        self.home = home
    }

    func isValidVault(_ url: URL) -> Bool {
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return Self.requiredMarkers.allSatisfy {
            fileManager.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    func discover() throws -> [URL] {
        var candidates = [
            home.appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents/Leo-Knowledge"),
            home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Obsidian/Leo-Knowledge"),
            home.appendingPathComponent("Documents/Leo-Knowledge"),
        ]
        let searchRoots = [
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents", isDirectory: true),
            home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Obsidian", isDirectory: true),
        ]
        for root in searchRoots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let candidate as URL in enumerator {
                let depth = candidate.pathComponents.count - root.pathComponents.count
                if depth > 4 { enumerator.skipDescendants(); continue }
                if candidate.lastPathComponent == "Leo-Knowledge" {
                    candidates.append(candidate)
                    enumerator.skipDescendants()
                }
            }
        }
        var unique = [String: URL]()
        for candidate in candidates where isValidVault(candidate) {
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            unique[resolved.path] = resolved
        }
        return unique.values.sorted { $0.path < $1.path }
    }
}

enum VaultPathSafety {
    static func resolve(relativePath: String, under root: URL) throws -> URL {
        guard relativePath.hasPrefix("/") == false else { throw CocoaError(.fileReadInvalidFileName) }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(relativePath).standardizedFileURL
        let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath()
        guard parent.path == canonicalRoot.path || parent.path.hasPrefix(canonicalRoot.path + "/") else {
            throw CocoaError(.fileReadNoPermission)
        }
        return candidate
    }
}

enum CourseGlossary {
    static func parse(_ markdown: String, limit: Int = 100) -> [String] {
        var inCoreTerms = false
        var terms: [String] = []
        var seen = Set<String>()

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                inCoreTerms = line.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("Core Terms") == .orderedSame
                continue
            }
            guard inCoreTerms else { continue }
            guard line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") else { continue }
            var term = String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if let separator = term.range(of: " — ") ?? term.range(of: " - ") {
                term = String(term[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            term = term.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
            let key = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if term.isEmpty == false, seen.insert(key).inserted {
                terms.append(term)
                if terms.count >= max(0, limit) { break }
            }
        }
        return terms
    }

    static func emptyTemplate(courseCode: String) -> String {
        "# \(courseCode) Glossary\n\n## Core Terms\n"
    }
}
