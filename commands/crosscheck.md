---
name: crosscheck
description: Cross-check recent, not-yet-verified work — in ANY project. Reconstruct what you shipped or optimized lately and haven't confirmed, find where each change's evidence lives (logs / DB / generated output / endpoint / UI / CI — discover, don't assume), and report honestly: does it run clean, did new problems appear, did the intended fixes actually work. Two rules — verify before asserting, and "ran" ≠ "worked". Read-only. Optional focus hint as argument.
argument-hint: "[optional focus — a project or change to scope to]"
---

# Crosscheck — Did My Recent Work Actually Hold?

Plain trigger: *"everything you built or optimized recently that you haven't cross-checked yet —
audit it: does it run clean or are there problems, did anything new break, and did the fixes work as
we intended?"*

Project-agnostic by design. The *what* and *where* differ every time, so this command carries **only
the parts that don't** — the scope discipline and two universal rules. Everything project-specific
(paths, logs, tables, stages) you **discover at runtime**; nothing of that is hard-coded here.

## 1. Scope — the un-cross-checked delta

Name what you're auditing: the changes/optimizations shipped recently that have **not yet been
verified**. Reconstruct in order:
- **this session's context** — what you built or changed and haven't since confirmed (usually enough);
- across several days / sessions, widen with recent `git log`, `.claude/plans/`, `~/.claude/handoffs/`.

Cover both directions explicitly: **did the intended fixes do what we wanted**, AND **did anything
new break** (a fix that dented something else, a fresh error since). If the delta is large or you're
unsure what's already been checked, state the scope in one line and let the user trim it — don't
interrogate, and don't silently audit a subset while implying you covered everything.

## 2. Locate the evidence — discover, don't assume

For each change, find where the truth of it lives. Different every project: application / access
logs, DB rows, generated output (articles, files), an API endpoint, a rendered page, cron /
supervisor state, CI or test results. `ls` / `grep` / inspect to locate it **this run** — never
assert a path or table you didn't confirm.

**Where you run it** — local vs prod — follows from context: already on the box (cwd, hostname) →
local reads are the truth; on your workstation against a server → reach it over SSH; a local-only
change → check it locally. Decide, state it in one line, ask only if genuinely ambiguous.

## 3. Check it — two rules that hold for every project

- **Verify before you assert.** Every "it's clean" needs a confirming read behind it. Re-check a
  surprising result with a second method before you call it — most apparent regressions are
  measurement artifacts (a rotated log, a timezone offset, a grep that silently matched nothing on a
  binary file), not real bugs.
- **"Ran" ≠ "worked".** A log line or a green process proves execution, not outcome. Where a change
  flows through stages, follow ONE real item end-to-end and confirm the result actually landed —
  reconcile the counts stage-to-stage; the bug lives where they stop matching. Compare today's
  numbers to the normal / baseline level, not to nothing.

Depth into the one thread that looks off — not breadth for its own sake.

## 4. Verdict — honest

Per change, plain words:
- **Works as intended** — with the evidence (the number, the traced item), not "should be fine".
- **Problem** — new breakage, or a fix that underperformed: the exact signal + what you'd do about
  it (propose, don't apply).
- **Couldn't verify** — say exactly why.

Then a **"not checked"** line — what you didn't reach, sample ≠ full population. Clean means verified,
never "didn't look". Then any out-of-scope oddity you noticed. Mirror the user's language.

## Hard rules

- **Read-only.** This audits; it does not fix. A problem gets reported + a proposed fix; the user
  decides. No writes, no restarts, no auto-fixes.
- **No blind identifiers** — discover paths / logs / DBs / tables at runtime or hedge them.
- **Carry nothing project-specific.** The moment you'd need a fixed path, log name, or schema, that's
  the signal to discover it, not to bake it into this command.
