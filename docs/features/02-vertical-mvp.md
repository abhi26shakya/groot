# Feature: Vertical MVP (shippable v0.1)

**Spec:** [.claude/specs/02-vertical-mvp.md](../../.claude/specs/02-vertical-mvp.md) — ✅ Complete

## Objective

Turn the Phase 0 runtime into a real, runnable macOS app: live file
monitoring, a first intelligent agent (Screenshot rename), organizing agents,
duplicate detection, storage analysis, and a SwiftUI shell with durable
persistence.

## User Story

As a Mac user, I want Groot to watch my Desktop and Downloads, quietly clean
up screenshots and duplicates (asking first), and show me what it's doing
from a menu bar app — with everything reversible.

## Technical Design

- `SQLiteJournalStore` — durable Undo journal over system `libsqlite3`.
- `VisionOCR` + `HeuristicFilenameSuggester` (+ optional
  `OllamaFilenameSuggester`) for screenshot renaming.
- `FSEventsWatcher` + `FileMonitoringAgent` — watches Desktop/Downloads,
  loop-guarded against the app's own journaled writes.
- `ScreenshotAgent` — OCR → rename, full preview/approval/autopilot loop; the
  reference implementation other agents' approval flow is modeled on.
- `DownloadsOrganizerAgent` — sorts new downloads into category folders by
  `FileCategory`.
- `DesktopCleanerAgent` — archives stale top-level Desktop files.
- `DuplicateDetectionAgent` — SHA-256 grouping; approval-gated trash,
  originals always kept.
- `StorageAnalyzerAgent` — largest files + plain-language recommendations,
  read-only.
- `ApprovingAgent` protocol — the UI routes approve/reject to any agent by
  `ApprovalRequest.agentID`.
- `GrootApp` — SwiftUI menu bar app: dashboard (stats, scan actions, storage
  insights, duplicate report, approvals, activity + Undo), floating glass
  bubble panel with physics, Full Disk Access onboarding banner.

## Files

- `Sources/GrootKit/Agents/{FileMonitoringAgent,FSEventsWatcher,ScreenshotAgent,DownloadsOrganizerAgent,DesktopCleanerAgent,DuplicateDetectionAgent,StorageAnalyzerAgent}.swift`
- `Sources/GrootKit/Services/{SQLiteJournalStore,VisionOCR}.swift`
- `GrootApp/App/{AppModel,GrootApp,MenuBarView}.swift`
- `GrootApp/UI/**`

## Acceptance Criteria

- [x] App builds via `xcodegen generate` + `xcodebuild`/Xcode and launches.
- [x] Taking a screenshot triggers an OCR-based rename proposal in Approval
      mode.
- [x] Dropping a file in Downloads sorts it into a category folder.
- [x] Duplicate scan groups by SHA-256 and only trashes with approval.
- [x] All actions appear in the activity log and are undoable.

## Screenshots

_Placeholder — capture from the running app: menu bar icon, dashboard,
bubble panel, approval sheet._
