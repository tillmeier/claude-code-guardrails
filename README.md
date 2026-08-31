# claude-code-guardrails

[![CI](https://github.com/tillmeier/claude-code-guardrails/actions/workflows/ci.yml/badge.svg)](https://github.com/tillmeier/claude-code-guardrails/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Hooks, commands and an output style I use with [Claude Code](https://code.claude.com), extracted
from my private config.

- **Hooks** — run outside the model's judgment: block bulk `git add` / `git commit -a` and
  WHERE-less SQL before the Bash call executes, record the session-start commit, snapshot work
  state before context compaction, run the project's own formatter after edits.
- **Commands** — a delivery loop (`/plan` → `/implement` → `/verify` → `/crosscheck`) and
  doc-maintenance commands (`/save-learnings-to-docs`, `/cleanup-docs`, `/refactor-claude-md`,
  `/init-local-md`).
- **Output style** — `terse.md`: result first, no padding.
- **Fleet sync** — push commands/skills/styles to your servers over SSH, audit drift with `--check`.

## Install

As a plugin (Claude Code ≥ 2.1):

```
/plugin marketplace add tillmeier/claude-code-guardrails
/plugin install guardrails@tillmeier
```

Restart Claude Code. Hooks are active immediately; commands are namespaced
(`/guardrails:plan`, `/guardrails:verify`, …); the output style is selectable with
`/output-style Terse`.

By hand (bare `/plan`, `/verify`, … and control over which hooks run):

```bash
git clone https://github.com/tillmeier/claude-code-guardrails ~/claude-code-guardrails
cp ~/claude-code-guardrails/commands/*.md      ~/.claude/commands/
cp ~/claude-code-guardrails/output-styles/*.md ~/.claude/output-styles/
```

then wire the hooks you want into `~/.claude/settings.json`:

```json
"hooks": {
  "SessionStart": [{"hooks": [{"type": "command", "command": "bash \"$HOME/claude-code-guardrails/hooks/session-start.sh\""}]}],
  "PreToolUse": [{"matcher": "Bash", "hooks": [
    {"type": "command", "command": "bash \"$HOME/claude-code-guardrails/hooks/sql-guard.sh\"", "timeout": 10},
    {"type": "command", "command": "bash \"$HOME/claude-code-guardrails/hooks/git-staging-guard.sh\"", "timeout": 10}
  ]}],
  "PostToolUse": [{"matcher": "Edit|Write|MultiEdit", "hooks": [{"type": "command", "command": "bash \"$HOME/claude-code-guardrails/hooks/format-file.sh\""}]}],
  "PreCompact": [{"hooks": [{"type": "command", "command": "bash \"$HOME/claude-code-guardrails/hooks/precompact-handoff.sh\""}]}]
}
```

Requirements: bash ≥ 3.2, git, python3. Tests need
[bats-core](https://github.com/bats-core/bats-core); the fleet sync needs ssh + rsync.

## Hooks

| File | Fires on | Does |
|---|---|---|
| `git-staging-guard.sh` | PreToolUse (Bash) | Denies `git add -A/--all/./:/` without a `--` pathspec and `git commit -a/-am/--all` — incl. `git -C` forms, command chains, `(…)`, `$(…)`, `{ …; }` |
| `sql-guard.sh` | PreToolUse (Bash) | Denies `DROP TABLE/DATABASE`, `TRUNCATE TABLE`, `DELETE FROM t` with no WHERE, on any line of the command |
| `session-start.sh` | SessionStart | Writes HEAD to a per-session marker file so `/verify` can diff against the session start |
| `precompact-handoff.sh` | PreCompact | Appends branch, last commits, dirty files and the newest plan file to `~/.claude/handoffs/<session>.md` (override dir with `CLAUDE_HANDOFF_DIR`); GC after 14 days |
| `format-file.sh` | PostToolUse (Edit\|Write\|MultiEdit) | Runs the nearest Biome/Prettier config (walking up to the git root), else black/ruff/isort/php-cs-fixer if installed, else nothing. Disable with `CLAUDE_NO_FORMAT=1` |

A blocked call exits 2; the tool call never runs and the model gets the stderr as the reason:

```text
$ git add -A && git commit -F -
BLOCKED by git-staging-guard: bare `git add` sweep (-A / --all / . / :/) with no explicit `--` pathspec

  offending segment: git add -A

Stage explicitly instead — name the files:
  git add <path> [<path>...]
  git diff --cached --name-only     # then read the index back before committing
[...]

$ git add hooks/git-staging-guard.sh tests/guard.bats
$ git commit -m "guard: judge commit flags per token"
```

Notes:

- Only exit 2 blocks a tool call; exit 1 is a non-blocking notice and the call proceeds. The
  tests assert exit codes, not just messages.
- The two Bash guards gate on a pure-bash prefilter and only parse JSON when the payload could
  match, so they cost ~milliseconds on unrelated calls. Numbers in
  [docs/git-staging-safety.md](docs/git-staging-safety.md).
- They are habit guards, not sandboxes: they inspect text, and an unusual spelling can evade
  them. A payload that merely *mentions* a guarded command (docs, commit messages) passes — and
  if it trips the guard anyway, write it with Edit/Write instead of Bash.

## Commands

| Command | Does |
|---|---|
| `/plan` | Short cited spec + verification plan before code; approval gate. `--codex` adds an external plan review (needs the optional [Codex plugin](https://github.com/openai/codex-plugin-cc), says so and continues without it) |
| `/implement` | Executes an agreed plan in small steps, verifies each, asks instead of guessing, halts on surprises |
| `/verify` | Ship gate: drives the changed flow for real and emits PASS/FAIL/SKIP with evidence. `--ui` iterates over screenshots per breakpoint (needs a browser MCP, degrades without) |
| `/crosscheck` | Read-only audit of recent unverified work: locate the evidence, verify before asserting, "ran" ≠ "worked" |
| `/save-learnings-to-docs` | Routes session learnings to the cheapest doc tier (hook → path-scoped rule → doc → skill → local → memory → CLAUDE.md last) and reconciles related docs |
| `/cleanup-docs` | Doc audit: measure → verify → cut; token-greps every fact before removing text; reports in bytes |
| `/refactor-claude-md` | Restructures CLAUDE.md into a lean core + on-demand tiers, no `@`-imports |
| `/init-local-md` | Generates a gitignored `.claude/local.md` from detected environment |

The loop in practice: `docs/workflow-recipes.md`. Plan files land in `.claude/plans/`,
gitignore them if you don't want them tracked.

## Fleet sync

`scripts/sync-commands.sh` pushes selected commands, skills, scripts and output styles to a list
of servers over SSH/rsync and can activate an output style remotely. Hosts and file lists live in
`sync-commands.conf` (gitignored — copy `sync-commands.conf.example`). `--check` compares every
configured file against each server (POSIX cksum) and reports MISSING / DRIFT / unmanaged files,
exit 2 on findings; `--dry-run` shows what would transfer.

## Tests

```bash
bats tests/        # 35 tests: guard patterns, SQL guard, formatter, session marker, handoff, wiring
```

CI runs the same suite on ubuntu; macOS bash 3.2 is the primary target.

## Background

The git guard exists because a chained `git add -A && … && git commit` once swept a parallel
session's work into a commit. The incident, the approaches that were tried and rejected, and the
measured hook costs are in [docs/git-staging-safety.md](docs/git-staging-safety.md).

## Not included

- My commit/push command (couples to private tooling; the staging discipline it implements is in
  the doc above) and my Codex-based review command (a vendor-neutral port is planned).
- 20 SEO skills and 12 agents that sit next to these files in my config — they are
  [AgriciDaniel's claude-seo](https://github.com/AgriciDaniel/claude-seo) (MIT), not mine.
- Anything client-specific. Scrubbed by grep before every commit.

## Differences from my private copy

- Absolute paths → `${CLAUDE_PLUGIN_ROOT}` / `$HOME`.
- `git-staging-guard.sh` judges `git commit` flags per token, so `--all` and `-a --amend` are
  caught too (the private copy missed both).
- `sql-guard.sh` was a `jq | read` one-liner in settings.json that only saw the first line of a
  command; it now checks every line and has the same prefilter as the git guard.
- `session-start.sh` keys the marker file by session id (`${CLAUDE_SESSION_ID}`) instead of an
  undocumented env-file export.
- `format-file.sh` reads the file path from the hook JSON itself, no `jq` wrapper needed.
- `sync-commands.sh` config moved to `sync-commands.conf`; `--help` works without one; empty
  `SERVERS` is an error, not a silent no-op.

## License

MIT — see `LICENSE`.
