import Foundation

/// Turns a model's free-form reply into a validated Swift value.
///
/// **Nothing a model produces may reach `FileService` unvalidated.** Models
/// wrap JSON in prose, fence it in ``` blocks, and occasionally emit something
/// unparseable; this decodes what it can, retries once with a repair prompt,
/// then fails closed rather than handing a guess to code that moves files.
public enum StructuredOutput {

    /// Decode `T` from a model reply, repairing once if the first attempt fails.
    ///
    /// - Parameters:
    ///   - type: the shape the caller expects.
    ///   - request: the original request; reused for the repair attempt.
    ///   - provider: the model to ask.
    ///   - validate: optional extra check (ranges, allowed values). Returning
    ///     `false` triggers the repair attempt and then failure.
    public static func decode<T: Decodable & Sendable>(
        _ type: T.Type,
        request: AIRequest,
        provider: some AIProvider,
        validate: (@Sendable (T) -> Bool)? = nil
    ) async throws -> T {
        let jsonRequest = AIRequest(
            prompt: request.prompt,
            system: request.system,
            maxTokens: request.maxTokens,
            expectsJSON: true)

        let first = try await provider.complete(jsonRequest)
        if let value = parse(type, from: first), validate?(value) ?? true {
            return value
        }

        // One repair attempt: show the model its own bad output and ask again.
        let repair = AIRequest(
            prompt: """
            Your previous reply could not be parsed as the required JSON.
            Reply with ONLY valid JSON, no prose and no code fences.

            Previous reply:
            \(first.prefix(1000))

            Original request:
            \(request.prompt)
            """,
            system: request.system,
            maxTokens: request.maxTokens,
            expectsJSON: true)

        let second = try await provider.complete(repair)
        if let value = parse(type, from: second), validate?(value) ?? true {
            return value
        }

        GrootLog.ai.error("structured output failed validation after one repair attempt")
        throw AIError.invalidStructuredOutput(String(second.prefix(200)))
    }

    /// Best-effort JSON extraction. Handles a bare object, a ```json fence, and
    /// JSON embedded in surrounding prose.
    static func parse<T: Decodable>(_ type: T.Type, from raw: String) -> T? {
        for candidate in candidates(in: raw) {
            if let data = candidate.data(using: .utf8),
               let value = try? JSONDecoder().decode(type, from: data) {
                return value
            }
        }
        return nil
    }

    /// Substrings worth attempting to decode, most likely first.
    static func candidates(in raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var results = [trimmed]

        // Strip a ``` / ```json fence.
        if trimmed.hasPrefix("```") {
            let withoutFence = trimmed
                .split(separator: "\n", omittingEmptySubsequences: false)
                .dropFirst()
                .prefix { !$0.hasPrefix("```") }
                .joined(separator: "\n")
            results.append(withoutFence.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // The outermost {...} or [...] found in prose.
        for (open, close) in [("{", "}"), ("[", "]")] {
            if let start = trimmed.range(of: open),
               let end = trimmed.range(of: close, options: .backwards),
               start.lowerBound < end.upperBound {
                results.append(String(trimmed[start.lowerBound..<end.upperBound]))
            }
        }
        return results
    }
}
