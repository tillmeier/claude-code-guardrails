---
name: cleanup-docs
description: Audit and clean up a repo's Claude documentation — measure the always-on tier first (CLAUDE.md + nested + .claude/rules/ + the auto-memory index), then merge redundancy, cut derivable and model-obsolete content, demote misplaced tiers, fix cross-refs. Verifies every fact survives before cutting; asks before destructive operations; reports byte deltas.
---

# Cleanup and Optimize Claude Documentation

Audit the Claude documentation in this repo and leave it smaller, truer and correctly tiered. The
order is fixed: **measure → audit → verify → execute → report**. Skipping the measure step produces
opinion-driven cleanup; skipping the verify step destroys knowledge.

Two standing rules for the whole run:

- **Re-read immediately before you rewrite.** A read from earlier in the session is not current
  state — other sessions and linters edit these files while you work.
- **Verify a claim before you "correct" it.** Cutting a claim that turns out to be true is worse
  than leaving one you doubt. If a doc cites something, check the source before overruling it.

## Phase 0: Measure (mandatory — no cuts before this)

```bash
# Always-on tier: everything here is paid for at every session start
wc -c CLAUDE.md CLAUDE.local.md 2>/dev/null
find . -name CLAUDE.md -not -path "*/node_modules/*" -not -path "*/vendor/*" | xargs wc -c
wc -c .claude/rules/*.md 2>/dev/null
wc -c ~/.claude/CLAUDE.md ~/.claude/projects/*/memory/MEMORY.md

# On-demand tier: cheap until read — count it, don't panic about it
ls .claude/docs/*.md 2>/dev/null | wc -l
```

Then cross-check in-session:

- **`/context`** — what actually loaded (*Memory files*), the **Skills** row (already
  budget-adjusted), and memory-bloat flags.
- **`/doctor`** — trim proposals for a checked-in CLAUDE.md (it cuts what Claude can derive from the
  codebase — directory layouts, dependency lists, architecture overviews — and keeps pitfalls,
  rationale and conventions that differ from tool defaults), plus an estimate of the **skill-listing**
  context cost and its biggest contributors.

**Measure bytes AND lines — tokens are what you're actually spending.** The official target is
"under 200 lines", but long-line prose defeats it: a 166-line CLAUDE.md measured 20.3 KB (~5k tokens)
in this fleet, and a 172-line one averaged ~124 chars/line — double normal, so it passed the line
test while costing what a 300–400-line file would. Verdict table — always-on total across project
CLAUDE.md + nested + rules + user CLAUDE.md + memory index:

| always-on total | verdict |
|---|---|
| **< 8 KB** | healthy — audit for accuracy only |
| **8–20 KB** | trim — demote to `.claude/rules/`, `.claude/docs/` or skills as you go |
| **> 20 KB (~5k+ tokens/session)** | expensive — trimming the always-on tier is the highest-value work here; `.claude/docs/` hygiene is cosmetic by comparison |

**These bands are a COST policy, not an adherence cliff — say so when you report them.** CLAUDE.md is
loaded in full at any size; there is no truncation and no documented byte threshold, and a controlled
study of 1,650 Claude Code sessions ([arXiv 2605.10039](https://arxiv.org/abs/2605.10039)) found
*no* measurable adherence difference between 25- and 500-line files, affirmative-null. What justifies
cutting is the recurring token cost on every future session, plus the qualitative official warning
that bloated files get their rules lost. Don't tell the user their file is "past the point where
adherence degrades" — that claim has no evidence behind it. Tell them what it costs per session.

The one byte cliff that IS real and enforced: `MEMORY.md` at 200 lines / 25 KB (below).

State the numbers in your first message. "Looks bloated" is not a finding; `38.9 KB / 265 lines` is.

**Then look for a ONE-LINE cause before proposing any merge.** Always-on bloat is usually
concentrated, not spread: in the worst repo measured, a single `@`-import was **54%** of the budget
and one section was another 19% — 73% of the problem in two edits, zero editorial judgment, zero risk
of losing a fact. Merging 116 docs would have been weeks of judgment for a fraction of that. Rank
candidates by **bytes removed ÷ judgment required** and work top-down; stop when the cheap wins are
gone rather than grinding into the expensive ones.

## Phase 1: Audit

Read the files and map them:

- **CLAUDE.md** — core conventions (always-on, the expensive shelf)
- **nested `CLAUDE.md`** — per-subsystem, loads when Claude reads files in that dir
- **`.claude/rules/`** — path-scoped, loads when Claude READS a matching file
- **`.claude/docs/`** — feature detail, loads on read
- **`.claude/local.md`** — environment, gitignored, don't modify
- **`~/.claude/projects/<project>/memory/`** — auto memory: `MEMORY.md` is always-on with a hard cap
  (first 200 lines OR 25 KB, then content silently stops loading); topic files load on demand

### 1. Redundant

Same fact in two places; near-duplicate files.

> **⚠ Similar names/sizes are a HYPOTHESIS, not redundancy.** Before declaring any two docs
> duplicates, **diff their actual content** — repeatedly, "obvious duplicates" turn out to each
> carry unique sections (one is a deep walkthrough, the other has the cron/limits/legal/migration
> detail; a "handover" is the canonical spec another doc says "read first"). Name- or size-based
> dedup destroys unique knowledge under a "cleanup" banner. Treat the audit's merge list as leads
> to verify, not a work order.

### 2. Outdated — by lifecycle marker, NOT by age

> **⚠ Old ≠ stale.** A doc untouched for a year can be perfectly accurate. Don't run an
> mtime-based sweep — verify the documented feature is actually gone before removing. Trigger
> archival on **lifecycle markers**, not dates:
> - Doc self-declares `retired` / `concluded` / `answered` (e.g. a finished A/B-test doc)
> - A "build handover" / "PLAN" doc whose feature shipped AND a canonical doc now exists
> - `grep` for a key identifier from the doc in the codebase returns nothing (feature removed)
>
> Prefer **archive/** (with a date-prefixed subdir) over deletion — keep the record, get it out of
> the active index. Leave `TODO`/`FIXME` alone; they're legitimate code comments, not doc rot.

### 3. Contradicting

Conflicting instructions across files — Claude picks one arbitrarily when two rules disagree, so a
contradiction is worse than a gap. Check the project CLAUDE.md against nested ones and against
`.claude/rules/`.

### 4. Dead references

Links to files that no longer exist; pointers to renamed paths; external links that 404.

### 5. Derivable content (always-on tier only)

Cut what Claude works out by reading the code: directory layouts, dependency lists, architecture
overviews, file-by-file descriptions, quick-start/install steps, standard language conventions,
self-evident practices, detailed API docs (link instead). Cross-check against `/doctor`'s proposal —
if it wants to cut something you think is load-bearing, say why in the report rather than silently
overruling it. Keep: non-default conventions, gotchas, rationale that isn't visible in the code.

### 6. Model-obsolete workarounds

Instructions written to compensate for an older model's limitation become pure overhead once the
limitation is gone (official guidance: revisit after major model releases). Symptoms: rules that
force single-file edits, forbid a tool that now works, prescribe verbose step-by-step ritual for
something Claude does correctly unprompted. Test: *would Claude get this right today without the
rule?* If yes, cut it.

### 7. Misplaced tier

- Path-specific "always do X when editing Y" prose in CLAUDE.md → `.claude/rules/` with `paths:`
- A multi-step procedure in CLAUDE.md → a skill
- A rule that must hold every time and needs no judgment → a hook (CLAUDE.md is advisory)
- **`@`-imports used to "shrink" CLAUDE.md** → they load at launch and don't reduce context; replace
  with a one-line pointer and hoist only the facts genuinely needed every session
- Other teams'/legacy subtrees pulling in nested CLAUDE.md you never work in → `claudeMdExcludes`,
  **but check nobody ever starts a session in there first.** Patterns match absolute paths, so
  excluding a subtree also strips the CLAUDE.md of a session *started inside* it. Excluding
  `**/.claude/worktrees/**` looks free and silently un-instruments every worktree session — the case
  where the fix is worse than the 3 KB it saves. Prefer starting Claude in the subtree over excluding it.

The tier ladder itself lives in `save-learnings-to-docs` — link, don't restate it here.

### 8. Frontmatter and description drift

A command's or skill's `description` is always-on context AND the routing signal, and it drifts from
the body silently (seen in this repo: a body rewritten to a 5-tier model while its description still
advertised 3 tiers). For every command/skill in scope: does the description still describe what the
body does, and does it lead with the words a request would actually contain?

Cost context: the skill listing's budget is **1% of the model's context window**; on overflow,
descriptions are dropped starting with the **least-invoked** skills, and each entry's
`description` + `when_to_use` is capped at **1,536 chars**. Levers if `/doctor` reports the listing is
expensive: trim descriptions at the source, `skillOverrides: "name-only"` for low-priority entries,
or raise `skillListingBudgetFraction`.

### 9. The auto-memory index

It rots exactly like a hand-maintained doc index, and it is always-on, so it rots expensively.
Same checks as above, plus:

- **Distinguish bloated-by-FAT from bloated-by-COUNT — only the first is your job.** Measure the
  per-line distribution before proposing anything:
  `LC_ALL=C awk '{print length()}' MEMORY.md | sort -rn | head -5`
  (`length()` with no argument, deliberately — a positional shell variable inside a command file gets
  substituted with the invocation's arguments before you ever see it).
  A few 2–3 KB entries = fat: verify their facts are in the topic file, then shrink each to a
  ≤200-char hook (mechanical, zero loss — this recovered 46% of one index). 117 entries averaging
  150 B = count: there is nothing to compress, and "shrinking" it means *dropping* learnings, which
  is an editorial call on live knowledge. Report it, name the headroom, don't cut.
- **Never** cut a fact that exists only in the index.
- **The 25 KB cliff.** Past 200 lines or 25 KB the tail stops loading with no error. Over ~15 KB,
  demoting fat entries beats anything in `.claude/docs/`, which costs nothing until read.
- Auto memory is machine-local and uncommitted: fix it in place, don't try to stage it.

## Phase 2: Verify (blocks Phase 3 — nothing is cut until this passes)

**Token-grep protocol — run it on every merge, shrink or archive candidate:**

```bash
# 1. Pull the distinctive tokens out of the text you are about to remove:
#    dates, ticket/MR numbers, hostnames, file paths, flags, ★corrections, measured values.
# 2. Prove each one exists in the survivor:
for t in "2026-07-15" "!3889" "serve-410.php" "validate_timestamps"; do
  grep -qF -- "$t" SURVIVOR.md || echo "MISSING: $t"
done
# 3. Append everything still MISSING to the survivor FIRST. Then, and only then, cut.
```

This is not optional ceremony: on the last run, 9 facts existed **only** in the text being shrunk and
would have been destroyed by a plausible-looking merge.

**Structural checks before archiving or merging a whole file:**

```bash
# (a) Heading sets — does A carry material B lacks?
comm -23 <(grep '^#' A.md | sort -u) <(grep '^#' B.md | sort -u)   # headings in A not in B
# (b) Inbound references — who links to A?
grep -rIl 'A\.md' .claude/ docs/ --include='*.md'
```

If A has headings absent from B, A is not a subset — keep both or merge selectively. If other docs or
commands reference A (especially "read A first"), A is a live dependency: re-point every reference
before touching it.

## Phase 3: Execute

**Back up the DOCS, not the directory.** `.claude/` can contain git worktrees, screenshots and tmp
output — measured 3.2 GB in one repo, where a naive `cp -r .claude` would have been the most
destructive thing in the run. Check first, copy only what you're about to edit:

```bash
du -sh .claude/*                                   # look before you copy
B=<scratchpad>/docs-backup && mkdir -p "$B"
cp CLAUDE.md "$B/"; cp -r .claude/rules "$B/"; cp .claude/local.md "$B/" 2>/dev/null
cp ~/.claude/projects/*/memory/MEMORY.md "$B/"     # gitignored files NEED this; tracked ones have git
```

**Move text mechanically — never by retyping.** A verbatim relocation (index → its own file, section
→ another doc) is a line-slice operation for a script. Reading 23 KB and re-emitting it invites
silent transcription drift, and the resulting diff can't prove nothing changed. Slice by heading
index, assert the block size, write both files, then run the Phase 2 token-grep across the pair.

**If the repo is live, stage your own paths explicitly.** Another session may be editing the same
tree (seen: four foreign modified files mid-run). `git add -A` would sweep their work into your
commit. Name your files: `git add CLAUDE.md .claude/docs/README.md`, and re-check `git status`
immediately before committing — it changes under you.

Then, one change at a time, asking before each destructive one:

```
Found potentially outdated content in [file]:
"[content snippet]"

This appears to reference [old feature/version].
Should this be:
1. Removed (outdated)
2. Updated (still relevant but needs changes)
3. Kept as-is (still valid)

Your choice (1/2/3):
```

Also ask on: merges ("merge `websocket.md` + `realtime-updates.md` into `communication-patterns.md`?"),
and conflicts ("`[topic]` differs in [file1] vs [file2] — which is current?"). Fix cross-references
and the CLAUDE.md index in the same pass as the change that broke them.

### The documentation index — prefer AUTO-GENERATION

**Measure the index before you decide to regenerate it.** "Hand-maintained" is a risk factor, not a
verdict — one measured index had 123 references, **0 broken, 116/116 docs covered**, with curated
one-line hooks an auto-harvester (H1 + first prose line) would have replaced with something worse.
The right move there was to **move it verbatim out of always-on context**, not to regenerate it.

```bash
# every referenced doc exists? every doc referenced?
python3 - <<'EOF'
import re,io,os
t=io.open('CLAUDE.md',encoding='utf-8').read()
refs={os.path.basename(r) for r in re.findall(r'`([\w./-]+\.md)`',t)}
disk={f for f in os.listdir('.claude/docs') if f.endswith('.md')}
print('broken refs:', sorted(refs-disk-{'CLAUDE.md'}) or 'none')
print('undocumented on disk:', len(disk-refs), 'of', len(disk))
EOF
```

Regenerate when it has already rotted or nobody maintains it. Otherwise a hand-maintained index rots:
it drifts out of sync with the docs and ends up describing live features as "not built". Two options:

- **Best — generate it.** A small script that walks `.claude/docs/`, harvests each doc's `# H1`
  + first prose line (or an in-doc `<!-- hook: ... -->` override), and emits the index as a build
  artifact. The index then *cannot* contradict the docs, and a `--check` mode gates staleness in CI.
  Don't stamp a date or a doc-count into it — those become the next lie.
- **If hand-maintained** — keep CLAUDE.md to a terse `title → path` list of the ~12-15 hottest docs
  only, and point to the full index. Never maintain the same blurb in two places (CLAUDE.md AND a
  README) — that guarantees drift.

```markdown
## Documentation
**Full index:** .claude/docs/README.md   # auto-generated; run the index script after adding a doc
**Path-scoped rules:** .claude/rules/     # load when Claude READS a matching file (0 always-on cost by design)
- [hot-doc].md — [≤10-word hook]          # only the cross-cutting docs most sessions touch
```

## Phase 4: Report — in numbers

```
Always-on tier:  CLAUDE.md 38,938 → 11,204 B | rules 3 → 5 files | MEMORY.md 19,356 → 10,475 B
Moved:           [what went to rules/ | docs/ | a skill | a hook]
Merged/archived: [file → survivor, each one token-verified]
Left alone:      [candidate + why it survived the audit]
```

Rules for the report: byte deltas, never adjectives. Every whole-block removal called out explicitly.
Anything you chose NOT to cut gets a line too — a silent omission reads as "nothing was there".

## Quality checks

- [ ] Phase 0 measured, numbers stated, verdict band named
- [ ] No fact cut that wasn't proven present in a survivor (token-grep ran)
- [ ] No claim "corrected" without checking its source first
- [ ] No duplicate topics; no contradicting instructions across tiers
- [ ] Every file's frontmatter description matches its body
- [ ] Cross-refs and the index resolve
- [ ] Backup exists; every destructive step was asked first
- [ ] Report carries before/after bytes and a "left alone" list

Goal is clarity and trust, not fewer files. A smaller docs tree that lost a hard-won gotcha is a
regression, not a cleanup.
