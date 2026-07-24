# Feature: System Architecture — Core Services Layer

**Spec:** [.claude/specs/07-system-architecture.md](../../.claude/specs/07-system-architecture.md) — ✅ Complete

## Objective

Build the shared seam that every future intelligence feature plugs into: a
model-agnostic `AIProvider` port, a structured-output validator, a shared
approval decision point, persisted settings, and a composition root — so that
Phase 08 (and beyond) is purely additive.

## User Story

As a developer adding a new AI-driven agent, I want one provider abstraction
and one approval-evaluation function to reuse, instead of re-deriving
"local-first with opt-in cloud" and "preview/approval/autopilot" logic per
agent.

## Technical Design

- `AIProvider` protocol + `HeuristicProvider`, `OllamaProvider`,
  `CloudProvider`, `FallbackChain` (`Services/AI/AIProvider.swift`).
- `StructuredOutput` — validated, schema-constrained model output
  (`Services/AI/StructuredOutput.swift`).
- Use cases built on top of the provider port (`Services/AI/UseCases.swift`),
  e.g. `CategorizerUseCase`, `FilenameUseCase`.
- `ApprovalPolicy` / `ApprovalService` — the shared `evaluate(_:autonomy:using:)`
  decision point every agent calls before acting.
- `SettingsStore` over `GrootDatabase` — per-agent autonomy, watched roots,
  custom categories, Ollama toggle/model, categorization threshold.
- `RuntimeComposer` — composition root that assembles the whole runtime from
  persisted settings, testable without a SwiftUI app.

## Files

- `Sources/GrootKit/Services/AI/{AIProvider,StructuredOutput,UseCases}.swift`
- `Sources/GrootKit/Services/{ApprovalPolicy,ApprovalService,SettingsStore,GrootDatabase,RuntimeComposer,AIService}.swift`

## Acceptance Criteria

- [x] `FallbackChain` can be composed from any ordered list of `AIProvider`s.
- [x] `CloudProvider.complete` throws `AIError.cloudConsentRequired` without
      explicit consent.
- [x] `ApprovalService.evaluate` produces the same `.proceed` /
      `.previewOnly` / `.declined` outcome for every calling agent.
- [x] `RuntimeComposer.compose` builds a fully wired `Runtime` in tests with
      no app target.

## Screenshots

_Not applicable — internal services layer, no direct UI._
