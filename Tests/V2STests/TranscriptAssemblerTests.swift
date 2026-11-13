import Foundation
import XCTest
@testable import v2s

final class TranscriptAssemblerTests: XCTestCase {
    func testInterimSizedSubtitleBatchDoesNotFlushRawChunk() async throws {
        let assembler = TranscriptAssembler()
        let start = fixedDate(10, 0, 0)
        _ = await assembler.ingest(
            RawFinalEvent(id: UUID(), capturedAt: start, source: .gemini, text: "Bonjour, nous commençons.")
        )

        let subtitle = await assembler.subtitleBatchIfDue(now: start.addingTimeInterval(8))
        XCTAssertEqual(subtitle?.french, "Bonjour, nous commençons.")
        let prematureChunk = await assembler.transcriptChunkIfDue(now: start.addingTimeInterval(8))
        XCTAssertNil(prematureChunk)

        let finalChunk = await assembler.transcriptChunkIfDue(now: start.addingTimeInterval(8), force: true)
        XCTAssertEqual(finalChunk?.french, "Bonjour, nous commençons.")
    }

    func testAdjacentSuffixPrefixOverlapIsRemoved() async throws {
        let assembler = TranscriptAssembler()
        let start = fixedDate(11, 0, 0)
        let previous = "Nous allons maintenant parler du traitement automatique de la langue"
        let next = "du traitement automatique de la langue et des modèles statistiques"

        _ = await assembler.ingest(
            RawFinalEvent(id: UUID(), capturedAt: start, source: .gemini, text: previous)
        )
        _ = await assembler.ingest(
            RawFinalEvent(id: UUID(), capturedAt: start.addingTimeInterval(8), source: .gemini, text: next)
        )

        let dueChunk = await assembler.transcriptChunkIfDue(now: start.addingTimeInterval(8), force: true)
        let chunk = try XCTUnwrap(dueChunk)
        XCTAssertEqual(chunk.french, previous + " et des modèles statistiques")
    }

    func testNonOverlappingTextIsKeptInFull() async throws {
        let assembler = TranscriptAssembler()
        let start = fixedDate(12, 0, 0)
        let previous = "Nous allons parler de tokenisation."
        let next = "Ensuite, nous verrons la normalisation."

        _ = await assembler.ingest(
            RawFinalEvent(id: UUID(), capturedAt: start, source: .gemini, text: previous)
        )
        _ = await assembler.ingest(
            RawFinalEvent(id: UUID(), capturedAt: start.addingTimeInterval(8), source: .gemini, text: next)
        )

        let dueChunk = await assembler.transcriptChunkIfDue(now: start.addingTimeInterval(8), force: true)
        let chunk = try XCTUnwrap(dueChunk)
        XCTAssertEqual(chunk.french, previous + " " + next)
    }

    func testWeakTwoWordOverlapIsKeptConservatively() async throws {
        let assembler = TranscriptAssembler()
        let start = fixedDate(13, 0, 0)
        let previous = "Le professeur revient sur la qualité"
        let next = "la qualité dépend aussi du contexte."

        _ = await assembler.ingest(
            RawFinalEvent(id: UUID(), capturedAt: start, source: .gemini, text: previous)
        )
        _ = await assembler.ingest(
            RawFinalEvent(id: UUID(), capturedAt: start.addingTimeInterval(8), source: .gemini, text: next)
        )

        let dueChunk = await assembler.transcriptChunkIfDue(now: start.addingTimeInterval(8), force: true)
        let chunk = try XCTUnwrap(dueChunk)
        XCTAssertEqual(chunk.french, previous + " " + next)
    }

    func testSameEventExtensionAppendsOnlyNewStableWords() async throws {
        let assembler = TranscriptAssembler()
        let start = fixedDate(14, 0, 0)
        let id = UUID()
        _ = await assembler.ingest(
            RawFinalEvent(id: id, capturedAt: start, source: .apple, text: "Bonjour aujourd'hui")
        )
        _ = await assembler.ingest(
            RawFinalEvent(
                id: id,
                capturedAt: start.addingTimeInterval(4),
                source: .apple,
                text: "Bonjour aujourd'hui nous allons étudier la tokenisation."
            )
        )

        let dueChunk = await assembler.transcriptChunkIfDue(now: start.addingTimeInterval(4), force: true)
        let chunk = try XCTUnwrap(dueChunk)
        XCTAssertEqual(chunk.french, "Bonjour aujourd'hui nous allons étudier la tokenisation.")
        XCTAssertEqual(chunk.sourceEventIDs, [id])
    }

    func testNaturalChunkFlushesAroundFortyFiveSeconds() async throws {
        let assembler = TranscriptAssembler()
        let start = fixedDate(15, 0, 0)
        for index in 0...5 {
            _ = await assembler.ingest(
                RawFinalEvent(
                    id: UUID(),
                    capturedAt: start.addingTimeInterval(Double(index * 9)),
                    source: .gemini,
                    text: "Phrase finale numéro \(index)."
                )
            )
        }

        let dueChunk = await assembler.transcriptChunkIfDue(now: start.addingTimeInterval(45))
        let chunk = try XCTUnwrap(dueChunk)
        XCTAssertEqual(chunk.startedAt, start)
        XCTAssertEqual(chunk.endedAt, start.addingTimeInterval(45))
        XCTAssertEqual(chunk.sourceEventIDs.count, 6)
        XCTAssertTrue(chunk.french.contains("Phrase finale numéro 0."))
        XCTAssertTrue(chunk.french.contains("Phrase finale numéro 5."))
    }

    func testExactDuplicateExpiresOutsideWindow() async throws {
        var configuration = TranscriptAssembler.Configuration.lectureDefault
        configuration.duplicateWindow = 30
        let assembler = TranscriptAssembler(configuration: configuration)
        let start = fixedDate(16, 0, 0)
        let text = "La qualité est importante."

        _ = await assembler.ingest(
            RawFinalEvent(id: UUID(), capturedAt: start, source: .gemini, text: text)
        )
        let immediateID = UUID()
        let immediate = await assembler.ingest(
            RawFinalEvent(id: immediateID, capturedAt: start.addingTimeInterval(12), source: .gemini, text: text)
        )
        XCTAssertEqual(immediate, .duplicateDropped(immediateID))

        let later = await assembler.ingest(
            RawFinalEvent(id: UUID(), capturedAt: start.addingTimeInterval(43), source: .gemini, text: text)
        )
        guard case .accepted = later else { return XCTFail("Expected a new final outside the deduplication window") }
        let chunk = await assembler.transcriptChunkIfDue(now: start.addingTimeInterval(43), force: true)
        XCTAssertEqual(chunk?.french.components(separatedBy: text).count, 3)
    }

    private func fixedDate(_ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 9
        components.day = 1
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date!
    }
}
