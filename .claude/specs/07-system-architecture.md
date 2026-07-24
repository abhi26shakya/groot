# Phase 07 — System Architecture: the Core Services Layer

**Status:** 🚧 In progress
**Targets:** `GrootKit` (SwiftPM library) · `GrootApp` (SwiftUI app, workstream D only)

## Objective

Build the **Core Services** layer of the roadmap architecture and harden the
runtime so Phases 03–06 drop in additively. Phases 01–02 delivered the agent
spine (`Agent` → `MessageBus` → `AgentManager`, six agents, `FileService` +
`SQLiteJournalStore`, SwiftUI app). This phase fills what is missing beneath it:
a real approval gate, a migratable database, persisted settings, agent health,
a non-blocking event pump, a widened AI port, and an app layer that isn't one
god object.

**This phase adds no agents and no user-facing features.** It is behavior-
preserving by design, with three deliberate exceptions listed under
[Acceptance Criteria](#acceptance-criteria).

## Motivation (what is broken today)

| Gap | Evidence in the current code |
|---|---|
| No `ApprovalService` — the rule "destructive ops always require approval regardless of mode" is documented but **enforced nowhere** | The `switch autonomy` block is copy-pasted per agent: `Agents/ScreenshotAgent.swift:91-110`, `Agents/DownloadsOrganizerAgent.swift:73-86`, and twice more. Each agent sets `isDestructive` itself; a new agent that omits the switch silently bypasses the safety model. |
| Database is one table with no migrations | `Services/SQLiteJournalStore.swift:54-70` hardcodes `PRAGMA user_version=1` and owns a private connection. |
| Nothing persists across launches | Roots and autonomy modes are hardcoded in `GrootApp/App/AppModel.swift:68-88`. |
| Event pump is head-of-line blocking | `Runtime/AgentManager.swift:71-73` awaits each agent serially; one OCR or hash sweep stalls delivery to every other agent. |
| `AgentHealth` referenced but never defined | `Models/AgentIdentity.swift:25` cites it; errors are stringified into `lastAction`. |
| AI port too narrow for Phases 03–04 | `FilenameSuggester` (`Services/AIService.swift:13`) is single-purpose. |

## Progress

**All workstreams implemented.** `swift test` is green at **104 tests** (from 32);
both targets build. The seven agents lost 273 lines and gained 181.

| # | Item | Status |
|---|------|--------|
| 2 | `GrootDatabase` + v1→v3 migrations; `SQLiteJournalStore` as a façade | ✅ Done |
| 3 | `ApprovalPolicy` (pure) + 10 truth-table tests | ✅ Done |
| 4 | `ApprovalService`; all four agents migrated; `ApprovingAgent` retired | ✅ Done |
| 5 | `AgentHealth` + report/bus plumbing | ✅ Done |
| A1 | Per-agent mailboxes in `AgentManager` | ✅ Done |
| A3 | `AgentCore` / `CoreAgent`; all seven agents migrated | ✅ Done |
| A4 | `Scheduler` + opt-in `tickCadence` | ✅ Done |
| A5 | `GrootLog` + `.agentFailed` propagation | ✅ Done |
| B3 | `SettingsStore` (roots, autonomy, consent persist) | ✅ Done |
| B4 | `NotificationManager` + `UserNotifier` | ✅ Done |
| C | `AIProvider` port, `StructuredOutput`, `FilenameUseCase`, `CategorizerUseCase` | ✅ Done |
| D | `RuntimeComposer`, event-driven UI with coalescing | ✅ Done |

Remaining from the original plan: the **view-model split** (`DashboardViewModel` /
`ApprovalsViewModel` / `BubblesViewModel`). `AppModel` shed composition and
polling to `RuntimeComposer` and the event stream, so the split is now cosmetic
rather than structural.

### Found and fixed along the way (not in the original plan)

- **`startEventPump()` had a lost-event race.** It subscribed to the bus *inside*
  its task, so an event published immediately after the call could be dropped
  before the subscription existed. It now subscribes before returning, and is
  `async`.
- **`tickCadence` had to be a protocol requirement, not an extension default.**
  As an extension-only member it bound statically, so `any Agent` always saw
  `.none` and every agent silently stopped receiving ticks. The same trap applies
  to anything else added to `Agent` later.
- **Event-driven refresh needed coalescing.** A bulk sweep publishes one event per
  file; without a 150 ms trailing debounce each one triggered a full snapshot plus
  a `SELECT *` over the journal.

### Behavioural consequence of the gate, worth knowing

`evaluate` suspends the calling agent while a request is outstanding, so an agent
handles one approval at a time instead of queuing an unbounded pile of prompts.
Per-agent mailboxes keep this from affecting any other agent, and
`ApprovalService(timeout:)` can bound the wait — the app leaves it unset, which
matches the previous wait-forever behaviour.

## Features

1. **`ApprovalService`** — one mandatory safety gate all agents route through.
2. **`GrootDatabase`** — shared connection + versioned migrations (v1 → v3).
3. **`SettingsStore`** — durable roots, per-agent autonomy, AI consent.
4. **`NotificationManager`** — background approval notifications.
5. **Per-agent mailboxes** — no cross-agent blocking in the event pump.
6. **`AgentHealth`, `AgentCore`, `Scheduler`, `GrootLog`** — runtime hygiene.
7. **`AIProvider` port** — provider-agnostic, structured-output-validated.
8. **`RuntimeComposer` + split view models** — testable composition root.

## Functional Requirements

### FR-1 — The safety invariant is enforced in exactly one place
A pure function decides every action, and destructive work can never proceed
unattended:

| | `.preview` | `.approval` | `.autopilot` |
|---|---|---|---|
| reversible (move/rename) | `.propose` | `.askUser` | `.proceed` |
| **destructive** (trash/delete/overwrite) | `.propose` | `.askUser` | **`.askUser`** |

Destructiveness is derived from `FileOperationKind.isDestructive`
(`Models/JournalEntry.swift`), not asserted by the calling agent.

### FR-2 — Agents no longer own approval bookkeeping
`ApprovalService.evaluate(_:autonomy:)` returns a decision, suspending until the
user answers when the decision is `.askUser`. The per-agent
`pending: [UUID: (source, destination)]` dictionaries and the
`approve(_:)`/`reject(_:)` pair are deleted; the `ApprovingAgent` protocol
(`Runtime/Agent.swift:42-47`) is retired.

### FR-3 — A slow agent cannot stall the bus
With a deliberately slow agent registered, every other agent still receives all
published events promptly. Per-agent event **ordering is preserved**.

### FR-4 — State survives relaunch
Watched roots, per-agent autonomy and enabled flags, AI provider selection, and
cloud consent are read from `SettingsStore` at bootstrap and written back on
change. A fresh install behaves exactly as the current hardcoded defaults.

### FR-5 — Existing databases migrate in place
An existing `~/Library/Application Support/Groot/groot.db` at `user_version = 1`
upgrades to v3 with all `undo_journal` rows intact. No migration ever drops or
rewrites user data.

### FR-6 — Model output is validated before it can act
No string returned by any `AIProvider` reaches `FileService` without passing
through `StructuredOutput` decode + validation. Cloud providers refuse to run
unless `SettingsStore.cloudConsent` is true.

## Technical Requirements

### Workstream A — Runtime (`Sources/GrootKit/Runtime/`)

**A1. Per-agent mailboxes.** `AgentManager.register(_:)` creates one
`AsyncStream<BusEvent>` per agent (`.bufferingNewest(256)`, matching
`MessageBus`) plus a delivery `Task` looping
`for await event in inbox { await agent.handle(event) }`. `dispatch` updates
coordinator aggregates then `yield`s to each inbox and returns immediately.
`yield` returning `.dropped` increments `AgentHealth.droppedEvents`.
Deregistration finishes the continuation and cancels the task.

Dispatch semantics are otherwise unchanged: `.agentReport` is **not** re-fanned
to agents; `.operationJournaled` **is** (the `FileMonitoringAgent` loop guard
depends on it).

**A2. `AgentHealth`** (`Models/AgentHealth.swift`):
```swift
public struct AgentHealth: Sendable, Codable, Hashable {
    public var lastError: String?
    public var errorCount: Int
    public var droppedEvents: Int
    public var lastHeartbeat: Date?
}
```
Added to `AgentReport` (`Models/AgentReport.swift`) with a defaulted initializer
so existing call sites compile unchanged. New `BusEvent.agentFailed(AgentID, String)`
folds into `latestReports`.

**A3. `AgentCore`** (`Runtime/AgentCore.swift`). Actors can't inherit, so use
composition: a `struct AgentCore` holding `descriptor`, `state`, `bus`, `health`
with `mutating func report(task:last:)`. Agents declare `var core: AgentCore`
and inherit default `start/pause/resume/stop` + reporting via a protocol
extension. Removes ~30 duplicated lines from each of the six agents.

**A4. `Scheduler`** (`Runtime/Scheduler.swift`). Tick ownership moves from the UI
(`AppModel.swift:178-185`) into `AgentManager`. Agents declare a cadence
(`.none` / `.every(TimeInterval)`); only subscribers receive `.tick`.

**A5. `GrootLog`** (`Runtime/GrootLog.swift`). `os.Logger` wrapper with
categories `runtime`, `agent`, `fileops`, `ai`, `db`. Replaces the
`"failed: \(error)"` display-string pattern in agents' `perform` methods.

### Workstream B — Core services (`Sources/GrootKit/Services/`)

**B1. `ApprovalService`** (`Services/ApprovalService.swift`) — the centerpiece,
split so the rule is testable without I/O:

```swift
public enum ActionDecision: Sendable, Equatable { case proceed, propose, askUser }

public enum ApprovalPolicy {
    /// Destructive ⇒ .askUser ALWAYS, regardless of mode. This is the invariant.
    public static func decide(isDestructive: Bool, autonomy: AutonomyMode) -> ActionDecision
}
```
The actor owns pending requests, publishes `.approvalRequested`, and suspends on
a `CheckedContinuation` keyed by request id; `resolve(id:approved:)` resumes it.

*Correctness:* every path — approve, reject, timeout, task cancellation, app
quit — routes through a single `resolve` that removes the entry **before**
resuming, so a continuation is resumed exactly once and never leaked. Pending
requests are persisted and either restored or explicitly expired at launch. The
timeout is configurable and resolves to rejected.

**B2. `GrootDatabase`** (`Services/GrootDatabase.swift`). Extract the connection
and statement plumbing currently private to `SQLiteJournalStore`
(`SQLiteJournalStore.swift:161-191`) into one shared actor, keeping the
`nonisolated(unsafe) var db` + static-bootstrap pattern already solved there for
Swift 6. Replace the hardcoded pragma with an ordered migration list applied one
per transaction, stamping `user_version`. `SQLiteJournalStore` becomes a thin
façade. **`JournalStore` and `FileService` are unchanged** — that boundary
already works.

**B3. `SettingsStore`** (`Services/SettingsStore.swift`). Typed façade over the
`settings` and `agent_state` tables. Consumed by `AppModel.bootstrap()` in place
of hardcoded values; written through by the dashboard's autonomy picker.

**B4. `NotificationManager`** (`Services/NotificationManager.swift`).
`protocol Notifying: Sendable` + a `UNUserNotificationCenter` implementation and
a `SpyNotifier` for tests. Only the concrete type imports `UserNotifications`.

### Workstream C — AI layer (`Sources/GrootKit/Services/AI/`)

- **`AIProvider`** — `complete(_ request: AIRequest) async throws -> String`,
  plus `capabilities: Set<AICapability>` (`.text`, `.vision`, `.embedding`) and
  `isLocal: Bool`.
- **Implementations** — `HeuristicProvider` (no-LLM default),
  `OllamaProvider` (generalizes `AIService.swift:96-128`, **keeping** its
  fallback-on-any-failure behavior, which is correct), `CloudProvider`
  (opt-in Claude API; consult the `claude-api` skill for current model IDs).
- **`StructuredOutput`** — decode against an expected `Decodable`, retry once
  with a repair prompt, then fail closed.
- **Use cases sit on top of the port:** `FilenameUseCase(provider:)` replaces
  `FilenameSuggester` as the abstraction; `CategorizerUseCase` is added as the
  Phase 03 seam. `TextRecognizing`/`VisionOCR` are already clean ports — unchanged.
- `HeuristicFilenameSuggester` and `FilenameSuggesterTests` keep working
  throughout: it is the offline default and the deterministic test anchor.

### Workstream D — App layer (`GrootApp/`)

- **`RuntimeComposer`** — `AppModel.bootstrap()`'s wiring (`AppModel.swift:54-106`)
  moves into **GrootKit** as a composition root taking a `SettingsStore`. This
  makes it headlessly testable, which it currently is not.
- **Event-driven UI** — replace the 0.5 s `manager.snapshot()` poll
  (`AppModel.swift:187-194`) with an `.agentReport`/`.agentFailed` subscription;
  keep one slow (2 s) poll solely for `uptime`.
- **Split view models** — `DashboardViewModel`, `ApprovalsViewModel` (talks to
  `ApprovalService`, not to agents), `BubblesViewModel`. `AppModel` shrinks to a
  container. The approval listener (`AppModel.swift:196-217`) folds into
  `ApprovalsViewModel`; `approvingAgents` is deleted.
- New files under `GrootApp/` require `xcodegen generate` before they build.

## File Structure

```
Sources/GrootKit/
├── Models/
│   ├── AgentHealth.swift                 NEW
│   ├── AgentReport.swift                 MODIFIED  (+ health)
│   └── BusEvent.swift                    MODIFIED  (+ agentFailed)
├── Runtime/
│   ├── AgentCore.swift                   NEW
│   ├── Scheduler.swift                   NEW
│   ├── GrootLog.swift                    NEW
│   ├── AgentManager.swift                MODIFIED  (mailboxes, scheduler)
│   └── Agent.swift                       MODIFIED  (retire ApprovingAgent)
├── Services/
│   ├── ApprovalService.swift             NEW
│   ├── GrootDatabase.swift               NEW
│   ├── SettingsStore.swift               NEW
│   ├── NotificationManager.swift         NEW
│   ├── RuntimeComposer.swift             NEW
│   ├── SQLiteJournalStore.swift          MODIFIED  (façade over GrootDatabase)
│   ├── FileService.swift                 UNCHANGED
│   ├── JournalStore.swift                UNCHANGED
│   └── AI/
│       ├── AIProvider.swift              NEW
│       ├── OllamaProvider.swift          NEW  (from AIService.swift)
│       ├── CloudProvider.swift           NEW
│       ├── StructuredOutput.swift        NEW
│       └── UseCases.swift                NEW  (Filename, Categorizer)
└── Agents/*.swift                        MODIFIED  (AgentCore + ApprovalService)

GrootApp/
├── App/AppModel.swift                    MODIFIED  (shrinks to container)
└── ViewModels/                           NEW  (Dashboard, Approvals, Bubbles)
```

## Database Changes

Migrations applied in order, each in a transaction, stamping `PRAGMA user_version`:

- **v1** — today's `undo_journal` schema **verbatim** (`SQLiteJournalStore.swift:56-68`),
  so existing databases match without rewriting.
- **v2** — `agent_state` (`agent_id` PK, `autonomy`, `enabled`, `last_state`),
  `settings` (`key` PK, `value`), `activity_log` (append-only: `agent_id`,
  `level`, `message`, `ts`), `pending_approvals` (for FR-2 restore-or-expire).
- **v3** — `rules`, `catalog`, `learning`. Created **empty and unused** now so
  Phases 03–04 add no migration risk later.

No migration may `DROP` or rewrite existing user data.

## API Changes

Internal to `GrootKit`; there is no external API. Breaking changes for callers:

- `ApprovingAgent` is **removed**. UI routes decisions to `ApprovalService`.
- `AgentReport.init` gains a defaulted `health:` parameter (source-compatible).
- `BusEvent` gains `.agentFailed` — exhaustive `switch`es over it must be updated.

## UI/UX Requirements

- Agent cards surface `AgentHealth` (last error, dropped-event count).
- The autonomy picker writes through `SettingsStore` and survives relaunch.
- Approval sheets are unchanged visually; they now resolve via `ApprovalService`.
- A destructive action attempted in Autopilot **now prompts** where it
  previously would not — the documented rule, finally enforced.

## Edge Cases

- **Continuation discipline.** A `CheckedContinuation` resumed twice traps; one
  never resumed leaks the agent's task forever. Approve, reject, timeout,
  cancellation, and app quit must each resume exactly once.
- **App quits with approvals pending.** Restore them at next launch or expire
  them explicitly — never leave orphaned rows implying uncommitted work.
- **Mailbox saturation.** A backed-up agent drops oldest events; the drop must be
  counted and visible in health, never silent.
- **Migration on a partially-written DB** (crash mid-upgrade) — per-migration
  transactions must leave `user_version` and schema consistent.
- **Existing v1 database in the wild** — must upgrade in place with history intact.
- **Ollama absent / timing out** — must keep falling back to the heuristic
  silently, exactly as today.
- **Cloud consent revoked mid-session** — the next `CloudProvider` call refuses.
- **Agent registered twice** — the second registration must not orphan the first
  agent's delivery task.

## Acceptance Criteria

- [ ] `swift build && swift test` green; all pre-existing tests still pass.
- [ ] `ApprovalPolicy.decide` covers all 6 cells with tests, including
      `(destructive, .autopilot) == .askUser`.
- [ ] An agent in `.autopilot` attempting a `.trash` op raises an approval and
      makes **zero** filesystem changes until resolved.
- [ ] A slow agent does not delay delivery to other agents (test proves it).
- [ ] A v1 `groot.db` upgrades to v3 with journal rows readable.
- [ ] Autonomy + roots survive quit and relaunch.
- [ ] `ApprovingAgent` and all per-agent `pending` dictionaries are gone.
- [ ] `xcodegen generate && xcodebuild -scheme GrootApp build` succeeds.
- [ ] **Only** these user-visible changes: persisted settings, health on agent
      cards, and destructive ops prompting in Autopilot.

## Testing Checklist

**Headless — `swift test`:**
- [ ] `ApprovalPolicyTests` — the 6-case safety truth table.
- [ ] `ApprovalServiceTests` — approve / reject / timeout / cancel each resume
      exactly once; no leaked pending entries.
- [ ] Destructive-gate integration test against a temp dir: autopilot + `.trash`
      → request raised, zero filesystem mutation until resolved.
- [ ] `AgentManagerTests` — mailbox isolation: a slow stub agent alongside a fast
      one; the fast agent receives all N events without waiting.
      *(This test fails against today's serial dispatch — it is the regression proof.)*
- [ ] `GrootDatabaseTests` — v1 fixture → v3, `user_version == 3`, rows preserved.
- [ ] `SettingsStoreTests` — write, reopen, assert values survive.
- [ ] `RuntimeComposerTests` — compose from a stub `SettingsStore`, assert the
      expected agent set is registered and the pump is running.
- [ ] `StructuredOutputTests` — malformed JSON → repair retry → fail closed.

**Manual E2E** (`xcodegen generate && xcodebuild … build`, then ⌘R):
- [ ] Set an agent to Autopilot, quit, relaunch → mode persisted.
- [ ] Screenshot on Desktop → bubble animates, approval sheet, approve → file
      moves; Undo restores it.
- [ ] Duplicate scan during an OCR pass → other bubbles keep updating (the
      visible payoff of A1).
- [ ] Destructive duplicate-delete in Autopilot → **still** prompts.
- [ ] Pre-existing `groot.db` migrates in place with history intact.

## Dependencies

- **Phase 01 — Foundation & Agent Runtime** (the spine being hardened).
- **Phase 02 — Vertical MVP** (the six agents being migrated).
- Blocks **Phase 03 — Intelligence** (needs the AI port + `rules`/`catalog`),
  **Phase 04 — Interaction & Learning** (needs `learning` + `SettingsStore`),
  and **Phase 06 — Recovery Center** (needs `activity_log`).
- No new external dependencies. Still system `libsqlite3`, `Vision`,
  `CoreServices`, `os` — nothing fetched over the network.

## Notes

**Build order** (keep `swift test` green after each step):

1. This spec + index row.
2. `GrootDatabase` + migrations; `SQLiteJournalStore` refactored onto it.
3. `ApprovalPolicy` (pure) + truth-table tests — highest value per line in the
   phase; the safety invariant becomes real here.
4. `ApprovalService`; migrate `ScreenshotAgent` first (the reference
   implementation per `CLAUDE.md`), then the rest; retire `ApprovingAgent`.
5. `AgentHealth` + `AgentCore`; migrate all six agents.
6. Mailboxes + `Scheduler` + `GrootLog`.
7. `SettingsStore`, `NotificationManager`.
8. AI provider port + use cases.
9. `RuntimeComposer` + view-model split; `xcodegen generate`; `xcodebuild`.

Steps 2–8 are GrootKit-only and verifiable with `swift test` alone; step 9 is the
only one needing Xcode.

**Risks.** The in-place migration is the highest-consequence item — users may
already hold a v1 `groot.db`. The continuation-based approval flow is the
trickiest code. Swift 6 complete concurrency is enforced
(`swiftLanguageMode(.v6)`, `SWIFT_STRICT_CONCURRENCY: complete`); expect friction
on `AgentCore` mutation across isolation boundaries — the patterns already solved
in `SQLiteJournalStore` and the tests' `static` helpers apply.

**Scope discipline.** No agents, no features. The `rules`, `catalog`, and
`learning` tables are created empty and left unused until Phases 03–04.
