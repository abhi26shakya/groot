# Feature: Foundation & Agent Runtime

**Spec:** [.claude/specs/01-foundation-runtime.md](../../.claude/specs/01-foundation-runtime.md) — ✅ Complete

## Objective

Establish the actor-based, message-bus runtime that every future agent plugs
into, and the safety-first file-mutation service that makes every agent
action undoable.

## User Story

As the Groot maintainer, I want a coordinator + broadcast-bus core so that
adding a new capability is "write one `Agent` actor," not "touch shared
mutable state across the app."

## Technical Design

- `Agent` protocol (`Sources/GrootKit/Runtime/Agent.swift`) — the single
  extension point.
- `MessageBus` (`Runtime/MessageBus.swift`) — broadcast `AsyncStream`; agents
  publish/subscribe `BusEvent`s and never call each other directly.
- `AgentManager` (`Runtime/AgentManager.swift`) — registry, lifecycle,
  event pump, report aggregation, UI snapshots.
- `FileService` (`Services/FileService.swift`) — the only path that mutates
  the filesystem; journals before acting; deletes go to Trash.
- `JournalStore` (`Services/JournalStore.swift`) — persistence boundary
  (`InMemoryJournalStore`, later `SQLiteJournalStore`).
- `HeartbeatAgent` — reference agent proving the lifecycle end-to-end.
- Safety model baked into the models from day one: `AutonomyMode` (preview /
  approval / autopilot), `FileOperationKind.isDestructive`, `ApprovalRequest`.

## Files

- `Sources/GrootKit/Runtime/{Agent,MessageBus,AgentManager}.swift`
- `Sources/GrootKit/Services/{FileService,JournalStore}.swift`
- `Sources/GrootKit/Agents/HeartbeatAgent.swift`
- `Sources/GrootKit/Models/{AgentIdentity,JournalEntry}.swift`

## Acceptance Criteria

- [x] `swift build` and `swift test` succeed with zero external dependencies.
- [x] An agent can be registered, started, and produce a `Snapshot` without a
      running app.
- [x] `FileService` writes a journal entry before every filesystem mutation.
- [x] Deletes always go through Trash, never `unlink`.

## Screenshots

_Not applicable — headless runtime, no UI._
