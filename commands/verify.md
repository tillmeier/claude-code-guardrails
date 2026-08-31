---
name: verify
description: Ship gate. Scope to this session's diff, exercise the change end-to-end (drive the real flow, not just tests/typecheck), and emit a PASS / FAIL / SKIP verdict with evidence. Run before /save-and-push on anything with a runtime surface. Optional focus hint as argument.
argument-hint: "[focus hint — what behavior to prove]"
---

# Verify Before Shipping

Your global CLAUDE.md forbids asserting things blind. This is the same rule applied to your own
code: **prove the change behaves, don't claim it does.** This command scopes to what you changed
this session and exercises it — it does not re-derive correctness from the diff alone.

This command is self-contained: it scopes to your session diff, exercises the change (method in
Phase 3), and emits a ship-gate verdict. `$ARGUMENTS`, if present, is a focus hint for what behavior
matters most.

## Phase 1: Scope the change

Reuse the base commit this plugin's `SessionStart` hook recorded when the session began
(`hooks/session-start.sh` writes a marker file keyed by session id, and exports
`CLAUDE_SESSION_START_COMMIT` where the harness supports env-file exports).

```bash
MARK="${TMPDIR:-/tmp}/claude-session-start-commit-${CLAUDE_SESSION_ID}"
BASE="${CLAUDE_SESSION_START_COMMIT:-}"
[ -z "$BASE" ] && [ -f "$MARK" ] && BASE=$(cat "$MARK")
if [ -n "$BASE" ] && git cat-file -e "$BASE" 2>/dev/null; then
  echo "Scope: session start ${BASE} → working tree"
  git diff --stat "$BASE" -- . ; git status --short
else
  echo "No session-start commit (SessionStart hook not installed?) — falling back to uncommitted working tree"
  git diff --stat HEAD -- . ; git status --short
fi
```

Flags (parse from `$ARGUMENTS`): `--staged` (only staged), `--base <ref>` (explicit base),
`--ui` (frontend iteration mode — see Phase 3). Everything else in `$ARGUMENTS` is the focus hint
(for `--ui`, the hint is the design reference or the list of problems to fix).

## Phase 2: Does verification even apply?

Don't theatre-test a diff with no runtime surface.

- Diff touches **only** docs / comments / config-with-no-behavior / other tests → **SKIP**, state why, stop.
- Diff touches **product source** (any language, any layer) → it has a runtime surface. Proceed. "It's just a small change" is not an exemption.

## Phase 3: Exercise it

**Default (logic) mode** — exercise the change directly. Drive the **actual flow** it affects — call
the endpoint, run the CLI path, load the page, trigger the cron, whatever the code's real entry point
is — and observe behavior against the focus hint.

- Prefer real execution over proxies. Tests passing and typecheck clean are necessary, not
  sufficient — they are not "verification" on their own; this goes past them.
- If the change can't be driven locally (prod-only path, external dependency), say so explicitly
  and state the **strongest** check you actually ran — never dress up "looks right" as verified.

**`--ui` mode** — frontend iteration loop instead of a single pass. Use for visual/UX changes where
"correct" is what it looks like across breakpoints, not what a function returns. It needs a
browser-automation MCP (built against the chrome-devtools MCP). **If none is available in this
session, say so, fall back to logic mode plus whatever static check you can run, and do not pretend
to have looked at pixels.**

1. **Load the design intent** from whatever the user actually provided: pasted screenshots of the
   problems, a mockup / design proposal image, a reference URL, or the `/plan` spec's UI section.
   If a design-guidance skill is installed (e.g. the official `frontend-design` plugin), pull it in
   for the aesthetic bar — spacing, type, alignment, weight. There is no design-diffing tool; the
   reference is the input you're given, not an external tool.
2. **Drive the real page** via the browser MCP (chrome-devtools: `navigate_page`, `take_snapshot`,
   `take_screenshot`, `evaluate_script`) — the running app, not a static mock. Capture the current
   state at the breakpoints that matter: desktop, tablet, mobile (`resize_page`).
3. **Diff against intent** — for each reported problem (white button, bold ad tag, broken tablet
   alignment, sidebar whitespace, misaligned header bar, drift from the design proposal…), state
   observed vs. intended concretely. Screenshot as evidence, don't assert from the DOM alone.
4. **Fix → re-screenshot → repeat.** Loop until each problem is visually resolved at every
   breakpoint. Spin up subagents/parallel checks per breakpoint or per component if it's faster.
   Surface any genuinely open design questions to the user rather than guessing intent.
5. Trigger dialogs cautiously (they can freeze the extension) — read console via the devtools MCP
   for JS errors rather than clicking anything that pops a native alert.

## Phase 4: Verdict

Emit one, up top, in plain words:

- **PASS** — what you drove + the observed behavior that proves it works (the concrete evidence,
  not "it should work"). If a `/plan` spec exists for this task, confirm its **Verification plan**
  section is satisfied.
- **FAIL** — the exact input/state → wrong output/crash, with the evidence. Do not proceed to ship.
- **SKIP** — no runtime surface (Phase 2), or undrivable-locally with the reason + the best check run.

For `--ui` mode the verdict is per-problem: each reported issue marked resolved (with the
after-screenshot) or still-open, across every breakpoint checked. Don't call it PASS with unresolved
items — list what's left.

## Wiring it into the ship path

Run `/verify` before you commit any change with a runtime surface. If you want it enforced rather
than remembered, give your commit step a pre-commit phase that refuses to commit un-verified product
code — that is a change to a load-bearing command, so make it deliberately, not as a side effect.
