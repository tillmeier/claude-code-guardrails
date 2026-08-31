---
name: save-learnings-to-docs
description: Save session learnings to the CHEAPEST tier that carries each one (hook → .claude/rules/ path-scoped → .claude/docs/ → skill → .claude/local.md → auto memory; CLAUDE.md last and gated), enforcing the CLAUDE.md and MEMORY.md budget gates, AND reconcile the docs related to this session — remove redundancy, fix outdated facts, fill gaps, check cross-refs. No git operations — pure documentation update.
---

# Save Session Learnings to Documentation

This command does **two** jobs, both by default — do not skip the second:

1. **Capture** — save this session's learnings to the right files (distributed pattern below).
2. **Reconcile** — audit the docs *related to this session* so that afterwards nothing is redundant,
   outdated, missing, or cross-broken. This is the reconciliation pass (its own phase below). It is
   what makes the bare command as strong as spelling it out by hand — capture-only leaves stale and
   duplicated docs behind.

Analyze this session and save all important learnings to the appropriate documentation files based on the distributed documentation pattern. BE CONCISE - each point should be 1-2 lines max.

## Quick Assessment

First, quickly scan the session for learnings and **triage each one to the cheapest tier that can
carry it**. CLAUDE.md is loaded in full on every single session; everything below it loads on demand
or on path-match. Default AWAY from CLAUDE.md — it is the most expensive shelf in the house, and a
bloated one measurably *reduces* instruction adherence (official: "Bloated CLAUDE.md files cause
Claude to ignore your actual instructions").

| # | Learning shape | Goes to | Loads |
|---|---|---|---|
| 0 | "Every time X, always do Y" — must hold without judgment | a **hook** in `settings.json` (`PreToolUse`/`PostToolUse`) | never — runs outside context |
| 1 | Applies to **every** session, can't be derived from code | CLAUDE.md | always |
| 2 | Applies only when touching a **file class** (templates, controllers, CSS, migrations) | `.claude/rules/<topic>.md` with `paths:` frontmatter | when Claude **reads** a matching file |
| 3 | Feature/subsystem detail, the war story, the "why" | `.claude/docs/[topic].md` | on read |
| 4 | A multi-step **procedure** (deploy runbook, import flow, release checklist) | `.claude/skills/<name>/SKILL.md` | on invocation |
| 5 | Environment/tooling, machine-specific | `.claude/local.md` | on read (**never `@`-import it**) |
| 6 | Machine-local, per-repo, not the team's business | auto memory `~/.claude/projects/<project>/memory/` | index always; topic files on read |

**Tier 0 first.** Official failure-pattern fix: *"If Claude already does something correctly without
the instruction, delete it or convert it to a hook."* A CLAUDE.md line is advisory and competes for
adherence; a hook fires deterministically at zero context cost. If the learning is "run X before Y"
or "never touch Z", it is a hook, not a bullet.

The measured case for this is stronger than most people assume: in a 1,650-session study of Claude
Code ([arXiv 2605.10039](https://arxiv.org/abs/2605.10039)), a **single, trivial, unambiguous
always-on rule** — prepend one fixed comment to each function — was followed only **60–68 % of the
time per function**, and compliance decayed a further ~5.6 % per function as the session ran on.
Not because the file was too big (size was an affirmative null); that is simply what prose
instructions achieve. A rule you cannot afford to have missed 3 times in 10 does not belong in
CLAUDE.md at all.

**Tier 2 is the most under-used and the biggest win.** A `.claude/rules/` file is markdown with YAML
frontmatter naming the globs it applies to:

```markdown
---
paths:
  - "themes/**/*.ss"
---
- One-line imperative rule. Full story: .claude/docs/<topic>.md
```

By design it costs zero always-on context and arrives exactly when it's relevant. Most "always do X
when editing Y" prose currently living in CLAUDE.md belongs here. Two caveats, both real:

- **Never `@`-import from inside a rule.** Imports in an unmatched rule have been observed loading
  unconditionally — the rule stays out of context, its imports don't ([#16299], open). Inline the
  one line; link the rest as a plain path.
- **Verify with `/context` after adding a rules file.** Same issue reports path-scoped rules loading
  globally despite `paths:`, and *every* `.md` under `.claude/rules/` is discovered recursively — so
  a `refs/` subfolder of deep references becomes always-on context, not progressive disclosure.
  Keep rules files few, short, and `paths:`-scoped.

[#16299]: https://github.com/anthropics/claude-code/issues/16299

## Documentation Targets

### 1. Core Project Knowledge (→ CLAUDE.md)

**Admission test — a learning enters CLAUDE.md only if ALL FOUR hold:**

1. **Universal** — it applies regardless of which file is being touched. If you can name the file
   glob it applies to, it's a `.claude/rules/` entry, not a CLAUDE.md line.
2. **Not derivable** — Claude can't work it out by reading the code. Directory layouts, dependency
   lists, architecture overviews and API surfaces are all derivable; cut them.
3. **Not a procedure** — if it has steps, it's a skill.
4. **Costly if unknown** — removing it would cause a real mistake. Apply the official prune test to
   your own new bullet: *"Would removing this cause Claude to make mistakes?"* If not, cut it.

**Official include/exclude list** (best-practices) — check the bullet against it before writing:

- ✅ bash commands Claude can't guess · style rules that differ from defaults · test instructions and
  preferred runner · repo etiquette (branch naming, PR conventions) · architectural decisions
  specific to this project · env quirks (required vars) · non-obvious gotchas
- ❌ anything Claude can work out by reading code · standard language conventions · detailed API docs
  (link instead) · information that changes frequently · long explanations or tutorials ·
  file-by-file descriptions of the codebase · self-evident practices

**Compress on the way in.** A gotcha enters as a ONE-LINE imperative rule with the war story
*linked*, never inlined:

- ✅ `- DECIMAL columns return STRINGS — cast (float) before zero-guards. Why: .claude/docs/x.md`
- ❌ a paragraph recounting the debugging session, the symptom, the three wrong hypotheses and the fix

**Examples that pass**: "Use dependency injection for all services" · "Always run `npm run validate`
before committing" · "API responses must follow JSend".

**Examples that FAIL** (and where they go instead): "In `.ss` templates use `<% else_if %>`"
→ rules (`paths: themes/**/*.ss`) · "Deploy = pull, flush as www-data, reload FPM" → skill ·
"The chart endpoint serves crypto from a different table than equities" → docs.

### 2. Environment-Specific (→ .claude/local.md) 
**Criteria**: Is this about local setup, debugging, or performance?
- Local development optimizations
- Debugging techniques or tools
- Performance tuning discoveries
- Environment-specific configurations
- Local service workarounds

**Examples**:
- "Set NODE_OPTIONS='--max-old-space-size=4096' for large builds"
- "Use Chrome DevTools Performance tab to profile React renders"
- "Local Redis must be flushed when switching between feature branches"

**Remember**: This file is gitignored! Only add non-sensitive information that's helpful for local development.

### 3. Feature/Module Documentation (→ .claude/docs/)
**Criteria**: Is this detailed knowledge about a specific part of the system?
- Implementation patterns for specific features
- Business logic explanations
- Integration details
- API endpoint documentation
- Database schema insights
- Error handling strategies

**File organization**:
- Check if relevant .md file exists in ./.claude/docs/
- If yes: append to existing file under appropriate section
- If no: create ONE new file with descriptive name (e.g., `authentication-flow.md`, `payment-integration.md`)

## Format Rules

### For all documentation:
```markdown
- Single bullet point per learning
- Include minimal code only when essential (1-3 lines)
- No explanatory paragraphs
- Combine closely related points
```

### Code example format:
```markdown
- Use service pattern: `class UserService extends BaseService`
- Validate input with zod: `schema.parse(input)`
```

## Update Process

1. **Read existing content** to avoid duplication
2. **Add new learnings** under appropriate sections
3. **Update CLAUDE.md index** if creating new docs — plain pointers, terse hooks:
   ```markdown
   ## 📁 Project Documentation
   Environment-specific: .claude/local.md   <- pointer, read on demand
   Path-scoped rules:    .claude/rules/     <- load when Claude READS a matching file

   ### Available detailed documentation:
   - authentication.md - auth flow, JWT handling
   - payment-integration.md - Stripe integration patterns
   - [new-file].md - [≤10-word trigger hook]
   ```

   An index entry is a **trigger hook**, not a summary: enough for Claude to decide "this is the doc
   for the task in front of me", nothing more. If an entry runs past ~10 words you are duplicating
   the doc into always-on context — and the duplicate is what goes stale.

4. **NEVER `@`-import** — not `local.md`, not docs, not anything sizeable. `@`-imports are expanded
   **eagerly at launch**: per the official memory docs, "splitting into @path imports helps
   organization but doesn't reduce context." An `@`-imported environment file costs its full token
   weight in every session, including the ones that never touch the environment. If you find an
   `@`-import of a large file at the top of CLAUDE.md, **replace it with a one-line pointer** and
   hoist only the handful of facts that genuinely are needed every session.

## Reconcile Pass (default — run it every time, after capture)

Capturing new learnings is only half the job. Now audit the docs **related to this session** and
leave them clean. This is the behavior that makes the bare command strong — don't treat it as
optional.

**Scope it first.** "Related" = docs this session touched or is topically about — the files you just
wrote to, plus their obvious neighbours (same feature/subsystem, files they cross-link). In a repo
with a large `docs/` tree (some of these repos carry 100+ docs), do NOT crawl and rewrite the whole
tree — that's slow and risks editing docs this session never informed. Bound the pass to the related
set; if you're unsure whether a doc is in scope, leave it and note it.

For each in-scope doc, check and fix four things:

1. **Redundant** — the same fact stated in two places (or a new bullet you just added that an
   existing one already covers). Merge into the single best home; delete the duplicate. Prefer the
   canonical doc for that topic.
2. **Outdated** — a claim this session proved wrong or superseded (a renamed file, a changed flag, a
   replaced approach, a fixed bug the doc still describes as open). Correct it or cut it. Don't leave
   a doc asserting something you now know is false.
3. **Missing** — a gap this session exposed that future-you will need and no doc yet covers. Fill it
   concisely.
4. **Cross-refs** — links/pointers between docs and the CLAUDE.md index still resolve and still
   describe the right thing. Fix stale pointers; add an index line for any new doc.

Be surgical, not slash-and-burn: correct and merge freely (git + your pre-commit review are the
safety net), but when you remove a whole block, **say so in your summary** so it shows up before you
commit. Honor the anti-fabrication rule — every path/flag you touch is verified, not guessed.

To skip this pass on a throwaway session, say "capture only" — otherwise it runs.

## Special Handling

### When updating CLAUDE.md — MEASURE, don't estimate:

Official target is **under 200 lines**. That is the only official number: CLAUDE.md is loaded in
full at any size — there is no truncation and no byte cliff. Measure both anyway, because **lines
and bytes are each only a proxy for tokens**, and long-line prose defeats the line count: a measured
172-line / 21.3 KB file averages ~124 chars/line, i.e. ~2× normal, so it passes the line target
while costing what a 300–400-line file would.

```bash
wc -lc CLAUDE.md            # lines + bytes; bytes ÷ 4 ≈ tokens — tokens are the honest unit
```

`/context` is the authoritative cross-check — it lists what actually loaded under **Memory files**
and flags memory bloat. `wc` is the cheap in-session proxy.

**Budget gate — run it BEFORE appending. The bands are a COST policy, not an adherence cliff:**

- **< 200 lines** → append freely (still apply the admission test).
- **200–400 lines** → append only tier-1 learnings; actively demote something else while you're in
  there. Mention the growth in your summary.
- **> 400 lines / > 20 KB (~5k tokens)** → **default to routing elsewhere.** Not because adherence
  falls off a cliff at that byte count — no evidence supports that — but because you are proposing
  to charge every future session in this repo ~5k tokens, forever, for a fact that `rules/`, `docs/`
  or a skill would deliver only when relevant. Append only if the learning genuinely applies to
  *every* session, and say what the file now costs. Suggest a prune pass (`/cleanup-docs`,
  `/refactor-claude-md`, or `/doctor`'s trim proposals).

**What the evidence actually says** (checked against primary sources 2026-08-15, not folklore):
McMillan 2026 ([arXiv 2605.10039](https://arxiv.org/abs/2605.10039), 1,650 Claude Code sessions)
varied CLAUDE.md across 25/100/250/500 lines — padded with *realistic rule-like content*, so rule
count co-varied — and found compliance 60.0/65.2/67.7/64.0 % with an **affirmative null** (p=0.16,
linear trend p=0.625, BF₁₀ 0.05–0.10). File size did not measurably reduce adherence in that range.
Three caveats keep this from being a licence to grow: the measured rule was one trivial syntactic
marker (`// @tracked`), and the paper itself says demanding instructions "are subject to additional
failure modes … that the marker does not capture"; it explicitly does **not** contradict the
attention-dilution literature at longer context scales; and it is a single unreplicated preprint.
So: stop asserting a byte-based adherence cliff, keep the cost discipline.

**The largest measured effect is within-session drift, not file size** — compliance odds fall ~5.6 %
per additional function generated (OR=0.944, pooled; the paper calls the shape non-monotonic), with
the median first omission at function 4.
That is the real argument for **tier 0**: anything that must hold every time belongs in a hook or a
build gate, where it fires deterministically, not in prose that decays as the session runs long.

Free trick worth using: **block-level HTML comments in CLAUDE.md are stripped before injection**, so
`<!-- maintainer note -->` costs zero context. Park rationale for humans there instead of in prose.

A capture command that only ever grows its target file is a rot engine. The gate is what makes this
command safe to run after every session.

- Add to existing sections when possible; create new sections only if necessary
- Never let the same fact live in both CLAUDE.md and a doc — pointer in one, content in the other

### When writing to auto memory (`~/.claude/projects/<project>/memory/`):

Auto memory is the *other* always-on file, and usually the bigger one. It is machine-local,
per-repository, uncommitted and Claude-authored. Committed docs are the team's; auto memory is this
machine's.

**Division of labour — get this right or knowledge goes missing:**

- A learning that belongs to the **repo** (convention, gotcha, subsystem behaviour) goes to
  `.claude/docs/` / `rules/` / CLAUDE.md — writing it only to auto memory hides it from everyone
  else, from CI, and from every other machine.
- A learning that is **this machine's** (local paths, personal workflow, cross-repo context, who the
  user is) goes to auto memory. Don't commit it into a project doc.

**Hard limit:** only the first **200 lines OR 25 KB of `MEMORY.md`, whichever comes first**, is
loaded at session start. Everything past that is dropped silently — the file still looks complete on
disk. Topic files in the same directory are *not* loaded at startup; Claude reads them on demand.
That asymmetry is the whole design: index in `MEMORY.md`, content in topic files.

```bash
wc -lc ~/.claude/projects/*/memory/MEMORY.md    # 200 lines / 25,000 bytes, whichever hits first
```

**Budget gate — run BEFORE appending an entry. 22 KB is a HOUSE guard-rail, not the cliff:** the
documented cutoff is 25 KB, so the band leaves ~3 KB of headroom on purpose. `wc -c` also slightly
over-states the load — YAML frontmatter and block-level HTML comments are stripped before the index
is measured and loaded, so they cost nothing.

- **< 15 KB** → append a one-line entry.
- **15–22 KB** → append only after demoting an existing fat entry into its topic file. Say so.
- **> 22 KB** → **STOP.** Demote first, then append. You are not at the cliff yet, but you are inside
  the last 3 KB before content starts being dropped silently on the next load — and the drop takes
  the tail, not the line you just wrote.

**"Still open" is NOT a reason to skip demotion.** A fat index line for an unfinished project is
still a fat index line; demotion moves detail into the topic file, it does not close anything. The
official remediation names no completion criterion — *"keep one line per entry, move detail into
topic files, and merge or drop stale entries"*. If every entry is open and the index is full, you
demote the **biggest** ones, not the finished ones. (Seen 2026-08-15 on a 21.6 KB index whose top
lines were 1398 / 986 / 980 / 831 B: a session declared nothing demotable because nothing was
concluded, then appended anyway.)

**An index entry is a hook, not a summary.** One line, ≤ ~200 characters, `[[topic-file]]` linked.
If an entry has grown into a paragraph of dates, hostnames and MR numbers, that content already
belongs in the topic file — **verify it's there, then shrink the index line**. Never delete a fact
that exists only in the index.

### When updating .claude/local.md:
- Never commit this file (it's gitignored)
- Focus on developer experience improvements
- Include machine-specific optimizations

### When creating new .claude/docs/ files:
```markdown
# [Feature/Module Name]

## Overview
[1-2 line description]

## Key Learnings
- [Learning from this session]
- [Another learning]

## Implementation Notes
- [Specific pattern discovered]

## Common Issues
- [Problem]: [Solution]
```

## Example Output

After analyzing the session, you might update:

**CLAUDE.md** (added under Code Style):
```markdown
- Use Result<T, E> pattern for error handling
- Prefer composition over inheritance
```

**.claude/local.md** (added under Debugging):
```markdown
- Enable React Query devtools: `import { ReactQueryDevtools } from '@tanstack/react-query-devtools'`
- Profile database queries: `EXPLAIN ANALYZE` in psql
```

**.claude/docs/error-handling.md** (new file):
```markdown
# Error Handling Patterns

## Overview
Standardized error handling using Result pattern

## Key Learnings
- All service methods return Result<T, Error>
- Use custom error classes extending BaseError
- Log errors with structured format: `logger.error({ err, context })`
```

## Completion Check

Before finishing:
- ✓ All significant learnings captured
- ✓ **Each learning went to the CHEAPEST tier that carries it** (rules/docs/skill before CLAUDE.md)
- ✓ **Budget gate ran** — `wc -lc CLAUDE.md` measured, not estimated; if the file grew, say by how
  much in the summary, and if it's over budget say so plainly instead of quietly appending
- ✓ **MEMORY.md gate ran** if anything went to auto memory — measured, and any entry that grew into
  a paragraph was demoted to its topic file (after verifying the facts are there) rather than left
  to push the index toward the 25 KB cutoff
- ✓ Repo-worthy learnings went to the repo, machine-local ones to auto memory — not the reverse
- ✓ No `@`-imports added or preserved (and none inside a `.claude/rules/` file)
- ✓ **Reconcile pass ran** over the related docs (unless "capture only" was requested)
- ✓ Redundancy removed (not just new dupes avoided — existing ones merged too)
- ✓ Outdated/superseded claims corrected or cut
- ✓ Gaps this session exposed are filled
- ✓ Cross-refs + CLAUDE.md index resolve and are accurate
- ✓ Any whole-block removals called out in the summary
- ✓ Appropriate categorization (core/local/feature)
- ✓ Format is concise (bullets, not paragraphs)

Remember: Focus on actionable knowledge that will help in future sessions. Skip obvious or temporary information.
