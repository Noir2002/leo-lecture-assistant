import Foundation

/// Buffers authoritative ASR finals for two independent consumers: short batches
/// for the optional live subtitle translation and larger raw French transcript chunks.
actor TranscriptAssembler {
    struct Configuration: Equatable, Sendable {
        var subtitleMinimum: TimeInterval = 5
        var subtitleTarget: TimeInterval = 8
        var subtitleMaximum: TimeInterval = 10
        var chunkMinimum: TimeInterval = 30
        var chunkTarget: TimeInterval = 45
        var chunkMaximum: TimeInterval = 60
        var chunkMinimumWords = 80
        var chunkMaximumWords = 180
        var pauseBoundary: TimeInterval = 12
        var duplicateWindow: TimeInterval = 60

        static let lectureDefault = Configuration()
    }

    private struct PendingBuffer: Sendable {
        var events: [RawFinalEvent]
        var french: String
        var startedAt: Date
        var endedAt: Date
    }

    private let configuration: Configuration
    private var pendingSubtitle: PendingBuffer?
    private var pendingChunk: PendingBuffer?
    private var readyChunks: [TranscriptChunk] = []
    private var latestTextByEventID: [UUID: String] = [:]
    private var recentStableTokens: [String] = []
    private var recentStableEndedAt = Date.distantPast

    init(configuration: Configuration = .lectureDefault) {
        self.configuration = configuration
    }

    /// Accepts only stable/final ASR text. Adjacent overlap is removed before the
    /// text reaches either the UI batch or the durable transcript buffer.
    func ingest(_ event: RawFinalEvent) -> TranscriptAssemblerEvent {
        let trimmed = Self.clean(event.text)
        guard trimmed.isEmpty == false else { return .duplicateDropped(event.id) }

        if event.capturedAt.timeIntervalSince(recentStableEndedAt) > configuration.duplicateWindow {
            recentStableTokens.removeAll(keepingCapacity: true)
            latestTextByEventID.removeAll(keepingCapacity: true)
        }

        let newTokens = Self.tokens(trimmed)
        var acceptedText = trimmed
        if let previousText = latestTextByEventID[event.id] {
            let previousTokens = Self.tokens(previousText)
            if previousTokens == newTokens {
                return .duplicateDropped(event.id)
            }
            if Self.hasPrefix(newTokens, prefix: previousTokens) {
                acceptedText = Self.removingLeadingWords(previousTokens.count, from: trimmed)
            }
        }

        if acceptedText == trimmed {
            let overlap = Self.overlapCount(previous: recentStableTokens, next: newTokens)
            if Self.isCertainOverlap(
                overlap,
                previousCount: recentStableTokens.count,
                nextCount: newTokens.count
            ) {
                acceptedText = Self.removingLeadingWords(overlap, from: trimmed)
            }
        }

        acceptedText = Self.clean(acceptedText)
        guard acceptedText.isEmpty == false else { return .duplicateDropped(event.id) }

        if let pendingChunk,
           shouldBreakAtPause(before: event, pending: pendingChunk) {
            readyChunks.append(Self.makeChunk(from: pendingChunk))
            self.pendingChunk = nil
        }

        let acceptedEvent = RawFinalEvent(
            id: event.id,
            capturedAt: event.capturedAt,
            source: event.source,
            text: acceptedText
        )
        append(acceptedEvent, to: &pendingSubtitle)
        append(acceptedEvent, to: &pendingChunk)

        latestTextByEventID[event.id] = trimmed
        recentStableTokens.append(contentsOf: Self.tokens(acceptedText))
        if recentStableTokens.count > 240 {
            recentStableTokens.removeFirst(recentStableTokens.count - 240)
        }
        recentStableEndedAt = event.capturedAt

        if let pendingChunk, chunkIsDue(pendingChunk) {
            readyChunks.append(Self.makeChunk(from: pendingChunk))
            self.pendingChunk = nil
        }
        return .accepted(acceptedEvent)
    }

    func subtitleBatchIfDue(now: Date, force: Bool = false) -> SubtitleBatch? {
        guard let pendingSubtitle else { return nil }
        let age = max(0, now.timeIntervalSince(pendingSubtitle.startedAt))
        let sentenceReady = Self.endsSentence(pendingSubtitle.french)
        let due = force
            || age >= configuration.subtitleMaximum
            || age >= configuration.subtitleTarget
            || (age >= configuration.subtitleMinimum && sentenceReady)
        guard due else { return nil }

        self.pendingSubtitle = nil
        return SubtitleBatch(
            sourceEventIDs: Self.uniqued(pendingSubtitle.events.map(\.id)),
            startedAt: pendingSubtitle.startedAt,
            endedAt: pendingSubtitle.endedAt,
            french: pendingSubtitle.french
        )
    }

    func transcriptChunkIfDue(now: Date, force: Bool = false) -> TranscriptChunk? {
        if readyChunks.isEmpty == false {
            return readyChunks.removeFirst()
        }
        guard let pendingChunk else { return nil }
        let elapsed = max(0, now.timeIntervalSince(pendingChunk.startedAt))
        guard force || elapsed >= configuration.chunkMaximum || chunkIsDue(pendingChunk) else {
            return nil
        }
        self.pendingChunk = nil
        return Self.makeChunk(from: pendingChunk)
    }

    func hasPendingSubtitle() -> Bool { pendingSubtitle != nil }
    func hasPendingChunk() -> Bool { pendingChunk != nil || readyChunks.isEmpty == false }

    func reset() {
        pendingSubtitle = nil
        pendingChunk = nil
        readyChunks.removeAll()
        latestTextByEventID.removeAll()
        recentStableTokens.removeAll()
        recentStableEndedAt = .distantPast
    }

    private func append(
        _ event: RawFinalEvent,
        to buffer: inout PendingBuffer?
    ) {
        if var current = buffer {
            if current.events.contains(where: { $0.id == event.id }) == false {
                current.events.append(event)
            }
            current.french = Self.joinFrench([current.french, event.text])
            current.endedAt = max(current.endedAt, event.capturedAt)
            buffer = current
        } else {
            buffer = PendingBuffer(
                events: [event],
                french: event.text,
                startedAt: event.capturedAt,
                endedAt: event.capturedAt
            )
        }
    }

    private func shouldBreakAtPause(before event: RawFinalEvent, pending: PendingBuffer) -> Bool {
        let gap = event.capturedAt.timeIntervalSince(pending.endedAt)
        let duration = pending.endedAt.timeIntervalSince(pending.startedAt)
        return gap >= configuration.pauseBoundary
            && (duration >= configuration.chunkMinimum
                || Self.tokens(pending.french).count >= configuration.chunkMinimumWords)
    }

    private func chunkIsDue(_ pending: PendingBuffer) -> Bool {
        let duration = max(0, pending.endedAt.timeIntervalSince(pending.startedAt))
        let words = Self.tokens(pending.french).count
        let naturalBoundary = Self.endsSentence(pending.french)
        return duration >= configuration.chunkMaximum
            || words >= configuration.chunkMaximumWords
            || (duration >= configuration.chunkTarget && naturalBoundary)
            || (duration >= configuration.chunkMinimum
                && words >= configuration.chunkMinimumWords
                && naturalBoundary)
    }

    private static func makeChunk(from pending: PendingBuffer) -> TranscriptChunk {
        TranscriptChunk(
            sourceEventIDs: uniqued(pending.events.map(\.id)),
            startedAt: pending.startedAt,
            endedAt: pending.endedAt,
            french: pending.french
        )
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords]) { substring, _, _, _ in
            guard let substring else { return }
            result.append(
                substring.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "fr_FR")
                )
            )
        }
        return result
    }

    private static func hasPrefix(_ value: [String], prefix: [String]) -> Bool {
        prefix.isEmpty == false
            && value.count > prefix.count
            && Array(value.prefix(prefix.count)) == prefix
    }

    private static func overlapCount(previous: [String], next: [String]) -> Int {
        guard previous.isEmpty == false, next.isEmpty == false else { return 0 }
        for count in stride(from: min(previous.count, next.count), through: 1, by: -1) {
            if Array(previous.suffix(count)) == Array(next.prefix(count)) { return count }
        }
        return 0
    }

    private static func isCertainOverlap(_ overlap: Int, previousCount: Int, nextCount: Int) -> Bool {
        guard overlap > 0 else { return false }
        if overlap >= 3 { return true }
        return overlap == previousCount && previousCount <= 2 && nextCount > previousCount
    }

    private static func removingLeadingWords(_ count: Int, from text: String) -> String {
        guard count > 0 else { return clean(text) }
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords]) { _, range, _, _ in
            ranges.append(range)
        }
        guard ranges.count > count else { return "" }
        var remainder = String(text[ranges[count].lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = remainder.unicodeScalars.first,
              CharacterSet.punctuationCharacters.contains(first) {
            remainder.removeFirst()
            remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return remainder
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = clean(text).last else { return false }
        return ".?!。！？…".contains(last)
    }

    private static func joinFrench(_ values: [String]) -> String {
        values.map(clean).filter { $0.isEmpty == false }.joined(separator: " ")
    }

    private static func uniqued(_ values: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return values.filter { seen.insert($0).inserted }
    }
}
