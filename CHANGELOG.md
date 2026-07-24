# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- **Recovery Center (Phase 06):** a dedicated window listing every journaled
  operation, filterable by agent/kind/revert-state and searchable by
  filename/path, with single and multi-select batch restore and
  filesystem-inert retention controls (clear old reverted entries / clear all
  history).
- `JournalFilter` (`Models/RecoveryFilter.swift`) and matching
  `entries(matching:)` / `deleteEntries(olderThan:revertedOnly:)` /
  `deleteAll()` on `JournalStore` (`InMemoryJournalStore` and
  `SQLiteJournalStore`).
- `docs/` — architecture, developer guide, and per-feature documentation.

### Changed
- **Trash is now reversible in-app.** `FileService.trash` captures the
  resulting Trash URL as `JournalEntry.destinationPath`, and
  `FileOperationKind.trash.isReversibleInApp` is now `true` (independent of
  `isDestructive`, which stays `true` — trashing still always requires
  approval). `FileService.restore(_:)` moves a trashed item back to its
  original path; `undo(_:)` and `restore(_:)` both return the reverted entry
  and now re-publish `.operationJournaled` so the File Monitor's loop guard
  suppresses the resulting FSEvents.

## [0.1.0] — Phases 0–8

### Added
- **Runtime (Phase 0/1):** `Agent` protocol, `MessageBus`, `AgentManager`,
  `FileService` (journal-before-act, Trash-only deletes), `JournalStore`
  (in-memory + `SQLiteJournalStore`), `HeartbeatAgent`.
- **Vertical MVP (Phase 1):** `FSEventsWatcher` + `FileMonitoringAgent`,
  `ScreenshotAgent` (Vision OCR → rename, full preview/approval/autopilot
  loop), `DownloadsOrganizerAgent`, `DesktopCleanerAgent`,
  `DuplicateDetectionAgent` (SHA-256, approval-gated trash),
  `StorageAnalyzerAgent`; `GrootApp` SwiftUI shell — menu bar, dashboard,
  floating bubble panel, Full Disk Access onboarding.
- **Core services layer (Phase 07):** `AIProvider` port (`HeuristicProvider`,
  `OllamaProvider`, `CloudProvider`, `FallbackChain`), `StructuredOutput`,
  `AI/UseCases.swift`, `ApprovalPolicy`/`ApprovalService`, `SettingsStore`,
  `GrootDatabase`, `RuntimeComposer` composition root.
- **AI Categorization Agent (Phase 08):** `CategorizationAgent` — content-aware
  sorting (Research/Finance/Career/Legal/Personal/… + custom categories) via
  `ContentExtractor` (text/Markdown/code, PDF via PDFKit, images via Vision)
  and `CategorizerUseCase`, gated by the standard safety model and reusing the
  journaled `FileService.move` path.

### Changed
- `FilenameSuggester` superseded by the general-purpose `AIProvider` port so
  categorization and future natural-language rules have a shared abstraction.

[Unreleased]: https://github.com/abhi26shakya/Groot/compare/4f679ed...HEAD
[0.1.0]: https://github.com/abhi26shakya/Groot/commits/4f679ed
