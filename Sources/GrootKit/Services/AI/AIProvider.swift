import Foundation

/// What a provider can do. Lets callers pick one without knowing the concrete
/// type (Phase 03 categorization needs `.text`; semantic search needs `.embedding`).
public enum AICapability: String, Sendable, Hashable, CaseIterable {
    case text
    case vision
    case embedding
}

/// One request to a model.
public struct AIRequest: Sendable {
    public let prompt: String
    /// Optional system/role framing.
    public let system: String?
    /// Upper bound on response length, where the provider supports it.
    public let maxTokens: Int?
    /// Set when the caller needs strictly-formatted output (see `StructuredOutput`).
    public let expectsJSON: Bool

    public init(
        prompt: String,
        system: String? = nil,
        maxTokens: Int? = nil,
        expectsJSON: Bool = false
    ) {
        self.prompt = prompt
        self.system = system
        self.maxTokens = maxTokens
        self.expectsJSON = expectsJSON
    }
}

public enum AIError: Error, Sendable, Equatable {
    /// The user has not opted in to sending content off the machine.
    case cloudConsentRequired
    case unavailable(String)
    case badResponse(String)
    /// The model's output failed validation and could not be repaired.
    case invalidStructuredOutput(String)
}

/// The port every model sits behind: the on-device heuristic, a local Ollama
/// server, or an opt-in cloud model.
///
/// This replaces `FilenameSuggester` as *the* abstraction — that protocol was
/// single-purpose, so Phase 03 (categorization) and Phase 04 (natural-language
/// rules) had nothing to plug into. Use cases are now built on top of this port
/// rather than beside it.
public protocol AIProvider: Sendable {
    var capabilities: Set<AICapability> { get }
    /// Whether inference happens on this machine. The UI surfaces it, and the
    /// cloud path is gated on explicit consent.
    var isLocal: Bool { get }
    func complete(_ request: AIRequest) async throws -> String
}

/// Always-available fallback that never calls a model. Keeps the app fully
/// functional with no Ollama server and no network.
public struct HeuristicProvider: AIProvider {
    public init() {}
    public var capabilities: Set<AICapability> { [.text] }
    public var isLocal: Bool { true }

    /// There is no model here — callers are expected to use a heuristic use case
    /// instead. Returning empty (rather than throwing) keeps fallback chains simple.
    public func complete(_ request: AIRequest) async throws -> String { "" }
}

/// Local LLM via an Ollama server on localhost. Generalized from the original
/// `OllamaFilenameSuggester`, keeping its most important property: **any**
/// failure is transparent, so the app never depends on Ollama being installed.
public struct OllamaProvider: AIProvider {
    private let endpoint: URL
    private let model: String
    private let session: URLSession

    public init(
        endpoint: URL = URL(string: "http://localhost:11434/api/generate")!,
        model: String = "llama3.1",
        timeout: TimeInterval = 8
    ) {
        self.endpoint = endpoint
        self.model = model
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: config)
    }

    public var capabilities: Set<AICapability> { [.text] }
    public var isLocal: Bool { true }

    public func complete(_ request: AIRequest) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "prompt": request.system.map { "\($0)\n\n\(request.prompt)" } ?? request.prompt,
            "stream": false
        ]
        if request.expectsJSON { body["format"] = "json" }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.unavailable("Ollama returned a non-200 response")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            throw AIError.badResponse("unexpected Ollama payload")
        }
        return text
    }
}

/// Opt-in cloud model. **Refuses to run without explicit consent** — local-first
/// is the product promise, so no code path may assume the user agreed.
public struct CloudProvider: AIProvider {
    private let consent: @Sendable () async -> Bool
    private let send: @Sendable (AIRequest) async throws -> String

    /// - Parameters:
    ///   - consent: read from `SettingsStore.cloudConsent()`.
    ///   - send: the actual API call, injected so this type stays testable and
    ///     `GrootKit` keeps no hard dependency on a specific vendor SDK.
    public init(
        consent: @escaping @Sendable () async -> Bool,
        send: @escaping @Sendable (AIRequest) async throws -> String
    ) {
        self.consent = consent
        self.send = send
    }

    public var capabilities: Set<AICapability> { [.text] }
    public var isLocal: Bool { false }

    public func complete(_ request: AIRequest) async throws -> String {
        guard await consent() else { throw AIError.cloudConsentRequired }
        return try await send(request)
    }
}

/// Tries providers in order, falling through on failure. This is how "use Ollama
/// if it's running, otherwise stay on-device" is expressed without any caller
/// having to know which providers exist.
public struct FallbackChain: AIProvider {
    private let providers: [any AIProvider]

    public init(_ providers: [any AIProvider]) {
        self.providers = providers
    }

    public var capabilities: Set<AICapability> {
        providers.reduce(into: Set<AICapability>()) { $0.formUnion($1.capabilities) }
    }
    public var isLocal: Bool { providers.allSatisfy(\.isLocal) }

    public func complete(_ request: AIRequest) async throws -> String {
        var lastError: Error = AIError.unavailable("no providers configured")
        for provider in providers {
            do {
                let result = try await provider.complete(request)
                if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return result
                }
            } catch {
                lastError = error
                GrootLog.ai.notice(
                    "provider failed, trying next: \(String(describing: error), privacy: .public)")
            }
        }
        throw lastError
    }
}
