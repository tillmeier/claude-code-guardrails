# Reviewer backend: design record and measurements

Why `/critical-review` is built the way it is, and what was measured while porting it (2026-09-08).
The README says what the pieces do; this is the why and the numbers.

## Decisions

- **The reviewer never sees the brief.** Telling a reviewer what a change is "supposed" to do
  collapses its true-positive rate (arXiv 2603.18740: framing a change as intended/bug-free took
  detection from 97.2 % to 3.6 % for one model; even strong models lose double digits, driven by
  false negatives). The paper's own fix is to redact intent before review. So `review-backend.sh`
  has no input for it at all — withholding is structural, not a prompt instruction — and the
  command applies the brief only after the review, behind a mandatory re-read of the source.
- **No self-review fallback.** The private command reviewed the diff itself when Codex was
  unavailable. In a transcript that is indistinguishable from an independent review, which defeats
  the point of the command. Exit 3 (no backend) and exit 4 (backend failed) stop the command.
- **One adapter script, not the Codex plugin.** Wrapping `codex-companion.mjs` would have kept the
  node + plugin dependency that v1 excluded. The plugin's two modes map to plain CLI calls:
  built-in review → `codex exec review --uncommitted | --base <ref>`; adversarial → `codex exec
  --sandbox read-only --output-schema <f> - < prompt`.
- **`claude -p --restricted`, not `--bare`.** `--bare` skips hooks and settings but also disables
  OAuth (API key only). `--restricted` removes the shell/code tools, ignores user/project/local
  settings (so none of the caller's hooks or plugins run inside the reviewer), and keeps OAuth.
  Verified: a haiku probe read a file through `Read`, could not create a file, and the caller's own
  SessionStart hook did not fire.
- **Models are pinned.** The Codex built-in reviewer once fell back to a deprecated model that the
  account was not entitled to, and failed. Pins live in a gitignored conf; defaults ship in the
  script and in `review-backend.conf.example`.
- **Session snapshot is write-once.** SessionStart fires again after a compaction and on resume
  with the same session id; overwriting the markers would move the baseline to "now" and hide the
  session's earlier edits from `/verify` and `/critical-review`.

## Gotchas found while building

- `${CLAUDE_SESSION_ID}` and `${CLAUDE_PLUGIN_ROOT}` are substituted into command text by the
  harness (verified with a probe plugin); they are not environment variables inside Bash calls.
  Anything that needs them takes them as arguments.
- `claude -p --json-schema` rejects a schema carrying a `$schema` draft key
  (`no schema with key or ref "https://json-schema.org/draft/2020-12/schema"`). The shipped schema
  has no `$schema`/`title` so the same file works for `codex --output-schema` and `claude --json-schema`.
- `claude -p --output-format json` returns the structured object in `structured_output`; an
  envelope with `is_error:false` and an empty result is possible and must not count as a review.
- `codex exec` without a prompt reads instructions from stdin and hangs on a tty; the script closes
  stdin for the built-in reviewer and feeds the prompt on stdin (`-`) in prompt mode. The same
  applies to `codex login status` when a stub reads stdin in tests.
- An untracked symlink passes `-f`; `cat` on it ships the target to the reviewer and
  `git hash-object -w` writes the target into the object database. Every reader checks `-L` first.
- A pure deletion is a `+c,0` hunk; no current line overlaps it. Findings on lines `c`/`c+1` count.
- In `claude -p` with no prompt host, Bash reads of the session files under `$TMPDIR` are denied
  even with `Bash(cat:*)` allowed (outside the working directory); the command still completes by
  other means, but costs turns. An interactive session prompts once instead.

## Measurements

| Run | Model | Wall time | Notes |
|---|---|---|---|
| `codex exec review --base HEAD~1` | gpt-5.5 | 90 s | 1-file diff |
| `codex exec review --base HEAD~1` | gpt-5.6-sol | 109 s | same diff |
| codex prompt mode with focus, 1 commit | gpt-5.6-sol | 122 s | schema-valid JSON |
| codex built-in, 13-file working tree (the port) | gpt-5.6-sol | 226 s / 292 s | two passes |
| claude backend, same tree, with focus | claude-sonnet-5 | 197 s | schema-valid JSON |
| nested `claude -p --plugin-dir . "/guardrails:critical-review --review-only"`, nothing to review | Fable 5.1 | 72 s, $0.81 | 19 turns |
| same, `--working-tree` on a planted symlink-guard removal | Fable 5.1 + codex gpt-5.6-sol | 321 s, $0.83 | 42 turns; found it as critical with the right line |
| bats suite (57 tests, fake backends) | — | ~25 s | bash 5.3 and 3.2 |

## What the reviewers found in the port itself

Twelve findings over three live passes, all confirmed against the code and fixed before the
commit: commits from another session interleaved inside the review range still contributed hunks;
`claude -p` loaded the caller's hooks and plugins; a second review in one session re-reviewed the
same uncommitted hunks (fixed with a review-point blob snapshot); a silent 200-entry cap in the
dirty snapshot; an empty Claude envelope passed as a review; the SessionStart re-fire reset the
baseline; symlink following in two places; deletion-only hunks dropped; `--feature` searched
`--all` and could pick an unmerged branch; working-tree reviews reported zero changed files;
`--print-prompt` printed nothing in native mode. A fourth pass on the committed result found the
one place the symlink guard was still missing. The tool caught its own bugs; that is the argument
for running it.
