---
name: setup-check
description: Check what of guardrails is set up on this machine — git/python3, the /critical-review reviewer, the Codex plugin, Node, Chrome, browser MCP servers, output style, hooks registered twice — and print the exact fix for each gap.
argument-hint: ""
allowed-tools: Bash(bash:*)
---

# Setup check

Run this once. It takes a few seconds: inside, `claude mcp list` starts each configured MCP server
for a health check, which is what every session start does as well.

```bash
R="${CLAUDE_PLUGIN_ROOT}"
if [ -n "$R" ]; then
  bash "$R/scripts/setup-check.sh" --plugin-root "$R"
elif [ -f "$HOME/claude-code-guardrails/scripts/setup-check.sh" ]; then
  bash "$HOME/claude-code-guardrails/scripts/setup-check.sh"
else
  echo "setup-check.sh not found: run bash <your checkout>/scripts/setup-check.sh directly"
fi
```

`${CLAUDE_PLUGIN_ROOT}` is filled in for plugin installs. Installed by hand it stays empty, and the
script is expected in `~/claude-code-guardrails`.

Then:

1. Show the output to the user verbatim in a code block. Don't summarise it away.
2. Exit 1 means a required tool is missing or a hook runs twice (`!`). Exit 0 with `✗` lines means
   optional parts are not set up. Say which of the two it is.
3. Offer the fixes in the order printed. Run a shell fix (`xcode-select --install`, `brew install …`,
   `claude mcp add …`, removing a duplicate hook from settings.json) only after the user says yes.
   The user types slash-command fixes (`/plugin …`, `/output-style …`, `/mcp`) themselves.
   After a `claude mcp add` or a plugin install, Claude Code needs a restart.
4. Claim nothing the output doesn't say. A `✓` browser server proves the MCP handshake, not that a
   browser launches; "login not checked" means exactly that.
