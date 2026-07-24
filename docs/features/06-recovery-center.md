# Feature: Recovery Center & Undo History

**Spec:** [.claude/specs/06-recovery-center.md](../../.claude/specs/06-recovery-center.md) — ✅ Complete

## Objective

Give users a single, trustworthy place to review every file operation Groot
has performed and reverse any of them — including restoring trashed
duplicates back to their original location. The capstone of the safety
model: nothing Groot does is one-way.

## User Story

As a Mac user, I want to see everything Groot has ever moved, renamed, or
trashed in one searchable window, and undo any of it — including bringing
back a file a duplicate scan sent to the Trash.

## Technical Design

- **Trash becomes reversible.** `FileService.trash(_:agentID:)`
  (`Sources/GrootKit/Services/FileService.swift`) now captures the resulting
  Trash URL via `trashItem(at:resultingItemURL:)` and stores it as
  `JournalEntry.destinationPath` (previously always `nil`).
  `FileOperationKind.trash.isReversibleInApp` is now `true` — distinct from
  `isDestructive` (still `true`, so trashing always requires approval).
- **`FileService.undo(_:)`** (already generic over move/rename) now also
  reverses trash entries, since restoring is mechanically identical: move
  `destinationPath` back to `sourcePath`. `FileService.restore(_:)` is a
  semantically-named wrapper over the same call for the Recovery Center's
  "Restore" action. Both return the reverted `JournalEntry`.
- **`JournalFilter`** (`Models/RecoveryFilter.swift`) — a composable,
  `Sendable` filter (agent, kind, revert-state, date range, search text) with
  one pure `matches(_:)` predicate shared by `InMemoryJournalStore` and
  translated to a parameterized `WHERE` clause by `SQLiteJournalStore`.
- **`JournalStore`** gains `entries(matching:)`, `deleteEntries(olderThan:revertedOnly:)`,
  and `deleteAll()` — retention that only ever touches journal rows, never a
  file on disk.
- **`AppModel`** exposes `recoveryEntries`, `loadRecovery(filter:)`,
  `restore(_:)`, `batchRestore(_:)`, and the two retention methods. `undo`/
  `restore` now also re-publish `.operationJournaled` with the reverted
  entry, so the File Monitor's loop guard suppresses the FSEvents a restore
  triggers (the same mechanism that already suppresses agent-originated
  writes).
- **`RecoveryCenterView`** — a new `Window("Recovery Center", id: "recovery")`
  scene: filter bar (agent/kind/revert-state/search), a live list of
  `RecoveryRow`s with per-row status and Undo/Restore, multi-select batch
  restore with a per-item outcome summary, and a retention menu (clear old
  reverted entries / clear all history, both confirmed).

## Files

- `Sources/GrootKit/Models/RecoveryFilter.swift`
- `Sources/GrootKit/Services/{JournalStore,SQLiteJournalStore,FileService}.swift`
- `GrootApp/App/{AppModel,GrootApp,MenuBarView}.swift`
- `GrootApp/UI/Recovery/{RecoveryCenterView,RecoveryRow,RecoveryFilterBar}.swift`
- `GrootApp/UI/Dashboard/DashboardComponents.swift` (Undo → Restore label for trash rows)
- `Tests/GrootKitTests/RecoveryTests.swift`

## Acceptance Criteria

- [x] The Recovery Center lists the complete journal, newest first.
- [x] Filtering by agent/kind/reverted-state and searching narrows the list.
- [x] Undo on a move/rename restores the file and marks the row reverted.
- [x] Restore on a trashed item returns it from the Trash to its original path.
- [x] Batch restore reports per-item outcomes and only reverts successes.
- [x] Clearing history removes journal rows without touching any file.
- [x] Legacy/unavailable/already-reverted rows show correct status and disable their action.

## Screenshots

_Placeholder — capture the Recovery Center window: filter bar, a mixed
move/trash history, a multi-selection with the batch restore bar, and the
retention menu._
