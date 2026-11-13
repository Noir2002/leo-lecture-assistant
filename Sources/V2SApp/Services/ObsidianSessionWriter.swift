import Darwin
import Foundation

enum ObsidianWriterError: Error, Equatable {
    case notStarted
    case pendingTranscript
    case invalidVault
    case unsafePath
    case writeFailed(Int32)
}

actor ObsidianSessionWriter: SessionWriter {
    private let fileManager: FileManager
    nonisolated let applicationSupportRoot: URL
    private var course: CourseDefinition?
    private var vaultRoot: URL?
    private var transcriptURL: URL?
    private var lectureURL: URL?
    private var journalURL: URL?
    private var startedAt: Date?

    init(fileManager: FileManager = .default, applicationSupportRoot: URL? = nil) {
        self.fileManager = fileManager
        self.applicationSupportRoot = applicationSupportRoot
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LeoLectureAssistant", isDirectory: true)
    }

    func start(
        course: CourseDefinition,
        vaultRoot: URL,
        source: String,
        engine: String,
        at date: Date = Date()
    ) async throws -> LectureSessionPaths {
        guard VaultDiscoveryService(fileManager: fileManager).isValidVault(vaultRoot) else {
            throw ObsidianWriterError.invalidVault
        }
        let courseRoot = try VaultPathSafety.resolve(relativePath: course.vaultPath, under: vaultRoot)
        guard fileManager.fileExists(atPath: courseRoot.path) else { throw ObsidianWriterError.unsafePath }
        let resources = courseRoot.appendingPathComponent("Resources", isDirectory: true)
        let lectures = courseRoot.appendingPathComponent("Lectures", isDirectory: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: lectures, withIntermediateDirectories: true)

        let glossary = resources.appendingPathComponent("Glossary.md")
        if fileManager.fileExists(atPath: glossary.path) == false {
            try CourseGlossary.emptyTemplate(courseCode: course.code).write(to: glossary, atomically: true, encoding: .utf8)
        }

        let day = Self.dayFormatter.string(from: date)
        let preferredTranscript = resources.appendingPathComponent("\(day) - Transcript.md")
        let transcript = try collisionSafeTranscriptURL(preferredTranscript)
        let lecture = lectures.appendingPathComponent("\(day) - Lecture.md")

        let sessionDirectory = applicationSupportRoot.appendingPathComponent("Sessions/\(day)", isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let journal = sessionDirectory.appendingPathComponent("\(course.code)-\(UUID().uuidString).jsonl")
        fileManager.createFile(atPath: journal.path, contents: nil)

        if fileManager.fileExists(atPath: transcript.path) == false {
            try Self.transcriptHeader(
                course: course,
                date: day,
                source: source,
                engine: engine
            ).write(to: transcript, atomically: true, encoding: .utf8)
        }

        if fileManager.fileExists(atPath: lecture.path) == false {
            try Self.lectureTemplate(course: course, date: day, transcriptName: transcript.deletingPathExtension().lastPathComponent)
                .write(to: lecture, atomically: true, encoding: .utf8)
        } else {
            try ensureManagedSections(in: lecture, transcriptName: transcript.deletingPathExtension().lastPathComponent)
        }

        self.course = course
        self.vaultRoot = vaultRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.transcriptURL = transcript
        self.lectureURL = lecture
        self.journalURL = journal
        self.startedAt = date
        return LectureSessionPaths(transcript: transcript.path, lecture: lecture.path, journal: journal.path)
    }

    func journalFinal(id: UUID, text: String, capturedAt: Date) async throws {
        guard let journalURL else { throw ObsidianWriterError.notStarted }
        let event = JournalEvent(kind: "final", id: id, capturedAt: capturedAt, text: text)
        try appendJSONLine(event, to: journalURL)
    }

    func appendChunk(_ chunk: TranscriptChunk) async throws {
        guard let transcriptURL, let journalURL else { throw ObsidianWriterError.notStarted }
        let block = Self.transcriptBlock(chunk)
        let existing = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
        if existing.contains(block.trimmingCharacters(in: .whitespacesAndNewlines)) == false {
            try appendLocked(block + "\n", to: transcriptURL)
        }
        try acknowledge(eventIDs: chunk.sourceEventIDs, at: chunk.endedAt, journalURL: journalURL)
    }

    func acknowledge(eventIDs: [UUID], at date: Date) async throws {
        guard let journalURL else { throw ObsidianWriterError.notStarted }
        try acknowledge(eventIDs: eventIDs, at: date, journalURL: journalURL)
    }

    /// Returns every finalized transcript event that was journaled but not acknowledged.
    /// All journals for today's course are considered so a crash followed by relaunch
    /// can resume without rewriting an already persisted chunk.
    func pendingFinals() throws -> [PendingJournalFinal] {
        guard let journalURL, let course else { throw ObsidianWriterError.notStarted }
        let directory = journalURL.deletingLastPathComponent()
        let candidates = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix(course.code + "-") }

        var finals: [UUID: PendingJournalFinal] = [:]
        var acknowledged = Set<UUID>()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for candidate in candidates {
            guard let contents = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            for line in contents.split(separator: "\n") {
                guard let data = String(line).data(using: .utf8),
                      let event = try? decoder.decode(JournalEvent.self, from: data) else { continue }
                if event.kind == "ack" {
                    acknowledged.insert(event.id)
                } else if event.kind == "final", let text = event.text {
                    finals[event.id] = PendingJournalFinal(id: event.id, capturedAt: event.capturedAt, text: text)
                }
            }
        }
        return finals.values
            .filter { acknowledged.contains($0.id) == false }
            .sorted { lhs, rhs in
                lhs.capturedAt == rhs.capturedAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.capturedAt < rhs.capturedAt
            }
    }

    func appendConfusionMarker(at date: Date, context: [TranscriptContextEntry]) async throws {
        guard let lectureURL else { throw ObsidianWriterError.notStarted }
        let contextText = context.map { entry in
            let time = Self.clockFormatter.string(from: entry.capturedAt)
            if let chinese = entry.chinese, chinese.isEmpty == false {
                return "[\(time)] FR: \(entry.french)\n[\(time)] ZH: \(chinese)"
            }
            return "[\(time)] FR: \(entry.french)"
        }.joined(separator: "\n")
        let entry = """
        ### \(Self.clockFormatter.string(from: date))

        Context:
        \(contextText)

        Status:
        unresolved
        """
        try appendToManagedBlock(section: "Confusion Markers", identifier: "confusion-markers", text: entry, in: lectureURL)
    }

    func updateOutline(_ outline: String) async throws {
        guard let lectureURL else { throw ObsidianWriterError.notStarted }
        try replaceManagedBlock(section: "Live Outline", identifier: "live-outline", text: outline, in: lectureURL)
    }

    func appendReview(_ review: String, startedAt: Date) throws {
        guard let lectureURL, let journalURL else { throw ObsidianWriterError.notStarted }
        let session = journalURL.deletingPathExtension().lastPathComponent
        let marker = "<!-- leo-review:\(session) -->"
        let section = """

        \(marker)
        ## Fiche de révision / 课后复习 — \(Self.clockFormatter.string(from: startedAt))

        \(review)

        """
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: lectureURL, options: .forReplacing, error: &coordinationError) { url in
            do {
                let current = try String(contentsOf: url, encoding: .utf8)
                guard current.contains(marker) == false else { return }
                try (current + "\n" + section).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    func finish(at date: Date = Date()) async throws {
        guard transcriptURL != nil, let lectureURL, let course else { throw ObsidianWriterError.notStarted }
        let handoff = "Status: pending\n\nRecommended command:\n\nProcess today's \(course.code) lecture."
        try replaceManagedBlock(section: "Codex Handoff", identifier: "codex-handoff", text: handoff, in: lectureURL)
    }

    func currentPaths() -> LectureSessionPaths? {
        guard let transcriptURL, let lectureURL, let journalURL else { return nil }
        return LectureSessionPaths(transcript: transcriptURL.path, lecture: lectureURL.path, journal: journalURL.path)
    }

    private func acknowledge(eventIDs: [UUID], at date: Date, journalURL: URL) throws {
        for id in eventIDs {
            try appendJSONLine(JournalEvent(kind: "ack", id: id, capturedAt: date, text: nil), to: journalURL)
        }
    }

    private func collisionSafeTranscriptURL(_ preferred: URL) throws -> URL {
        guard fileManager.fileExists(atPath: preferred.path) else { return preferred }
        let existing = (try? String(contentsOf: preferred, encoding: .utf8)) ?? ""
        if Self.isLeoTranscript(existing) { return preferred }
        let stem = preferred.deletingPathExtension().lastPathComponent
        for suffix in 2...99 {
            let candidate = preferred.deletingLastPathComponent().appendingPathComponent("\(stem) (\(suffix)).md")
            guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
            let content = (try? String(contentsOf: candidate, encoding: .utf8)) ?? ""
            if Self.isLeoTranscript(content) { return candidate }
        }
        throw ObsidianWriterError.unsafePath
    }

    private func ensureManagedSections(in url: URL, transcriptName: String) throws {
        try ensureManagedBlock(section: "Live Outline", identifier: "live-outline", initial: "", in: url)
        try ensureManagedBlock(section: "Confusion Markers", identifier: "confusion-markers", initial: "", in: url)
        try ensureManagedBlock(section: "Transcript", identifier: "transcript-link", initial: "[[\(transcriptName)]]", in: url)
        try ensureManagedBlock(section: "Codex Handoff", identifier: "codex-handoff", initial: "Status: pending", in: url)
    }

    private func ensureManagedBlock(section: String, identifier: String, initial: String, in url: URL) throws {
        let content = try String(contentsOf: url, encoding: .utf8)
        guard content.contains("<!-- leo-managed:start \(identifier) -->") == false else { return }
        var updated = content
        if updated.hasSuffix("\n") == false { updated += "\n" }
        updated += "\n## \(section)\n\n\(managedBlock(identifier: identifier, text: initial))\n"
        try atomicWrite(updated, to: url)
    }

    private func replaceManagedBlock(section: String, identifier: String, text: String, in url: URL) throws {
        try ensureManagedBlock(section: section, identifier: identifier, initial: "", in: url)
        let content = try String(contentsOf: url, encoding: .utf8)
        let startToken = "<!-- leo-managed:start \(identifier) -->"
        let endToken = "<!-- leo-managed:end \(identifier) -->"
        guard let start = content.range(of: startToken),
              let end = content.range(of: endToken, range: start.upperBound..<content.endIndex) else {
            throw ObsidianWriterError.unsafePath
        }
        let range = start.lowerBound..<end.upperBound
        let updated = content.replacingCharacters(in: range, with: managedBlock(identifier: identifier, text: text))
        try atomicWrite(updated, to: url)
    }

    private func appendToManagedBlock(section: String, identifier: String, text: String, in url: URL) throws {
        try ensureManagedBlock(section: section, identifier: identifier, initial: "", in: url)
        let content = try String(contentsOf: url, encoding: .utf8)
        let startToken = "<!-- leo-managed:start \(identifier) -->"
        let endToken = "<!-- leo-managed:end \(identifier) -->"
        guard let start = content.range(of: startToken),
              let end = content.range(of: endToken, range: start.upperBound..<content.endIndex) else {
            throw ObsidianWriterError.unsafePath
        }
        let current = String(content[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = current.isEmpty ? text : current + "\n\n" + text
        let updated = content.replacingCharacters(
            in: start.lowerBound..<end.upperBound,
            with: managedBlock(identifier: identifier, text: combined)
        )
        try atomicWrite(updated, to: url)
    }

    private func managedBlock(identifier: String, text: String) -> String {
        "<!-- leo-managed:start \(identifier) -->\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n<!-- leo-managed:end \(identifier) -->"
    }

    private func atomicWrite(_ text: String, to url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                try text.data(using: .utf8)?.write(to: coordinatedURL, options: [.atomic])
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private func appendJSONLine<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try appendLocked(String(data: encoder.encode(value), encoding: .utf8)! + "\n", to: url)
    }

    private func appendLocked(_ text: String, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ObsidianWriterError.writeFailed(errno) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ObsidianWriterError.writeFailed(errno) }
        defer { flock(descriptor, LOCK_UN) }
        let data = Data(text.utf8)
        try data.withUnsafeBytes { rawBuffer in
            guard var base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, base, remaining)
                guard count > 0 else { throw ObsidianWriterError.writeFailed(errno) }
                remaining -= count
                base = base.advanced(by: count)
            }
        }
        guard fsync(descriptor) == 0 else { throw ObsidianWriterError.writeFailed(errno) }
    }

    private static func transcriptHeader(
        course: CourseDefinition,
        date: String,
        source: String,
        engine: String
    ) -> String {
        """
        ---
        type: source
        course: \(course.code)
        created: \(date)
        updated: \(date)
        source: \(yamlScalar(source))
        engine: \(yamlScalar(engine))
        ---

        # \(course.code) — Raw Transcript — \(date)
        """
    }

    private static func transcriptBlock(_ chunk: TranscriptChunk) -> String {
        """

        ## \(clockFormatter.string(from: chunk.startedAt))–\(clockFormatter.string(from: chunk.endedAt))

        \(chunk.french.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    private static func isLeoTranscript(_ content: String) -> Bool {
        content.contains("<!-- leo-transcript -->")
            || content.range(of: #"(?m)^# .+ — Raw Transcript — \d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
            || content.range(of: #"(?m)^# .+ — Transcript — \d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private static func yamlScalar(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func lectureTemplate(course: CourseDefinition, date: String, transcriptName: String) -> String {
        """
        ---
        type: lecture
        domain:
          - \(course.domain)
        status: seed
        course:
          - \(course.code)
        created: \(date)
        updated: \(date)
        aliases: []
        ---

        <!-- leo-lecture -->
        # \(course.code) — \(date)

        ## Before Class

        ### 今天要学什么

        ### 我提前不理解的问题

        ## Raw Notes

        这是原始课堂笔记区域。

        Codex 不得主动重写 Raw Notes，除非我明确要求。

        ## Live Outline

        <!-- leo-managed:start live-outline -->

        <!-- leo-managed:end live-outline -->

        ## Teacher Emphasis

        ## New Concepts

        - [[]]

        ## Questions

        ## Confusion Markers

        <!-- leo-managed:start confusion-markers -->

        <!-- leo-managed:end confusion-markers -->

        ## After Class

        ### 我真正理解了什么

        ### 我还不理解什么

        ### 下一步

        ## Transcript

        <!-- leo-managed:start transcript-link -->
        [[\(transcriptName)]]
        <!-- leo-managed:end transcript-link -->

        ## Codex Handoff

        <!-- leo-managed:start codex-handoff -->
        Status: pending
        <!-- leo-managed:end codex-handoff -->
        """
    }

    private struct JournalEvent: Codable {
        let kind: String
        let id: UUID
        let capturedAt: Date
        let text: String?
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_CA_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_CA_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

struct PendingJournalFinal: Equatable, Sendable {
    let id: UUID
    let capturedAt: Date
    let text: String
}
