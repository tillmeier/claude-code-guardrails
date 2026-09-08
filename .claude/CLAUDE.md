# claude-code-guardrails

Public plugin repo. Read this before changing anything; the README covers what the files do.
This file lives in `.claude/` on purpose: Claude Code loads it for checkouts of this repo, while a
root-level `CLAUDE.md` is not loaded for plugin users and trips `claude plugin validate --strict`.

## Where changes come from

- The maintainer's private `~/.claude` config is the canonical source. This repo is a curated,
  scrubbed downstream of it: `hooks/git-staging-guard.sh`, `precompact-handoff.sh`,
  `session-start.sh` (private name: `session-start-hook.sh`), `format-file.sh`,
  `scripts/sync-commands.sh`, all of `commands/`, `output-styles/terse.md` and `docs/` have a
  private twin. Public-only: `sql-guard.sh`, `hooks.json`, the manifests, `tests/`, CI, README,
  and the reviewer adapter (`scripts/review-backend.sh`, its `.conf.example`, the findings schema).
- `commands/critical-review.md` is a port, not a copy: the private twin stays pinned to the Codex
  plugin by design, the public one calls `scripts/review-backend.sh`. Port review-logic changes
  (scope, brief, filtering, findings format) in both directions; do not port the backend abstraction
  back unless the maintainer says so.
- Improvements to a file with a private twin are ported in both directions on purpose — a
  drift check on the private side flags when either side moved. Fix here freely, but say in the
  commit message what needs porting back.
- The two copies differ deliberately: no hostnames, client names, private tooling references or
  absolute paths here. Do not "restore" anything that looks stripped.

## Gates before a commit

- `bats tests/` green (bats-core; CI runs the same suite on ubuntu). A hook change without a test
  change is suspicious.
- The maintainer's scrub grep (term list is private, ask for it to be run) must return nothing.
  Never add hostnames, IPs, client or product names, SSH aliases, or home-directory absolute
  paths.
- `claude plugin validate --strict .claude-plugin/plugin.json` and `claude plugin tag .` must pass;
  `plugin.json` and `marketplace.json` versions must agree. Tags are `guardrails--vX.Y.Z`.

## Conventions the code cannot show

- Target is bash 3.2 (macOS default): no associative arrays, no `${var,,}`, no `mapfile`.
  Dependencies stay at bash, git, python3.
- Hook exit codes: only exit 2 blocks a tool call and shows stderr to the model; exit 1 is a
  non-blocking notice and the call proceeds. Tests assert the code, not the message.
- Any PreToolUse (Bash) hook fires on every Bash call. It must gate on a pure-bash `case`
  prefilter and spawn python3 only when the payload can match. Measured numbers in
  `docs/git-staging-safety.md`.
- Hooks are habit guards, not sandboxes: they inspect text. Accept documented residuals rather
  than growing regexes into a parser.
- `hooks.json` references scripts via `bash "${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh"`; never an
  absolute path.
- Never put `$` followed by a digit inside a shell block in a `commands/*.md` file: the harness
  substitutes positional arguments there before the model sees it. Use `length()`, `NF`, sed
  groups.
- Commands must degrade explicitly when an optional dependency is absent (`--codex` without the
  Codex plugin, `--ui` without a browser MCP): say so and continue, never pretend.
- `commands/verify.md` and `commands/critical-review.md` read the session files
  `${TMPDIR:-/tmp}/claude-session-start-{commit,dirty,blobs}-${CLAUDE_SESSION_ID}` written by
  `hooks/session-start.sh`; keep the three in sync. `${CLAUDE_SESSION_ID}` and
  `${CLAUDE_PLUGIN_ROOT}` are substituted into command text by the harness — they are NOT
  environment variables inside Bash calls, so pass them as arguments to anything that needs them.
- `scripts/review-backend.sh` is the only vendor-specific file: it must never take the brief or any
  intent as input, never run a backend other than the one named, and never exit 0 without a review.
  Backend tests use fake `codex`/`claude` executables on PATH — no model calls in `tests/`.

## Testing a change like a user

```bash
CLAUDE_CONFIG_DIR=$(mktemp -d) claude plugin marketplace add "$PWD"
CLAUDE_CONFIG_DIR=<same dir> claude plugin install guardrails@tillmeier
CLAUDE_CONFIG_DIR=<same dir> claude plugin details guardrails     # component inventory + token cost
```

Works pre-publication from the local path and without a login. A model-in-the-loop run in a fresh
profile needs a login there; the SessionStart hook fires before that gate and proves the wiring.

## Writing

Plain and to the point: what a thing does, how, how to use it. No self-promotion, no story
sections in README or manifests; incident write-ups and measurements live in `docs/`.
