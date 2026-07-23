import XCTest
@testable import GrootKit

final class FilenameSuggesterTests: XCTestCase {

    func testHeuristicPicksFirstMeaningfulLine() async {
        let suggester = HeuristicFilenameSuggester()
        let ocr = """
        12:04
        VS Code Installation Error
        Could not write to /usr/local/bin
        """
        let name = await suggester.suggest(
            ocrText: ocr,
            original: URL(fileURLWithPath: "/tmp/Screenshot.png"))
        XCTAssertEqual(name, "VS Code Installation Error")
    }

    func testHeuristicFallsBackToOriginalNameWhenNoText() async {
        let suggester = HeuristicFilenameSuggester()
        let name = await suggester.suggest(
            ocrText: "",
            original: URL(fileURLWithPath: "/tmp/IMG_4821.jpg"))
        XCTAssertEqual(name, "IMG_4821")
    }

    func testSanitizerStripsIllegalCharactersAndTruncatesOnWordBoundary() {
        XCTAssertEqual(
            FilenameSanitizer.sanitize("Invoice: March/2026 <final>"),
            "Invoice March 2026 final")

        let long = "The quick brown fox jumps over the lazy dog again and again forever"
        let result = FilenameSanitizer.sanitize(long, maxLength: 20)
        XCTAssertLessThanOrEqual(result.count, 20)
        XCTAssertFalse(result.hasSuffix(" "))
        // Truncated on a word boundary → no partial trailing word.
        XCTAssertTrue(long.hasPrefix(result))
    }

    func testSanitizerSkipsShortNoiseLines() {
        // Lines with < 3 letters are skipped as noise (timestamps, icons).
        XCTAssertEqual(HeuristicFilenameSuggester.firstMeaningfulLine(in: "9:41\n▲\nMeeting Notes"),
                       "Meeting Notes")
    }
}
