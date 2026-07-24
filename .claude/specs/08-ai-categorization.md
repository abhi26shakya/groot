# Phase 08: AI Categorization Agent — Content-Aware Sorting

## Objective

Ship the first **content-aware** agent: a `CategorizationAgent` that reads what a
file actually *contains* (not just its extension) and files it into a meaningful
top-level category — **Research, Finance, Career, Legal, Personal, …** plus
user-defined custom categories — using the local-first `AIProvider` stack landed
in Phase 07.

This is the "Intelligence" milestone from the roadmap. Phase 07 built the seam
(`CategorizerUseCase`, `StructuredOutput`, provider fallback chain,
`ApprovalService`, `SettingsStore`); Phase 08 turns that seam into a running,
tested, safety-gated agent and the settings surface for managing categories.
Crucially, adding it must be **purely additive** — one new `Agent`, one content
extractor, category persistence, and settings plumbing — with **no runtime,
bus, or `FileService` changes**.

## Features

- **Content extraction** across the common file types: plain text / Markdown /
  code read directly; PDF text via PDFKit; images via the existing `VisionOCR`.
  A bounded excerpt (first N characters) is all that ever reaches the model.
- **AI categorization** via `CategorizerUseCase`: the model must pick one of the
  *allowed* categories (built-in + custom) or the agent leaves the file alone.
  Below the confidence threshold → no action, never a guess.
- **Category catalog** — a built-in set plus unlimited user-defined categories,
  persisted via `SettingsStore`, each mapping to a destination folder root.
- **Safety-gated moves** through the standard preview / approval / autopilot loop
  (`ApprovalService.evaluate`), reusing the `FileService` journaled-move path so
  every categorization is undoable from the Recovery Center.
- **Extension fallback** — when AI is unavailable/undecided and the user opted in
  to fallback, fall back to `FileCategory.forURL` coarse buckets; otherwise skip.
- **Settings UI** — enable/disable the agent, choose autonomy mode, manage custom
  categories (add/rename/delete, pick destination), and set the confidence
  threshold and the "AI-only vs. extension-fallback" toggle.

## Functional Requirements

1. The agent reacts to `.fileCreated` (and optionally `.fileModified` for files
   that arrive empty then fill in) for files inside its configured roots
   (default `~/Desktop` and `~/Downloads`; reuse `SettingsStore.watchedRoots()`).
2. It must **skip**: directories, dotfiles, partial-download extensions
   (`crdownload`, `part`, `download`, `tmp`), files already inside a managed
   category folder (its own output — guard using the category catalog's folder
   names, mirroring `DownloadsOrganizerAgent.shouldOrganize`), and files whose
   coarse `FileCategory` is one the agent is configured to ignore (e.g. leave
   `installers`/`archives` to the Downloads Organizer to avoid two agents
   fighting over the same file — see Edge Cases).
3. Extract a bounded content excerpt (default 2 000 chars, matching
   `CategorizerUseCase`'s internal cap) using the type-appropriate extractor.
4. Call `CategorizerUseCase.categorize(filename:contentExcerpt:)` with the allowed
   category list = built-in categories ∪ enabled custom categories.
5. On a confident decision, resolve a collision-safe destination
   (`DestinationResolver.collisionSafe`) under `<root>/<CategoryFolder>/` and route
   through `ApprovalService.evaluate` with a non-destructive `.move`:
   - `.proceed` → `FileService.move`, increment count, `core.journaled(entry)`,
     `core.report(...)`.
   - `.previewOnly` → publish a report describing the proposed move; do not touch
     the filesystem.
   - `.declined` → report skipped.
6. On `nil` decision (unavailable/low-confidence): if the "extension fallback"
   setting is on, categorize via `FileCategory.forURL` into the mapped folder;
   otherwise leave the file untouched and report "undecided".
7. Destination folders are created on demand by `FileService` (it already
   refuses to clobber and journals before acting). The agent must never call
   `unlink` or delete — categorization only ever **moves**.
8. All model input stays on-device unless the user has enabled a cloud provider;
   the cloud path is already gated by `CloudProvider` + `SettingsStore.cloudConsent`
   and the agent must not bypass it.

## Technical Requirements

- **Language/concurrency:** Swift 6 complete concurrency, `swiftLanguageMode(.v6)`.
  New agent is an `actor` conforming to **`CoreAgent`** (compose `AgentCore` for
  lifecycle/reporting — see `DownloadsOrganizerAgent` as the reference shape).
- **No new external dependencies.** PDFKit, Vision, Foundation only — all system
  frameworks. GrootKit stays dependency-free.
- **Dependency injection:** the agent is injected its `FileService`,
  `ApprovalService?`, a `CategorizerUseCase` (built from the composed
  `AIProvider`), a `ContentExtractor`, its roots, and its category catalog — so
  tests substitute a stub provider/extractor (mirror `ScreenshotAgentTests`'
  `StubRecognizer`). No agent constructs its own provider.
- **Pure, testable seams:** the `shouldCategorize(_:)` guard and the
  built-in→folder mapping must be `nonisolated` pure functions (like
  `shouldOrganize`), and content extraction dispatch (extension → strategy) must
  be a pure function unit-tested without touching disk where possible.
- **Wiring:** register the agent in `RuntimeComposer` alongside the other agents;
  read its enabled/autonomy state from `SettingsStore`. Follow the existing
  registration pattern — no changes to `AgentManager`/`MessageBus`.
- **Logging:** use `GrootLog` (the `.ai`/agent categories) for provider failures
  and skipped files; never log file *contents*.

## File Structure

```
Sources/GrootKit/
  Agents/
    CategorizationAgent.swift        # NEW — actor CategorizationAgent: CoreAgent
  Services/
    ContentExtractor.swift           # NEW — text extraction (plain/PDF/image)
  Models/
    CategoryCatalog.swift            # NEW — built-in + custom categories, folder map
Tests/GrootKitTests/
  CategorizationAgentTests.swift     # NEW — skip rules, decide→move, fallback, low-confidence
  ContentExtractorTests.swift        # NEW — text/markdown/PDF/unknown dispatch + bounds
  CategoryCatalogTests.swift         # NEW — built-ins, custom add/rename/delete, folder names
```

Existing files touched (integration only, no behavioural change to them):

```
Sources/GrootKit/Services/RuntimeComposer.swift   # register CategorizationAgent
Sources/GrootKit/Services/SettingsStore.swift      # custom-category + threshold keys
GrootApp/…/Settings (if a settings screen exists)  # category management UI
```

New GrootApp files require `xcodegen generate`; new `Sources/GrootKit` files are
picked up by SwiftPM automatically.

## Database Changes (if applicable)

None required for the agent to function — categorization moves are recorded in the
existing `undo_journal` via `FileService` (no schema change).

Custom categories persist through `SettingsStore` (its existing
`UserDefaults`-backed string/bool keys). Store the catalog as a JSON-encoded
string under a new key (e.g. `custom_categories`). **No new `GrootDatabase`
tables.** If a future phase wants per-file category history, that is out of scope
here.

## API Changes (if applicable)

- **`BusEvent`:** no new cases required — the agent reports via `.agentReport`
  and journaled moves via `.operationJournaled`, both already fanned correctly.
  (Optional, only if the dashboard needs it later: a `.fileCategorized` event —
  **deferred**, do not add speculatively.)
- **`SettingsStore`:** add typed accessors:
  - `customCategories() async -> [CustomCategory]` / `setCustomCategories(_:)`
  - `categorizationThreshold() async -> Double` / setter (default `0.6`)
  - `categorizationExtensionFallback() async -> Bool` / setter (default `true`)
- **`CategoryCatalog`** (new public model): `builtIns`, merged `allowedNames`,
  and `folderName(for:)`. `CustomCategory` is `Codable, Sendable, Identifiable`.
- No breaking changes to `AIProvider`, `CategorizerUseCase`, `FileService`,
  `AgentManager`, or the `Agent` protocol.

## UI/UX Requirements (if applicable)

- **Settings → Categorization** panel:
  - Toggle: enable agent; picker: autonomy mode (Preview / Approval / Autopilot);
    the destructive-op rule still holds but categorization is move-only so
    Autopilot acts immediately.
  - List of custom categories with add / rename / delete and a destination-folder
    picker per category; built-ins shown read-only with their folder names.
  - Slider/stepper: confidence threshold (0.5–0.95); toggle: extension fallback.
  - Copy must state clearly that content is analyzed **on-device** by default and
    that cloud analysis only happens if the user enabled it (reflect
    `provider.isLocal`).
- **Dashboard:** the agent appears as a normal card/bubble via its
  `AgentDescriptor` (name "Categorizer", a distinct `colorHex`, an SF Symbol such
  as `tag` / `sparkles.rectangle.stack`), showing current task, last action, and
  files-categorized count — no bespoke dashboard code beyond the descriptor.
- **Approval sheet** reuses the existing `ApprovalRequest` presentation
  ("Move <file> to <Category>"), so no new sheet type.

## Edge Cases

- **Two agents, one file:** Downloads Organizer sorts by extension, Categorizer by
  content — both watch `~/Downloads`. Resolve by configuration: Categorizer
  ignores the coarse buckets the Organizer owns (installers/archives/media/audio
  by default) and focuses on `documents`/`pictures`/`other`; document this and
  make the ignore-set injectable. The `FileService` no-clobber + journal guard
  means even a race is safe (loser fails cleanly), but avoid the race by config.
- **Own output loop:** never re-categorize a file already inside a managed
  category folder (guard on catalog folder names + the File Monitor's
  `operationJournaled` loop guard already suppresses app-originated events).
- **Unreadable / encrypted / zero-byte files:** extractor returns empty →
  `CategorizerUseCase` gets an empty excerpt → returns `nil` → skip (or extension
  fallback). Never crash, never block.
- **Huge files:** only the bounded excerpt is read; for PDFs read the first page
  or first N chars, not the whole document. Enforce a hard cap and a read timeout.
- **Model hallucinates a folder:** impossible to reach `FileService` —
  `CategorizerUseCase` validates the category against the allowed set and the
  confidence range before returning.
- **Custom category deleted while files sit in its folder:** deleting a category
  only removes it from the *allowed* list; existing folders/files are untouched.
- **Ollama absent / offline:** `FallbackChain` → `HeuristicProvider` returns
  empty → `nil` decision → extension fallback or skip. App fully functional.
- **Cloud consent revoked mid-session:** `CloudProvider` throws
  `cloudConsentRequired`, caught inside `CategorizerUseCase`, treated as `nil`.
- **Non-`.autopilot` modes:** in `.preview` nothing moves; in `.approval` the
  batch waits on the user — the agent must not block its event loop while waiting
  (approval resolves via `ApprovalService`, not by parking `handle`).

## Acceptance Criteria

- [ ] `CategorizationAgent` conforms to `CoreAgent`, is registered by
      `RuntimeComposer`, and appears in `AgentManager.snapshot()`.
- [ ] Given a text/PDF/image file with recognizable content and a stub provider
      returning a confident allowed category, the agent moves it under the correct
      category folder via `FileService`, journals the move, and reports it.
- [ ] A low-confidence or `nil` decision results in **no filesystem change** (or an
      extension-fallback move when that setting is on) — verified by test.
- [ ] Destructive operations are impossible: the agent only issues `.move`.
- [ ] In `.preview` mode no file is moved; in `.approval` mode a move only happens
      after approval; in `.autopilot` the move happens immediately.
- [ ] With no Ollama and no cloud consent, the app builds, runs, and the agent
      degrades to extension fallback / skip with no errors surfaced to the user.
- [ ] Custom categories added in Settings persist across relaunch and appear in the
      allowed set passed to the model.
- [ ] `swift build` and `swift test` pass; no new external dependency in
      `Package.swift`.

## Testing Checklist

- [ ] `ContentExtractorTests`: extension→strategy dispatch; plain/markdown/code
      read directly; unknown/binary returns empty; excerpt length bound enforced;
      (PDF/image paths verified with a small fixture or tolerated as live tests,
      following the Vision-in-SPM caveat in CLAUDE.md).
- [ ] `CategoryCatalogTests`: built-in names + folders; custom add/rename/delete;
      merged allowed set; folder-name collision handling.
- [ ] `CategorizationAgentTests` (stub provider + `InMemoryJournalStore` + temp
      dir): confident decision → journaled move to right folder; low-confidence →
      no move; `nil` + fallback-on → extension move; `nil` + fallback-off → skip;
      dotfile/partial/dir/already-sorted → skipped by `shouldCategorize`;
      preview/approval/autopilot mode matrix; ignore-set prevents Organizer overlap.
- [ ] `SettingsStore` round-trip for custom categories + threshold + fallback flag.
- [ ] Full `swift test` green; targeted runs, e.g.
      `swift test --filter CategorizationAgentTests`.

## Dependencies

- **Phase 01 — Foundation & Agent Runtime**: `Agent`/`CoreAgent`, `MessageBus`,
  `AgentManager`, `FileService`, `JournalStore`.
- **Phase 02 — Vertical MVP**: `FileMonitoringAgent` (emits `.fileCreated`),
  `DownloadsOrganizerAgent` (the reference agent shape and the overlap it must
  avoid), `FileCategory`, `DestinationResolver`.
- **Phase 07 — System Architecture — Core Services Layer**: `AIProvider` stack
  (`FallbackChain`/`Ollama`/`Cloud`/`Heuristic`), `CategorizerUseCase`,
  `StructuredOutput`, `ApprovalService`/`ApprovalPolicy`, `SettingsStore`,
  `RuntimeComposer`, `GrootLog`. This phase consumes the seams that phase created.

## Notes

- The whole point of Phase 07's `CategorizerUseCase` was to make this phase "add
  an agent, not an architecture." Honor that: **no runtime/bus/FileService
  changes.** If something here seems to require touching the runtime, reconsider
  the approach first.
- `ScreenshotAgent` remains the reference implementation of the full
  preview/approval/autopilot loop; `DownloadsOrganizerAgent` is the reference for
  the move-only, `ApprovalService.evaluate`-driven organizer shape. This agent is
  essentially "Downloads Organizer, but categorized by content instead of
  extension."
- Keep content extraction conservative and bounded — this is the only place file
  *contents* are read into memory, and (with cloud opt-in) the only place they
  could leave the machine. Privacy copy in Settings must be explicit.
- Deferred (future phases): per-file category history/undo-by-category, learning
  from user re-categorizations (Phase "Interaction & Learning"), semantic search
  over extracted text (Phase "Platform"), and a `.fileCategorized` bus event if a
  richer dashboard needs it.
