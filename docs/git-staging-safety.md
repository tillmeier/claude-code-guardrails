# Git staging safety in shared repos

Why Claude-issued commits stage by name, what guards exist, and which approaches were tried and
rejected. Written the day of the incident; the plan it was promoted from has retired.

## The incident (2026-08-19, commit 9cc724e)

A commit swept a parallel session's work: 225 lines of a `sync-commands.sh` rewrite, plus
`CLAUDE.md`, `settings.json` and a 413-line `.bak`, under a message describing none of it.

**Root cause was not missing attribution — it was a missing look.** Staging and committing ran in ONE
chained call (`git add -A && … && git commit -F -`), so the staged set was never rendered. A week
earlier in another repo, the same model with the list in front of it correctly excluded four foreign
files. The discriminator is whether the list was seen.

## What shipped

- **`hooks/git-staging-guard.sh`** (`PreToolUse`/Bash): denies bulk staging — `-A`, `--all`, `.`,
  `:/` without an explicit `--` pathspec — and `git commit -a/-am`, including `git -C` forms, chains,
  and the wrapper spellings `(git add -A)`, `$(git add -A)`, `{ git add -A; }`. A **habit guard, not
  a sandbox**: unusual spellings evade it. You cannot *accidentally* name someone else's file, which
  is the point.
- **The commit step stages BY NAME** (my `save-and-push` command — not in this repo, see the README),
  then reads the index back (`--name-only`, `--stat`) before the commit message is written.
- **Index gate before anything is staged**: the index is shown and every entry must be accounted
  for. Pathspec exclusion does NOT unstage, so pre-staged foreign work would ride along regardless.

## Rejected — do not rebuild

- **Auto-excluding a dirty baseline taken when the commit step starts.** Built, verified, reverted
  the same hour: in the real workflow you work first and invoke the command after, so your own
  edits are already dirty at that point, land in the baseline, and get excluded → **empty commit**.
  The baseline survives only as an *advisory* annotation beside live status.
- **A write-log from `PostToolUse Edit|Write`.** Blind to Bash edits (`sed`/heredocs), which dominate
  under bypass mode — coverage would vary invisibly with permission mode.
- **A `git status` snapshot after every Bash call** to catch those Bash edits: mechanically complete,
  but taxes every tool call in every repo to solve what staging by name solves for free.
- **A SessionStart baseline**: sessions run for days; the foreign edit landed mid-session, so it
  misses the actual incident.
- **Worktree isolation**: right answer for normal repos, structurally unavailable for `~/.claude` —
  commands must live at `~/.claude/commands/` to load at all.
- **A commit fingerprint checkpoint** (block commit unless the staged set matches a confirmed
  fingerprint): sound, but marginal once staging is explicit. Deferred, not refuted.

## Measured mechanics — verified, not assumed

- `git status --porcelain` is **not** a path list: renames print `R old -> new`, paths with spaces
  print **quoted**. `cut -c4-` yields non-paths. Use `-z` + NUL split; `R`/`C` records carry two
  fields (new, then old).
- Pathspec exclusion works with `:(exclude,literal)<path>` — `literal` is required so `*`, `[`, `:`
  or a leading `-` in a filename is not reinterpreted as glob/magic. It does **not** unstage.
- **`path` is a special variable in zsh, tied to `$PATH`.** Assigning it inside a loop destroyed the
  command search path mid-script. Use any other name.
- **Hook exit codes**: `2` blocks the tool call and shows stderr as the reason; `1` is a NON-blocking
  error and the call proceeds. The gitleaks hook returned 1 on secrets found and therefore never
  blocked anything from the day it was written.
- **Hooks fire on EVERY Bash call.** A hook that spawns `python3` unconditionally costs ~65 ms per
  call — the cost that got gitleaks removed (at ~100 Bash calls per session, ~6 s of hook tax).
  Gate on a pure-bash prefilter first: 8 ms for calls the hook does not care about.
  Re-measured 2026-08-30 on an arm64 Mac (system python 3.9, n=100 sequential, wall clock incl.
  spawn): `bash -c true` 6.9 ms · guard fast path 11.2 ms · guard full path 35.6 ms ·
  `python3 -c pass` alone 19.7 ms. The absolute numbers track the interpreter's start-up time;
  the fast/full gap is the point.

## Known-accepted residuals

- The guard false-positives when a command's *payload* contains a git command at line start (writing
  docs about it, or a commit message describing it). Workaround: use Edit/Write — the hook only
  inspects Bash.
- No blocking secret scanner since gitleaks was removed 2026-08-19 (privacy of repos + cost). A grep
  over the staged diff replaced it: a net, not a gate.
