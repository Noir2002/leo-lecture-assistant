# Leo Lecture Assistant 初始化报告

> 这是 2026-09-01 的历史记录。当前功能与安装方式见 [README](../README.md)。

## 当前状态

项目已在 `leo-learning` 分支完成初始化和第一版实现。可行性仍评估为高（8/10）：
音频捕获、Apple 转录/翻译和 overlay 直接复用 v2s；Gemini、课程配置、Vault 持久化、
恢复、fallback 与测试均已接入。真实课堂前仍需要用户完成 Auth Key 和 macOS 权限操作。

## v2s 原始项目检查

- 来源：`https://github.com/franklioxygen/v2s.git`
- baseline commit：`3aaaaa199bccddddb354bd9d2ee1a17e6b1f714c`
- 保持 `origin` 不变，未推送、未创建 fork。
- baseline `swift test`：50 tests PASS。首次 Sparkle artifact 下载曾因本机 GitHub Keychain
  credential 查询失败，Xcode 完成依赖下载后重跑通过。
- baseline 无签名 Debug `xcodebuild`：PASS。
- upstream README 声明 MIT，但该 commit 根目录没有 `LICENSE` 文件；本项目保留声明，
  新增 `ATTRIBUTION.md`，没有虚构版权行。

## 已实现功能

- 解耦 Audio、Transcription、Translation、Persistence、Outline 协议和统一 coordinator。
- 配置驱动的五门课程、法语到简体中文默认语言、轻量课程 UI 与运行 overlay。
- 复用 v2s application audio、microphone、Apple SpeechAnalyzer/legacy Speech、Apple Translation。
- FINAL-only evidence/translation；interim 只显示淡色预览。
- 双层转录缓冲：约 8 秒字幕、30–60 秒 Obsidian 双语段落；跨 FINAL 前缀/重叠去重。
- Pause、Finish、没听懂、active timer、Open in Obsidian、诊断 summary JSON。
- 可见名称 `Leo Lecture Assistant`，bundle ID `com.leo.lectureassistant`；关闭 upstream Sparkle 自动更新。

## Gemini 集成

- Live transcription：`gemini-3.5-transcribe-live`，SMART，fr-FR，最多 100 个课程术语。
- 音频 adapter：PCM16 little-endian、mono、16 kHz。
- 8:15 预连接、8:30 轮换、2 秒 final drain、边界排序和去重。
- Translation/outline：`gemini-3.5-flash-lite` 严格 structured JSON。
- 长期 Auth Key 只存在 Keychain；Live 使用一次性、模型受限 ephemeral token。
- 真实 Gemini integration test 默认跳过，当前没有读取或配置真实 key。

## Obsidian 集成

唯一有效 Vault：
`~/Library/Mobile Documents/com~apple~CloudDocs/Obsidian/Leo-Knowledge`

已读取并遵守根 `AGENTS.md`。应用只允许写当前课程的 Glossary、Transcript 和 Lecture；
transcript 以可读双语段落 append-only + lock + fsync，原始 FINAL 留在本地 recovery journal；
Lecture 只替换 Leo managed blocks，Raw Notes 保留。
初始化实现和测试没有向真实 Vault 创建课堂文件。

## 自动 fallback

Key 缺失、401/403、429、网络中断会熔断整堂课到 Apple Local；不选择付费 endpoint，
不自动恢复 Gemini。预连接执行有限 1/2/4 秒 backoff；429 不重试。大纲失败不会阻止
Finish 保存 transcript。

## Build/Test 结果

- 最终测试：81 tests executed，0 failures，1 个真实 Gemini 测试按设计 skipped。
- 双层缓冲覆盖 cumulative/overlap 去重、独立时间窗、多事件恢复、七片段回归与三小时模拟测试。
- 无签名 Debug clean build：PASS。
- 无签名 Debug build：PASS（最终 clean build 命令见本报告完成时的终端记录）。
- mock integration：French FINAL → translation pair → append transcript → update outline → finish PASS。
- 2026-09-01 真实 Apple Local smoke test：MacBook Air 麦克风采集法语成功，写入 7 个
  FINAL FR/ZH chunk、1 个 90 秒 Confusion Marker，并在 Obsidian 中核对通过。
- 首次 smoke test 发现并修复 `fr-FR` 被旧 v2s 短语言 ID adapter 回退为英语的问题；
  新增 `fr-FR → fr` 回归测试。

## Vault 路径

`~/Library/Mobile Documents/com~apple~CloudDocs/Obsidian/Leo-Knowledge`

## 需要 Leo 手动完成

1. 登录 Google AI Studio，在**未启用 billing** 的项目中新建 2026 Auth Key。
2. 首次启动后在 Settings → Gemini Auth Key 输入 key，点击 Set Key，再点击 Test Gemini。
3. 勾选确认该项目未启用 billing；应用无法从 key 自动证明计费状态。
4. 按 macOS 提示授予 Speech Recognition、Microphone 和 Audio Capture 权限。
5. 按系统提示下载法语 Speech 与简体中文 Translation 资源。
6. 分发、Archive 或 notarize 时再提供 Apple Developer 签名；本地 Debug 不需要。

## 第一次运行步骤

1. 日常使用直接从 Spotlight、Finder 或 Dock 打开已安装的
   `~/Applications/Leo Lecture Assistant.app`；源码更新后运行 `./scripts/install-local.sh` 覆盖安装。
2. 在 Settings 核对自动发现的 Vault 和课程配置。
3. 建议先选 Apple Local + microphone 做 30 秒测试，点击“没听懂”，再 Finish。
4. 在 Obsidian 核对当天 Transcript、Lecture、Raw Notes 和 Confusion Markers。
5. 配置并测试 Auth Key 后，再用 Gemini Smart 做短课测试；观察状态是否为 Gemini Smart。

当前本地 Release 已使用固定 bundle ID `com.leo.lectureassistant` 和 ad-hoc 签名安装并启动；
不需要付费 Apple Developer 账号。旧安装在覆盖前会自动移动到带时间戳的备份目录。

## 已知限制

- 真实 Gemini Live schema、配额和 Auth Key 尚未用用户凭据端到端验证；官方服务变化可能要求更新。
- 2026-09-01 的既有测试 Transcript 按 Leo 的选择保持原样；新的段落格式从后续 Session 生效。
- Free Tier 取决于 Google 项目设置和政策，应用只能执行模型/重试 guard，不能查询 billing 状态。
- macOS 权限、法语语音资源、中文翻译资源和 Apple Intelligence 可用性必须在目标 Mac 上确认。
- Apple Intelligence 不可用时本地大纲使用保守的 extractive summary；不影响 transcript 保存。
- 无有效云翻译时恢复的未确认 FINAL 会优先保住法语证据，中文字段可能为空，需课后整理。

## 下一步建议

完成上述手动操作后进行一次 5 分钟 Zoom/浏览器课程 dry run，验证应用音频、fallback、
Obsidian iCloud 写入和 Finish 流程；确认后再用于完整课堂。课后由外部 Codex 执行
`Process today's COURSE_CODE lecture.`，本应用不会调用 OpenAI API。
