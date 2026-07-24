import Foundation

/// Filename generation expressed on top of `AIProvider`.
///
/// `FilenameSuggester` (in `AIService.swift`) stays as the agents' interface —
/// `ScreenshotAgent` is unchanged — but the *implementation* now composes a
/// provider instead of hardcoding an HTTP call, so swapping Ollama for a cloud
/// model is a construction detail.
public struct FilenameUseCase: FilenameSuggester {
    private let provider: any AIProvider
    private let fallback: FilenameSuggester

    public init(
        provider: any AIProvider,
        fallback: FilenameSuggester = HeuristicFilenameSuggester()
    ) {
        self.provider = provider
        self.fallback = fallback
    }

    public func suggest(ocrText: String, original: URL) async -> String {
        guard !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return await fallback.suggest(ocrText: ocrText, original: original)
        }

        let request = AIRequest(
            prompt: """
            Text extracted from a screenshot:
            \"\"\"
            \(ocrText.prefix(1500))
            \"\"\"
            """,
            system: "You name files. Reply with ONLY a short, descriptive filename "
                  + "(3-8 words, no extension, no quotes, Title Case).")

        do {
            let raw = try await provider.complete(request)
            let base = FilenameSanitizer.sanitize(raw)
            return base.isEmpty
                ? await fallback.suggest(ocrText: ocrText, original: original)
                : base
        } catch {
            // Any failure — no server, timeout, garbage — falls back silently.
            return await fallback.suggest(ocrText: ocrText, original: original)
        }
    }
}

/// A category decision plus the model's reasoning, used by the Phase 03
/// content-aware sorting agent.
public struct CategoryDecision: Codable, Sendable, Equatable {
    public let category: String
    public let confidence: Double
    public let reason: String?

    public init(category: String, confidence: Double, reason: String? = nil) {
        self.category = category
        self.confidence = confidence
        self.reason = reason
    }
}

/// Content-aware categorization. **The Phase 03 seam** — built now so that phase
/// adds an agent rather than an architecture.
///
/// Output is validated: the category must be one the caller offered and the
/// confidence must be in range, so a hallucinated folder name can never reach
/// `FileService`.
public struct CategorizerUseCase: Sendable {
    private let provider: any AIProvider
    /// The only categories the model is allowed to choose from.
    public let allowed: [String]
    /// Below this, the caller should treat the answer as "don't know".
    public let minimumConfidence: Double

    public init(
        provider: any AIProvider,
        allowed: [String],
        minimumConfidence: Double = 0.6
    ) {
        self.provider = provider
        self.allowed = allowed
        self.minimumConfidence = minimumConfidence
    }

    /// - Returns: the decision, or `nil` when the model is unavailable or not
    ///   confident enough. `nil` means "leave it alone" — never a guess.
    public func categorize(filename: String, contentExcerpt: String) async -> CategoryDecision? {
        let request = AIRequest(
            prompt: """
            File: \(filename)
            Content excerpt:
            \"\"\"
            \(contentExcerpt.prefix(2000))
            \"\"\"

            Choose exactly one category from: \(allowed.joined(separator: ", "))
            Reply as JSON: {"category": "...", "confidence": 0.0-1.0, "reason": "..."}
            """,
            system: "You classify files. Reply with JSON only.",
            expectsJSON: true)

        let permitted = Set(allowed)
        do {
            let decision = try await StructuredOutput.decode(
                CategoryDecision.self,
                request: request,
                provider: provider,
                validate: { permitted.contains($0.category) && (0...1).contains($0.confidence) })
            return decision.confidence >= minimumConfidence ? decision : nil
        } catch {
            GrootLog.ai.notice(
                "categorization unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
