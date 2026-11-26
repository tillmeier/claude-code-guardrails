---
name: plan
description: Front-load a task with a short, cited design spec and get approval BEFORE writing code. Produces a persistent plan artifact that survives compaction and defines the verification contract /verify later checks. Pass the task description as the argument; add --codex to have an independent reviewer (Codex by default, the same one /critical-review uses) adversarially review the spec before you build.
argument-hint: "[--codex] [what you want built / changed]"
effort: xhigh
---

# Plan Before Building

Turn a task into a **short, cited design spec**, get a go/no-go, then implement against it.
This guards the entry of the loop; `/verify` guards the exit. Keep it lean: a spec, not a
novel. If the task is trivial
(one-file, obvious, reversible), say so and skip straight to doing it — don't ceremony-tax small work.

The task is `$ARGUMENTS`. If empty, ask the user what they want to build in one line, then proceed.

**Flag:** if `$ARGUMENTS` contains `--codex`, strip it out (the rest is the task) and set
`CODEX_REVIEW=true` — this runs Phase 2.5 below, which needs a reviewer CLI and says
`PLAN NOT REVIEWED` without one. Everything else is unchanged.

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
Fill in `SLUG` yourself, a few words from the task. Never paste the task text into the shell: it is
user text, and backticks or `$(…)` in it would run as a command.

```bash
# Prefer the project's .claude/plans/; fall back to ~/.claude/plans/ outside a repo.
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$HOME/.claude")
PLAN_DIR="$ROOT/.claude/plans"; [ -d "$ROOT/.claude" ] || PLAN_DIR="$HOME/.claude/plans"
mkdir -p "$PLAN_DIR"
SLUG='<short-task-slug>'   # a-z, 0-9 and -, at most 50 characters
SLUG=$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | cut -c1-50 | sed 's/^-//; s/-$//')
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
wrong approach is cheapest to catch here, before anything is built. The reviewer is whatever
`scripts/review-backend.sh` picks, the same one `/critical-review` uses: `REVIEWER` if set, else
`REVIEW_CUSTOM_CMD`, else the Codex CLI if it is logged in, else the Claude Code CLI (models and
codex effort pinned in `review-backend.conf`). It gets the spec and may read the files the spec
cites, never write them: codex runs in its read-only sandbox, claude with Read/Grep/Glob only,
gemini with no tools at all; a custom command is your own and runs as you. It answers in plain
text. Treat it as a second opinion, not a verdict.

Put the spec path into `PLAN_FILE` as a single-quoted shell string (write a `'` inside the path as
`'\''`), then run the block **with `run_in_background: true`** and act on
its completion notice: a review at high effort takes minutes, longer than a foreground call is
allowed to run. If the run is stopped before it finishes, that is `PLAN NOT REVIEWED (interrupted)`.

```bash
bash <<'PLANREVIEW'
PLAN_FILE='<spec path from Phase 2>'
RB="${CLAUDE_PLUGIN_ROOT}/scripts/review-backend.sh"
[ -f "$RB" ] || RB="${REVIEW_BACKEND:-$HOME/claude-code-guardrails/scripts/review-backend.sh}"
if [ -z "$PLAN_FILE" ]; then
  echo "PLAN NOT REVIEWED: no spec path was filled in"
  exit 0
fi
if [ ! -f "$RB" ]; then
  echo "PLAN NOT REVIEWED: scripts/review-backend.sh not found — export REVIEW_BACKEND=<checkout>/scripts/review-backend.sh"
  exit 0
fi
OUT=$(mktemp); ERR=$(mktemp)
trap 'rm -f "$OUT" "$ERR"' EXIT
bash "$RB" --spec "$PLAN_FILE" > "$OUT" 2> "$ERR"
RC=$?
if [ "$RC" -eq 0 ] && grep -q '[^[:space:]]' "$OUT"; then
  echo "PLAN REVIEWED ($(sed -n 's/^review-backend: //p' "$ERR" | head -n 1)):"
  cat "$OUT"
else
  echo "PLAN NOT REVIEWED (exit $RC):"
  grep '^review-backend:' "$ERR"                      # the adapter's own reason first, never cut off
  echo "── reviewer output (last 20 lines) ──"
  grep -v '^review-backend:' "$ERR" | tail -n 20
fi
PLANREVIEW
```

**`PLAN NOT REVIEWED` means exactly that — never "no findings".** It is the answer for every exit
other than 0: 3 = no reviewer on this machine, 4 = the reviewer ran and failed (or its codex run
header did not show the read-only sandbox, the pinned model and effort), 1 = a usage problem such as
an empty spec. Say it out loud and let the user decide whether to proceed unreviewed. Never review
the spec yourself in its place.

Then: fold legitimate findings into the spec, and surface anything that needs the user's call as an
open question. Don't rubber-stamp — if the reviewer is wrong, say why. If it is right, the spec
changes before Phase 3, not after you've written the code.

## Phase 3: Approval gate

Present the spec inline (the file is the record; the user shouldn't have to open it) and call
`ExitPlanMode` to get an explicit go/no-go **before touching any product code**. If `ExitPlanMode`
errors because the session is not in plan mode, gate with `AskUserQuestion` instead (recommended
scope first) — the error is not an approval.

**Open questions carry a guess.** Every question you put to the user — in Phase 1, when folding
Codex findings, or here — comes as `Q: … GUESS: <your best answer + why>`, one question per
decision. A wrong guess gets corrected in one word; a bare question costs the user a paragraph.

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
