import Foundation
import XCTest
@testable import v2s

final class LectureConfigurationTests: XCTestCase {
    func testDefaultRegistryLoadsFourCurrentCourses() throws {
        let registry = try CourseRegistry(courses: LeoConfiguration.defaultCourses)
        XCTAssertEqual(Set(registry.courses.map(\.code)), ["GSO-6082", "IFT-7022", "GIF-7001", "GIF-7005"])
        let course = try registry.course(code: "IFT-7022")
        XCTAssertEqual(course.domain, "natural-language-processing")
        XCTAssertEqual(course.sourceLanguage, "fr-FR")
        XCTAssertEqual(course.targetLanguage, "zh-CN")
        XCTAssertEqual(course.glossaryPath, "Resources/Glossary.md")
    }

    func testRegistryRejectsDuplicateAndUnsafeCourse() {
        let course = LeoConfiguration.defaultCourses[0]
        XCTAssertThrowsError(try CourseRegistry(courses: [course, course])) {
            XCTAssertEqual($0 as? CourseRegistryError, .duplicateCode(course.code))
        }
        let unsafe = CourseDefinition(
            code: "BAD", officialTitle: "Bad", domain: "bad",
            vaultPath: "10_Courses/../Secrets", sourceLanguage: "fr-FR",
            targetLanguage: "zh-CN", glossaryPath: "../Glossary.md"
        )
        XCTAssertThrowsError(try CourseRegistry(courses: [unsafe]))
    }

    func testConfigurationRoundTripContainsNoCredential() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("config.json")
        let store = LeoConfigurationStore(fileURL: url)
        var config = LeoConfiguration.default
        config.vaultPath = "/tmp/Leo-Knowledge"
        config.selectedCourse = "GIF-7005"
        store.save(config)
        XCTAssertEqual(store.load(), config)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.localizedCaseInsensitiveContains("apiKey"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("credential"))
    }

    func testVaultDiscoveryFindsUniqueAndMultipleCandidates() throws {
        let home = try temporaryDirectory()
        let first = home.appendingPathComponent("Documents/Nested/Leo-Knowledge")
        try makeValidVault(first)
        var found = try VaultDiscoveryService(home: home).discover()
        XCTAssertEqual(found.map(\.path), [first.standardizedFileURL.path])

        let second = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Obsidian/Leo-Knowledge")
        try makeValidVault(second)
        found = try VaultDiscoveryService(home: home).discover()
        XCTAssertEqual(Set(found.map(\.path)), Set([first.path, second.path]))
    }

    func testVaultPathSafetyRejectsTraversal() throws {
        let root = try temporaryDirectory()
        XCTAssertThrowsError(try VaultPathSafety.resolve(relativePath: "../outside", under: root))
    }

    private func makeValidVault(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for marker in VaultDiscoveryService.requiredMarkers {
            let url = root.appendingPathComponent(marker)
            if marker.contains(".") {
                try Data().write(to: url)
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
