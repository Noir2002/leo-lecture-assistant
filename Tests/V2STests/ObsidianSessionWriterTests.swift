import Foundation
import XCTest
@testable import v2s

final class ObsidianSessionWriterTests: XCTestCase {
    private let course = LeoConfiguration.defaultCourses.first { $0.code == "IFT-7022" }!

    func testTranscriptAppendIsFrenchOnlyWithoutTrackingMetadata() async throws {
        let environment = try makeEnvironment()
        let writer = ObsidianSessionWriter(applicationSupportRoot: environment.support)
        let date = fixedDate(12, 0, 0)
        let paths = try await writer.start(course: course, vaultRoot: environment.vault, source: "Mock PCM", engine: "Apple Local", at: date)
        let id = UUID()
        try await writer.journalFinal(id: id, text: "La qualité logicielle.", capturedAt: date)
        let chunk = TranscriptChunk(
            sourceEventIDs: [id],
            startedAt: date,
            endedAt: date.addingTimeInterval(45),
            french: "La qualité logicielle."
        )
        try await writer.appendChunk(chunk)
        try await writer.appendChunk(chunk)
        let transcript = try String(contentsOfFile: paths.transcript, encoding: .utf8)
        XCTAssertFalse(transcript.contains("leo-paragraph"))
        XCTAssertFalse(transcript.contains("leo-event"))
        XCTAssertFalse(transcript.contains(id.uuidString))
        XCTAssertFalse(transcript.contains("### FR"))
        XCTAssertFalse(transcript.contains("### ZH"))
        XCTAssertFalse(transcript.contains("软件质量"))
        XCTAssertTrue(transcript.range(of: #"## \d{2}:\d{2}:\d{2}–\d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil)
        XCTAssertTrue(transcript.contains("## 12:00:00–12:00:45\n\nLa qualité logicielle."))
        XCTAssertEqual(transcript.components(separatedBy: "La qualité logicielle.").count - 1, 1)
        XCTAssertTrue(transcript.contains("source: 'Mock PCM'"))
        XCTAssertTrue(transcript.contains("engine: 'Apple Local'"))
        let pending = try await writer.pendingFinals()
        XCTAssertTrue(pending.isEmpty)
    }

    func testPendingJournalRecoveryReturnsOnlyUnacknowledgedFinals() async throws {
        let environment = try makeEnvironment()
        let writer = ObsidianSessionWriter(applicationSupportRoot: environment.support)
        _ = try await writer.start(course: course, vaultRoot: environment.vault, source: "Mock", engine: "Gemini Smart", at: fixedDate(9, 0, 0))
        let pendingID = UUID()
        try await writer.journalFinal(id: pendingID, text: "Un segment final.", capturedAt: fixedDate(9, 0, 1))
        let recovered = try await writer.pendingFinals()
        XCTAssertEqual(recovered, [PendingJournalFinal(id: pendingID, capturedAt: fixedDate(9, 0, 1), text: "Un segment final.")])
    }

    func testChunkAcknowledgesMultipleRawEventsAndRecoversCrashAfterVaultAppend() async throws {
        let environment = try makeEnvironment()
        let writer = ObsidianSessionWriter(applicationSupportRoot: environment.support)
        let paths = try await writer.start(
            course: course,
            vaultRoot: environment.vault,
            source: "Mock",
            engine: "Gemini Smart",
            at: fixedDate(9, 30, 0)
        )
        let ids = [UUID(), UUID()]
        try await writer.journalFinal(id: ids[0], text: "Première phrase.", capturedAt: fixedDate(9, 30, 1))
        try await writer.journalFinal(id: ids[1], text: "Deuxième phrase.", capturedAt: fixedDate(9, 30, 8))

        let simulatedDurableBlock = """

        ## 09:30:01–09:30:08

        Première phrase. Deuxième phrase.
        """
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: paths.transcript))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(simulatedDurableBlock.utf8))
        try handle.close()

        let replayed = TranscriptChunk(
            sourceEventIDs: ids,
            startedAt: fixedDate(9, 30, 1),
            endedAt: fixedDate(9, 30, 8),
            french: "Première phrase. Deuxième phrase."
        )
        try await writer.appendChunk(replayed)
        let pendingAfterReplay = try await writer.pendingFinals()
        XCTAssertTrue(pendingAfterReplay.isEmpty)
        let transcript = try String(contentsOfFile: paths.transcript, encoding: .utf8)
        XCTAssertEqual(transcript.components(separatedBy: "Première phrase. Deuxième phrase.").count - 1, 1)
    }

    func testManagedOutlinePreservesRawNotesAndConfusionContext() async throws {
        let environment = try makeEnvironment()
        let lecture = environment.courseRoot.appendingPathComponent("Lectures/2026-09-01 - Lecture.md")
        try FileManager.default.createDirectory(at: lecture.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "# Existing\n\n## Raw Notes\n\nUSER BYTES 你好\n"
        try original.write(to: lecture, atomically: true, encoding: .utf8)

        let writer = ObsidianSessionWriter(applicationSupportRoot: environment.support)
        _ = try await writer.start(course: course, vaultRoot: environment.vault, source: "Mock", engine: "Apple Local", at: fixedDate(10, 0, 0))
        try await writer.updateOutline("1. Assurance qualité\n  1.1 Tests")
        try await writer.updateOutline("1. Qualité\n  1.1 Vérification")
        try await writer.appendConfusionMarker(
            at: fixedDate(10, 2, 0),
            context: [TranscriptContextEntry(capturedAt: fixedDate(10, 1, 30), french: "Pourquoi?", chinese: "为什么？")]
        )
        let updated = try String(contentsOf: lecture, encoding: .utf8)
        XCTAssertTrue(updated.contains("## Raw Notes\n\nUSER BYTES 你好"))
        XCTAssertFalse(updated.contains("1. Assurance qualité"))
        XCTAssertTrue(updated.contains("1. Qualité"))
        XCTAssertTrue(updated.contains("Status:\nunresolved"))
        XCTAssertTrue(updated.contains("ZH: 为什么？"))
    }

    func testNinetySecondConfusionWindow() {
        let now = fixedDate(11, 0, 0)
        let entries = [
            TranscriptContextEntry(capturedAt: now.addingTimeInterval(-91), french: "old", chinese: nil),
            TranscriptContextEntry(capturedAt: now.addingTimeInterval(-90), french: "boundary", chinese: nil),
            TranscriptContextEntry(capturedAt: now.addingTimeInterval(-2), french: "recent", chinese: "最近"),
        ]
        XCTAssertEqual(TranscriptContextWindow.recent(entries, now: now).map(\.french), ["boundary", "recent"])
    }

    func testNonLeoTranscriptCollisionUsesSafeSuffix() async throws {
        let environment = try makeEnvironment()
        let resources = environment.courseRoot.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let existing = resources.appendingPathComponent("2026-09-01 - Transcript.md")
        try "USER FILE".write(to: existing, atomically: true, encoding: .utf8)
        let writer = ObsidianSessionWriter(applicationSupportRoot: environment.support)
        let paths = try await writer.start(course: course, vaultRoot: environment.vault, source: "Mock", engine: "Apple Local", at: fixedDate(8, 0, 0))
        XCTAssertTrue(paths.transcript.hasSuffix("2026-09-01 - Transcript (2).md"))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "USER FILE")
    }

    func testLegacyBilingualTranscriptIsPreserved() async throws {
        let environment = try makeEnvironment()
        let resources = environment.courseRoot.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let existing = resources.appendingPathComponent("2026-09-01 - Transcript.md")
        let eventID = UUID()
        let legacy = """
        ---
        type: source
        course:
          - IFT-7022
        created: 2026-09-01
        ---

        <!-- leo-transcript -->
        # IFT-7022 — Transcript — 2026-09-01

        ## Session 1

        Start: 09:00:00
        Course: IFT-7022
        Source: Microphone
        Engine: Gemini Smart

        ---

        <!-- leo-paragraph:\(UUID().uuidString) -->
        <!-- leo-event:\(eventID.uuidString) -->
        ## 09:00:01–09:00:45

        ### FR

        Nous allons parler de tokenisation.

        ### ZH

        我们将讨论分词。

        ---
        """
        try legacy.write(to: existing, atomically: true, encoding: .utf8)

        let writer = ObsidianSessionWriter(applicationSupportRoot: environment.support)
        let paths = try await writer.start(
            course: course,
            vaultRoot: environment.vault,
            source: "MacBook Air Microphone",
            engine: "Gemini",
            at: fixedDate(9, 0, 0)
        )

        let transcript = try String(contentsOfFile: paths.transcript, encoding: .utf8)
        XCTAssertEqual(transcript, legacy)
    }

    func testMockFrenchPCMSmokePipeline() async throws {
        let environment = try makeEnvironment()
        let writer = ObsidianSessionWriter(applicationSupportRoot: environment.support)
        let paths = try await writer.start(course: course, vaultRoot: environment.vault, source: "Synthesized French PCM", engine: "Mock", at: fixedDate(14, 0, 0))
        let id = UUID()
        try await writer.journalFinal(id: id, text: "Bonjour, nous étudions le langage naturel.", capturedAt: fixedDate(14, 0, 1))
        try await writer.appendChunk(
            TranscriptChunk(
                sourceEventIDs: [id],
                startedAt: fixedDate(14, 0, 1),
                endedAt: fixedDate(14, 0, 9),
                french: "Bonjour, nous étudions le langage naturel."
            )
        )
        try await writer.updateOutline("1. Traitement automatique de la langue naturelle")
        try await writer.finish(at: fixedDate(14, 0, 10))
        let transcript = try String(contentsOfFile: paths.transcript, encoding: .utf8)
        XCTAssertTrue(transcript.contains("Bonjour, nous étudions le langage naturel."))
        XCTAssertFalse(transcript.contains("你好，我们学习自然语言。"))
        XCTAssertTrue(try String(contentsOfFile: paths.lecture, encoding: .utf8).contains("Status: pending"))
    }

    @MainActor
    func testFinishSendsOnlyCurrentSessionWithFreshBookmarkAndPreservesNotes() async throws {
        let environment = try makeEnvironment()
        let date = fixedDate(13, 0, 0)
        let support = environment.support
        let writer = ObsidianSessionWriter(applicationSupportRoot: support)
        let store = LeoConfigurationStore(fileURL: support.appendingPathComponent("config.json"))
        var config = LeoConfiguration.default
        config.vaultPath = environment.vault.path
        config.selectedCourse = course.code
        config.engineMode = .appleLocal
        config.freeTierConfirmed = true
        config.reviewAfterAppleLocal = true
        store.save(config)
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-only")
        let review = StubReviewGenerator()
        let coordinator = LectureSessionCoordinator(configStore: store, credentialStore: credentials, writer: writer, reviewGenerator: review)

        let prior = try await writer.start(
            course: course, vaultRoot: environment.vault, source: "Prior class", engine: "Apple Local",
            at: fixedDate(12, 0, 0)
        )
        try await writer.journalFinal(id: UUID(), text: "Un ancien cours.", capturedAt: fixedDate(12, 0, 10))
        let lecture = URL(fileURLWithPath: prior.lecture)
        let original = try String(contentsOf: lecture, encoding: .utf8)
        try (original + "\n\nUne annotation privée.").write(to: lecture, atomically: true, encoding: .utf8)

        try await coordinator.start(sourceName: "Fixture", at: date)
        coordinator.recordAppleFinal(id: UUID(), french: "Voici les vecteurs.", capturedAt: date.addingTimeInterval(1))
        coordinator.recordAppleFinal(id: UUID(), french: "Voici les vecteurs.", capturedAt: date.addingTimeInterval(2))
        coordinator.markConfusion(at: date.addingTimeInterval(3))
        coordinator.recordAppleFinal(id: UUID(), french: "Puis on calcule la similarité.", capturedAt: date.addingTimeInterval(4))
        let summary = try await coordinator.finish(at: date.addingTimeInterval(5))

        XCTAssertEqual(summary.reviewStatus, "Gemini review saved")
        XCTAssertEqual(review.requests.count, 1)
        let request = try XCTUnwrap(review.requests.first)
        XCTAssertEqual(request.transcript.map(\.french), ["Voici les vecteurs. Puis on calcule la similarité."])
        XCTAssertEqual(request.bookmarks.first?.context.map(\.french), ["Voici les vecteurs."])
        let saved = try String(contentsOf: lecture, encoding: .utf8)
        XCTAssertTrue(saved.contains("Une annotation privée."))
        XCTAssertTrue(saved.contains("Fiche de révision"))
        let raw = try String(contentsOfFile: summary.transcriptPath, encoding: .utf8)
        XCTAssertTrue(raw.contains("Un ancien cours."))
        XCTAssertTrue(raw.contains("Puis on calcule la similarité."))
        XCTAssertFalse(raw.contains("Résumé bilingue"))
    }

    @MainActor
    func testFinishKeepsTranscriptOnReviewFailure() async throws {
        let environment = try makeEnvironment()
        let support = environment.support
        let writer = ObsidianSessionWriter(applicationSupportRoot: support)
        let store = LeoConfigurationStore(fileURL: support.appendingPathComponent("config.json"))
        var config = LeoConfiguration.default
        config.vaultPath = environment.vault.path
        config.selectedCourse = course.code
        config.engineMode = .appleLocal
        config.freeTierConfirmed = true
        config.reviewAfterAppleLocal = true
        store.save(config)
        let credentials = InMemoryCredentialStore()
        try credentials.save("test-only")
        let review = StubReviewGenerator()
        review.error = EngineFailure.quota
        let coordinator = LectureSessionCoordinator(configStore: store, credentialStore: credentials, writer: writer, reviewGenerator: review)
        let date = fixedDate(13, 0, 0)
        try await coordinator.start(sourceName: "Fixture", at: date)
        coordinator.recordAppleFinal(id: UUID(), french: "Une phrase à préserver.", capturedAt: date.addingTimeInterval(1))
        let summary = try await coordinator.finish(at: date.addingTimeInterval(2))
        XCTAssertEqual(coordinator.state, .saved)
        XCTAssertEqual(summary.reviewStatus, "Transcript saved · Gemini review unavailable")
        XCTAssertTrue(try String(contentsOfFile: summary.transcriptPath, encoding: .utf8).contains("Une phrase à préserver."))
        XCTAssertFalse(try String(contentsOfFile: summary.lecturePath, encoding: .utf8).contains("Fiche de révision"))
    }

    func testRealGeminiReviewWithSyntheticLectureIsOptIn() async throws {
        guard ProcessInfo.processInfo.environment["LEO_RUN_GEMINI_INTEGRATION"] == "1" else {
            throw XCTSkip("Set LEO_RUN_GEMINI_INTEGRATION=1 and configure Keychain to run")
        }
        let store = GeminiCredentialStore()
        guard store.isConfigured else { throw XCTSkip("Gemini Auth Key is not configured in Keychain") }
        let start = fixedDate(14, 0, 0)
        let text = "La précision est la proportion de vrais positifs parmi les prédictions positives. Le rappel rapporte les vrais positifs à tous les positifs réels."
        let review = try await GeminiReviewGenerator(client: GeminiAPIClient(credentialStore: store), costGuard: CostGuard())
            .generate(ReviewRequest(
                course: course,
                glossary: ["précision", "rappel"],
                transcript: [TranscriptChunk(sourceEventIDs: [UUID()], startedAt: start, endedAt: start.addingTimeInterval(20), french: text)],
                bookmarks: [LectureBookmark(capturedAt: start.addingTimeInterval(25),
                    context: [TranscriptContextEntry(capturedAt: start, french: text, chinese: nil)])]
            ))
        XCTAssertTrue(review.contains("课程大纲"))
        XCTAssertTrue(review.contains("核心概念"))
        XCTAssertTrue(review.contains("没听懂"))
        XCTAssertNotNil(review.range(of: #"\p{Han}"#, options: .regularExpression))
    }

    func testGeminiIntegrationIsOptInAndNeverReadsDotEnv() async throws {
        guard ProcessInfo.processInfo.environment["LEO_RUN_GEMINI_INTEGRATION"] == "1" else {
            throw XCTSkip("Set LEO_RUN_GEMINI_INTEGRATION=1 and configure Keychain to run")
        }
        let store = GeminiCredentialStore()
        guard store.isConfigured else { throw XCTSkip("Gemini Auth Key is not configured in Keychain") }
        let client = GeminiAPIClient(credentialStore: store)
        try await client.testConnection()
        let token = try await client.ephemeralToken(course: course, glossary: ["rappel"])
        XCTAssertFalse(token.isEmpty)
    }

    private func makeEnvironment() throws -> (vault: URL, courseRoot: URL, support: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let vault = root.appendingPathComponent("Leo-Knowledge", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        for marker in VaultDiscoveryService.requiredMarkers {
            let url = vault.appendingPathComponent(marker)
            if marker.contains(".") { try Data().write(to: url) }
            else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        }
        let courseRoot = vault.appendingPathComponent(course.vaultPath, isDirectory: true)
        try FileManager.default.createDirectory(at: courseRoot, withIntermediateDirectories: true)
        let support = root.appendingPathComponent("Support", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (vault, courseRoot, support)
    }

    private func fixedDate(_ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = 2026
        components.month = 9
        components.day = 1
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date!
    }
}

private final class StubReviewGenerator: ReviewGenerator {
    var requests: [ReviewRequest] = []
    var error: Error?

    func generate(_ request: ReviewRequest) async throws -> String {
        requests.append(request)
        if let error { throw error }
        return "Résumé bilingue / 双语总结"
    }
}
