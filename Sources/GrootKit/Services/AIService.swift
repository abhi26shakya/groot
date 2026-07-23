import Foundation

/// Extracts text from an image file. `VisionOCR` is the production
/// implementation; tests inject a stub so they don't depend on the Vision
/// framework being available headlessly.
public protocol TextRecognizing: Sendable {
    func recognizeText(in url: URL) async throws -> String
}

/// Produces a human-meaningful filename from a file's recognized text/content.
/// Kept as a protocol so the on-device heuristic, a local Ollama model, or a
/// cloud model can be swapped without touching the agents that call it.
public protocol FilenameSuggester: Sendable {
    /// - Parameters:
    ///   - ocrText: text recognized from the file (may be empty).
    ///   - original: the file's current URL (used for extension/fallback name).
    /// - Returns: a base filename **without** extension, already sanitized.
    func suggest(ocrText: String, original: URL) async -> String
}

/// Utilities shared by all suggesters.
public enum FilenameSanitizer {
    /// Characters illegal in macOS filenames plus a few we avoid for tidiness.
    private static let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")

    /// Turn arbitrary text into a safe, readable base filename.
    public static func sanitize(_ text: String, maxLength: Int = 60) -> String {
        // Collapse whitespace, strip illegal characters.
        let cleaned = text
            .components(separatedBy: illegal)
            .joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let collapsed = cleaned.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }

        if collapsed.count <= maxLength { return collapsed }
        // Truncate on a word boundary where possible.
        let clipped = String(collapsed.prefix(maxLength))
        if let lastSpace = clipped.lastIndex(of: " ") {
            return String(clipped[..<lastSpace])
        }
        return clipped
    }
}

/// Default, fully on-device suggester. No network, deterministic → unit-tested.
/// Picks the first substantive line of OCR text and cleans it into a filename.
public struct HeuristicFilenameSuggester: FilenameSuggester {
    public init() {}

    public func suggest(ocrText: String, original: URL) async -> String {
        let candidate = Self.firstMeaningfulLine(in: ocrText)
        let base = FilenameSanitizer.sanitize(candidate)
        if !base.isEmpty { return base }
        // Fall back to the original name (minus extension) so we never return "".
        let fallback = original.deletingPathExtension().lastPathComponent
        return fallback.isEmpty ? "Untitled" : fallback
    }

    /// First line with enough alphabetic content to be a real title.
    static func firstMeaningfulLine(in text: String) -> String {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            if letters >= 3 { return line }
        }
        return ""
    }
}

/// Optional local-LLM suggester. Talks to a running Ollama server on localhost.
/// On any failure (server down, timeout, bad response) it transparently falls
/// back to the heuristic, so the app never depends on Ollama being present.
public struct OllamaFilenameSuggester: FilenameSuggester {
    private let endpoint: URL
    private let model: String
    private let fallback: FilenameSuggester
    private let session: URLSession

    public init(
        endpoint: URL = URL(string: "http://localhost:11434/api/generate")!,
        model: String = "llama3.1",
        fallback: FilenameSuggester = HeuristicFilenameSuggester(),
        timeout: TimeInterval = 8
    ) {
        self.endpoint = endpoint
        self.model = model
        self.fallback = fallback
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: config)
    }

    public func suggest(ocrText: String, original: URL) async -> String {
        guard !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return await fallback.suggest(ocrText: ocrText, original: original)
        }
        do {
            let prompt = """
            You name files. Given the text extracted from a screenshot, reply with ONLY a short, \
            descriptive filename (3-8 words, no extension, no quotes, Title Case). \
            Extracted text:
            \"\"\"
            \(ocrText.prefix(1500))
            \"\"\"
            """
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["model": model, "prompt": prompt, "stream": false]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = json["response"] as? String else {
                return await fallback.suggest(ocrText: ocrText, original: original)
            }
            let base = FilenameSanitizer.sanitize(raw)
            return base.isEmpty
                ? await fallback.suggest(ocrText: ocrText, original: original)
                : base
        } catch {
            return await fallback.suggest(ocrText: ocrText, original: original)
        }
    }
}
