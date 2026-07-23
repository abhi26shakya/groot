# Groot — AI Storage Management Agent for macOS

A modular, multi-agent "AI operating layer" for macOS. Storage management is the
first capability; the runtime is designed so new agents (email, photos, code
projects, …) drop in without touching the core.

See `~/.claude/plans/read-this-and-come-validated-owl.md` for the full architecture
and roadmap. Per-phase specifications live in [`.claude/specs/`](.claude/specs/README.md) —
every phase `.md` file goes there, numbered sequentially. Create the next one with
the `/create-spec` command.

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

All six agents are live in the app; use **Scan Duplicates** / **Analyze Storage** / **Tidy Desktop**
in the dashboard. **32 GrootKit tests** cover every agent's core logic.

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

## Next steps (Phase 1 — vertical MVP)

1. **App target + project generation.** Add a SwiftUI `GrootApp` target. Install
   `xcodegen` (`brew install xcodegen`) and generate `Groot.xcodeproj` from a
   `project.yml`, or add an executable/app target. Configure entitlements for
   **Full Disk Access** + user-selected files, and set up notarized signing early.
2. **Wire GRDB.** Add `GRDB.swift` in `Package.swift`, implement a
   `SQLiteJournalStore: JournalStore`, and add the schema
   (`undo_journal`, `catalog`, `rules`, `activity_log`, `agent_state`, `learning`).
3. **File Monitoring Agent** (FSEvents) → **Screenshot Agent** (Vision OCR +
   local-LLM rename) → **Downloads/Desktop organizers** → **Duplicate Detection**
   (SHA-256 + Vision feature prints) → **Storage Analyzer**.
4. **UI:** menu-bar shell + Dashboard + floating bubble panel (`NSPanel` + SwiftUI
   `Canvas`).

## Local AI dependency

Categorization / renaming / NL rules run against a local **Ollama** server
(`brew install ollama && ollama pull llama3.1`). Cloud LLM is opt-in only.
