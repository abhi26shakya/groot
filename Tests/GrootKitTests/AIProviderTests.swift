import XCTest
@testable import GrootKit

/// Serialized script of canned replies. An actor rather than a lock, because
/// `NSLock` is unavailable from async contexts under Swift 6.
private actor Script {
    private let replies: [Result<String, AIError>]
    private(set) var calls = 0

    init(_ replies: [Result<String, AIError>]) { self.replies = replies }

    func next() throws -> String {
        let reply = calls < replies.count ? replies[calls] : .failure(AIError.unavailable("exhausted"))
        calls += 1
        return try reply.get()
    }
}

/// Returns canned replies in order and counts how many times it was asked.
private struct ScriptedProvider: AIProvider {
    let script: Script

    init(_ replies: [Result<String, AIError>]) { self.script = Script(replies) }
    init(_ texts: [String]) { self.init(texts.map { Result<String, AIError>.success($0) }) }

    var capabilities: Set<AICapability> { [.text] }
    var isLocal: Bool { true }

    func complete(_ request: AIRequest) async throws -> String {
        try await script.next()
    }

    var callCount: Int { get async { await script.calls } }
}

private struct Answer: Codable, Equatable {
    let category: String
    let confidence: Double
}

final class AIProviderTests: XCTestCase {

    // MARK: Cloud consent

    /// Local-first is the product promise: no consent, no call — and the call
    /// must not even be attempted.
    func testCloudProviderRefusesWithoutConsent() async {
        let attempted = Attempted()
        let provider = CloudProvider(
            consent: { false },
            send: { _ in await attempted.mark(); return "should not happen" })

        do {
            _ = try await provider.complete(AIRequest(prompt: "hi"))
            XCTFail("expected cloudConsentRequired")
        } catch let error as AIError {
            XCTAssertEqual(error, .cloudConsentRequired)
        } catch {
            XCTFail("unexpected error \(error)")
        }

        let didCall = await attempted.value
        XCTAssertFalse(didCall, "the request must never leave the machine without consent")
    }

    func testCloudProviderProceedsWithConsent() async throws {
        let provider = CloudProvider(consent: { true }, send: { _ in "ok" })
        let result = try await provider.complete(AIRequest(prompt: "hi"))
        XCTAssertEqual(result, "ok")
    }

    // MARK: Fallback chain

    func testFallbackChainSkipsFailingProviders() async throws {
        let failing = ScriptedProvider([.failure(.unavailable("offline"))])
        let working = ScriptedProvider(["second answer"])
        let chain = FallbackChain([failing, working])

        let result = try await chain.complete(AIRequest(prompt: "x"))
        XCTAssertEqual(result, "second answer")
        let calls_failing = await failing.callCount
        XCTAssertEqual(calls_failing, 1)
    }

    func testFallbackChainTreatsEmptyReplyAsFailure() async throws {
        let empty = ScriptedProvider(["   "])
        let working = ScriptedProvider(["real"])
        let chain = FallbackChain([empty, working])
        let result = try await chain.complete(AIRequest(prompt: "x"))
        XCTAssertEqual(result, "real")
    }

    func testFallbackChainThrowsWhenEveryProviderFails() async {
        let chain = FallbackChain([ScriptedProvider([.failure(.unavailable("a"))])])
        do {
            _ = try await chain.complete(AIRequest(prompt: "x"))
            XCTFail("expected a throw")
        } catch {
            // expected
        }
    }

    // MARK: Structured output

    func testDecodesPlainJSON() async throws {
        let provider = ScriptedProvider(["{\"category\":\"Finance\",\"confidence\":0.9}"])
        let answer = try await StructuredOutput.decode(
            Answer.self, request: AIRequest(prompt: "x"), provider: provider)
        XCTAssertEqual(answer, Answer(category: "Finance", confidence: 0.9))
        let calls_provider = await provider.callCount
        XCTAssertEqual(calls_provider, 1, "clean output needs no repair round")
    }

    func testDecodesJSONWrappedInCodeFenceAndProse() async throws {
        let fenced = ScriptedProvider(["```json\n{\"category\":\"Career\",\"confidence\":0.7}\n```"])
        let fromFence = try await StructuredOutput.decode(
            Answer.self, request: AIRequest(prompt: "x"), provider: fenced)
        XCTAssertEqual(fromFence.category, "Career")

        let chatty = ScriptedProvider(["Sure! Here you go: {\"category\":\"Research\",\"confidence\":0.8} Hope that helps."])
        let fromProse = try await StructuredOutput.decode(
            Answer.self, request: AIRequest(prompt: "x"), provider: chatty)
        XCTAssertEqual(fromProse.category, "Research")
    }

    func testRepairsOnceThenSucceeds() async throws {
        let provider = ScriptedProvider(["not json at all", "{\"category\":\"Finance\",\"confidence\":0.5}"])
        let answer = try await StructuredOutput.decode(
            Answer.self, request: AIRequest(prompt: "x"), provider: provider)
        XCTAssertEqual(answer.category, "Finance")
        let calls_provider = await provider.callCount
        XCTAssertEqual(calls_provider, 2, "exactly one repair attempt")
    }

    /// Fail closed: unparseable output must never be handed on as a guess.
    func testFailsClosedAfterOneRepairAttempt() async {
        let provider = ScriptedProvider(["garbage", "still garbage"])
        do {
            _ = try await StructuredOutput.decode(
                Answer.self, request: AIRequest(prompt: "x"), provider: provider)
            XCTFail("expected invalidStructuredOutput")
        } catch let error as AIError {
            guard case .invalidStructuredOutput = error else {
                return XCTFail("wrong error \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        let calls_provider = await provider.callCount
        XCTAssertEqual(calls_provider, 2, "must not retry forever")
    }

    /// Well-formed JSON that violates the caller's rules is still rejected.
    func testValidationRejectsWellFormedButInvalidOutput() async {
        let provider = ScriptedProvider([
            "{\"category\":\"Nonsense\",\"confidence\":0.9}",
            "{\"category\":\"Nonsense\",\"confidence\":0.9}"
        ])
        do {
            _ = try await StructuredOutput.decode(
                Answer.self, request: AIRequest(prompt: "x"), provider: provider,
                validate: { $0.category == "Finance" })
            XCTFail("expected validation to reject")
        } catch {
            // expected
        }
    }

    // MARK: Use cases

    func testCategorizerRejectsHallucinatedCategories() async {
        let provider = ScriptedProvider([
            "{\"category\":\"MadeUpFolder\",\"confidence\":0.99}",
            "{\"category\":\"MadeUpFolder\",\"confidence\":0.99}"
        ])
        let categorizer = CategorizerUseCase(provider: provider, allowed: ["Finance", "Career"])
        let decision = await categorizer.categorize(filename: "x.pdf", contentExcerpt: "invoice")
        XCTAssertNil(decision, "a category outside the allowed list must never be returned")
    }

    func testCategorizerReturnsNilBelowConfidenceThreshold() async {
        let provider = ScriptedProvider(["{\"category\":\"Finance\",\"confidence\":0.2}"])
        let categorizer = CategorizerUseCase(
            provider: provider, allowed: ["Finance"], minimumConfidence: 0.6)
        let decision = await categorizer.categorize(filename: "x.pdf", contentExcerpt: "invoice")
        XCTAssertNil(decision, "low confidence means leave it alone, not guess")
    }

    func testCategorizerAcceptsValidConfidentAnswer() async {
        let provider = ScriptedProvider(["{\"category\":\"Finance\",\"confidence\":0.91}"])
        let categorizer = CategorizerUseCase(provider: provider, allowed: ["Finance", "Career"])
        let decision = await categorizer.categorize(filename: "x.pdf", contentExcerpt: "invoice")
        XCTAssertEqual(decision?.category, "Finance")
    }

    func testFilenameUseCaseFallsBackWhenProviderFails() async {
        let provider = ScriptedProvider([.failure(.unavailable("no server"))])
        let useCase = FilenameUseCase(provider: provider)
        let name = await useCase.suggest(
            ocrText: "VS Code Installation Error\nmore text",
            original: URL(fileURLWithPath: "/tmp/Screenshot.png"))
        XCTAssertEqual(name, "VS Code Installation Error",
                       "a dead provider must fall back to the on-device heuristic")
    }

    func testFilenameUseCaseSanitizesModelOutput() async {
        let provider = ScriptedProvider(["Invoice/2026: \"Q3\"\n"])
        let useCase = FilenameUseCase(provider: provider)
        let name = await useCase.suggest(
            ocrText: "some text here",
            original: URL(fileURLWithPath: "/tmp/Screenshot.png"))
        XCTAssertFalse(name.contains("/"), "illegal path characters must be stripped")
        XCTAssertFalse(name.contains("\""))
    }

    func testFilenameUseCaseSkipsTheModelWhenThereIsNoText() async {
        let provider = ScriptedProvider(["should not be used"])
        let useCase = FilenameUseCase(provider: provider)
        let name = await useCase.suggest(
            ocrText: "   ", original: URL(fileURLWithPath: "/tmp/Holiday.png"))
        XCTAssertEqual(name, "Holiday")
        let calls_provider = await provider.callCount
        XCTAssertEqual(calls_provider, 0, "no OCR text means nothing to ask about")
    }
}

/// Tiny actor flag, so the consent test can observe whether the send closure ran.
private actor Attempted {
    private(set) var value = false
    func mark() { value = true }
}
