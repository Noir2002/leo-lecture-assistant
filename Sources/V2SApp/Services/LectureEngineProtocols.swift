import Foundation

protocol AudioCaptureEngine: AnyObject {
    func start(source: InputSource) async throws -> AsyncThrowingStream<AudioFrame, Error>
    func pause()
    func resume()
    func stop()
}

protocol TranscriptionEngine: AnyObject {
    var events: AsyncStream<TranscriptEvent> { get }
    func start(course: CourseDefinition, glossary: [String]) async throws
    func ingest(_ frame: AudioFrame) async throws
    func finish() async
}

protocol TranslationEngine: AnyObject {
    func translate(_ request: TranslationRequest) async throws -> TranslationResult
}

protocol SessionWriter: AnyObject {
    func start(course: CourseDefinition, vaultRoot: URL, source: String, engine: String, at: Date) async throws -> LectureSessionPaths
    func journalFinal(id: UUID, text: String, capturedAt: Date) async throws
    func appendChunk(_ chunk: TranscriptChunk) async throws
    func acknowledge(eventIDs: [UUID], at: Date) async throws
    func appendConfusionMarker(at: Date, context: [TranscriptContextEntry]) async throws
    func updateOutline(_ outline: String) async throws
    func finish(at: Date) async throws
}

protocol ReviewGenerator: AnyObject {
    func generate(_ request: ReviewRequest) async throws -> String
}
