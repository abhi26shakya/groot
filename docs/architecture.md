# Architecture

## Two-target layout

```
Package.swift          ─┐
Sources/GrootKit/       ├─ GrootKit (SwiftPM library) — runtime + all agents
Tests/GrootKitTests/    ─┘  No UI. No AppKit windows. Dependency-free (system
                            libsqlite3, Vision, CoreServices only).

project.yml            ─┐
GrootApp/                ├─ GrootApp (SwiftUI app, XcodeGen-generated project)
Groot.xcodeproj         ─┘  Thin UI layer. Links GrootKit as a package product.
```

`Package.swift` is the source of truth for `GrootKit`. The Xcode project is
**generated** from `project.yml` (`xcodegen generate`) and is not hand-edited.

## Runtime shape

```
                 ┌──────────────┐
   publish       │  MessageBus  │       fan-out via AsyncStream
  ──────────────▶│  (BusEvent)  │────────────────┬───────────────┐
                 └──────────────┘                │               │
                        ▲                        ▼               ▼
                        │                 ┌───────────┐   ┌───────────────┐
                        │                 │  Agent A  │   │   Agent B …   │
                        │                 │  (actor)  │   │   (actor)     │
                        │                 └───────────┘   └───────────────┘
                        │                        │
                 ┌──────┴───────┐                │ mutates filesystem via
                 │ AgentManager │◀── reports ────┘
                 │ (coordinator)│
                 └──────────────┘
```

- **`Agent` protocol** (`Sources/GrootKit/Runtime/Agent.swift`) is the single
  extension point. Every capability is an `actor`. `id`/`descriptor` are
  `nonisolated` so the UI and coordinator can read them without `await`.
- **`MessageBus`** (`Runtime/MessageBus.swift`) is a broadcast `AsyncStream`;
  each subscriber gets its own stream. Agents never call each other directly —
  they only publish/subscribe typed `BusEvent`s (`Models/BusEvent.swift`). That
  event vocabulary is the entire contract between agents.
- **`AgentManager`** (`Runtime/AgentManager.swift`) registers agents, runs the
  event pump that fans every `BusEvent` out to each agent's `handle(_:)`,
  aggregates the latest `AgentReport` per agent, and produces `Snapshot`s for
  the UI. `.agentReport` is **not** re-fanned to agents; `.operationJournaled`
  **is** (the File Monitor needs it as a loop guard against its own writes).
- **`RuntimeComposer`** (`Services/RuntimeComposer.swift`) is the composition
  root: it builds the database → services → agents → event pump from
  persisted settings, and is itself unit-testable (no SwiftUI app needed to
  exercise "which agents exist, what are they injected with").

## Services (the only ways the world gets touched)

| Service | Responsibility |
|---|---|
| `FileService` | **The only path that mutates the filesystem.** Journals a `JournalEntry` *before* acting (powers Undo / Recovery / activity log). Deletes go to Trash (`trashItem`), capturing the resulting Trash URL so `restore(_:)` can move it back — never `unlink`. Refuses to clobber an existing destination. |
| `JournalStore` | Persistence boundary for journal entries. `InMemoryJournalStore` (tests) or `SQLiteJournalStore` (production, over `GrootDatabase`). Also the query/retention API (`entries(matching: JournalFilter)`, `deleteEntries(olderThan:revertedOnly:)`, `deleteAll()`) behind the Recovery Center. |
| `ApprovalService` | Publishes `.approvalRequested` and resolves `approve(_:)`/`reject(_:)` for any agent conforming to `ApprovingAgent`; `ApprovalService.evaluate` is the shared preview/approval/autopilot decision point every agent calls before acting. |
| `SettingsStore` | Per-agent autonomy mode, watched roots, custom categories, Ollama toggle/model, categorization threshold — all persisted in `GrootDatabase`. |
| `GrootDatabase` | Thin wrapper over system `libsqlite3` (no external dependency). Schema for journal, settings, categories. |
| `ContentExtractor` | Bounded content excerpt for categorization: plain text/Markdown/code read directly, PDF via PDFKit, images via `VisionOCR`. |
| `VisionOCR` | Apple Vision text recognition, behind the `TextRecognizing` protocol so agents can be tested with a stub recognizer. |
| `AIService` / `AI/AIProvider.swift` | The model port (see below). |
| `DestinationResolver` | Collision-safe destination paths for moves. |
| `NotificationManager` | User-facing notifications (approvals, completions). |

## AI architecture — local-first provider chain

```
        AIProvider (protocol: capabilities, isLocal, complete(_:))
              │
   ┌──────────┼───────────────┬─────────────────────┐
   ▼          ▼                ▼                     ▼
Heuristic   Ollama          Cloud (opt-in,       FallbackChain
Provider    Provider        consent-gated)        (tries providers
(offline,   (localhost      Never runs without    in order, falls
never       :11434, model   explicit consent)      through on failure
fails)      configurable)                            or empty result)
```

- **`AIProvider`** is the single port every model sits behind — replacing the
  earlier single-purpose `FilenameSuggester` so new use cases (categorization,
  future NL rules) have something to plug into.
- **`HeuristicProvider`** never calls a model; it's the always-available
  fallback that keeps the app fully functional with no Ollama and no network.
- **`OllamaProvider`** talks to a local Ollama server; any failure is
  transparent so the app never depends on Ollama being installed.
- **`CloudProvider`** refuses to run without explicit consent
  (`SettingsStore.cloudConsent()`) — local-first is the product promise, so no
  code path may assume the user agreed.
- **`FallbackChain`** tries providers in order and falls through on failure or
  empty output — this is how "use Ollama if it's running, else stay
  on-device" is expressed without any caller knowing which providers exist.
- **Use cases** (`Services/AI/UseCases.swift`, e.g. `CategorizerUseCase`,
  `FilenameUseCase`) sit on top of a provider and turn free text into
  validated `StructuredOutput` (`Services/AI/StructuredOutput.swift`) — the
  model must pick one of the *allowed* categories or the agent leaves the
  file alone; below the confidence threshold is never a guess.

## Agents (current)

| Agent | Reacts to | Does |
|---|---|---|
| `HeartbeatAgent` | `.tick` | Reference implementation proving the lifecycle end-to-end. |
| `FileMonitoringAgent` (+ `FSEventsWatcher`) | raw FSEvents | Watches Desktop/Downloads, publishes `.fileCreated`/`.fileModified`, loop-guarded against its own journaled writes. |
| `ScreenshotAgent` | `.fileCreated` | OCR (Vision) → intelligent rename, full preview/approval/autopilot loop — the reference implementation of that loop, including `approve(_:)`/`reject(_:)`. |
| `DownloadsOrganizerAgent` | `.fileCreated` | Sorts new downloads into category folders by coarse `FileCategory`. |
| `DesktopCleanerAgent` | `.tick` (throttled) + intents | Archives stale top-level Desktop files. |
| `DuplicateDetectionAgent` | scan intents | SHA-256 grouping; **approval-gated** trash, originals always kept, never `unlink`. |
| `StorageAnalyzerAgent` | scan intents | Largest files + plain-language recommendations; read-only, never mutates. |
| `CategorizationAgent` | `.fileCreated` | Content-aware sort (Research/Finance/Career/… + custom categories) via `AIProvider` + `ContentExtractor`; claims only `.documents`/`.pictures` buckets so it doesn't fight `DownloadsOrganizerAgent` over installers/archives/media. |

## Safety model

`AutonomyMode` (`Models/AgentIdentity.swift`) is per-agent:

- **`.preview`** — proposes only, no filesystem change.
- **`.approval`** — publishes `.approvalRequested` and waits.
- **`.autopilot`** — acts immediately on reversible ops.

`FileOperationKind.isDestructive` (`Models/JournalEntry.swift`) gates this:
**destructive operations (trash/delete/overwrite) always require approval,
regardless of configured mode.** `ScreenshotAgent` is the reference
implementation of the full loop; every other agent reuses
`ApprovalService.evaluate` rather than reimplementing the decision.

`isDestructive` is deliberately independent of `isReversibleInApp`: trash is
*destructive* (always needs approval to run) yet still *reversible in-app*
(the item's resulting Trash URL is journaled, so the Recovery Center can move
it back) — the two flags answer different questions and both stay true for
`.trash`. The **Recovery Center** (`GrootApp/UI/Recovery/`) is the capstone of
this model: every journaled operation is listed, filterable, searchable, and
individually or batch-restorable, and its retention controls (`clearHistory`,
`clearAllHistory`) only ever remove journal rows — never a file on disk.

## App wiring (GrootApp)

`AppModel` (`GrootApp/App/AppModel.swift`) is the single `@MainActor
@Observable` view model. `bootstrap()` calls `RuntimeComposer.compose(...)`,
then runs two loops (publish `.tick` every 1s; poll `manager.snapshot()` every
0.5s into observable state) and listens for approval requests. It holds a
**typed** reference to `ScreenshotAgent` because `approve`/`reject` aren't
part of the `Agent` protocol. The UI itself is a menu bar item, a `Dashboard`
(stats, scan actions, storage insights, duplicate report, approvals,
activity+Undo), and a floating glass **bubble** panel (`BubbleField` +
`BubblePanelController`) with simple physics.

## Concurrency

Swift 6 language mode with **complete concurrency checking** is enforced
project-wide (`swiftLanguageMode(.v6)`, `SWIFT_STRICT_CONCURRENCY: complete`).
Everything is `Sendable`-correct. See `CLAUDE.md` for the specific gotchas
already solved (actor `deinit`, actor `init` calling isolated methods,
`async let` capturing `self`).
