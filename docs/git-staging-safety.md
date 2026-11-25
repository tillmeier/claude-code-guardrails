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
- A wrapper hides the command from both guards: `bash -c 'git add -A'`, `eval`, a script file. They
  inspect text at command position; following a wrapper means writing a shell parser.

## Closed after the 2026-11-17 audit (v0.6.1)

Probed against the shipped hooks; each new test failed on the old code first.
- `git add -u` / `--update` passed: the guard only knew `-A`, `--all`, `.`, `:/`. Without a pathspec
  `-u` stages every tracked change, the same sweep.
- `git add -A -- .` passed: any `--` counted as a narrowing pathspec, even when the pathspec after it
  is the whole tree. Now a sweep flag needs a named path, and a whole-tree pathspec needs an
  `:(exclude)`.
- The release review found the first per-token version counting shell tokens as pathspecs:
  `git add -A 2>&1`, `> log.txt` and `# comment` passed, though the old guard blocked them. Redirects
  (with their target) and comments are dropped before the check. A dry run (`-n`) stages nothing and
  passes.
- sql-guard: a WHERE-less `DELETE FROM t` passed as soon as anything followed on the line (`2>&1`,
  `| cat`, `; SELECT 1`), because the old pattern swallowed the closing quote into the table name and
  needed the line to end there. `TRUNCATE t` without `TABLE` passed too; MySQL and Postgres accept it.
  The bare form counts only at a statement start, so a commit message ending in "fix truncate
  behavior" passes; a shell-escaped identifier (`\"User\"`) counts as a table name.
- v0.6.3: a replay of real Bash calls through the v0.6.1 pattern showed one new class of false
  blocks, a search for the statement: `grep -E "x|DELETE FROM t|y"` (7 in 30 days). A `|` now ends
  the statement only after whitespace (`… FROM t | cat`); glued to the table name it is a regex
  alternation. Residual, accepted: a pattern whose last alternative is the statement
  (`"x|DELETE FROM t"`) ends at the closing quote and is still blocked.
- v0.6.4: the same replay, read the other way, showed a regression of v0.6.1: the old `\S+` took
  any token as the table name, the new name pattern did not know interpolation, so
  `f"DELETE FROM {t}"` and `"DELETE FROM ${TABLE}"` passed. `{`, `}` and `%` now belong to a name.
- v0.6.5: a model review of the v0.6.1 to v0.6.4 changes found two more spellings the old guards
  blocked and the new ones let through, neither of which occurs in the replayed calls:
  `git add -A 2> "build output.log"` (the redirect target was split at the space and its second
  half counted as a pathspec; redirects are now removed with a quoted target, and words are split
  quote-aware), and `mysql -e "DELETE FROM \`users\`"` (a backtick name escaped for the shell was
  not a table name). The replay and the review find different things: the replay only knows the
  spellings people used, the review only the ones it thinks of. Run both.
- v0.6.6: the next review round found a third one in the v0.6.5 tokenizer: in
  `(git add -A 2> "build.log")` the removed redirect left the closing `)` as a word of its own,
  which became empty after trimming and still counted as a pathspec. Empty words are dropped now.
  Three rounds, one spelling each, is the sign that single cases do not cover a tokenizer: the
  maintainer now checks the guard against a generated matrix of every combination of wrapper,
  sweep flag, pathspec, redirect and comment (5,418 cases; the v0.6.5 guard got 30 of them wrong).
- v0.6.7: a second model (Gemini) reviewing v0.6.4 to v0.6.6 found four more gaps in the same spot, all
  from treating a partly quoted word as two words: `git add -A > "$TMPDIR"/git.log` and
  `git add -A >"build.log"2>&1` passed (the unquoted rest of the target counted as a pathspec),
  `<>` and `<<<` passed, and `git add "."/src/a.sh` and `git add ":/"$file` were blocked as the whole
  tree. Four rounds, one spelling each: the hand-built splitter is replaced by Python's `shlex`
  (`punctuation_chars`), which builds the words the way the shell does. Redirect operators take their
  target with them, a file descriptor written before one is not a word, and a segment with unbalanced
  quotes is skipped: the segment split cut through a quoted string, so it is payload, not a command
  (`grep -E '… && git add -A )'`). The matrix with these six spellings added: 10,038 cases, the new guard
  0 wrong, the v0.6.6 guard 2,240 wrong. Replaying 30 days of real calls (8,510): identical verdicts.
- v0.7.0: the new Gemini backend's first real run reviewed v0.6.7 and found three more: `git add -A #
  don't` passed (the apostrophe in the comment made shlex fail, and the segment was skipped), `git add
  -A > $(mktemp)` passed (the split substitution left `mktemp` as a "path"), and a quoted `"#x"` was read
  as a comment. Comments are now cut quote-aware before shlex, and `$(…)`, `$((…))` and backticks become
  one placeholder word first. Matrix: 17,184 cases, 0 wrong (v0.6.7: 1,819); replay unchanged.
- v0.7.1: a Codex review of v0.7.0 found that the command was still cut into segments by a plain regex,
  also INSIDE quotes: `git add -A > "audit;log"` left a half with an open quote, which the new payload rule
  then skipped. Segments now split only at unquoted separators; a line break still always splits (an
  apostrophe in a heredoc body must not hide the commands after it). The quote-aware split exposed one more
  old bug: the `git commit` check split by whitespace and read `-abc` inside a quoted message as `-a`; it
  now reads shell words and skips the values of `-m`, `-F` and the like. Matrix 23,069 cases, 0 wrong;
  replay unchanged.
- How the replay works: every Bash command the sessions really ran (from the transcripts, filtered
  by each record's own timestamp) goes through the old and the candidate script, and the exit codes
  are compared in both directions. "Newly blocked" finds false positives, "released" finds
  regressions; hand-written tests found neither of the two above. Filter by record, not by file
  date: a transcript touched this week can hold months of calls.

## More traps in shared checkouts (2026-10)

Each one cost real work in a repo several sessions used at once.

- **`git worktree remove` deletes gitignored files without a word.** Without `--force` it refuses
  only modified or untracked files; scratch data, captures, `.venv` and build output kept in the
  worktree are gone, and processes started there keep running from the deleted directory (a dev
  server served stale code for hours). Before removing: `git -C <wt> status --ignored --short`,
  `lsof +D <wt>`, and ask the sessions that used it. "Clean and nothing unpushed" is not enough.
- **A poisoned index: `fatal: unable to read <sha>` on `status` and `commit`.** `git ls-files -s`
  listed files of a pre-commit hook's own repo; it happened after `~/.cache/pre-commit` was cleared
  and the hook environments reinstalled (cause not proven). The fix is `git read-tree HEAD`, then
  re-stage your files by name. `git reset` fails with the same error. Working tree and HEAD are
  untouched.
- **Don't reuse a branch after its PR was squash-merged.** The next PR from that branch got no
  check run at all (`check-runs` → `total_count: 0`), so required checks never reported and
  auto-merge waited forever. Branch fresh off `main` and `git cherry-pick` only the commits made
  after the squash-merge: git applies their diffs and stops on a conflict.
  `git checkout <old-branch> -- <paths>` would copy the stale branch's whole files and silently
  revert anything `main` changed in them since. Merging `main` into the stale branch conflicts
  with the squashed copy of your own commit.
- **`git reset --soft` onto a moved `origin/main` reverts other people's merges.** The index still
  held the older tree, so one "fixtures" commit carried old versions of 11 files and would have
  undone four merged commits. Before merging a bulk PR, list what it changes beside the bulk
  (`git diff --name-only $(git merge-base HEAD origin/main) HEAD | grep -v '^<bulk-dir>/'`) and
  compare each extra file's blob with the versions before its recent commits: an exact match means
  a revert.
- **"fix #N" anywhere in a commit title or body on the default branch closes PR #N**, not only
  issues, and no leading "Fixes" is needed. A docs commit closed another session's approved PR and
  disabled its auto-merge. Keep the verb away from the number ("PR #N (search fix)"); repair with
  `gh pr reopen N` and re-enable auto-merge.
- **"ahead 1" is not yours by default.** The one unpushed commit can be another session's, held
  back for review; a plain push ships it. Check `git log origin/<branch>..HEAD` first. To push only
  yours: a detached worktree at `origin/<branch>`, `cherry-pick` your commits, `cmp` the touched
  files, push from there.
- **Diverged (ahead N, behind M, other sessions' local commits): do not commit in the shared tree at
  all.** Move your change into a push worktree at `origin/<branch>` -
  `git diff HEAD -- <your files> | git -C <pushwt> apply --index`, copy new files - then test, commit
  and push from there. Afterwards, once `cmp` shows the shared tree's files byte-identical to the
  pushed commit, `git restore --staged -- <those paths>` first (a staged entry survives the next two
  steps: `checkout --` restores from the index), then `git checkout -- <your modified files>` and remove
  your new files in the shared tree:
  a leftover UNTRACKED copy of a file the next pull brings aborts the owners' `pull --rebase`
  ("untracked working tree files would be overwritten").
- **The checkout may be on another session's branch.** The session-start snapshot said `master`; a
  parallel session had switched the shared checkout since, and `git checkout -b` branched off their
  branch and moved the checkout out from under them. Run `git status -sb` before branching, and
  branch in your own `git worktree add`.
- **A code rewind silently reverts other sessions' commits.** Claude Code's checkpoint restore
  (Esc Esc → restore code, `--rewind-files`, the SDK `rewind_files` request) copies the session's
  backup over the current file without checking for changes made since, so a commit another session
  made to that file is undone in the working tree (code read of 2.1.312; seen once, sat dirty for
  three days). `"fileCheckpointingEnabled": false` in the main checkout's
  `.claude/settings.local.json` turns it off for that repo and its worktrees (measured); conversation
  rewind keeps working.
