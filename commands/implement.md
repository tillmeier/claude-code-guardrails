---
name: implement
description: Execute an already-agreed plan one step at a time — implement the smallest shippable increment, verify it before moving on, ask open questions instead of guessing, and HALT on anything unforeseen. Pass a plan file as the argument, or omit it to use the plan already in the conversation.
argument-hint: "[path-to-plan-file | (uses the plan in context)]"
---

# Implement, One Step at a Time

The execution atom between `/plan` and `/verify`. Use it when a plan already exists — an audit
with ranked fixes, a `/plan` spec, or a proposal you've just approved in chat — and you want it
built with discipline instead of one big undifferentiated dump.

The contract, non-negotiable: **implement in small ordered steps · verify each step before the next
· ask rather than guess · stop the moment something is unforeseen.** Speed is not the goal;
not-shipping-a-surprise is.

## Phase 1: Load the plan and LOCK scope before touching code

- If `$ARGUMENTS` is a file path, read it. Otherwise use the agreed plan already in the conversation
  (or the newest `.claude/plans/*.md` if one exists). If you can't find a clear plan, stop and ask
  — don't invent one.
- **Decompose into an ordered step list** of the smallest independently-shippable increments, and
  show it. Ranked-options audits often bury scope ambiguity here — e.g. "implement it" could mean
  *all* the options or just the top-ranked ones the audit itself recommends first. **Surface that as
  an open question and get an answer before writing anything.** Do not assume "all of it, in listed
  order" — confirm order and cut-line.
- Honor the global anti-fabrication rule: every file/function/column/flag you name in the step plan
  is cited (`path:line`) or hedged. Grep before you assert.

Do not start Phase 2 until the step list and scope are confirmed.

## Phase 2: The step loop

For each step, in order:

1. **Implement** just that increment — the smallest change that stands on its own. No reaching ahead
   into later steps.
2. **Verify it** before moving on: drive the actual behavior the step changed (run the path, hit the
   endpoint, exercise the flow) — not "it compiles." Reuse `/verify`'s logic-mode discipline. If a
   `/plan` spec exists, check this step against its **Verification plan** section. State what you
   drove and what you observed.
3. **Report** the step in one or two lines: what changed, what you verified, green/red — then
   continue to the next step. Keep the momentum visible.

**Ask, don't guess.** The moment a step needs a decision the plan didn't settle — an ambiguous
requirement, two reasonable approaches, an unclear expected value — stop and ask. A wrong guess
buried three steps deep is expensive to unwind.

## HALT conditions — stop and surface, do not push through

Stop the loop and report the moment any of these happen (this is the "stop if something unforeseen
happens" clause, made explicit):

- An unexpected error, failing verification, or behavior that contradicts the plan's assumptions.
- The change turns out bigger or more entangled than the plan assumed (hidden blast radius).
- A step would require an **irreversible or out-of-scope action** — deleting data, a force op,
  pushing to main/master, touching prod, a schema migration the plan didn't call for.
- Anything the plan simply didn't foresee.

On halt: say which step, what happened, what you observed, and the options — then wait. Don't
"work around it" silently. Respect command safety (README → Design rules): ask first on rm / bulk
`sed -i` / force ops / pushes; `git reflog` before any reset.

## Phase 3: Handoff

When the confirmed scope is done: summarize what shipped step-by-step, then point to the tail of the
recipe — a final `/verify` as the formal gate (or `/verify --ui` for visual work),
`/save-learnings-to-docs`, then commit (staged BY NAME). Leave prod re-checks for their separate
pass, `/crosscheck`.
