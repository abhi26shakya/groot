# Feature: AI Categorization Agent — Content-Aware Sorting

**Spec:** [.claude/specs/08-ai-categorization.md](../../.claude/specs/08-ai-categorization.md) — ✅ Complete

## Objective

Ship the first content-aware agent: a `CategorizationAgent` that reads what a
file actually *contains* and files it into a meaningful top-level category
(Research, Finance, Career, Legal, Personal, … plus user-defined categories),
using the local-first `AIProvider` stack from Phase 07 — purely additive, with
no runtime, bus, or `FileService` changes.

## User Story

As a Mac user, I want new documents and images on my Desktop/Downloads sorted
by what they're actually about, not just their file extension — and I want to
approve every move before it happens.

## Technical Design

- `ContentExtractor` (`Services/ContentExtractor.swift`) — bounded excerpt
  (default 2,000 chars): plain text/Markdown/code read directly, PDF via
  PDFKit, images via `VisionOCR`.
- `CategorizerUseCase` (`Services/AI/UseCases.swift`) — the model picks one of
  the *allowed* categories or returns nothing; below the confidence threshold
  is never a guess.
- `CategoryCatalog` (`Models/CategoryCatalog.swift`) — built-in categories +
  unlimited user-defined ones, each mapping to a destination folder.
- `CategorizationAgent` (`Agents/CategorizationAgent.swift`) — reacts to
  `.fileCreated`, skips directories/dotfiles/partial-downloads/its own output,
  claims only the `.documents`/`.pictures` coarse buckets (leaving
  installers/archives/media/audio/code to `DownloadsOrganizerAgent` so the two
  agents never fight over the same file), and files matches through the
  standard `ApprovalService.evaluate` → journaled `FileService.move` path.
- Extension fallback: when AI is unavailable/undecided and the user opted in,
  falls back to `FileCategory.forURL` coarse buckets; otherwise skips the
  file entirely.

## Files

- `Sources/GrootKit/Agents/CategorizationAgent.swift`
- `Sources/GrootKit/Services/ContentExtractor.swift`
- `Sources/GrootKit/Models/CategoryCatalog.swift`
- `Sources/GrootKit/Services/AI/UseCases.swift` (`CategorizerUseCase`)
- `Tests/GrootKitTests/CategorizationAgentTests.swift`,
  `Tests/GrootKitTests/CategoryCatalogTests.swift`,
  `Tests/GrootKitTests/ContentExtractorTests.swift`

## Acceptance Criteria

- [x] A new document in a watched root with clear content is proposed for a
      move to the matching category, gated by the agent's `AutonomyMode`.
- [x] Below the confidence threshold with no extension fallback, the file is
      left untouched.
- [x] Files already inside the organized root, or of a claimed-elsewhere
      type (installers/archives/media/audio/code), are never touched by this
      agent.
- [x] Every move is journaled through `FileService`, so it's undoable from
      the Recovery Center like any other agent's action.

## Screenshots

_Placeholder — capture the categorization approval card in the dashboard and
the resulting `~/Documents/Groot/<Category>/` folder._
