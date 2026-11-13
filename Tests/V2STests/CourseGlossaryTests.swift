import XCTest
@testable import v2s

final class CourseGlossaryTests: XCTestCase {
    func testParsesOnlyCoreTermsAndDeduplicates() {
        let markdown = """
        # Glossary
        - ignored
        ## Core Terms
        - assurance qualité — note
        * [[apprentissage automatique]]
        + Assurance qualité
        ## Other
        - ignored too
        """
        XCTAssertEqual(CourseGlossary.parse(markdown), ["assurance qualité", "apprentissage automatique"])
    }

    func testCapsVocabularyAtOneHundred() {
        let markdown = "## Core Terms\n" + (0..<150).map { "- term-\($0)" }.joined(separator: "\n")
        let result = CourseGlossary.parse(markdown)
        XCTAssertEqual(result.count, 100)
        XCTAssertEqual(result.first, "term-0")
        XCTAssertEqual(result.last, "term-99")
    }

    func testEmptyTemplateIsConservative() {
        XCTAssertEqual(CourseGlossary.emptyTemplate(courseCode: "IFT-7022"), "# IFT-7022 Glossary\n\n## Core Terms\n")
    }
}
