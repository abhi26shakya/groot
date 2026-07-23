# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Groot is an AI-powered Storage Management Agent for macOS — designed to grow into a general "AI operating layer" where many specialized agents cooperate. Storage management is the first capability. Distribution target is a **notarized DMG outside the App Store** (needs Full Disk Access, which the App Store sandbox forbids). AI is **local-first**: Apple Vision OCR + an optional local Ollama server; cloud LLMs are opt-in only.

The full architecture/roadmap lives at `~/.claude/plans/read-this-and-come-validated-owl.md`.

## Phase specifications

All phase specs live in **`.claude/specs/`** only, numbered sequentially
(`01-…md`, `02-…md`, …) with descriptive filenames; `.claude/specs/README.md` is
the index. Use the **`/create-spec`** command (`.claude/commands/create-spec.md`)
to add the next phase — it enforces the location, numbering, required section
template, and index update. **Never create a phase `.md` file anywhere else.**
`README.md`/`CLAUDE.md` are project docs, not phase specs.

## Two-target layout (this is the key structural fact)

- **`GrootKit`** (SwiftPM library, `Sources/GrootKit/`) — the entire runtime and all agents. **No UI, no AppKit-window code.** This is what makes agents unit-testable headlessly with `swift test`. It is intentionally **dependency-free** (uses system `libsqlite3`, `Vision`, `CoreServices` — nothing fetched over the network).
- **`GrootApp`** (SwiftUI app, `GrootApp/`) — thin UI layer that links `GrootKit`. The Xcode project is **generated** from `project.yml` by XcodeGen and is not committed; regenerate it after changing sources or `project.yml`.

`Package.swift` is the source of truth for `GrootKit`; the app just links the product.

## Commands

```bash
# Runtime + agents (fast, headless, offline) — do this for most work:
swift build
swift test
swift test --filter ScreenshotAgentTests            # one test class
swift test --filter ScreenshotAgentTests/testDetection   # one test

# The macOS app:
brew install xcodegen        # one-time
xcodegen generate            # regenerate Groot.xcodeproj after adding files / editing project.yml
xcodebuild -project Groot.xcodeproj -scheme GrootApp -destination 'platform=macOS' build
open Groot.xcodeproj         # then ⌘R in Xcode
```

Adding a new source file under `GrootApp/` requires a `xcodegen generate` before it's picked up (the project globs `GrootApp/`). New files under `Sources/GrootKit/` are picked up automatically by SwiftPM.

## Architecture (the parts that span files)

Everything is built on one pattern: **agents are actors that communicate only through a broadcast bus; a coordinator drives their lifecycle.** Adding a capability = adding one `Agent` — no runtime changes.

- **`Agent` protocol** (`Runtime/Agent.swift`) — the single extension point. Every capability is an `actor` conforming to it. `descriptor` and `id` are `nonisolated` (immutable) so the UI/coordinator read them without awaiting.
- **`MessageBus`** (`Runtime/MessageBus.swift`) — broadcast `AsyncStream`; each subscriber gets its own stream. Agents **never call each other directly** — they publish/subscribe `BusEvent`s (`Models/BusEvent.swift`). The typed event vocabulary is the whole contract between agents.
- **`AgentManager`** (`Runtime/AgentManager.swift`) — registers agents, runs an event pump that fans every `BusEvent` out to each agent's `handle(_:)`, aggregates the latest `AgentReport` per agent, and produces `Snapshot`s for the UI. `bus` is `nonisolated let` so UI/tests can publish onto it. Note: `.agentReport` is **not** re-fanned to agents, but `.operationJournaled` **is** (the File Monitor needs it as a loop guard).
- **`FileService`** (`Services/FileService.swift`) — **the only path that mutates the filesystem.** It writes a `JournalEntry` **before** acting (this is what powers Undo / Recovery / activity log). Deletes go to the Trash (`trashItem`), never `unlink`. It refuses to clobber an existing destination. `JournalStore` (`Services/JournalStore.swift`) is the persistence boundary: `InMemoryJournalStore` for tests, `SQLiteJournalStore` in production.

### Safety model — respect it when adding agents

`AutonomyMode` (`Models/AgentIdentity.swift`) is per-agent: `.preview` proposes only (no filesystem change), `.approval` publishes `.approvalRequested` and waits, `.autopilot` acts on reversible ops. `FileOperationKind.isDestructive` (`Models/JournalEntry.swift`) gates behavior — **destructive ops (trash/delete/overwrite) must always require approval regardless of mode.** `ScreenshotAgent` is the reference implementation of the full preview/approval/autopilot loop (including `approve(_:)`/`reject(_:)` for pending proposals).

### App wiring

`AppModel` (`GrootApp/App/AppModel.swift`) is the single `@MainActor @Observable` view model: it constructs the bus/manager/store/agents in `bootstrap()`, runs two loops (publish `.tick` every 1s; poll `manager.snapshot()` every 0.5s into observable state), listens for approval requests, and owns the floating `BubblePanelController`. It holds a **typed** reference to `ScreenshotAgent` because `approve`/`reject` aren't part of the `Agent` protocol.

## Conventions specific to this codebase

- **Swift 6 language mode with complete concurrency** is enforced (`swiftLanguageMode(.v6)` in Package.swift, `SWIFT_STRICT_CONCURRENCY: complete` in project.yml). Everything must be `Sendable`-correct. Common gotchas already solved here: actor `deinit` can't touch isolated state (see `nonisolated(unsafe) var db` in `SQLiteJournalStore`); actor `init` can't call isolated methods (bootstrap runs as `static` against the raw handle); test helpers passed to `async let` must be `static` to avoid sending `self`.
- **Pure functions for anything hardware/OS-dependent, so it's testable.** FSEvents flag→event mapping is `FSEventsWatcher.classify(flags:)`; screenshot detection is `ScreenshotAgent.isScreenshot(_:)`; filename cleanup is `FilenameSanitizer`. The C-dependent / Vision-dependent parts are verified by a tolerant live test or manually in the app.
- **`FSEventsWatcher`** owns the raw `FSEventStreamRef` and is `@unchecked Sendable`; it passes `Unmanaged<Self>` through `FSEventStreamContext.info` and must balance that retain in `stop()`/on creation failure. Its callback runs on a private dispatch queue — agents hop back into their actor via `Task { await self?.ingest(...) }`.
- **New agents are injected their dependencies** (recognizer, suggester, `FileService`, roots/paths) rather than constructing them, so tests can substitute stubs (e.g. `StubRecognizer` in `ScreenshotAgentTests`).
