# Phase 04 — Interaction & Learning

**Status:** 🔜 Planned
**Targets:** `GrootKit` + `GrootApp`

## Objective

Let users drive Groot by voice and natural-language rules, and have it learn
their habits.

## Deliverables

- **Voice Assistant Agent** — Apple Speech framework (whisper.cpp fallback) →
  Intent parsing → `AgentManager` routing → `AVSpeechSynthesizer` responses.
  Maps utterances ("organize my Desktop", "delete duplicate PDFs", "pause
  scanning") to existing `Intent` cases.
- **Automation Rule Engine (NL)** — "If a PDF contains Invoice, move it to
  Finance" → local LLM compiles to a structured, validated rule. Supports
  priorities, enable/disable, test, import/export. Rules persist via the
  `JournalStore`/SQLite layer (new `rules` table).
- **Learning Engine** — observe user corrections/approvals/rejections and folder
  preferences → generate recommendations that feed the Categorization agent.

## Depends on

- Phase 03 categorization; the `Intent` vocabulary; SQLite persistence.

## Verification

- Intent-parsing unit tests (utterance → `Intent`); rule compilation tests
  (NL → structured rule) with a stubbed LLM; learning-signal aggregation tests.
