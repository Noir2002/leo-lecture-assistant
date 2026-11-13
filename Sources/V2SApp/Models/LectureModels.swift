import AVFoundation
import Foundation

enum LectureEngineMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case geminiSmart
    case appleLocal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .geminiSmart: return "Gemini Smart"
        case .appleLocal: return "Apple Local"
        }
    }
}

struct CourseDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: String { code }
    let code: String
    let officialTitle: String
    let domain: String
    let vaultPath: String
    let sourceLanguage: String
    let targetLanguage: String
    let glossaryPath: String
}

struct SubtitleSettings: Codable, Equatable, Sendable {
    var showsInterim = true
    var translatedFirst = true
}

struct LeoConfiguration: Codable, Equatable, Sendable {
    var vaultPath: String?
    var selectedCourse: String
    var engineMode: LectureEngineMode
    var subtitleSettings: SubtitleSettings
    var outlineInterval: TimeInterval
    var sessionRotationInterval: TimeInterval
    var freeTierConfirmed: Bool
    var reviewAfterAppleLocal: Bool? = nil
    var courses: [CourseDefinition]

    static let defaultCourses = [
        CourseDefinition(
            code: "IFT-7022",
            officialTitle: "Traitement automatique de la langue naturelle",
            domain: "natural-language-processing",
            vaultPath: "10_Courses/2026-Autumn/IFT-7022",
            sourceLanguage: "fr-FR",
            targetLanguage: "zh-CN",
            glossaryPath: "Resources/Glossary.md"
        ),
        CourseDefinition(
            code: "GIF-7001",
            officialTitle: "Vision numérique",
            domain: "computer-vision",
            vaultPath: "10_Courses/2026-Autumn/GIF-7001",
            sourceLanguage: "fr-FR",
            targetLanguage: "zh-CN",
            glossaryPath: "Resources/Glossary.md"
        ),
        CourseDefinition(
            code: "GIF-7005",
            officialTitle: "Introduction à l'apprentissage automatique",
            domain: "machine-learning",
            vaultPath: "10_Courses/2026-Autumn/GIF-7005",
            sourceLanguage: "fr-FR",
            targetLanguage: "zh-CN",
            glossaryPath: "Resources/Glossary.md"
        ),
        CourseDefinition(
            code: "GSO-6082",
            officialTitle: "Gestion de projets",
            domain: "project-management",
            vaultPath: "10_Courses/2026-Autumn/GSO-6082",
            sourceLanguage: "fr-FR",
            targetLanguage: "zh-CN",
            glossaryPath: "Resources/Glossary.md"
        ),
    ]

    static let `default` = LeoConfiguration(
        vaultPath: nil,
        selectedCourse: "IFT-7022",
        engineMode: .appleLocal,
        subtitleSettings: SubtitleSettings(),
        outlineInterval: 600,
        sessionRotationInterval: 510,
        freeTierConfirmed: false,
        courses: defaultCourses
    )
}

struct AudioFrame: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let capturedAt: Date
}

enum TranscriptEvent: Equatable, Sendable {
    case interim(text: String, capturedAt: Date)
    case final(text: String, capturedAt: Date)
    case status(String)
    case failure(EngineFailure)

    var isAuthoritativeFinal: Bool {
        if case .final = self { return true }
        return false
    }
}

enum EngineFailure: Error, Equatable, Sendable {
    case missingCredential
    case authentication
    case quota
    case network
    case server(Int)
    case malformedResponse
    case unavailable(String)

    var requiresImmediateFallback: Bool {
        switch self {
        case .missingCredential, .authentication, .quota, .network:
            return true
        case .server, .malformedResponse, .unavailable:
            return false
        }
    }
}

struct TranslationRequest: Sendable {
    let course: CourseDefinition
    let glossary: [String]
    let recentFrenchContext: String
    let currentSegment: String
}

struct TranslationResult: Codable, Equatable, Sendable {
    let correctedFrench: String
    let chineseTranslation: String
}

enum TranscriptSource: String, Codable, Equatable, Sendable {
    case gemini
    case apple
    case recovery
}

struct RawFinalEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let capturedAt: Date
    let source: TranscriptSource
    let text: String
}

struct SubtitleBatch: Equatable, Sendable {
    let sourceEventIDs: [UUID]
    let startedAt: Date
    let endedAt: Date
    let french: String
}

struct TranscriptChunk: Equatable, Sendable {
    let sourceEventIDs: [UUID]
    let startedAt: Date
    let endedAt: Date
    let french: String
}

enum TranscriptAssemblerEvent: Equatable, Sendable {
    case accepted(RawFinalEvent)
    case duplicateDropped(UUID)
}

struct LectureBookmark: Sendable {
    let capturedAt: Date
    let context: [TranscriptContextEntry]
}

struct ReviewRequest: Sendable {
    let course: CourseDefinition
    let glossary: [String]
    let transcript: [TranscriptChunk]
    let bookmarks: [LectureBookmark]
}

struct TranscriptContextEntry: Equatable, Sendable {
    let capturedAt: Date
    let french: String
    let chinese: String?
}

enum TranscriptContextWindow {
    static func recent(
        _ entries: [TranscriptContextEntry],
        seconds: TimeInterval = 90,
        now: Date
    ) -> [TranscriptContextEntry] {
        let start = now.addingTimeInterval(-seconds)
        return entries.filter { (start...now).contains($0.capturedAt) }
    }
}

struct LectureSessionPaths: Codable, Equatable, Sendable {
    let transcript: String
    let lecture: String
    let journal: String
}

struct SessionSummary: Codable, Equatable, Sendable {
    let course: String
    let startedAt: Date
    let endedAt: Date
    let activeDuration: TimeInterval
    let engine: String
    let fallbackReason: String?
    let transcriptPath: String
    let lecturePath: String
    let confusionMarkerCount: Int
    let finalChunkCount: Int
    let reviewStatus: String?
    let errors: [String]
}
