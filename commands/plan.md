---
name: plan
description: Front-load a task with a short, cited design spec and get approval BEFORE writing code. Produces a persistent plan artifact that survives compaction and defines the verification contract /verify later checks. Pass the task description as the argument; add --codex to have Codex adversarially review the spec before you build.
argument-hint: "[--codex] [what you want built / changed]"
---

# Plan Before Building

Turn a task into a **short, cited design spec**, get a go/no-go, then implement against it.
This guards the entry of the loop; `/verify` guards the exit. Keep it lean: a spec, not a
novel. If the task is trivial
(one-file, obvious, reversible), say so and skip straight to doing it — don't ceremony-tax small work.

The task is `$ARGUMENTS`. If empty, ask the user what they want to build in one line, then proceed.

**Flag:** if `$ARGUMENTS` contains `--codex`, strip it out (the rest is the task) and set
`CODEX_REVIEW=true` — this runs Phase 2.5 below, which needs the optional Codex plugin and is a
stated no-op without it. Everything else is unchanged.

## Phase 1: Scope & research (read-only)

Do NOT edit anything yet. Understand the ground truth first.

- For a **small/localized** task: grep/read the affected files yourself.
- For a **broad or unfamiliar** task (touches many files, unclear blast radius, new subsystem):
  delegate the sweep to the `Explore` agent (read-only) so you map naming/conventions without
  burning main-context. Wait for it before writing the spec.

**Honor the anti-fabrication rule** (README → Design rules): every file path, env var,
function, DB column, or flag that goes into the spec must be either cited to a real location
(`path:line`) or hedged (`probably X — grep first`). A spec full of guessed identifiers is worse
than no spec. Grep first, then write.

## Phase 2: Write the spec artifact

Write a spec file so the plan survives context compaction and gives `/verify` a definition of done.

```bash
# Prefer the project's .claude/plans/; fall back to ~/.claude/plans/ outside a repo.
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/.claude")
PLAN_DIR="$ROOT/.claude/plans"; [ -d "$ROOT/.claude" ] || PLAN_DIR="$HOME/.claude/plans"
mkdir -p "$PLAN_DIR"
SLUG=$(echo "$ARGUMENTS" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -c1-50 | sed 's/-$//')
PLAN_FILE="$PLAN_DIR/$(date +%Y-%m-%d)-${SLUG:-task}.md"
echo "$PLAN_FILE"
```

Write `PLAN_FILE` with exactly these sections (terse — 1-3 lines each unless a section genuinely needs more):

```markdown
# Plan: <task>
Date: <YYYY-MM-DD> · Repo/branch: <repo> @ <branch>

## Goal
<the outcome, in 1-2 lines — what's true when this is done>

## Approach
<the chosen path, 2-5 lines. If you rejected an alternative for a real reason, one line on why.>

## Files to touch
- `path:line` — <what changes>   (every path cited or hedged — no blind identifiers)

## Risks & unknowns
- <what could break / what you're unsure about; mark the irreversible ones>

## Verification plan   ← this is the contract /verify checks
- <how we PROVE it works: the exact flow to drive + expected observable behavior.
   Not "tests pass" — what user-visible/behavioral thing must be true.>

## Rollback
<how to undo if it goes wrong — revert commit / feature flag / restore path>

## Out of scope
<what this deliberately does NOT do, so scope doesn't creep mid-build>
```

These are working artifacts — not auto-committed. Add `.claude/plans/` to a repo's `.gitignore`
if you don't want them tracked (or commit the good ones as design records — your call).

## Phase 2.5: External plan review (only if `--codex`)

Skip this phase entirely unless `CODEX_REVIEW=true`.

Have a second, independent model adversarially review the **spec, before any code exists** — a
wrong approach is cheapest to catch here, before anything is built. This phase uses the optional
[OpenAI Codex plugin for Claude Code](https://github.com/openai/codex-plugin-cc). **If the
`codex:rescue` skill is not available in this session, say so in one line — "`--codex` requested,
Codex plugin not installed, continuing without external review" — and go straight to Phase 3.
Never fake a review.** Invoke it via `Skill(codex:rescue)` with `--fresh` as the first arg (skips
the "continue previous Codex thread?" prompt), then the framing below. It routes through Codex as
a generic `task`, so treat the output as a smart second opinion, not a verdict. Keep it read-only —
the rescue agent can write files by default; the "no code yet" framing below is what holds it to
review-only, so keep that explicit.

> Review-only, do not edit any files. Adversarially review this DESIGN SPEC before implementation.
> There is no code yet. Find: wrong or unstated assumptions, missing edge cases, a simpler approach
> that gets the same outcome, hidden blast radius, and anything in the Verification plan that
> wouldn't actually prove the goal. Be blunt. If the approach is sound, say so in one line — don't
> invent problems.

Then: fold legitimate findings into the spec, and surface anything that needs the user's call as an
open question. Don't rubber-stamp — if the reviewer is wrong, say why. If it is right, the spec
changes before Phase 3, not after you've written the code.

## Phase 3: Approval gate

Present the spec inline (the file is the record; the user shouldn't have to open it) and call
`ExitPlanMode` to get an explicit go/no-go **before touching any product code**.

- **Approved** → implement strictly against the spec. If reality forces a deviation, say so out
  loud and update the spec file — don't silently drift.
- **Rejected / changes** → revise the spec, re-present. Don't start coding on a half-agreed plan.

## After implementing

Point the user at `/verify` to exercise the change against the **Verification plan** section
before committing. The spec's verification section is exactly what `/verify` uses to decide
what "done" means for this change.

## When to skip this command

- Trivial, reversible, one-file edits → just do it; a spec is overhead.
- Pure exploration / "what is this" questions → no plan needed.
- You're mid-task and already aligned → don't retroactively ceremony it.
