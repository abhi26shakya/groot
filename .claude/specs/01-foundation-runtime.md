# Phase 01 — Foundation & Agent Runtime

**Status:** ✅ Complete
**Targets:** `GrootKit` (SwiftPM library)

## Objective

Stand up the modular multi-agent runtime that every capability plugs into, plus
the journaled filesystem layer that makes every later action safe and reversible.
Fully headless and unit-testable — no UI, no external dependencies.

## Scope / Deliverables

- **`Agent` protocol** (`Sources/GrootKit/Runtime/Agent.swift`) — the single
  extension point. Every capability is an `actor` conforming to it. `descriptor`
  and `id` are `nonisolated`.
- **`MessageBus`** (`Runtime/MessageBus.swift`) — broadcast `AsyncStream`; agents
  publish/subscribe `BusEvent`s and never call each other directly.
- **`AgentManager`** (`Runtime/AgentManager.swift`) — registry, lifecycle
  (start/pause/resume/stop), event pump, per-agent `AgentReport` aggregation, and
  `Snapshot`s for the UI.
- **`FileService`** (`Services/FileService.swift`) — the only path that mutates the
  filesystem. Journals a `JournalEntry` **before** acting; move/undo round-trip;
  Trash-based delete (never `unlink`); refuses to clobber.
- **`JournalStore`** protocol + `InMemoryJournalStore` (persistence boundary).
- **Safety model** — `AutonomyMode` (preview/approval/autopilot),
  `FileOperationKind.isDestructive`, `ApprovalRequest` (`Models/`).
- **`HeartbeatAgent`** — reference agent proving lifecycle + reporting end-to-end.

## Non-goals

- No SwiftUI, no persistence backend beyond in-memory, no real filesystem watching.

## Verification

- `swift test` — `MessageBusTests`, `AgentManagerTests`, `FileServiceTests`
  (move → journal → undo restores original).
