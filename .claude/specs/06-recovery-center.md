# Phase 06: Recovery Center & Undo History

**Status:** 🔜 Planned
**Targets:** `GrootKit` + `GrootApp`

## Objective

Give users a single, trustworthy place to review **every** file operation Groot
has performed and reverse any of them — including restoring trashed duplicates
back to their original location. Today the dashboard shows a truncated activity
list with per-move Undo; this phase turns that into a dedicated, searchable,
filterable **Recovery Center** and makes trash operations reversible in-app.

This is the capstone of the safety model: nothing Groot does is one-way.

## Features

- A dedicated **Recovery Center** window (separate SwiftUI `Window` scene, also
  reachable from the menu bar and a dashboard "Open Recovery Center" button).
- Full, scrollable history of journaled operations (move / rename / trash), newest
  first, not truncated.
- **Filter** by agent, operation kind, reverted-state, and date range.
- **Search** by filename or path substring.
- **Single undo** and **multi-select batch undo/restore**.
- **Restore-from-Trash**: trashed items (e.g. duplicates) can be moved back to
  their original path.
- Per-row status: Applied · Reverted · Unavailable (source/target gone).
- Retention controls: clear reverted entries older than N days; "Clear history"
  (removes journal rows only — never touches files).
- Empty state with guidance.

## Functional Requirements

1. Show all `JournalEntry` rows from the `JournalStore`, sorted by `timestamp`
   descending.
2. For each entry display: filename, source→destination, agent, kind, timestamp,
   and current status.
3. **Undo (move/rename):** move the file at `destinationPath` back to
   `sourcePath`; mark `revertedAt`. Fail gracefully if the destination is missing
   or the origin is now occupied (surface a clear reason, do not crash).
4. **Restore (trash):** move the trashed item back to `sourcePath`; mark
   `revertedAt`. Requires that `trash` operations record the trashed item's URL
   (see Technical Requirements) — without it, restore is disabled for that row.
5. Batch actions operate over the current selection; each item is attempted
   independently and a per-item result is reported (N restored, M skipped + why).
6. Filters and search compose (AND) and update the list live.
7. Retention/clear affects **journal rows only**; it must never delete or move a
   real file.
8. Reverting an already-reverted entry is rejected (idempotent), reusing the
   existing `FileService.FileServiceError.alreadyReverted`.

## Technical Requirements

- **Make trash reversible.** In `FileService.trash(_:agentID:)`
  (`Sources/GrootKit/Services/FileService.swift`), capture the trashed URL via
  `trashItem(at:resultingItemURL:)` and store it in `JournalEntry.destinationPath`
  (currently `nil`). Update `FileOperationKind.trash.isReversibleInApp` to `true`
  and add `FileService.restore(_ entryID:)` (or extend `undo` to handle `.trash`
  by moving `destinationPath` → `sourcePath`).
- **Query API on `JournalStore`** (`Services/JournalStore.swift`): add
  `entries(matching filter: JournalFilter) async throws -> [JournalEntry]`, with a
  `JournalFilter` value type (agentID?, kinds: Set, revertedOnly/appliedOnly,
  dateRange?, searchText?). Implement in both `InMemoryJournalStore` and
  `SQLiteJournalStore` (the SQLite version builds a parameterized `WHERE`; reuse
  the existing `idx_journal_time` index).
- **Retention:** add `JournalStore.deleteEntries(olderThan: Date, revertedOnly: Bool)`
  and `deleteAll()`. SQLite via `DELETE`; in-memory via dictionary filter.
- **AppModel** (`GrootApp/App/AppModel.swift`): expose `recoveryEntries` state, a
  `loadRecovery(filter:)`, `undo(_:)` (already exists — extend to route trash to
  restore), `batchUndo(_:)`, and retention methods. Keep all filesystem calls on
  the `FileService` actor.
- Reuse existing types: `JournalEntry`, `AgentID`, `ByteFormat`, `FileService`.

## File Structure

```
Sources/GrootKit/
  Models/RecoveryFilter.swift          # new: JournalFilter value type
  Services/JournalStore.swift          # +query/retention methods on protocol & InMemory impl
  Services/SQLiteJournalStore.swift    # +parameterized query + delete methods
  Services/FileService.swift           # trash records destination; restore()/undo handles .trash

GrootApp/
  App/GrootApp.swift                   # +Window("Recovery", id: "recovery") scene
  App/AppModel.swift                   # +recovery state, filters, batch undo, retention
  UI/Recovery/RecoveryCenterView.swift # new: list + toolbar (filters/search)
  UI/Recovery/RecoveryRow.swift        # new: one entry row with status + action
  UI/Recovery/RecoveryFilterBar.swift  # new: agent/kind/date/search controls

Tests/GrootKitTests/
  RecoveryTests.swift                  # new
```

## Database Changes (if applicable)

- No new tables. `undo_journal.destination_path` is now populated for `trash`
  rows (previously `NULL`); existing NULL rows remain non-restorable and render as
  "Unavailable" — no migration required (`PRAGMA user_version` stays `1`; bump to
  `2` only if a query index is added).
- Optional: add `CREATE INDEX IF NOT EXISTS idx_journal_agent ON undo_journal(agent_id);`
  if agent filtering becomes slow (bump `user_version` to `2`).

## API Changes (if applicable)

Internal (no network API). Additions:

- `JournalStore`: `entries(matching:)`, `deleteEntries(olderThan:revertedOnly:)`,
  `deleteAll()`.
- `FileService`: `restore(_ entryID:)`; `undo(_:)` accepts `.trash` entries that
  have a `destinationPath`.
- `FileOperationKind.trash.isReversibleInApp == true`.

## UI/UX Requirements (if applicable)

- New window, min size ~720×520, same glass/Vision-Pro aesthetic
  (`.ultraThinMaterial`, gradient backdrop) as the dashboard.
- Top toolbar: search field + filter chips (Agent ▾, Kind ▾, Date ▾, "Reverted
  only" toggle) + retention menu.
- List rows: kind icon, filename (bold), `source → destination` (secondary,
  truncating middle), agent + relative time, right-aligned status badge and an
  **Undo/Restore** button (disabled with tooltip when unavailable/already
  reverted).
- Multi-select (⌘/⇧-click) with a batch action bar showing "Restore N selected".
- Confirmation only for batch operations and for "Clear history".
- Empty state: icon + "No operations yet — Groot hasn't moved anything."

## Edge Cases

- **Origin occupied:** a file already exists at `sourcePath` → skip, status
  "Can't restore: original location occupied" (reuses `destinationExists`).
- **Destination missing:** the moved/trashed file no longer exists (user emptied
  Trash, moved it in Finder) → status "Unavailable", action disabled.
- **Legacy trash rows** with `destinationPath == nil` (created before this phase)
  → non-restorable, clearly labeled.
- **Already reverted:** action disabled; programmatic attempt returns
  `alreadyReverted`.
- **Batch partial failure:** report per-item outcomes; never abort the whole batch
  on one failure.
- **External moves:** if FSEvents re-observes a restored file, the loop guard
  (`.operationJournaled`) must suppress re-processing — publish it on restore too.
- **Retention safety:** clearing history must be filesystem-inert; assert no
  `FileManager` mutation occurs on that path.

## Acceptance Criteria

- [ ] A Recovery Center window lists the complete journal, newest first.
- [ ] Filtering by agent/kind/reverted and searching by filename narrows the list.
- [ ] Undo on a move/rename restores the file to its original path and marks the
      row reverted.
- [ ] Restore on a trashed duplicate returns it from the Trash to its original
      path and marks the row reverted.
- [ ] Batch restore of a multi-selection reports N restored / M skipped with
      reasons and reverts only the successful ones.
- [ ] "Clear history" removes journal rows without touching any file on disk.
- [ ] Unavailable/legacy/already-reverted rows show correct status and disabled
      actions.

## Testing Checklist

- [ ] `FileService.trash` records the resulting Trash URL in `destinationPath`.
- [ ] `FileService.restore`/`undo` moves a trashed item back to origin; sets
      `revertedAt`; publishes `.operationJournaled`.
- [ ] Restore rejects when origin is occupied (`destinationExists`) and when the
      trashed file is missing (`sourceMissing`).
- [ ] `JournalStore.entries(matching:)` returns correct results for each filter
      dimension and combinations, in both in-memory and SQLite implementations.
- [ ] `deleteEntries(olderThan:revertedOnly:)` and `deleteAll()` remove only the
      intended rows and touch no files (verify a fixture file still exists after).
- [ ] Batch restore over a mixed selection (some restorable, some not) yields the
      expected per-item outcomes.
- [ ] Full suite green: `swift test`; app builds: `xcodegen generate && xcodebuild -scheme GrootApp build`.

## Dependencies

- **Phase 01 — Foundation & Agent Runtime** (`JournalStore`, `FileService`,
  `JournalEntry`, `FileOperationKind`, the `.operationJournaled` loop guard).
- **Phase 02 — Vertical MVP** (`SQLiteJournalStore`, the dashboard activity list
  this replaces/extends, `DuplicateDetectionAgent` which produces trash entries).

## Notes

- This phase deliberately does **not** add near-duplicate/perceptual image
  matching — that belongs to Phase 03 (Similar Image Detection). Keep scope to
  history + reversal.
- Making `trash` reversible slightly changes semantics: duplicates removed by the
  Duplicate Detection agent become one-click restorable, strengthening the
  "nothing is destructive without recourse" guarantee. Emptying the system Trash
  remains outside Groot's control and correctly renders those rows "Unavailable".
- Consider surfacing a compact "recently reverted" toast in the dashboard when an
  undo happens from the Recovery Center, for feedback continuity.
