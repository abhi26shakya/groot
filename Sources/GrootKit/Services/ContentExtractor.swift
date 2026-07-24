import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Reads a bounded excerpt of a file's *contents* for the `CategorizationAgent`.
///
/// This is the **only** place file contents are read into memory, and (with a
/// cloud model opted in) the only place they could leave the machine — so it is
/// deliberately conservative: always bounded, never throws, and returns `""` on
/// anything it can't handle. An empty excerpt makes `CategorizerUseCase` return
/// `nil` ("leave it alone"), which is the safe outcome.
public struct ContentExtractor: Sendable {
    /// Image text comes from OCR — injected so tests avoid the Vision framework
    /// (same port `ScreenshotAgent` uses).
    private let recognizer: any TextRecognizing

    public init(recognizer: any TextRecognizing) {
        self.recognizer = recognizer
    }

    /// How to pull text out of a given file, chosen purely from its extension.
    public enum Strategy: Equatable, Sendable {
        case text          // decode the bytes directly
        case pdf           // PDFKit, first pages only
        case image         // OCR
        case unsupported   // archives/installers/media/binary → no excerpt
    }

    /// Pure extension → strategy mapping. `nonisolated`/static so it's unit-tested
    /// without touching disk.
    public static func strategy(for ext: String) -> Strategy {
        let e = ext.lowercased()
        if textExtensions.contains(e) { return .text }
        if e == "pdf" { return .pdf }
        if imageExtensions.contains(e) { return .image }
        return .unsupported
    }

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "text", "log", "csv", "tsv", "json", "yaml", "yml",
        "xml", "html", "htm", "rtf", "swift", "py", "js", "ts", "java", "kt", "c",
        "h", "cpp", "go", "rs", "rb", "php", "sh", "toml", "ini", "conf"
    ]

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp"
    ]

    /// A best-effort text excerpt of at most `limit` characters. Never throws.
    public func excerpt(from url: URL, limit: Int = 2000) async -> String {
        let raw: String
        switch Self.strategy(for: url.pathExtension) {
        case .text:        raw = Self.readText(url, byteCap: limit * 4)
        case .pdf:         raw = Self.readPDF(url)
        case .image:       raw = (try? await recognizer.recognizeText(in: url)) ?? ""
        case .unsupported: raw = ""
        }
        return String(raw.prefix(limit))
    }

    // MARK: Strategies

    /// Read only the first `byteCap` bytes so a multi-GB log never loads whole.
    /// Lossy UTF-8 decode means binary-ish files degrade to noise rather than
    /// crashing; the model treats that as low-signal and returns `nil`.
    static func readText(_ url: URL, byteCap: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: byteCap)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// First pages of a PDF, concatenated. Bounded to avoid pulling a 500-page
    /// document into memory.
    static func readPDF(_ url: URL, maxPages: Int = 2) -> String {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: url) else { return "" }
        var pieces: [String] = []
        for index in 0..<min(doc.pageCount, maxPages) {
            if let text = doc.page(at: index)?.string, !text.isEmpty {
                pieces.append(text)
            }
        }
        return pieces.joined(separator: "\n")
        #else
        return ""
        #endif
    }
}
