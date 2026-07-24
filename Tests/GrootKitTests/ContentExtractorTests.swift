import XCTest
@testable import GrootKit

final class ContentExtractorTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("groot-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    private struct StubRecognizer: TextRecognizing {
        let text: String
        func recognizeText(in url: URL) async throws -> String { text }
    }

    private func extractor(ocr: String = "") -> ContentExtractor {
        ContentExtractor(recognizer: StubRecognizer(text: ocr))
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: Strategy dispatch (pure)

    func testStrategyDispatch() {
        XCTAssertEqual(ContentExtractor.strategy(for: "txt"), .text)
        XCTAssertEqual(ContentExtractor.strategy(for: "MD"), .text)
        XCTAssertEqual(ContentExtractor.strategy(for: "swift"), .text)
        XCTAssertEqual(ContentExtractor.strategy(for: "pdf"), .pdf)
        XCTAssertEqual(ContentExtractor.strategy(for: "png"), .image)
        XCTAssertEqual(ContentExtractor.strategy(for: "heic"), .image)
        XCTAssertEqual(ContentExtractor.strategy(for: "zip"), .unsupported)
        XCTAssertEqual(ContentExtractor.strategy(for: "dmg"), .unsupported)
        XCTAssertEqual(ContentExtractor.strategy(for: ""), .unsupported)
    }

    // MARK: Text

    func testReadsPlainText() async throws {
        let url = try write("note.txt", "Quarterly revenue report for Q3")
        let excerpt = await extractor().excerpt(from: url)
        XCTAssertEqual(excerpt, "Quarterly revenue report for Q3")
    }

    func testReadsMarkdownAndCode() async throws {
        let md = try write("readme.md", "# Title\nSome body text")
        let code = try write("main.swift", "let x = 42")
        let mdExcerpt = await extractor().excerpt(from: md)
        let codeExcerpt = await extractor().excerpt(from: code)
        XCTAssertTrue(mdExcerpt.contains("Title"))
        XCTAssertTrue(codeExcerpt.contains("let x = 42"))
    }

    func testExcerptIsBounded() async throws {
        let url = try write("big.txt", String(repeating: "a", count: 10_000))
        let excerpt = await extractor().excerpt(from: url, limit: 100)
        XCTAssertEqual(excerpt.count, 100)
    }

    // MARK: Images

    func testImageUsesOCR() async throws {
        // No real image needed — strategy routes .png to the injected recognizer.
        let url = sandbox.appendingPathComponent("shot.png")
        try Data([0x89, 0x50]).write(to: url)
        let excerpt = await extractor(ocr: "Invoice #4471").excerpt(from: url)
        XCTAssertEqual(excerpt, "Invoice #4471")
    }

    // MARK: Failure / unsupported → empty (never throws)

    func testUnsupportedReturnsEmpty() async throws {
        let url = try write("archive.zip", "not really a zip")
        let excerpt = await extractor().excerpt(from: url)
        XCTAssertTrue(excerpt.isEmpty)
    }

    func testMissingFileReturnsEmpty() async {
        let url = sandbox.appendingPathComponent("does-not-exist.txt")
        let excerpt = await extractor().excerpt(from: url)
        XCTAssertTrue(excerpt.isEmpty)
    }

    func testZeroByteReturnsEmpty() async throws {
        let url = try write("empty.txt", "")
        let excerpt = await extractor().excerpt(from: url)
        XCTAssertTrue(excerpt.isEmpty)
    }
}
