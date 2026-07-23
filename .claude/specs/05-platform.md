# Phase 05 — Platform

**Status:** 🔜 Planned
**Targets:** `GrootKit` + `GrootApp` (+ future companions)

## Objective

Evolve Groot from a storage manager into a general "AI operating layer" for
macOS. Everything here is additive — the `Agent` protocol + `MessageBus` already
make new capabilities plug in without runtime changes.

## Deliverables

- **Semantic file search** — Spotlight + on-device embeddings.
- **Cloud sync** — cross-device state and settings.
- **Backup awareness** — integrate Time Machine / backup status into destructive-op gating.
- **Plugin marketplace** — third-party agents packaged against the `Agent` protocol.
- **Predictive storage forecasting** — project when the disk fills.
- **AI analytics dashboard** — success rates, storage recovered over time, agent uptime.
- **Future agent domains** — email, photos, code projects, reminders, calendar,
  clipboard, document summarizer (each a new `Agent`).

## Depends on

- All prior phases; the `ApprovingAgent`/safety model for any destructive plugins.

## Verification

- Per-capability test suites; plugin-loading contract tests; forecasting model
  validation against historical usage fixtures.
