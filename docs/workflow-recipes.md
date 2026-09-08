# Workflow Recipes

Two recurring delivery loops, codified as command chains so they're a habit, not a retyped
paragraph. Composable atoms — fire them in sequence, skip any step that doesn't apply. The
judgment stays yours; the steps stay consistent.

Both recipes share one spine: **align → ask open questions → implement incrementally → verify
locally → doc-sync → push.** The only things that vary are (a) whether an external reviewer looks
at the plan (optional) and (b) how you verify. The after-the-fact re-check (did it actually hold in
prod / at volume?) is a
separate pass — now its own command, `/crosscheck` (see Notes).

`/implement` is the execution atom for the middle: it takes an agreed plan (a file, a `/plan` spec,
or the proposal in chat) and runs it one step at a time — verify each step, ask on ambiguity, halt
on anything unforeseen. Use it whenever the plan is worth executing carefully; skip it and just code
inline for a short obvious change.

---

## Recipe A — logic / backend

For API, data, cron, generator, DB, business-logic work. Correctness is behavioral.

```
/plan [--codex] "<task>"     # cited spec → (optional external review) → open Qs → approval gate
/implement                   # execute the spec step by step; verify each; ask; halt on surprise
/verify                      # final gate: exercise the real flow locally; PASS/FAIL with evidence
/critical-review             # optional exit gate: independent reviewer on the diff → approve fixes once
/save-learnings-to-docs      # check ALL related docs: up to date, nothing redundant/missing/outdated
<commit step>                # stage BY NAME → staged-diff secret grep → commit → push (not in this repo)
```

`/implement` also takes a plan file directly — e.g. `/implement /tmp/audit-plan-example.md` when
the plan is an audit you produced without `/plan`.

- `--codex` needs the optional OpenAI Codex plugin and no-ops without it. Drop it when the approach
  is obvious and low-risk — don't tax small work.
- `/verify` proves it locally; the after-the-fact re-check is `/crosscheck` (see Notes).

## Recipe B — frontend / UI

For layout, styling, responsive, design-parity work. "Correct" is what it looks like across
breakpoints.

```
/plan "<task>"               # spec + open Qs (add --codex only for a risky refactor)
/implement                   # execute step by step (or just code inline for a small UI tweak)
/verify --ui "<design ref / list of problems>"   # browser-MCP screenshots × breakpoints +
                                                  # compare vs your design reference; iterate til clean
/save-learnings-to-docs
<commit step>
```

- `--ui` is the iterate-until-perfect loop: screenshot → diff against intent → fix → re-screenshot,
  at desktop/tablet/mobile. Paste the problem screenshots or point at the design proposal as the hint.

---

## Notes

- **Every recipe surfaces open questions before proceeding** — that's baked into `/plan`'s approval
  gate and `/verify`'s "ask rather than guess intent." You don't have to type "ask me all open
  questions" anymore; the commands do it.
- **Trivial, reversible work skips the recipe.** One-file obvious edits don't need a spec or a gate.
- **`/critical-review` is the exit-gate review of the *changes*** — an independent reviewer (Codex,
  Claude or your own command via `scripts/review-backend.sh`) sees the diff without the task brief;
  you judge its findings against the code and approve fixes once. `/plan --codex` reviews the *plan*
  (entry gate). Use both on high-stakes work, either alone otherwise.
- **`/crosscheck` is the after-the-fact audit** — orthogonal to the build spine, works in any
  project. "Audit everything I shipped/optimized recently and haven't cross-checked — runs clean? did
  anything new break? did the fixes work?" Grounds from the session, discovers where each change's
  evidence lives (logs / DB / output / endpoint), applies verify-before-assert + "ran ≠ worked",
  read-only. Deliberately thin and generic — nothing project-specific is baked in; it's discovered at
  runtime. Skip it for a small change you can eyeball; it earns its place across several changes /
  several days / prod.
- These are chains of independent commands on purpose (no mega-driver): each stays debuggable, and
  you can start mid-chain or swap a step without unwinding an orchestrator.
- **The doc-sync + push tail can collapse into one command** if your commit step runs
  `/save-learnings-to-docs` first (mine does). Then the last two lines of each recipe = one command.
- **Invocation**: a leading `/cmd` is CLI-expanded with exact `$ARGUMENTS`; a mid-sentence
  "go ahead and /cmd" is model-invocation (works only if the command allows it — commands with
  `disable-model-invocation` don't, and never flag the delegated sub-skills or you break chaining). Lead
  with the slash when exact flags must land.
- **No design-diffing MCP exists here** — `/verify --ui` compares against the reference *you* paste
  (screenshots / mockup / proposal), driven through a browser MCP (chrome-devtools in my setup).
  Don't reference a design tool.
