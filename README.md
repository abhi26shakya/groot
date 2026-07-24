# Groot — AI Storage Management Agent for macOS

A modular, multi-agent "AI operating layer" for macOS. Storage management is the
first capability; the runtime is designed so new agents (email, photos, code
projects, …) drop in without touching the core.

See `~/.claude/plans/read-this-and-come-validated-owl.md` for the full architecture
and roadmap. Per-phase specifications live in [`.claude/specs/`](.claude/specs/README.md) —
every phase `.md` file goes there, numbered sequentially. Create the next one with
the `/create-spec` command.

Further reading: [`docs/architecture.md`](docs/architecture.md) (system design),
[`docs/development.md`](docs/development.md) (setup, testing, conventions),
[`docs/features/`](docs/features) (one doc per shipped feature), and
[`CHANGELOG.md`](CHANGELOG.md).

## Features

- **Live file monitoring** (FSEvents) across Desktop/Downloads, loop-guarded
  against Groot's own writes.
- **Screenshot agent** — Vision OCR → intelligent rename, with a full
  preview/approval/autopilot autonomy loop.
- **Downloads Organizer** / **Desktop Cleaner** — extension-based sorting and
  stale-file archiving.
- **Duplicate Detection** — SHA-256 grouping, approval-gated Trash, originals
  always kept.
- **Storage Analyzer** — largest files + plain-language recommendations,
  read-only.
- **AI Categorization Agent** — content-aware sorting into Research, Finance,
  Career, Legal, Personal, and custom categories, via a local-first
  `AIProvider` (on-device heuristic → optional local Ollama → opt-in cloud).
- **Recovery** — every filesystem mutation is journaled before it happens;
  deletes go to Trash, never `unlink`; everything is undoable.
- **GrootApp** — SwiftUI menu bar app: dashboard, floating glass bubble
  panel, Full Disk Access onboarding.

## Requirements

- macOS 14+ (Sonoma or later), Xcode 15+, Swift 6 toolchain.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the app
  project (`brew install xcodegen`).
- Optional: [Ollama](https://ollama.com) for local-LLM renaming/categorization
  (`brew install ollama && ollama pull llama3.1`). Cloud LLM use is opt-in
  only and off by default.

## Project Structure

```
Sources/GrootKit/     the headless runtime + all agents (SwiftPM library)
  Runtime/            Agent protocol, MessageBus, AgentManager
  Agents/             one actor per capability
  Services/           FileService, ApprovalService, SettingsStore, AI/…
  Models/             BusEvent, JournalEntry, AgentIdentity, …
Tests/GrootKitTests/  swift test — 128 tests, all headless
GrootApp/             SwiftUI app: menu bar, dashboard, bubble panel
Package.swift         source of truth for GrootKit
project.yml           XcodeGen input; Groot.xcodeproj is generated, not committed
.claude/specs/        numbered phase specifications
docs/                 architecture, developer guide, feature docs
```

## Status — Phase 1 (vertical MVP) ✅ — runnable app

A real macOS app that builds and launches. Menu-bar + dashboard UI, live FSEvents
monitoring, a Screenshot agent (Vision OCR → intelligent rename), floating agent
bubbles, and durable SQLite persistence.

**Build & run the app:**
```bash
brew install xcodegen        # one-time
xcodegen generate            # creates Groot.xcodeproj from project.yml
open Groot.xcodeproj         # ⌘R in Xcode, or:
xcodebuild -scheme GrootApp -destination 'platform=macOS' build
```
On first run, grant **Full Disk Access** (the dashboard banner deep-links to the
right Settings pane). Take a screenshot or drop a file on the Desktop to see agents
react. Screenshots default to **Approval** mode — approve from the dashboard.

Phase 1 additions on top of the runtime:
- `SQLiteJournalStore` — durable Undo journal over system `libsqlite3`.
- `VisionOCR` + `HeuristicFilenameSuggester` (+ optional `OllamaFilenameSuggester`).
- `FSEventsWatcher` + `FileMonitoringAgent` — watches Desktop/Downloads, loop-guarded.
- `ScreenshotAgent` — OCR → rename, with preview/approval/autopilot autonomy.
- `DownloadsOrganizerAgent` — sorts new downloads into category folders (by `FileCategory`).
- `DesktopCleanerAgent` — archives stale top-level Desktop files (intent + throttled tick).
- `DuplicateDetectionAgent` — SHA-256 grouping; **approval-gated** trash, originals kept, never `unlink`.
- `StorageAnalyzerAgent` — largest files + plain-language recommendations (read-only).
- `ApprovingAgent` protocol — UI routes approve/reject to any agent by `ApprovalRequest.agentID`.
- `GrootApp/` — SwiftUI app: menu bar, dashboard (stats, scan actions, storage insights,
  duplicate report, approvals, activity+Undo), floating glass **bubble** panel with physics,
  Full Disk Access onboarding.

All agents are live in the app; use **Scan Duplicates** / **Analyze Storage** / **Tidy Desktop**
in the dashboard.

## Status — Phase 07/08 (core services + AI categorization) ✅

- **Core services layer:** `AIProvider` port (`HeuristicProvider`,
  `OllamaProvider`, `CloudProvider`, `FallbackChain`), `StructuredOutput`,
  `ApprovalPolicy`/`ApprovalService`, `SettingsStore`, `GrootDatabase`,
  `RuntimeComposer` composition root — see
  [`docs/features/07-system-architecture.md`](docs/features/07-system-architecture.md).
- **`CategorizationAgent`:** content-aware sorting into built-in and custom
  categories via `ContentExtractor` (text/Markdown/code, PDF, Vision OCR) and
  `CategorizerUseCase`, gated by the same safety model as every other agent —
  see [`docs/features/08-ai-categorization.md`](docs/features/08-ai-categorization.md).

All seven agents + the composition root are covered by **128 GrootKit tests**
(`swift test`).

## Status — Phase 0 (foundation) ✅

Implemented and unit-tested (`swift test`, 9 tests passing):

- **`Agent`** protocol — the single extension point; every capability is an actor
  conforming to it (`Sources/GrootKit/Runtime/Agent.swift`).
- **`MessageBus`** — broadcast `AsyncStream` event bus; agents never call each
  other directly (`Sources/GrootKit/Runtime/MessageBus.swift`).
- **`AgentManager`** — central coordinator: registry, lifecycle
  (start/pause/resume/stop), event pump, report aggregation, UI snapshots
  (`Sources/GrootKit/Runtime/AgentManager.swift`).
- **`FileService`** — the *only* path that mutates the filesystem. Journals every
  op **before** it runs → powers Undo / Recovery Center. Deletes go to Trash,
  never `unlink` (`Sources/GrootKit/Services/FileService.swift`).
- **`JournalStore`** — persistence boundary; in-memory now, GRDB/SQLite later.
- **`HeartbeatAgent`** — reference agent proving the lifecycle end-to-end.

The safety model (`AutonomyMode`: preview / approval / autopilot,
`FileOperationKind.isDestructive`, `ApprovalRequest`) is baked into the models
from day one.

## Build & test

```bash
swift build
swift test
```

Phase 0 is intentionally **dependency-free** so it builds offline.

## Next steps

See the still-planned phases in [`.claude/specs/README.md`](.claude/specs/README.md):
**03 Intelligence**, **04 Interaction & Learning**, **05 Platform**, and
**06 Recovery Center & Undo History**. Add the next phase spec with
`/create-spec`.

## Local AI dependency

Categorization / renaming / NL rules run against a local **Ollama** server
(`brew install ollama && ollama pull llama3.1`). Cloud LLM is opt-in only.

## Development Workflow

See [`docs/development.md`](docs/development.md) for full setup, build, and
testing instructions, branch strategy, and coding conventions.

## Contributing

This is currently a single-maintainer project. Changes land via feature
branches merged into `main` through a PR; `main` must always build and pass
`swift test`. New phases start with `/create-spec`; see `CLAUDE.md` for the
conventions every change follows.

## License

No license file is currently published for this repository; all rights are
reserved by the author unless a `LICENSE` file is added.
