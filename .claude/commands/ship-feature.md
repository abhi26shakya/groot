---
description: Complete the current feature by validating, committing, pushing, creating a pull request, merging it, cleaning up branches, and preparing the repository for the next feature.
allowed-tools: Read, Bash, mcp__github__create_pull_request, mcp__github__merge_pull_request, mcp__github__delete_branch
---

# Ship Feature

Complete the current feature following the team's Git workflow.

## Step 0 — Preconditions

Before doing anything:

1. Verify GitHub MCP is connected.
2. Verify the current branch is **not** `main`.
3. Verify there are no unresolved merge conflicts.
4. Verify the project builds successfully.
5. Run all available tests.

If GitHub MCP is unavailable, stop immediately and print:

```
GitHub MCP is not connected. Run /mcp to check connection.
```

If the current branch is `main`, stop and print:

```
Refusing to ship from main.
Create a feature branch first.
```

---

# Step 1 — Identify Current Branch

Run:

```bash
git branch --show-current
```

Store the result as:

```
CURRENT_BRANCH
```

Report:

```
✓ Current branch — CURRENT_BRANCH
```

---

# Step 2 — Discover the Current Feature Specification

Read every file inside:

```
.claude/specs/
```

Determine which specification corresponds to the current branch.

Extract:

- Phase title
- Objective
- Overview
- Acceptance Criteria
- Testing Checklist
- Definition of Done (if present)

If no matching specification exists, stop and report:

```
No matching specification found in .claude/specs/.
```

---

# Step 3 — Review Changes

Run:

```bash
git diff --staged
git diff
git status
git log main..HEAD --oneline
```

Review every modified file.

Ensure every implementation matches the specification.

If something appears unfinished, warn before continuing.

---

# Step 4 — Generate Commit Message

Generate a Conventional Commit.

Allowed prefixes:

- feat
- fix
- refactor
- docs
- chore
- test
- perf
- ci

Rules:

- lowercase
- under 72 characters
- no period
- describe what users can now do
- never describe implementation details

Examples:

Good

```
feat: organize downloads automatically
```

```
feat: add ai file categorization
```

Bad

```
feat: implemented CategorizerService
```

```
fix: updated api
```

---

# Step 5 — Commit

Run:

```bash
git add .
git commit -m "<generated-message>"
```

Report:

```
✓ Committed — <message>
```

---

# Step 6 — Push

Run:

```bash
git push -u origin CURRENT_BRANCH
```

If upstream already exists:

```bash
git push
```

Report:

```
✓ Pushed — CURRENT_BRANCH
```

---

# Step 7 — Create Pull Request

Create a pull request using GitHub MCP.

Base branch:

```
main
```

Head:

```
CURRENT_BRANCH
```

## Title

Use plain English.

Do **not** include the conventional commit prefix.

Example

```
Add AI file categorization
```

---

## Description

Generate:

```markdown
## Summary

<one paragraph describing the completed feature>

## Specification

Phase: <phase title>

## What Changed

- file 1 — description
- file 2 — description
- file 3 — description

## Acceptance Criteria

- [x] Item
- [x] Item
- [x] Item

## Testing

- [x] Project builds successfully
- [x] Unit tests pass
- [x] Manual testing completed

### Verification Steps

1.
2.
3.

## Notes

Additional implementation notes if needed.
```

Report:

```
✓ Pull request created

<PR URL>
```

---

# Step 8 — Merge Pull Request

Merge using:

**Squash Merge**

Never use merge commit.

Never use rebase merge.

Report:

```
✓ Pull request merged
```

---

# Step 9 — Delete Remote Branch

Delete:

```
CURRENT_BRANCH
```

using GitHub MCP.

Report:

```
✓ Remote branch deleted
```

---

# Step 10 — Update Local Repository

Run:

```bash
git checkout main
```

Then

```bash
git pull origin main
```

Report:

```
✓ Local main updated
```

---

# Step 11 — Delete Local Branch

Run:

```bash
git branch -D CURRENT_BRANCH
```

Report:

```
✓ Local branch deleted
```

---

# Step 12 — Repository Validation

Verify:

- Working tree clean
- On main
- Up to date with origin/main

Run:

```bash
git status
```

Expected:

```
On branch main

Your branch is up to date with 'origin/main'.

nothing to commit, working tree clean
```

---

# Final Summary

Print exactly:

```
═══════════════════════════════════════════════

🚀 /ship-feature complete

✓ Feature validated
✓ Project builds successfully
✓ Tests passed
✓ Specification satisfied
✓ Committed
✓ Pushed
✓ Pull request created
✓ Pull request merged (Squash)
✓ Remote branch deleted
✓ Switched to main
✓ Repository updated
✓ Local branch deleted

Repository is clean and ready for the next feature.

Next step:

/create-spec

═══════════════════════════════════════════════
```

---

# Rules

- Never commit directly to `main`.
- Always work from a feature branch.
- Always use Conventional Commits.
- Always squash merge.
- Never leave the repository with uncommitted changes.
- Never merge if the project does not build.
- Never merge if tests fail.
- Never merge if the specification is incomplete.
- Never continue if GitHub MCP is unavailable.
- Never continue if pull request creation fails.
- Always delete both the remote and local feature branches after a successful merge.
- Always finish on the latest `main` branch with a clean working tree.