---
name: critical-review
description: Exit-gate review of this session's changes by a reviewer that never sees the task brief — Codex, Claude or your own command via scripts/review-backend.sh. Findings → plan mode with proposed fixes (one approve/deny), or --review-only for findings in chat. --adversarial forces the deeper prompt-mode pass. Refuses to fake a review when no reviewer is available.
argument-hint: "[--review-only] [--adversarial] [--no-brief] [--show-brief] [--brief-file <path>] [--final <topic> | --feature <topic>] [--since <ref-or-date>] [--base <ref>] [--session] [--working-tree] [focus ...]"
allowed-tools: Read, Glob, Grep, Edit, Write, Bash(bash:*), Bash(git:*), Bash(python3:*), Bash(cat:*), Bash(echo:*), Bash(printf:*), Bash(awk:*), Bash(cut:*), Bash(sort:*), Bash(head:*), Bash(tail:*), Bash(wc:*), Bash(tr:*), Bash(find:*), Bash(ls:*), Bash(mkdir:*), Bash(cp:*), Bash(test:*)
---

# Critical Review

You are running a **critical review** of the changes made in THIS session, by an independent
reviewer, and then judging its findings against the code and the session's intent.

The reviewer is whatever `scripts/review-backend.sh` finds: the Codex CLI, the Claude Code CLI, or a
command you configured (`REVIEWER=codex|claude|custom`, models pinned in `review-backend.conf`). It
runs read-only and **never sees the conversation brief** — only the diff and, optionally, your focus
text. Framing a change as intended or bug-free collapses a reviewer's true-positive rate
(arXiv 2603.18740), so intent is applied only afterwards, by you, behind a mandatory source re-read.

**Default** (no `--adversarial`, no focus text): the backend's native reviewer when it has one
(Codex), else its prompt-mode adversarial pass. `--adversarial` or any focus text forces prompt
mode on every backend.

**ABSOLUTE RULES:**

- **DO NOT** edit, patch or write any project file BEFORE the user approves the plan via
  `ExitPlanMode`. Phase 5 is the ONLY place project edits are permitted, and only for approved findings.
- **DO NOT** commit or push at any point in this command, even after plan approval.
- **DO NOT** review the diff yourself in place of the backend. If no reviewer is available or the
  reviewer fails, say so and stop (Phase 0 / Phase 2). A self-review reads like an independent one in
  the transcript and is exactly what this command exists to prevent.
- **DO** critically evaluate each finding against the actual code BEFORE accepting it into the plan.
- **DO** silently drop findings whose lines are outside the session's scope (Phase 3 hard-drop) and
  findings your own evaluation rejects (Phase 4a); keep the dropped list in memory for `show dropped`.
- **DEFAULT PATH** (no `--review-only`): after filtering, `EnterPlanMode`, write a plan with every
  surviving finding (What & why · Verified by · Fix · Complexity) plus an implementation order, then
  `ExitPlanMode` for one approve/deny. On approve, Phase 5 implements the approved fixes.
- **REVIEW-ONLY PATH** (`--review-only`, or zero surviving findings): present findings in chat in one
  flowing message, close with the options block, stop. No plan mode, no implementation.
- **EXCEPTION:** writing the session files under `${TMPDIR:-/tmp}` named below and appending to the
  review log is always permitted (ephemeral metadata + append-only instrumentation).

Session files (all keyed by `${CLAUDE_SESSION_ID}`, written under `${TMPDIR:-/tmp}`, GC'd after 7 days by `hooks/session-start.sh`):

| File | Written by | Holds |
|---|---|---|
| `claude-session-start-commit-<sid>` | `hooks/session-start.sh` | HEAD when the session began |
| `claude-session-start-dirty-<sid>` | `hooks/session-start.sh` | paths already modified/untracked at session start |
| `claude-session-start-blobs-<sid>` | `hooks/session-start.sh` | `<blob sha>TAB<path>` of each dirty file's content at session start |
| `claude-session-last-review-commit-<sid>` | this command (Phase 6) | HEAD after the last review in this session |
| `claude-session-last-review-blobs-<sid>` | this command (Phase 6) | `<blob sha>TAB<path>` of each dirty file's content at that review |
| `claude-review-brief-<sid>.md` | this command (Phase 1.5) | the conversation brief, never shown to the reviewer |
| `claude-review-dirty-fallback-<sid>` | this command (Phase 1, only without a snapshot) | the opening gitStatus paths, the dirty list of last resort |

---

## Phase 0: Is a reviewer available?

Before anything else (no brief, no scope work), ask the backend script:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/review-backend.sh" --detect
```

`${CLAUDE_PLUGIN_ROOT}` is filled in for plugin installs. If it is empty (installed by hand), the
script is at `${REVIEW_BACKEND:-$HOME/claude-code-guardrails/scripts/review-backend.sh}`; if that
file does not exist either, tell the user to export `REVIEW_BACKEND=<checkout>/scripts/review-backend.sh`
and stop. Remember the path you used as `RB` for Phase 2.

- Exit 0 prints `<backend> <model>`. Remember both as `BACKEND` and `MODEL`; continue.
- Exit 3: print the script's stderr verbatim (it names every check it made and how to fix it) and
  **stop**. Do not generate a brief, do not review anything yourself.
- Any other exit: print the error and stop.

---

## Phase 1: Determine Review Scope

Raw arguments: `$ARGUMENTS`

**Step 1: Parse arguments.** Extract these from the raw arguments:

- `--review-only` → set `REVIEW_ONLY`, remove (skips plan mode; chat-only output)
- `--adversarial` → set `ADVERSARIAL`, remove (forces prompt mode)
- `--no-brief` → set `NO_BRIEF`, remove (skips Phase 1.5; Phase 4a runs without the brief cross-check)
- `--show-brief` → set `SHOW_BRIEF`, remove (Phase 1.5 generates the brief, prints it, exits — no review)
- `--brief-file <path>` → consume next arg as `USER_BRIEF_FILE`, remove both (Phase 1.5 uses this file)
- `--base <ref>` → store ref, remove both
- `--session` → set session flag, remove
- `--working-tree` → set working-tree flag, remove
- `--since <ref-or-date>` → consume next arg as `SINCE_REF`, remove both
- `--feature <topic>` → consume next arg as `FEATURE_TOPIC`, remove both
- `--final <topic>` → consume next arg as `FINAL_TOPIC`, set `ADVERSARIAL=1`, remove both
- Everything remaining = `FOCUS_TEXT` (steers the reviewer; forces prompt mode)

`--since`, `--feature` and `--final` REQUIRE a value. `--final` without a topic aborts with a usage
message (auto-detecting feature clusters from history is too heuristic; use `--since <ref-or-date>`).

**Step 2: Resolve REVIEW_BASE.**

Priority order:

1. **`--base <ref>`** (explicit override): use the provided ref.

2. **`--working-tree`**: use HEAD (uncommitted changes only).

3. **`--session`**: the session-start marker (everything since Claude Code started):

   ```bash
   MARK="${TMPDIR:-/tmp}/claude-session-start-commit-${CLAUDE_SESSION_ID}"
   BASE="${CLAUDE_SESSION_START_COMMIT:-}"
   [ -z "$BASE" ] && [ -f "$MARK" ] && BASE=$(cat "$MARK")
   echo "${BASE:-HEAD}"
   ```

4. **`--since <ref-or-date>`**: try `SINCE_REF` as a git ref first (hash, branch, tag, `HEAD~N`); fall
   back to a date string:

   ```bash
   if git rev-parse --verify --quiet "${SINCE_REF}" >/dev/null 2>&1; then
     REVIEW_BASE=$(git rev-parse "${SINCE_REF}")
   else
     REVIEW_BASE=$(git rev-list --before="${SINCE_REF}" -1 HEAD 2>/dev/null)   # "2 weeks ago", "2026-04-01", …
   fi
   [ -n "$REVIEW_BASE" ] || { echo "cannot resolve --since '${SINCE_REF}' as a git ref or a date" >&2; exit 1; }
   ```

5. **`--feature <topic>`**: the earliest commit whose message OR touched paths match the topic; base =
   its parent, so the first matching commit is INCLUDED:

   ```bash
   # HEAD's own history only (no --all): a match on an unrelated or unmerged branch would make the
   # range compare divergent trees and review work that is not on this branch.
   MATCH_FROM_MSG=$(git log HEAD --grep="${FEATURE_TOPIC}" --regexp-ignore-case --pretty=format:"%H %ai %s" --reverse 2>/dev/null)
   MATCH_FROM_PATH=$(git log HEAD --pretty=format:"%H %ai" --reverse -- "*${FEATURE_TOPIC}*" 2>/dev/null | head -100)
   FIRST_HASH=$( { echo "$MATCH_FROM_MSG"; echo "$MATCH_FROM_PATH"; } | awk 'NF' | sort -k2 | head -1 | cut -d' ' -f1)
   if [ -z "$FIRST_HASH" ]; then
     echo "no commits or files match topic '${FEATURE_TOPIC}' — try another keyword, or --since <ref-or-date>" >&2; exit 1
   fi
   REVIEW_BASE=$(git rev-parse "${FIRST_HASH}^" 2>/dev/null || echo "${FIRST_HASH}")
   ```

6. **`--final <topic>`**: same discovery as `--feature` (with `FINAL_TOPIC`), plus `ADVERSARIAL=1`, a
   confirmation gate before the reviewer runs (Step 4e), and the "Feature scope" plan header (Phase 4c).

7. **No flags (DEFAULT — scope to THIS session):**

   **STEP A — Find the session start HEAD (`CONV_START`).** Read the marker the SessionStart hook wrote:

   ```bash
   MARK="${TMPDIR:-/tmp}/claude-session-start-commit-${CLAUDE_SESSION_ID}"
   CONV_START="${CLAUDE_SESSION_START_COMMIT:-}"
   [ -z "$CONV_START" ] && [ -f "$MARK" ] && CONV_START=$(cat "$MARK")
   echo "${CONV_START:-}"
   ```

   If that is empty (hook not installed, or the session started outside a repo), fall back to the
   `gitStatus` system message at the very beginning of this conversation: the FIRST hash under
   "Recent commits:" is the HEAD when the conversation started. If neither exists, tell the user the
   session-start hook is not installed and use `--base`/`--since` semantics only if they gave one;
   otherwise stop.

   **STEP B — Last-review marker (second review in the same session):**

   ```bash
   MARKER=$(cat "${TMPDIR:-/tmp}/claude-session-last-review-commit-${CLAUDE_SESSION_ID}" 2>/dev/null)
   ```

   **STEP C — Stale-marker check.** A marker from THIS session is a descendant of `CONV_START`:

   ```bash
   git merge-base --is-ancestor "${CONV_START}" "${MARKER}" 2>/dev/null   # 0 = marker is newer than CONV_START
   ```

   - `MARKER` empty → `REVIEW_BASE = CONV_START`
   - `MARKER == CONV_START` → `REVIEW_BASE = CONV_START`
   - `CONV_START` is a strict ancestor of `MARKER` → a prior review already ran here → `REVIEW_BASE = MARKER`
   - otherwise (marker older, or unrelated) → `REVIEW_BASE = CONV_START`

   Without this check a stale marker would widen the scope to other sessions' commits.

**Step 3: Determine what changed.**

```bash
git log --oneline ${REVIEW_BASE}..HEAD 2>/dev/null
```

**Step 3b: Identify THIS session's commits (default mode only).**

Skip this narrowing when any of `--working-tree`, `--base`, `--session`, `--since`, `--feature`,
`--final` is active: those modes want the full range (`REVIEW_RANGE = REVIEW_BASE..HEAD`).

In default mode `REVIEW_BASE..HEAD` may contain commits from OTHER sessions that ran in parallel. Scan
this conversation for `git commit` outputs (`[main abc1234] …`), collect the hashes created HERE, and:

```bash
git log --oneline ${REVIEW_BASE}..HEAD | grep -E "^(hash1|hash2|hash3)"
```

- `OWN_COMMITS` = this session's hashes (oldest → newest); `CONV_END` = the newest of them.
- `OTHER_COMMITS` = everything else in the range. If non-empty: print
  `⚠ N commits from other sessions detected in REVIEW_BASE..HEAD — excluded from review scope`, list
  them one per line, and use `REVIEW_BASE..CONV_END`.
- `REVIEW_RANGE` = `REVIEW_BASE..CONV_END` if other commits exist, else `REVIEW_BASE..HEAD`.

```bash
git diff --name-only ${REVIEW_RANGE} 2>/dev/null                 # committed changes in scope
git diff --name-only HEAD 2>/dev/null                            # unstaged
git diff --name-only --cached HEAD 2>/dev/null                   # staged
git ls-files --others --exclude-standard 2>/dev/null             # untracked
cat "${TMPDIR:-/tmp}/claude-session-start-dirty-${CLAUDE_SESSION_ID}" 2>/dev/null   # dirty before this session
cat "${TMPDIR:-/tmp}/claude-session-start-blobs-${CLAUDE_SESSION_ID}" 2>/dev/null   # <sha>TAB<path> at session start
```

**Which lines are this session's: `scripts/scope-delta.sh`.** One call classifies every uncommitted
file and prints exactly one verdict per path — a lookup that fails says so instead of returning an
empty diff (which used to turn every finding in that file into "out of scope"). It sits next to the
backend script: `SD="$(dirname "$RB")/scope-delta.sh"`. Run it from the repo root with every
currently uncommitted path (unstaged, staged and untracked, from the lists above):

```bash
SD="<dir of RB>/scope-delta.sh"
bash "$SD" --dirty "<dirty list>" --blobs "<blobs file>" -- <path> [<path> ...]
```

**Baseline (`--dirty` / `--blobs`), default mode only:**

- A review already ran in this session (Step C chose `REVIEW_BASE = MARKER`) and
  `${TMPDIR:-/tmp}/claude-session-last-review-blobs-${CLAUDE_SESSION_ID}` exists → pass only
  `--blobs <that file>` (its paths are the dirty list). A second review then covers only what changed
  since the first, committed or not.
- Otherwise the session-start pair: `--dirty ${TMPDIR:-/tmp}/claude-session-start-dirty-${CLAUDE_SESSION_ID}
  --blobs ${TMPDIR:-/tmp}/claude-session-start-blobs-${CLAUDE_SESSION_ID}`.
- Exit 2 (a baseline file does not exist — no snapshot hook ran): write the paths from the "Status:"
  section of the conversation's opening `gitStatus` message, one per line, to
  `${TMPDIR:-/tmp}/claude-review-dirty-fallback-${CLAUDE_SESSION_ID}` and re-run with
  `--dirty <that file> --blobs /dev/null`.

**Explicit modes** (`--working-tree`, `--base`, `--session`, `--since`, `--feature`, `--final`): every
uncommitted change is in scope as it stands — the user asked for the range, not for this session's
share of it — so pass `--dirty /dev/null --blobs /dev/null` (every path comes back `FULL`).

**Verdicts → Phase 3:**

| Verdict | Meaning | Phase 3 |
|---|---|---|
| `FULL <path>` + `@@` lines | not dirty at the baseline (incl. untracked new files) | those hunks are in scope |
| `DELTA <path>` + `@@` lines | dirty at the baseline; only what changed since | ONLY those hunks are in scope |
| `UNCHANGED <path>` | nothing changed since the baseline | exclude the file |
| `LIKELY <path> (<reason>)` | this session's share is unprovable | add to `LIKELY_IN_SCOPE_FILES` |

`@@ -a,b +c,d @@` ranges are line-accurate against the file on disk. For every `LIKELY` path warn
`⚠ <path>: <reason> — findings flagged as scope-unverifiable`; reasons are `not-snapshotted` (dirty
at the baseline, no blob: hook older than the snapshot, a path git quotes, a file deleted at the
time), `broken: …` (snapshot sha unusable, file gone, diff failed) and `no-text-hunks` (binary).
Hard-dropping these would hide real findings on lines this session added; the tag keeps the user the
arbiter.

```bash
# Committed hunks — default mode: per OWN commit, so a commit another session interleaved inside
# REVIEW_RANGE contributes no hunks (a git range cannot exclude it, this can):
git show --unified=0 --format= <own-hash> 2>/dev/null | grep -E '^(diff --git|@@)'   # once per OWN_COMMITS entry
# Non-default modes (the full range is wanted):
git diff --unified=0 ${REVIEW_RANGE} 2>/dev/null | grep -E '^(diff --git|@@)'
```

Residual: a per-commit hunk carries the line numbers of the file *at that commit*; later commits that
shift lines above it drift the range. The Phase 4a source re-read is what catches a misattributed
finding — do not widen a hunk to compensate.

**Pre-dirty file committed in this session** (default mode). If an own commit touches a path that is
in the baseline dirty list, its per-commit hunks contain the pre-session edits too. Replace them with
`bash "$SD" <same baseline args> --now <CONV_END> -- <path>` — the delta from the baseline blob to the
file at the newest own commit, same verdicts. If the file is dirty again, its uncommitted verdict
from the first call comes on top.

**Store the combined hunks and the changed-file lists** for Phase 3: committed (per own commit, or
`REVIEW_RANGE`), `FULL` and `DELTA` hunks (committed or not), and `LIKELY_IN_SCOPE_FILES`.

If nothing changed — no own commits, and every uncommitted path came back `UNCHANGED` — say "No
changes found in this session. Nothing to review." and stop. A `LIKELY` path counts as a change.

**Step 4: Mode, file classes, scope summary, confirmation.**

**4a. `REVIEW_MODE` and `MODE_LABEL`:**

- `ADVERSARIAL` set → `REVIEW_MODE=prompt`, `MODE_LABEL="adversarial review"`
- else `FOCUS_TEXT` non-empty → `REVIEW_MODE=prompt`, `MODE_LABEL="adversarial review (focus text)"`
- else → `REVIEW_MODE=native`, `MODE_LABEL="native review"` — for a backend without a native reviewer
  the script switches to prompt mode and says so; the label then reads `"adversarial review (no native reviewer for <backend>)"`.

**4b. `SCOPE_HEADLINE`:** `--final` → `Feature topic: "<FINAL_TOPIC>"` and `MODE_LABEL="final feature review (adversarial)"`;
`--feature` → `Feature topic: "<FEATURE_TOPIC>"`, `MODE_LABEL="feature review"`; `--since` →
`Since: "<SINCE_REF>" (resolved to <first 8 of REVIEW_BASE>)`, `MODE_LABEL="since-window review"`;
otherwise the summary says `This session (since <short REVIEW_BASE>)`.

**4c. Classify files** (facets, not a partition — a test file counts as code and test):

```bash
FILES_IN_SCOPE=$( { git diff --name-only "${REVIEW_RANGE}"; git diff --name-only HEAD; git diff --name-only --cached HEAD; git ls-files --others --exclude-standard; } 2>/dev/null | sort -u)
FC_TOTAL=$(echo "$FILES_IN_SCOPE" | grep -c .)
FC_CODE=$(echo "$FILES_IN_SCOPE" | grep -cE '\.(php|js|ts|tsx|jsx|py|go|rs|rb|java|kt|swift|sh|css|scss|html)$')
FC_DOCS=$(echo "$FILES_IN_SCOPE" | grep -cE '(\.md$|^docs/|^\.claude/|^README)')
FC_TESTS=$(echo "$FILES_IN_SCOPE" | grep -cE '(test|spec|_test\.|\.test\.|\.bats$)')
FC_OTHER=$(echo "$FILES_IN_SCOPE" | grep -cvE '\.(php|js|ts|tsx|jsx|py|go|rs|rb|java|kt|swift|sh|css|scss|html|md)$')
```

**4d. Print the scope summary:**

```
Review scope: <"This session (since <short REVIEW_BASE>)" | SCOPE_HEADLINE>
Base: <REVIEW_BASE>
Review range: <REVIEW_RANGE> (<N> commits, <oldest date> → <newest date>)
Reviewer: <BACKEND> · <MODEL> · <MODE_LABEL>[, focus: "<FOCUS_TEXT>"]
Changed files: <FC_TOTAL> total — code <FC_CODE> · docs <FC_DOCS> · tests <FC_TESTS> · other <FC_OTHER>
<file list>
```

**4e. Confirmation gate (`--final` only).** A final review can span a large history and spends
reviewer tokens accordingly. Ask once with `AskUserQuestion` ("Proceed with the adversarial review of
this scope?" — Proceed (Recommended) / Abort) and stop on Abort. `--feature` and `--since` have no
gate: the user gave explicit input.

**Step 5: Record the session start if the hook did not:**

```bash
MARK="${TMPDIR:-/tmp}/claude-session-start-commit-${CLAUDE_SESSION_ID}"
[ -f "$MARK" ] || git rev-parse HEAD > "$MARK"
```

---

## Phase 1.5: Generate the Conversation Brief

**Purpose:** the reviewer sees the diff but never the conversation that produced it, so it will flag
intentional design. The brief is your terse account of *why* this session made these changes; Phase
4a uses it to filter "we built it that way on purpose" findings. It is **never sent to the backend**
— the script has no input for it, on purpose.

**Skip rule:** `NO_BRIEF` set → skip this phase, `BRIEF_FILE=""`, continue with Phase 2.

**Step 1: Resolve the path.**

```bash
BRIEF_FILE="${TMPDIR:-/tmp}/claude-review-brief-${CLAUDE_SESSION_ID}.md"
```

**Step 2a: User-provided brief** — if `USER_BRIEF_FILE` is set:

```bash
[ -f "$USER_BRIEF_FILE" ] || { echo "--brief-file: '$USER_BRIEF_FILE' not found" >&2; exit 1; }
cp "$USER_BRIEF_FILE" "$BRIEF_FILE"
```

Skip 2b.

**Step 2b: Auto-generate the brief from the conversation.** Exactly the five sections below, no
preamble, terse, quote the user where possible. **Honest emptiness beats fabrication**: a section with
no real content is `—`. Cap at 3200 characters (trim the longest section first; if still over,
append `(brief truncated to 3200 chars)` and stop).

```markdown
# Conversation Brief

## Intent
<1-3 sentences. What did the user actually ask for, in their words if possible.>

## Scope
Touches: <files/areas this session modified, high level — e.g. "report entry points, the HTTP client">
Intentionally does NOT touch: <areas the user said to leave alone, or "—">

## Do not flag
<One bullet per item that must NOT become a finding because it is intentional / out of scope / accepted / deferred. One-line reason each:>
- <pattern X is intentional because <reason from the conversation>>
- <Y is out of scope — user said "leave Z alone, separate task">
- <accepted trade-off: <thing> in exchange for <other thing>>

## Rejected alternatives
- <approach → why rejected>   (skip if none)

## Verification status
<tests run, manual checks, browser checks done in this session — or "untested" / "—">
```

Anchor every "Do not flag" item to a quote/paraphrase from the user or a stated design decision;
never invent constraints. For a cold-start conversation write a one-sentence factual `Intent` and
leave the rest `—`.

Archive a copy:

```bash
LOG_DIR="${CLAUDE_REVIEW_LOG_DIR:-$HOME/.claude/logs}"
mkdir -p "$LOG_DIR/critical-review-briefs" && cp "$BRIEF_FILE" "$LOG_DIR/critical-review-briefs/${CLAUDE_SESSION_ID}.md" 2>/dev/null || true
```

**Step 3: One-line preview.**

```bash
INTENT_LINE=$(awk '/^## Intent/{flag=1; next} flag && NF{print; exit}' "$BRIEF_FILE")
echo "Brief: ${INTENT_LINE} ($(wc -l < "$BRIEF_FILE" | tr -d ' ') lines — pass --show-brief to see it in full)"
```

**Step 4: `SHOW_BRIEF` set** → `cat "$BRIEF_FILE"` and stop.

---

## Phase 2: Run the Review

Everything the reviewer gets is assembled by `review-backend.sh` from git: the diff (plus untracked
file bodies for the working tree) and, in prompt mode, your focus text. **Never pass the brief, the
intent, or any "this is expected" framing** — not as focus text either. Focus text steers *toward*
scrutiny ("look hard at the locking"); intent steers away from it.

**Which runs to make** (the backend reviews either a commit range or the working tree, never both at once):

- **Case A — only uncommitted changes** (no own commits, or `REVIEW_BASE == HEAD`, or `--working-tree`):
  one run, `--scope working-tree`.
- **Case B — only committed changes**: one run, `--base <REVIEW_BASE>`.
- **Case C — both**: two runs, `--base <REVIEW_BASE>` and `--scope working-tree`; merge the findings
  and label each with its run. If every uncommitted path came back `UNCHANGED` from
  `scope-delta.sh`, this is Case B — skip the working-tree run (a `LIKELY` path keeps it).

**Invocation** (`RB` = the script path from Phase 0; `REVIEW_MODE` from Step 4a; add
`--focus "<FOCUS_TEXT>"` only when there is focus text):

```bash
RESULT="${TMPDIR:-/tmp}/claude-review-result-${CLAUDE_SESSION_ID}.txt"
bash "$RB" --mode <REVIEW_MODE> --base <REVIEW_BASE> > "$RESULT" 2> "${RESULT}.err"; STATUS=$?
# or, for the working tree:  bash "$RB" --mode <REVIEW_MODE> --scope working-tree > "$RESULT" 2> "${RESULT}.err"; STATUS=$?
cat "${RESULT}.err"; echo "exit=$STATUS"
```

The first stderr line is the status line `review-backend: <backend> · <model> · <mode> mode · <scope>`
— repeat it to the user so it is on record which reviewer actually ran.

**Exit handling:**

- `0` → `RESULT` holds the review. In prompt mode it is JSON per `scripts/review-findings.schema.json`
  (`verdict`, `summary`, `findings[]` with `severity`, `title`, `body`, `file`, `line_start`, `line_end`,
  `confidence`, `recommendation`). In native mode it is the reviewer's own text; extract each finding's
  file, line range, severity and claim from it as best it allows, and treat a finding without a file
  or lines as `likely-in-scope` at most.
- `3` → no reviewer after all (auth expired between Phase 0 and now, PATH changed). Print the stderr
  and **stop**.
- `4` → the reviewer ran and failed; the stderr carries its last 40 lines. Print them and **stop**.
  Do not retry blindly, do not review the diff yourself. The user decides (`codex login`, another
  `REVIEWER=`, or skip).
- `1` → usage/config error in how you called the script: fix the call, retry once, then stop.

A review that takes a while is normal (a native Codex pass on a small diff was measured at ~90-110 s;
a Claude pass with 30 tool turns can be several minutes). Wait for it.

---

## Phase 3: Filter Findings by Scope (HARD DROP)

**Before presenting ANY finding, verify it is in scope using the hunks stored in Phase 1 Step 3.**

The reviewer may have seen a wider diff than the session's own work (`REVIEW_BASE..HEAD` with other
sessions' commits, or every dirty file in the tree). Those extra findings are dropped here.

Classify each finding:

1. **strict-in-scope** — `finding.file` is in the changed-file list (committed in `REVIEW_RANGE`, OR
   new uncommitted) AND `line_start..line_end` overlaps a stored hunk for that file. Render normally.
2. **likely-in-scope** — `finding.file` is in `LIKELY_IN_SCOPE_FILES` (a `LIKELY` verdict), or the
   finding has no usable line range. Tag `scope=likely`; rendered under "Scope unverifiable"; the user
   is the arbiter.
3. **out-of-scope** — neither. **DROP**, but record `file:line_start-line_end` + a one-line reason;
   Phase 4c lists them.

Hunk check: `@@ -a,b +c,d @@` from `git diff --unified=0` gives the new-file ranges; a finding is in
scope if its range overlaps any `+c,d` range in the same file (`,d` defaults to 1). **Pure deletions
are `+c,0`** — nothing in the current file overlaps a zero-length range, yet removed validation or
cleanup is exactly what a reviewer flags on the lines now adjacent to the gap: treat a `+c,0` hunk as
covering current lines `c` and `c+1`, and a finding on a deleted file (in the changed list, absent on
disk) as strict-in-scope.

Sort: strict first (critical → low), then likely (critical → low).

---

## Phase 4: Critical Evaluation, Logging & Render Decision

**Step 4a — Evaluate silently (do not narrate this step).**

**4a.0 — Load the brief** (if Phase 1.5 produced one): read `BRIEF_FILE`; note `## Do not flag`,
`## Rejected alternatives` and the "Intentionally does NOT touch" line. If there is no brief, skip
item 5 below.

For each surviving finding, read the actual code and judge:

1. **Verify the claim** — is the reviewer's description of the code accurate? Read the lines.
2. **Relevance** — caused by THIS session's changes, or pre-existing code flagged because it sits next
   to the edit? Drop the latter.
3. **Real-world impact** — given this codebase (its CLAUDE.md, domain, patterns): material risk or a
   theoretical nit? Drop speculative and stylistic noise.
4. **Contradiction check** — does it contradict a deliberate design choice the user made here? Drop or
   note the disagreement.
5. **Brief cross-check** — does the finding match a `Do not flag` item, re-litigate a rejected
   alternative, or touch an "Intentionally does NOT touch" area? If yes, **re-read the source** to
   verify the brief's claim (the brief is your own account; you can be wrong about your own work).
   - Claim verified against the code → drop as `intentional-by-conversation`, recording the exact brief
     line (`dropped_by_brief: "Do not flag: …"`).
   - Claim NOT supported by the code → KEEP the finding and mark the brief item `suspect`; Phase 4c
     surfaces it so the user knows the brief was wrong.

   **Never drop a finding solely because it appears in `Do not flag`.** The list is a hypothesis, not
   a gag order; the source re-read is mandatory. That is the whole reason the brief never reaches the
   reviewer and is applied only here.

Keep only findings where your own evaluation agrees (fully or partially). Track drops per reason:
`out-of-scope / misdescribed / pre-existing / theoretical / contradicts-intent / intentional-by-conversation`,
and keep the dropped findings themselves (title, `file:lines`, reason, one-line rationale,
`dropped_by_brief` if any) for `show dropped`.

**Step 4b — Format the findings** (same format for both render paths):

```
### N/Total · [severity] · `path/to/file:line_start-line_end`

**What & why:** [2-3 plain-language sentences — what the problem is AND why it matters for this change. A smart non-expert can follow it.]
**Verified by:** [1 sentence — what you actually checked, naming files and lines. If you cannot write this without hand-waving, drop the finding in 4a instead.]
**Fix:** [1-3 sentences or short bullets — concrete direction, not a full patch.]
**Complexity:** trivial | moderate | complex
```

Complexity: **trivial** = single line/block, obvious, no design decision (guard clause, missing
await, typo, missing default). **moderate** = one module, some judgment, no cross-file coordination.
**complex** = multi-file, architectural, touches invariants or rollout/migration — belongs in `/plan`.

**Step 4b-log — Log this run as events.** Always, on both render paths, before rendering. Without
the log no future tuning of this command is evidence-based: how many reviewer findings survive the
filter, how many the user accepts, whether a brief drop ever hid a real bug.

The log (`${CLAUDE_REVIEW_LOG_DIR:-~/.claude/logs}/critical-review.jsonl`) is a stream of
**immutable events joined by ids**, written by `scripts/review-log.py` next to the backend script
(`RL="<dir of RB>/review-log.py"`). Three rules:

- **Nobody patches rows by hand.** What the user decides is logged as its own event at the moment
  this command sees the decision. (A `verdict` field for the user to fill in later was the v0.2
  design; in the maintainer's log it was filled for 5 of ~2,000 findings.)
- **No event = unresolved.** Never infer a decision. An approved plan is a decision; a fix that was
  *executed* is a resolution; neither says the finding was *correct* — keep the three apart.
- **Ids, not positions.** `N` restarts with every review, and one session can run several, so every
  event names the `run_id` of the review it belongs to.

**1. One `run` event** — prints the run id; keep it as `RUN_ID`, it goes into the rendered output
(Step 4c) so a later reply can name the review it answers. Log it **even with zero surviving
findings** — runs are the denominator.

```bash
RL="<dir of RB>/review-log.py"
python3 "$RL" run session="${CLAUDE_SESSION_ID}" \
  repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo unknown)")" \
  diff_sha="$(git rev-parse HEAD 2>/dev/null || echo uncommitted)" \
  model="<BACKEND> <MODEL>" mode="<REVIEW_MODE>" brief_active="<1 if a brief was used, else 0>" \
  reviewer_findings="<how many the reviewer returned>" dropped_scope="<Phase 3 drops>" \
  dropped_judgment="<Phase 4a drops, brief drops excluded>" dropped_brief="<brief drops>" \
  kept="<surviving findings, strict + likely>"
```

**2. One `finding` event per surviving finding** (strict and likely; not the dropped ones). `n` is the
number the finding carries in the rendered output (`3` for `3/Total`, `L2` for likely-in-scope).
Several calls can share one Bash invocation:

```bash
python3 "$RL" finding session="${CLAUDE_SESSION_ID}" run_id="<RUN_ID>" n="<N>" severity="<severity>" \
  file="<file>" line_start="<line_start>" line_end="<line_end>" issue="<one short sentence, <200 chars>"
```

**3. One `brief_drop` event per `intentional-by-conversation` drop** (`k` counts them: 1, 2, …) — the
brief-precision dataset; without it "did the brief ever hide a real bug?" has no answer:

```bash
python3 "$RL" brief_drop session="${CLAUDE_SESSION_ID}" run_id="<RUN_ID>" k="<K>" file="<file>" \
  line_start="<line_start>" line_end="<line_end>" issue="<one short sentence>" \
  brief_excerpt="<the brief line that triggered the drop, <200 chars>"
```

Values are plain shell arguments: keep `issue`, `reason` and `brief_excerpt` free of double quotes,
backticks and `$` (rephrase instead of escaping). The script rejects a malformed call with exit 1 and
writes nothing — fix the call and retry once.

**4. Decisions and outcomes are logged later, where they happen** — Step 4c (what the user answers)
and Phase 5 (what happened to each fix):

| Event | Fields | When |
|---|---|---|
| `decision` | `run_id`, `n`, `decision=accepted\|declined`, `via=plan_approval\|go_ahead\|plan_request\|pushback`, `reason` | the user accepts a finding (approves the plan, says `go ahead on N` or `/plan N`) or rejects it as wrong |
| `resolution` | `run_id`, `n`, `status=auto_applied\|skipped\|failed\|abandoned`, `reason`, `complexity` | Phase 5 / a `go ahead` edit: what happened to the fix |
| `brief_drop_overruled` | `run_id`, `k`, `reason` | after `show dropped`, the user says a brief drop was a real finding |

A later decision on the same finding supersedes the earlier one (the stats take the last). `skip`,
silence, or a denied plan with no stated objection logs **nothing** — that finding stays unresolved.

**If an append fails** (disk, permissions, python error): do not abort or re-prompt. The review
output is the deliverable; move on.

**Reading the log:** `python3 "<dir of RB>/critical-review-stats.py"` — distinct ids, undecided
findings reported as unresolved instead of guessed, rows from before the event schema in a separate
legacy bucket. The log and therefore the numbers are host-local.

---

**Step 4c — Render decision: branch on `REVIEW_ONLY` and finding count.**

### Case 1 — `REVIEW_ONLY` set, OR zero strict-in-scope findings survived

Render in chat (one flowing message, Step 4b format), then the options block, then STOP — no plan
mode, no Phase 5.

Order: strict findings (critical → low); then, if any, the likely findings under

```
---
## ⚠ Scope unverifiable (this session's share of the file cannot be proven)

These findings sit in files that were already modified when this session began and have no usable
snapshot, or that have no text hunks (binary). The flagged lines cannot be proven to come from THIS
session. Most are still real bugs the session either introduced or now owns.
```

each prefixed `[scope: likely]`.

```
---

## Options

- **Trivial fixes** → say `go ahead on N` (or `go ahead on all trivial`) and I apply them directly.
- **Moderate/complex fixes** → say `/plan N` and I draft a plan before touching code.
- **Disagree with a finding** → push back and we discuss.
- **Audit the filter** → reply `show dropped` for the findings dropped in 4a with their reasons.
- **Audit the brief** → reply `show brief` for the full conversation brief used for filtering.
- **Done** → say `skip` or ignore this message.

Reviewer: <BACKEND> · <MODEL> · <MODE_LABEL> · run <RUN_ID>

Dropped (visible audit, not silent):
[one line per dropped finding: `- <severity> · <file>:<lines> — <reason>`; for intentional-by-conversation drops append the triggering brief line in parentheses. Every drop, not just a count. "(none)" if zero.]

Brief used for filtering:
[if active: `Intent: <first sentence>. Do-not-flag items: N. Reply 'show brief' to see it in full.` — else `(none — --no-brief was passed or Phase 1.5 was skipped)`]

Changes are NOT committed. Commit when you are satisfied.
```

**Log what the user then answers** (later turns; vocabulary in Step 4b-log §4). Take the `run_id`
from the review the user is answering — the `run <RUN_ID>` line under it — never from a newer review:

- `go ahead on N` → `decision` accepted `via=go_ahead`, then after the edit a `resolution`
  (`auto_applied`, or `failed` / `skipped` with the reason).
- The user pushes back and the finding is withdrawn as wrong → `decision` declined `via=pushback`
  with the reason in a few words. If the discussion ends with the finding standing, log nothing new.
- After `show dropped`, the user says a brief drop was real → `brief_drop_overruled` for its `k`, and
  treat the finding as reinstated.
- `/plan N` → `decision` accepted `via=plan_request` — asking for a plan accepts the finding as
  real. No `resolution`: the fix happens in `/plan` → `/implement`, outside this log.
- `skip`, silence → nothing. Unresolved is a legitimate final state.

If zero strict AND zero likely findings survived, skip the options block:

```
No actionable findings for this session's changes.
Reviewer: <BACKEND> · <MODEL> · <MODE_LABEL> · run <RUN_ID>

Dropped (visible audit, not silent):
[same per-line listing, or "(none)"]
```

Then stop.

### Case 2 — Default path (no `REVIEW_ONLY`, ≥ 1 strict-in-scope finding)

If only likely findings survived, do NOT enter plan mode — fall through to Case 1: auto-fix is
reserved for findings whose scope is proven.

Call `EnterPlanMode`, write the plan file with the template below, then `ExitPlanMode`.

```markdown
# Critical Review — [N] finding(s) to review and fix

**Scope:** [one of]
- `--final`: **Mode:** Final feature review (adversarial) · **Feature topic:** `<FINAL_TOPIC>` · **Range:** `<REVIEW_RANGE>` (<N> commits, <oldest> → <newest>) · **Files reviewed:** <FC_TOTAL> (<FC_CODE> code, <FC_DOCS> docs, <FC_TESTS> tests, <FC_OTHER> other)
- `--feature`: **Mode:** Feature review · **Feature topic:** `<FEATURE_TOPIC>` · **Range:** `<REVIEW_RANGE>` (<N> commits)
- `--since`: **Mode:** Since-window review · **Since:** `<SINCE_REF>` (resolved to `<short REVIEW_BASE>`) · **Range:** `<REVIEW_RANGE>`
- otherwise: **Scope:** This session's changes since `<short REVIEW_BASE>` (range `<REVIEW_RANGE>`).

**Reviewer:** <BACKEND> · <MODEL> · <MODE_LABEL>[, focus: "…"] · run `<RUN_ID>`
**Brief:** [active: one-line Intent + `(N do-not-flag items, M rejected alternatives)` · `--no-brief`: `(disabled)` · degenerate: `(no conversation intent detected)`]
**Likely-in-scope (after the strict findings):** [K] findings in files whose session share is unprovable (`LIKELY` verdict) — reviewed, NOT auto-fixed; the user adjudicates each after the plan runs.
**Dropped:** [`<file>:<lines> — <reason>` per line; intentional-by-conversation drops append `(brief: <line>)`; "none" if zero]

---

## Findings & proposed fixes

### 1/[Total] · [severity] · `path/to/file:line_start-line_end`

**What & why:** …
**Verified by:** …
**Fix:** …
**Complexity:** trivial | moderate | complex

[one section per strict finding]

[if any likely findings:]

---

## ⚠ Likely-in-scope (NOT in the auto-fix order)

Files whose session share is unprovable (`LIKELY` verdict): possibly this session's bugs, possibly pre-existing.
The executor skips them; after the plan completes, surface them in chat for a one-by-one decision.

### L1/[Total likely] · `[scope: likely]` · [severity] · `path/to/file:line_start-line_end`
(same four lines)

---

## Implementation order (Phase 5, on approval)

1. Trivial fix #N (file:lines) — one line
2. Moderate fix #K (file:lines) — one-line approach
3. Complex fix #J (files) — one-line approach

Trivial first (fast, low-risk, individually revertible), moderate next, complex last. If any fix
fails, the loop stops and later items are abandoned.

## Verification after implementation

This command runs no tests and commits nothing. After the fixes: run the project's own checks (see
its CLAUDE.md), then commit when satisfied.
```

- **Approved** → log one `decision` accepted `via=plan_approval` per strict finding in the plan
  (Step 4b-log §4), then Phase 5.
- **Denied / exited** → stop. Nothing was edited. Log a `decision` declined (`via=pushback`, reason)
  ONLY for findings the user explicitly called wrong; a bare denial says nothing about the findings —
  they stay unresolved.

---

## Phase 5: Post-Approval Implementation (default path only)

Runs only after approval in Phase 4c Case 2. Execute the plan's implementation order.

For each fix:

1. Re-read the target file. If the lines drifted since Phase 1 (compare `git hash-object <file>` with
   the blob you recorded), adjust the edit. If you cannot locate the target confidently, SKIP it as
   `target_drifted` and continue.
2. Apply with `Edit` (preferred) or `Write` (new files only).
3. Re-read the modified region and confirm the change is what you intended.
4. Log the outcome as a `resolution` event (Step 4b-log §4; `n` = the finding's number in the plan,
   `run_id` = the one in the plan's Reviewer line):

```bash
python3 "<dir of RB>/review-log.py" resolution session="${CLAUDE_SESSION_ID}" run_id="<RUN_ID>" n="<N>" \
  status=auto_applied complexity="<complexity>"
```

   A fix you SKIP gets `status=skipped reason=target_drifted`; an `Edit` that errors gets
   `status=failed reason=edit_failed`; every fix abandoned because the loop stopped gets
   `status=abandoned reason=loop_stopped`. Executed ≠ accepted ≠ correct — this event records only
   what happened to the edit.

Log failures stay non-fatal.

**Stop-on-failure:** if `Edit` errors (drift, non-unique match, permissions, clearly broken syntax
afterwards), stop the loop immediately — no later fixes, even independent ones. Report applied fixes,
the failed fix with its error, and the abandoned ones.

**Afterwards:** no commit, no tests, no push. One short message: `Applied [A] fix(es). [B] abandoned.`
plus one bullet per applied fix (`file:lines — what`) and per abandoned fix (`file:lines — reason:
target_drifted | edit_failed | <other>`). Remind the user to run the project's checks, then commit.

---

## Phase 6: Marker Update

After Case 1 OR Case 2 (approved or denied), record the review point — HEAD *and* the content of every
uncommitted file — so a follow-up `/critical-review` in this session covers only what changed since:

```bash
MARK_DIR="${TMPDIR:-/tmp}"
git rev-parse HEAD > "$MARK_DIR/claude-session-last-review-commit-${CLAUDE_SESSION_ID}"
BLOBS="$MARK_DIR/claude-session-last-review-blobs-${CLAUDE_SESSION_ID}"; : > "$BLOBS"
DIRTY=$(git status --porcelain --untracked-files=all | sed -e 's/^...//' -e 's/^.* -> //' | grep -v '^"' | grep .)
EXISTING=$(printf '%s\n' "$DIRTY" | while IFS= read -r p; do [ ! -L "$p" ] && [ -f "$p" ] && printf '%s\n' "$p"; done)   # never hash through a symlink
if [ -n "$EXISTING" ]; then
  SHAS=$(printf '%s\n' "$EXISTING" | git hash-object -w --stdin-paths)
  [ "$(printf '%s\n' "$SHAS" | grep -c .)" -eq "$(printf '%s\n' "$EXISTING" | grep -c .)" ] \
    && paste <(printf '%s\n' "$SHAS") <(printf '%s\n' "$EXISTING") > "$BLOBS"
fi
```

(Same format and rules as the session-start snapshot in `hooks/session-start.sh`; run from the repo root.)

No separate summary block — Phase 4c / Phase 5 already said everything.

---

## Modes & Examples

- `/critical-review` — native review (or prompt mode on a backend without one) → plan mode with fixes; approve once to apply.
- `/critical-review --review-only` — findings in chat, no plan mode, no auto-fix.
- `/critical-review --adversarial` — deeper prompt-mode pass that actively tries to break the change → plan mode.
- `/critical-review --adversarial --review-only` — deeper pass, findings only.
- `/critical-review performance` — focus text forces prompt mode, weighted toward performance.
- `/critical-review --adversarial --base main security` — since `main`, focused on security.
- `/critical-review --session` — everything since Claude Code started (all conversations in it).
- `/critical-review --working-tree` — uncommitted changes only.
- `/critical-review --final "rate limiter"` — final feature review: every commit/file matching the topic across the history, adversarial, asks before spending tokens. For a feature that is "done".
- `/critical-review --feature "export"` — like `--final` without auto-adversarial and without the gate.
- `/critical-review --since "2 weeks ago"` — a time window (date string → commit via `git rev-list --before`).
- `/critical-review --since main` — same as `--base main`, reads more naturally.
- `/critical-review --no-brief` — skip the brief; every reviewer finding is judged on code alone.
- `REVIEWER=claude /critical-review …` — force a backend for one run (see `scripts/review-backend.conf.example`).
