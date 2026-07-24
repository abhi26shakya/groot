# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- `docs/` — architecture, developer guide, and per-feature documentation.

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
