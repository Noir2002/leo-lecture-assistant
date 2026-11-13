import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class LectureSessionCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case paused
        case finishing
        case saved
        case saveFailed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var statusText = "Ready"
    @Published private(set) var activeEngine: LectureEngineMode = .appleLocal
    @Published private(set) var fallbackReason: String?
    @Published private(set) var paths: LectureSessionPaths?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var confusionMarkerCount = 0
    @Published private(set) var credentialConfigured = false
    @Published var config: LeoConfiguration {
        didSet {
            configStore.save(config)
            credentialConfigured = credentialStore.isConfigured
        }
    }

    var onInterim: ((String) -> Void)?
    var onCloudTranslation: ((TranslationResult) -> Void)?

    private let configStore: LeoConfigurationStore
    private let credentialStore: CredentialStore
    private let writer: ObsidianSessionWriter
    private let apiClient: GeminiAPIClient
    private let costGuard: CostGuard
    private let reviewGenerator: ReviewGenerator
    private let assembler = TranscriptAssembler()
    private var appleFinalTask: Task<Void, Never>?
    private var bookmarkTask: Task<Void, Never>?
    private var fallbackDrainTask: Task<Void, Never>?
    private var bookmarks: [LectureBookmark] = []
    private var sessionTranscript: [TranscriptChunk] = []
    private var pendingWrites: [TranscriptChunk] = []
    private var transcriptFlushTask: Task<Void, Never>?
    private var acceptsCloudReview = false
    private var liveManager: GeminiSessionManager?
    private var liveEventTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var subtitleFlushTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var startedAt: Date?
    private var activeStartedAt: Date?
    private var accumulatedActiveDuration: TimeInterval = 0
    private var course: CourseDefinition?
    private var glossary: [String] = []
    private var translationContext: [TranscriptContextEntry] = []
    private var confusionContext: [TranscriptContextEntry] = []
    private var finalChunkCount = 0
    private var errors: [String] = []
    private var journaledRawIDs = Set<UUID>()

    init(
        configStore: LeoConfigurationStore = LeoConfigurationStore(),
        credentialStore: CredentialStore = GeminiCredentialStore(),
        writer: ObsidianSessionWriter = ObsidianSessionWriter(),
        reviewGenerator: ReviewGenerator? = nil
    ) {
        let loadedConfiguration = configStore.load()
        self.configStore = configStore
        self.credentialStore = credentialStore
        self.writer = writer
        self.config = loadedConfiguration
        self.apiClient = GeminiAPIClient(credentialStore: credentialStore)
        self.costGuard = CostGuard(outlineInterval: loadedConfiguration.outlineInterval)
        self.reviewGenerator = reviewGenerator ?? GeminiReviewGenerator(client: apiClient, costGuard: costGuard)
        self.activeEngine = loadedConfiguration.engineMode
        self.credentialConfigured = credentialStore.isConfigured
    }

    var courses: [CourseDefinition] { config.courses }

    var selectedCourse: CourseDefinition? {
        try? CourseRegistry(courses: config.courses).course(code: config.selectedCourse)
    }

    func setCourse(_ code: String) {
        guard config.courses.contains(where: { $0.code == code }), state == .idle || state == .saved else { return }
        config.selectedCourse = code
    }

    func setEngineMode(_ mode: LectureEngineMode) {
        guard state == .idle || state == .saved else { return }
        config.engineMode = mode
        activeEngine = mode
    }

    func setVaultPath(_ path: String) {
        guard state == .idle || state == .saved else { return }
        config.vaultPath = path
    }

    func setFreeTierConfirmed(_ value: Bool) {
        config.freeTierConfirmed = value
    }

    func saveCredential(_ key: String) throws {
        try credentialStore.save(key)
        credentialConfigured = true
    }

    func deleteCredential() throws {
        try credentialStore.delete()
        credentialConfigured = false
    }

    func testGeminiConnection() async throws {
        try await apiClient.testConnection()
        if let course = selectedCourse {
            _ = try await apiClient.ephemeralToken(course: course, glossary: [])
        }
    }

    func start(sourceName: String, at date: Date = Date()) async throws {
        guard state == .idle || state == .saved else { return }
        let registry = try CourseRegistry(courses: config.courses)
        let course = try registry.course(code: config.selectedCourse)
        guard let vaultPath = config.vaultPath else { throw ObsidianWriterError.invalidVault }
        let vault = URL(fileURLWithPath: vaultPath, isDirectory: true)

        await resetRuntimeState()
        await costGuard.resetForNewClass()
        self.course = course
        self.startedAt = date
        self.activeStartedAt = date
        self.activeEngine = config.engineMode
        acceptsCloudReview = config.engineMode == .geminiSmart || config.reviewAfterAppleLocal == true
        let sessionPaths = try await writer.start(
            course: course,
            vaultRoot: vault,
            source: sourceName,
            engine: config.engineMode.displayName,
            at: date
        )
        paths = sessionPaths
        glossary = loadGlossary(course: course, vaultRoot: vault)
        await replayPendingJournal(course: course)

        if config.engineMode == .geminiSmart {
            guard credentialStore.isConfigured, config.freeTierConfirmed else {
                fallback(to: .missingCredential)
                beginRunningTimer()
                state = .running
                return
            }
            do {
                let manager = GeminiSessionManager(
                    client: apiClient,
                    rotationInterval: config.sessionRotationInterval
                )
                try await manager.start(course: course, glossary: glossary)
                liveManager = manager
                observeLiveEvents(manager.events)
                activeEngine = .geminiSmart
                statusText = "Gemini Smart"
            } catch let failure as EngineFailure {
                fallback(to: failure)
            } catch {
                fallback(to: .network)
            }
        } else {
            statusText = "Apple Local"
        }
        state = .running
        beginRunningTimer()
    }

    func ingest(_ buffer: AVAudioPCMBuffer, capturedAt: Date = Date()) {
        guard state == .running, activeEngine == .geminiSmart, let liveManager else { return }
        Task {
            do {
                try await liveManager.ingest(AudioFrame(buffer: buffer, capturedAt: capturedAt))
            } catch let failure as EngineFailure {
                await MainActor.run { self.fallback(to: failure) }
            } catch {
                await MainActor.run { self.fallback(to: .network) }
            }
        }
    }

    func recordAppleFinal(id: UUID, french: String, capturedAt: Date = Date()) {
        guard state == .running,
              activeEngine == .appleLocal else { return }
        let previous = appleFinalTask
        appleFinalTask = Task {
            await previous?.value
            await ingestRawFinal(
                RawFinalEvent(id: id, capturedAt: capturedAt, source: .apple, text: french)
            )
        }
    }

    func markConfusion(at date: Date = Date()) {
        guard state == .running || state == .paused else { return }
        let previous = bookmarkTask
        let finals = appleFinalTask
        confusionMarkerCount += 1
        bookmarkTask = Task {
            await previous?.value
            await finals?.value
            let context = TranscriptContextWindow.recent(confusionContext, now: date)
            bookmarks.append(LectureBookmark(capturedAt: date, context: context))
            do { try await writer.appendConfusionMarker(at: date, context: context) }
            catch { recordError("Confusion marker: \(type(of: error))") }
        }
    }

    func pause() async {
        guard state == .running else { return }
        captureActiveDuration()
        state = .paused
        statusText = "Paused"
        timerTask?.cancel()
        timerTask = nil
        await drainLiveTranscription()
        await appleFinalTask?.value
        await flushSubtitle(force: true)
        await flushTranscript(force: true)
        await awaitQueuedTranslations()
    }

    func resume() async {
        guard state == .paused, let course else { return }
        activeStartedAt = Date()
        if config.engineMode == .geminiSmart, fallbackReason == nil, credentialStore.isConfigured {
            do {
                let manager = GeminiSessionManager(client: apiClient, rotationInterval: config.sessionRotationInterval)
                try await manager.start(course: course, glossary: glossary)
                liveManager = manager
                observeLiveEvents(manager.events)
                activeEngine = .geminiSmart
                statusText = "Gemini Smart"
            } catch let failure as EngineFailure {
                fallback(to: failure)
            } catch {
                fallback(to: .network)
            }
        }
        state = .running
        beginRunningTimer()
    }

    func finish(at date: Date = Date()) async throws -> SessionSummary {
        guard state == .running || state == .paused || state == .saveFailed,
              let course, let startedAt, let paths else { throw ObsidianWriterError.notStarted }
        state = .finishing
        statusText = "Saving transcript"
        captureActiveDuration()
        timerTask?.cancel()
        await drainLiveTranscription()
        await appleFinalTask?.value
        await flushSubtitle(force: true)
        await flushTranscript(force: true)
        await awaitQueuedTranslations()
        await bookmarkTask?.value
        do {
            guard pendingWrites.isEmpty else { throw ObsidianWriterError.pendingTranscript }
            try await writer.finish(at: date)
        } catch {
            state = .saveFailed
            throw error
        }
        let reviewStatus = await generateReview(course: course, startedAt: startedAt)

        let summary = SessionSummary(
            course: course.code,
            startedAt: startedAt,
            endedAt: date,
            activeDuration: accumulatedActiveDuration,
            engine: activeEngine.displayName,
            fallbackReason: fallbackReason,
            transcriptPath: paths.transcript,
            lecturePath: paths.lecture,
            confusionMarkerCount: confusionMarkerCount,
            finalChunkCount: finalChunkCount,
            reviewStatus: reviewStatus,
            errors: errors
        )
        statusText = reviewStatus ?? "Class Saved"
        do { try saveSummary(summary) }
        catch { statusText += " · diagnostics unavailable" }
        state = .saved
        return summary
    }

    private func generateReview(course: CourseDefinition, startedAt: Date) async -> String? {
        guard acceptsCloudReview, sessionTranscript.isEmpty == false else { return nil }
        guard config.freeTierConfirmed, credentialStore.isConfigured else {
            return "Transcript saved · Gemini review needs configuration"
        }
        statusText = "Transcript saved · generating review"
        do {
            let review = try await reviewGenerator.generate(
                ReviewRequest(course: course, glossary: glossary, transcript: sessionTranscript, bookmarks: bookmarks)
            )
            try await writer.appendReview(review, startedAt: startedAt)
            return "Gemini review saved"
        } catch {
            recordError("Review: \(type(of: error))")
            return "Transcript saved · Gemini review unavailable"
        }
    }

    private func drainLiveTranscription() async {
        await fallbackDrainTask?.value
        let manager = liveManager
        let events = liveEventTask
        liveManager = nil
        liveEventTask = nil
        await manager?.finish()
        await events?.value
    }

    func openLectureInObsidian() {
        guard let path = paths?.lecture else { return }
        let fileURL = URL(fileURLWithPath: path)
        let relative = course.flatMap { course in
            config.vaultPath.map { vault in
                fileURL.path.replacingOccurrences(of: URL(fileURLWithPath: vault).path + "/", with: "")
            }
        }
        if let relative,
           var components = URLComponents(string: "obsidian://open") {
            components.queryItems = [
                URLQueryItem(name: "vault", value: "Leo-Knowledge"),
                URLQueryItem(name: "file", value: relative),
            ]
            if let url = components.url, NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(fileURL)
    }

    private func observeLiveEvents(_ stream: AsyncStream<TranscriptEvent>) {
        liveEventTask?.cancel()
        liveEventTask = Task { [weak self] in
            for await event in stream {
                guard let self, Task.isCancelled == false else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: TranscriptEvent) async {
        switch event {
        case .interim(let text, _):
            onInterim?(text)
        case .final(let text, let capturedAt):
            await processGeminiFinal(text, capturedAt: capturedAt)
        case .status(let value):
            statusText = value
            if value == "Gemini Live rotating" {
                await flushSubtitle(force: true)
            }
        case .failure(let failure):
            fallback(to: failure)
        }
    }

    private func processGeminiFinal(_ text: String, capturedAt: Date) async {
        switch state {
        case .running, .paused, .finishing:
            break
        case .idle, .saved, .saveFailed:
            return
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }
        await ingestRawFinal(
            RawFinalEvent(id: UUID(), capturedAt: capturedAt, source: .gemini, text: normalized)
        )
    }

    private func handleCloudFailure(_ failure: EngineFailure) async {
        let circuitIsOpen = await costGuard.cloudDisabledReason != nil
        if failure.requiresImmediateFallback || circuitIsOpen {
            fallback(to: failure)
        } else {
            recordError("Cloud request: \(String(describing: failure))")
        }
    }

    private func ingestRawFinal(
        _ event: RawFinalEvent,
        journalAlreadyWritten: Bool = false
    ) async {
        do {
            let isNewEvent = journaledRawIDs.insert(event.id).inserted
            if journalAlreadyWritten == false {
                try await writer.journalFinal(id: event.id, text: event.text, capturedAt: event.capturedAt)
            }
            switch await assembler.ingest(event) {
            case .duplicateDropped(let id):
                if isNewEvent {
                    try await writer.acknowledge(eventIDs: [id], at: event.capturedAt)
                }
                return
            case .accepted(let accepted):
                if accepted.source != .recovery {
                    confusionContext.append(
                        TranscriptContextEntry(capturedAt: accepted.capturedAt, french: accepted.text, chinese: nil)
                    )
                    confusionContext = TranscriptContextWindow.recent(confusionContext, now: accepted.capturedAt)
                }
            }
            await flushTranscript(force: false, now: event.capturedAt)
            if let batch = await assembler.subtitleBatchIfDue(now: event.capturedAt) {
                subtitleFlushTask?.cancel()
                subtitleFlushTask = nil
                handleSubtitleBatch(batch)
            }
            await scheduleSubtitleFlush()
        } catch {
            recordError("Raw final: \(type(of: error))")
        }
    }

    private func scheduleSubtitleFlush() async {
        guard subtitleFlushTask == nil, await assembler.hasPendingSubtitle() else { return }
        subtitleFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ModelConfig.defaultTranslationWindow * 1_000_000_000))
            guard let self, Task.isCancelled == false else { return }
            self.subtitleFlushTask = nil
            await self.flushSubtitle(force: true)
        }
    }

    private func flushSubtitle(force: Bool) async {
        subtitleFlushTask?.cancel()
        subtitleFlushTask = nil
        guard let batch = await assembler.subtitleBatchIfDue(now: Date(), force: force) else { return }
        handleSubtitleBatch(batch)
    }

    private func handleSubtitleBatch(_ batch: SubtitleBatch) {
        if activeEngine == .geminiSmart {
            enqueueTranslation(batch)
        }
    }

    private func enqueueTranslation(_ batch: SubtitleBatch) {
        let previous = translationTask
        translationTask = Task { [weak self] in
            await previous?.value
            guard let self, Task.isCancelled == false else { return }
            await self.translateForLiveUI(batch)
        }
    }

    private func awaitQueuedTranslations() async {
        await translationTask?.value
        translationTask = nil
    }

    private func translateForLiveUI(_ batch: SubtitleBatch) async {
        guard let course else { return }
        var usedGemini = false
        let result: TranslationResult
        do {
            if activeEngine == .geminiSmart {
                let context = translationContext.map(\.french).joined(separator: " ")
                result = try await GeminiTranslationEngine(client: apiClient, costGuard: costGuard).translate(
                    TranslationRequest(
                        course: course,
                        glossary: glossary,
                        recentFrenchContext: context,
                        currentSegment: batch.french
                    )
                )
                usedGemini = true
            } else {
                result = TranslationResult(correctedFrench: batch.french, chineseTranslation: "")
            }
        } catch let failure as EngineFailure {
            await handleCloudFailure(failure)
            result = TranslationResult(correctedFrench: batch.french, chineseTranslation: "")
        } catch {
            recordError("Segment translation: \(type(of: error))")
            result = TranslationResult(correctedFrench: batch.french, chineseTranslation: "")
        }

        let contextEntry = TranscriptContextEntry(
            capturedAt: batch.endedAt,
            french: batch.french,
            chinese: result.chineseTranslation
        )
        translationContext.append(contextEntry)
        translationContext = TranscriptContextWindow.recent(translationContext, seconds: 60, now: batch.endedAt)
        if usedGemini { onCloudTranslation?(result) }
    }

    private func flushTranscript(force: Bool, now: Date = Date()) async {
        let previous = transcriptFlushTask
        let task = Task {
            await previous?.value
            await persistTranscript(force: force, now: now)
        }
        transcriptFlushTask = task
        await task.value
    }

    private func persistTranscript(force: Bool, now: Date) async {
        while let chunk = await assembler.transcriptChunkIfDue(now: now, force: force) {
            pendingWrites.append(chunk)
        }
        while let chunk = pendingWrites.first {
            do {
                try await writer.appendChunk(chunk)
                pendingWrites.removeFirst()
                if chunk.startedAt >= (startedAt ?? .distantFuture) {
                    sessionTranscript.append(chunk)
                }
                finalChunkCount += 1
            } catch {
                recordError("Persistence: \(type(of: error))")
                return
            }
        }
    }

    private func replayPendingJournal(course: CourseDefinition) async {
        guard let pending = try? await writer.pendingFinals(), pending.isEmpty == false else { return }
        for event in pending {
            await ingestRawFinal(
                RawFinalEvent(id: event.id, capturedAt: event.capturedAt, source: .recovery, text: event.text),
                journalAlreadyWritten: true
            )
        }
        await flushSubtitle(force: true)
        await flushTranscript(force: true)
        await awaitQueuedTranslations()
    }

    private func fallback(to failure: EngineFailure) {
        guard activeEngine != .appleLocal || fallbackReason == nil else { return }
        activeEngine = .appleLocal
        fallbackReason = String(describing: failure)
        statusText = "Fallback: Apple Local"
        errors.append("Fallback: \(String(describing: failure))")
        let manager = liveManager
        let events = liveEventTask
        liveManager = nil
        liveEventTask = nil
        fallbackDrainTask = Task {
            await manager?.finish()
            await events?.value
        }
    }

    private func loadGlossary(course: CourseDefinition, vaultRoot: URL) -> [String] {
        guard let courseRoot = try? VaultPathSafety.resolve(relativePath: course.vaultPath, under: vaultRoot),
              let text = try? String(
                contentsOf: courseRoot.appendingPathComponent(course.glossaryPath),
                encoding: .utf8
              ) else { return [] }
        return CourseGlossary.parse(text)
    }

    private func beginRunningTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, Task.isCancelled == false else { return }
                self.elapsed = self.accumulatedActiveDuration
                    + (self.activeStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
            }
        }
    }

    private func captureActiveDuration() {
        if let activeStartedAt {
            accumulatedActiveDuration += max(0, Date().timeIntervalSince(activeStartedAt))
        }
        activeStartedAt = nil
        elapsed = accumulatedActiveDuration
    }

    private func resetRuntimeState() async {
        liveEventTask?.cancel()
        timerTask?.cancel()
        subtitleFlushTask?.cancel()
        translationTask?.cancel()
        liveManager = nil
        paths = nil
        startedAt = nil
        activeStartedAt = nil
        accumulatedActiveDuration = 0
        elapsed = 0
        fallbackReason = nil
        translationContext = []
        confusionContext = []
        finalChunkCount = 0
        confusionMarkerCount = 0
        errors = []
        journaledRawIDs = []
        appleFinalTask = nil
        bookmarkTask = nil
        fallbackDrainTask = nil
        transcriptFlushTask = nil
        bookmarks = []
        sessionTranscript = []
        pendingWrites = []
        subtitleFlushTask = nil
        translationTask = nil
        await assembler.reset()
    }

    private func saveSummary(_ summary: SessionSummary) throws {
        let root = writer.applicationSupportRoot.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let name = formatter.string(from: summary.startedAt)
            .replacingOccurrences(of: ":", with: "-") + "-\(summary.course).json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(summary).write(to: root.appendingPathComponent(name), options: [.atomic])
    }

    private func recordError(_ value: String) {
        errors.append(value)
    }
}
