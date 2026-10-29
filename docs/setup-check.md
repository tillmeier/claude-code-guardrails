# setup-check

## Overview
`scripts/setup-check.sh` (run by `/guardrails:setup-check`) reports what of guardrails is set up on a
machine and prints the exact fix for each gap. It installs nothing. Design decisions and the CLI
facts the parser rests on, as of v0.5.0.

## Decisions
- Named `setup-check`, not `doctor`: Claude Code has a built-in `/doctor`, and a hand-installed bare
  `/doctor` would collide with it.
- Exit 1 only for a missing git/python3 or a hook that runs twice. Optional parts (reviewer, Codex
  plugin, Node, Chrome, browser servers, output style) print `✗` with a fix and still exit 0.
- Every `✓` names what it rests on: "codex login checked", "claude CLI on PATH (login not checked)",
  "MCP handshake ok, browser launch not tested". Nothing claims more than the probe proved.
- Commands and skills that exist both in the plugin and in `~/.claude` are info only: they coexist
  under different names (`/plan` and `/guardrails:plan`), and a private twin differs on purpose.
- Hooks are the only real conflict. A plugin hook is reported as running twice when user settings
  register the same script stem on the same event with an overlapping matcher.
  - Matchers made only of names and `|` are compared name by name (the hooks docs: plain names match
    exactly, `A|B` is a list). `*`, empty or anything regex-like counts as overlapping, so a real
    duplicate is never missed. Same script on a disjoint matcher → info line, not `!`.
- The Chrome 144 rule applies only to `--autoConnect` servers. `--browserUrl` / `--wsEndpoint` may
  point at a remote browser, so no version claim is made for them.
- Output style and hooks are read from user settings only and reported as such; project, local and
  managed settings can override them.

## Implementation notes
- On macOS without the command-line tools, `/usr/bin/git` and `/usr/bin/python3` are stubs that open
  an installer dialog when run. The script checks `xcode-select -p` first and never runs a tool that
  resolves into the stub dir (`SETUP_CHECK_STUB_DIR`, default `/usr/bin`) in that case.
- Every external call goes through `run_bounded`: output to a file (a surviving grandchild can't hold
  a pipe open), TERM then KILL by PID after 2 s, `SETUP_CHECK_TIMEOUT` (default 20 s). Never a
  pattern kill.
- `claude mcp list` is the only source covering user, project, local and plugin scope. It starts
  every configured server for a health check (~4 s here), as each session start does; an `npx`
  server may fetch its package then. Lines look like `name: command args - ✔ Connected`; with no
  servers it prints "No MCP servers configured". Output with no such lines is reported as
  unrecognized, never as "none configured".
- `claude plugin list --json` fields seen: `id`, `enabled`, `scope`, `installPath`. An unknown shape
  gives `–`, never `✓`.
- chrome-devtools-mcp 1.10.1 `engines`: `^20.19.0 || ^22.12.0 || >=23`; the Node check uses that
  range, not a minimum.

## Rejected
- Reading `~/.claude.json` for MCP servers: internal format, moves with `CLAUDE_CONFIG_DIR`, misses
  plugin and project scope.
- Treating command/skill overlap as a fault (see Decisions).
- Bundling the browser MCP server in this plugin: deferred to a separate plugin.

## Residuals
- A private hook stored under a different file name is not detected as a duplicate (match is by
  script stem).
- Stdio MCP servers spawned by a timed-out `claude mcp list` may outlive the kill.
- `claude mcp list` is CLI text; a format change lands in "unrecognized output" (covered by a test
  fixture), not in a false verdict.
