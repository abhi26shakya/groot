# Groot — Phase Specifications

This folder (`.claude/specs/`) holds **all** phase specification files, numbered
sequentially. It is the single home for phase specs — no phase `.md` file lives
anywhere else. New specs are created with the `/create-spec` command
(`.claude/commands/create-spec.md`).

## Conventions (going forward)

- Every future phase spec is created **only** inside `.claude/specs/`.
- Numbering continues sequentially: `07-...md`, `08-...md`, …
- Filenames are descriptive (`NN-short-description.md`).
- This index is updated whenever a phase file is added or its status changes.
- `README.md` here (this index) and the root `README.md`/`CLAUDE.md` are project
  docs, **not** phase specs.

## Index

| # | Phase | Status | Spec |
|---|-------|--------|------|
| 01 | Foundation & Agent Runtime | ✅ Complete | [01-foundation-runtime.md](01-foundation-runtime.md) |
| 02 | Vertical MVP (shippable v0.1) | ✅ Complete | [02-vertical-mvp.md](02-vertical-mvp.md) |
| 03 | Intelligence | 🔜 Planned | [03-intelligence.md](03-intelligence.md) |
| 04 | Interaction & Learning | 🔜 Planned | [04-interaction-and-learning.md](04-interaction-and-learning.md) |
| 05 | Platform | 🔜 Planned | [05-platform.md](05-platform.md) |
| 06 | Recovery Center & Undo History | 🔜 Planned | [06-recovery-center.md](06-recovery-center.md) |
| 07 | System Architecture — Core Services Layer | ✅ Complete | [07-system-architecture.md](07-system-architecture.md) |
| 08 | AI Categorization Agent — Content-Aware Sorting | ✅ Complete | [08-ai-categorization.md](08-ai-categorization.md) |

The authoritative architecture/roadmap narrative lives in
`~/.claude/plans/read-this-and-come-validated-owl.md`; these files break it into
per-phase, version-controlled specs.
