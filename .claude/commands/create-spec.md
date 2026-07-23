---
description: Create the next sequential phase specification in .claude/specs/
---

# Command: create-spec

Create a new phase specification for the project.

## Instructions

When this command is executed:

1. Ensure the `.claude/specs/` folder exists. If it does not, create it. This is
   the single canonical home for phase specifications.

2. Scan `.claude/specs/` and determine the highest existing phase number.

3. Create the next sequential phase specification file inside `.claude/specs/`
   using the format:

   ```
   .claude/specs/NN-descriptive-phase-name.md
   ```

   Examples:
   - `.claude/specs/07-notifications.md`
   - `.claude/specs/08-settings-page.md`
   - `.claude/specs/09-semantic-search.md`

4. Never create phase specification files outside `.claude/specs/`.

5. The specification must be detailed enough that another AI or developer could
   implement it without requiring additional clarification.

6. Every specification must include the following sections:

   ```
   # Phase NN: <Title>

   ## Objective

   ## Features

   ## Functional Requirements

   ## Technical Requirements

   ## File Structure

   ## Database Changes (if applicable)

   ## API Changes (if applicable)

   ## UI/UX Requirements (if applicable)

   ## Edge Cases

   ## Acceptance Criteria

   ## Testing Checklist

   ## Dependencies

   ## Notes
   ```

7. If the phase depends on previous phases, clearly list those dependencies
   (reference them by number and title, e.g. "Phase 02 — Vertical MVP").

8. Update `.claude/specs/README.md` (the phase index) to include the newly created
   phase — add a row to the index table with its number, title, status, and link.
   If the root `README.md` tracks completed-phase status, update it too.

9. Use descriptive filenames and maintain continuous numbering.

10. Do not implement the feature — only create the specification document unless
    explicitly instructed otherwise.

## Output

A single Markdown file inside `.claude/specs/` that follows the project's existing
specification style (see `01-foundation-runtime.md` … `06-recovery-center.md` for
reference), plus the updated `.claude/specs/README.md` index.
