# Phase 03 — Intelligence

**Status:** 🔧 In Progress
**Targets:** `GrootKit` + `GrootApp`

## Objective

Make organization content-aware rather than extension-based, and round out the
file-management capabilities.

## Deliverables

- ✅ **AI Categorization Agent** — content-aware sorting (metadata + OCR + document
  text) into Research/Finance/Career/Programming/… plus **unlimited custom
  categories**, powered by a local LLM with structured (JSON) output validated
  before any action. Reuses the `AIService` abstraction and `FileService`.
  Shipped as [Phase 08](08-ai-categorization.md) (`CategorizationAgent`).
- ✅ **Smart Renaming** — generalize the screenshot rename pipeline to any file
  type. Shipped as `SmartRenameAgent` (`Sources/GrootKit/Agents/SmartRenameAgent.swift`):
  reuses `ContentExtractor`/`FilenameSuggester` from Phase 08's seam, renames
  in place through the standard move/approval/journal pipeline, and stays
  disjoint from `ScreenshotAgent` (mutual exclusion) and safe alongside
  `CategorizationAgent` (documented race, self-healing via `FileService`'s
  guards, explicit `.fileCreated` re-publish for downstream agents).
- **Large File Manager** — detect files over configurable limits; suggest
  compress/archive/delete/move.
- **Empty Folder Cleanup** — detect + preview + confirm.
- **Intelligent Trash Management** — estimate recoverable space, check backup
  availability, summarize, require approval before emptying.
- **Similar Image Detection** — Vision feature prints for burst/near-duplicate/
  edited copies; recommend the highest-quality version.

## Depends on

- Phase 02 agents, `ApprovingAgent`, `FileScanner`, `DuplicateDetectionAgent`
  (extends its perceptual path).

## Verification

- Unit tests for categorization prompt→result mapping (stubbed LLM), large-file
  thresholds, empty-folder detection, and perceptual grouping fixtures.
