# Developer Guide

## Setup

```bash
brew install xcodegen   # one-time, only needed for the macOS app target
```

`GrootKit` itself has no external dependencies — it builds and tests offline
with the system Swift toolchain alone.

## Build

```bash
swift build                    # GrootKit runtime + agents (fast, headless)
xcodegen generate               # regenerate Groot.xcodeproj after adding files
                                 # under GrootApp/ or editing project.yml
xcodebuild -project Groot.xcodeproj -scheme GrootApp \
  -destination 'platform=macOS' build
open Groot.xcodeproj             # then ⌘R in Xcode
```

New files under `Sources/GrootKit/` are picked up automatically by SwiftPM.
New files under `GrootApp/` need `xcodegen generate` before Xcode sees them
(the project globs `GrootApp/`).

## Testing

```bash
swift test                                          # full suite (128 tests)
swift test --filter ScreenshotAgentTests             # one test class
swift test --filter ScreenshotAgentTests/testDetection  # one test
```

There is no UI test target — `GrootApp` is a thin SwiftUI layer over
`GrootKit`, and everything with meaningful logic is tested headlessly through
the library. Vision-/FSEvents-dependent code paths are exercised through
tolerant live tests or verified manually in the app.

## Branch strategy

- `main` is always buildable and green (`swift build && swift test`).
- Feature work happens on `feature/<short-name>` branches, merged via PR.
- Phase specs (`.claude/specs/NN-*.md`) track scope; a phase is only marked
  `✅ Complete` in `.claude/specs/README.md` once its code and tests land on
  `main`.

## Claude Code workflow

- `/create-spec` — add the next sequential phase spec to `.claude/specs/`.
- `/implement-spec` — implement a phase spec end-to-end with tests.
- `/generate-docs` — regenerate this documentation set.
- `/ship-feature` — validate, commit, push, PR, merge, and clean up branches
  for the current feature.
- See `CLAUDE.md` for the full command list and the architectural
  conventions every change must follow.

## Coding conventions

- **Swift 6, complete concurrency.** Every type crossing an actor boundary
  must be `Sendable`-correct. See `CLAUDE.md` for solved gotchas (actor
  `deinit` can't touch isolated state; actor `init` can't call isolated
  methods; `async let` helpers must be `static` to avoid capturing `self`).
- **Agents are actors that only talk over the bus.** Never call another
  agent's methods directly — publish a `BusEvent` and let the receiving
  agent's `handle(_:)` react.
- **`FileService` is the only path that touches the filesystem.** Any new
  agent that needs to move/delete/rename a file goes through it, so every
  operation is journaled and undoable.
- **Pure functions for anything hardware/OS-dependent**, so it's unit
  testable without the real subsystem: `FSEventsWatcher.classify(flags:)`,
  `ScreenshotAgent.isScreenshot(_:)`, `FilenameSanitizer`,
  `CategorizationAgent.shouldCategorize(_:)`.
- **Dependencies are injected, not constructed**, so tests can substitute
  stubs (`StubRecognizer`, `InMemoryJournalStore`, a fake `AIProvider`).
- **Destructive operations always require approval**, regardless of an
  agent's configured `AutonomyMode` — enforced via
  `FileOperationKind.isDestructive`.
