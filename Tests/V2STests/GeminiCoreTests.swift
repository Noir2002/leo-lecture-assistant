import AVFoundation
import Foundation
import XCTest
@testable import v2s

final class GeminiCoreTests: XCTestCase {
    func testRotationStateMachineHandover() {
        var machine = GeminiRotationStateMachine()
        XCTAssertEqual(machine.connected(), 1)
        XCTAssertEqual(machine.state, .current(1))
        XCTAssertEqual(machine.preconnected(), 2)
        XCTAssertEqual(machine.state, .preconnected(current: 1, next: 2))
        XCTAssertEqual(machine.rotate()?.old, 1)
        XCTAssertEqual(machine.state, .draining(old: 1, current: 2))
        machine.drained()
        XCTAssertEqual(machine.state, .current(2))
    }

    func testCostGuardRejectsInterimAndCircuitBreaksOnQuota() async throws {
        let guardrail = CostGuard()
        do {
            try await guardrail.authorize(.translation, finalTranscript: false)
            XCTFail("Interim should never be authorized")
        } catch {}
        await guardrail.record(.quota)
        do {
            try await guardrail.authorize(.translation, finalTranscript: true)
            XCTFail("Quota must circuit-break cloud requests")
        } catch let error as EngineFailure {
            XCTAssertEqual(error, .quota)
        }
    }

    func testOutlineRateLimit() async throws {
        let guardrail = CostGuard(outlineInterval: 600)
        let now = Date()
        try await guardrail.authorize(.outline, finalTranscript: true, now: now)
        do {
            try await guardrail.authorize(.outline, finalTranscript: true, now: now.addingTimeInterval(599))
            XCTFail("Second outline inside ten minutes must fail")
        } catch {}
    }

    func testStrictTranslationDecodeAndFallbackExtraction() throws {
        let direct = Data(#"{"correctedFrench":"qualité","chineseTranslation":"质量"}"#.utf8)
        XCTAssertEqual(try GeminiTranslationEngine.decode(direct).chineseTranslation, "质量")
        let wrappedText = "prefix " + #"{"correctedFrench":"test","chineseTranslation":"测试"}"# + " suffix"
        let wrapped = Data(wrappedText.utf8)
        XCTAssertEqual(try GeminiTranslationEngine.decode(wrapped).correctedFrench, "test")
        XCTAssertThrowsError(try GeminiTranslationEngine.decode(Data(#"{"correctedFrench":""}"#.utf8)))
        XCTAssertThrowsError(try GeminiTranslationEngine.decode(Data(#"{"correctedFrench":"test","chineseTranslation":"测试","extra":true}"#.utf8)))
    }

    func testOnlyFinalTranscriptIsAuthoritative() {
        let now = Date()
        XCTAssertFalse(TranscriptEvent.interim(text: "draft", capturedAt: now).isAuthoritativeFinal)
        XCTAssertTrue(TranscriptEvent.final(text: "final", capturedAt: now).isAuthoritativeFinal)
    }

    func testThreeMalformedResponsesOpenCircuit() async throws {
        let guardrail = CostGuard()
        await guardrail.record(.malformedResponse)
        await guardrail.record(.malformedResponse)
        var disabledReason = await guardrail.cloudDisabledReason
        XCTAssertNil(disabledReason)
        await guardrail.record(.malformedResponse)
        disabledReason = await guardrail.cloudDisabledReason
        XCTAssertEqual(disabledReason, .malformedResponse)
    }

    func testCredentialStoreAbstractionNeverNeedsKeychainInUnitTests() throws {
        let store = InMemoryCredentialStore()
        XCTAssertFalse(store.isConfigured)
        try store.save("test-only-not-a-real-key")
        XCTAssertTrue(store.isConfigured)
        XCTAssertEqual(try store.read(), "test-only-not-a-real-key")
        try store.delete()
        XCTAssertNil(try store.read())
    }

    func testPCMConverterProducesMono16kInt16() throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        for channel in 0..<2 {
            for sample in 0..<4_800 { buffer.floatChannelData![channel][sample] = 0.1 }
        }
        let data = try PCM16Converter.convert(buffer)
        XCTAssertGreaterThan(data.count, 3_000)
        XCTAssertLessThan(data.count, 3_300)
        XCTAssertEqual(data.count % 2, 0)
    }
}
