#!/usr/bin/env bats
# scripts/setup-check.sh — run against a PATH that holds only basic utilities plus fakes, so a
# missing git / python3 / node / claude / codex is really missing. No real claude/codex is called.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SC="$ROOT/scripts/setup-check.sh"
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"; mkdir -p "$CLAUDE_CONFIG_DIR"
  export TMPDIR="$BATS_TEST_TMPDIR"
  unset REVIEWER CODEX_REVIEW_MODEL CODEX_REVIEW_EFFORT CLAUDE_REVIEW_MODEL CLAUDE_REVIEW_MAX_TURNS \
        REVIEW_CUSTOM_CMD REVIEW_BACKEND_CONF GUARDRAILS_CHROME_APP SETUP_CHECK_STUB_DIR CLAUDE_PLUGIN_ROOT
  export SETUP_CHECK_TIMEOUT=5
  TB="$BATS_TEST_TMPDIR/toolbin"; FB="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$TB" "$FB"
  local t p
  for t in bash sh cat sed grep head tail cut tr dirname basename mktemp rm sleep env wc sort mkdir \
           chmod ls awk date touch ln; do
    p=$(PATH=/usr/bin:/bin command -v "$t") && ln -s "$p" "$TB/$t"
  done
  export PATH="$FB:$TB"
  fake uname 'echo Linux'
  printf '[]\n' > "$BATS_TEST_TMPDIR/plugins.json"; export FAKE_PLUGINS="$BATS_TEST_TMPDIR/plugins.json"
  export FAKE_MCP="$BATS_TEST_TMPDIR/mcp.txt"; : > "$FAKE_MCP"
  export FAKE_PIDFILE="$BATS_TEST_TMPDIR/claude.pid"
}

fake() { printf '#!/bin/sh\n%s\n' "$2" > "$FB/$1"; chmod +x "$FB/$1"; }
real() { PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin command -v "$1"; }
with_git()    { printf '#!/bin/sh\nexec %s "$@"\n' "$(real git)" > "$TB/git"; chmod +x "$TB/git"; }
with_python() { printf '#!/bin/sh\nexec %s "$@"\n' "$(real python3)" > "$TB/python3"; chmod +x "$TB/python3"; }
with_codex()  { fake codex 'case "$1 $2" in "login status") exit 0 ;; esac; exit 1'; }
with_node()   { fake node "echo $1"; }
with_claude() {
  fake claude 'exec 3>&-
case "$1 $2" in
  "plugin list") cat "$FAKE_PLUGINS" ;;
  "mcp list")
    case "${FAKE_MCP_MODE:-}" in
      hang)        echo $$ > "$FAKE_PIDFILE"; sleep 8 ;;
      ignore-term) echo $$ > "$FAKE_PIDFILE"; trap "" TERM; sleep 8; sleep 8 ;;
      grandchild)  echo $$ > "$FAKE_PIDFILE"; ( sleep 8 ) & sleep 8 ;;
      fail)        echo boom >&2; exit 7 ;;
      *)           cat "$FAKE_MCP" ;;
    esac ;;
  *) exit 1 ;;
esac'
}
mcp() { printf '%s\n' "Checking MCP server health…" "" "$@" > "$FAKE_MCP"; }
CD_ISO='chrome-devtools: npx -y chrome-devtools-mcp@1.10.1 --isolated --screenshotMaxWidth 1280 - ✔ Connected'
CD_LIVE='chrome-live: npx -y chrome-devtools-mcp@1.10.1 --autoConnect --redactNetworkHeaders - ✔ Connected'
settings() { printf '%s\n' "$1" > "$CLAUDE_CONFIG_DIR/settings.json"; }
# Substring assertions as plain commands: a failing `[[ … ]]` mid-test does not fail it on bash 3.2.
has()   { case "$output" in *"$1"*) return 0 ;; esac; printf 'expected in output: %s\n---\n%s\n' "$1" "$output" >&2; return 1; }
hasnt() { case "$output" in *"$1"*) printf 'unexpected in output: %s\n---\n%s\n' "$1" "$output" >&2; return 1 ;; esac; }
all_present() {
  with_git; with_python; with_codex; with_claude; with_node v22.12.0
  fake google-chrome 'echo Google Chrome 156.0.1.2'
  printf '[{"id":"codex@openai-codex","enabled":true}]\n' > "$FAKE_PLUGINS"
  mcp "$CD_ISO" "$CD_LIVE"
  settings '{"outputStyle":"Terse"}'
}

@test "setup-check: everything present → exit 0, every ✓ names what it rests on, nothing ✗ or !" {
  all_present
  run bash "$SC"
  [ "$status" -eq 0 ]
  has "✓ git: git version"; has "✓ python3: Python 3"
  has "✓ /critical-review reviewer: codex gpt-6.1-sol (codex login checked)"
  has "✓ Codex plugin for /plan --codex: enabled"
  has "✓ node v22.12.0"; has "✓ Chrome 156.0.1.2 ("
  has "✓ browser server 'chrome-devtools' (isolated profile): MCP handshake ok, browser launch not tested"
  has "✓ browser server 'chrome-live' (attached to your running Chrome, --autoConnect): MCP handshake ok"
  has "✓ output style in user settings: Terse"
  has "plugin not active"
  hasnt "  ✗ "; hasnt "  ! "
}

@test "setup-check: optional tools absent → exit 0 with the exact fixes; '–' where the claude CLI is missing" {
  with_git; with_python
  run bash "$SC"
  [ "$status" -eq 0 ]
  has "✗ /critical-review reviewer: none usable"; has "→ npm i -g @openai/codex && codex login"
  has "– Codex plugin: can't check without the claude CLI on PATH"
  has "✗ node: not on PATH"; has "→ install Node 22.12 or newer from https://nodejs.org"
  has "✗ Chrome: not found"; has "→ install Google Chrome from https://www.google.com/chrome/"
  has "– browser MCP servers: can't list without the claude CLI on PATH"
  has "output style in user settings: (no readable settings.json)"
  # with Homebrew on PATH the node fix says so
  fake brew 'exit 0'
  run bash "$SC"
  has "→ brew install node"
}

@test "setup-check: claude CLI as the only reviewer → 'login not checked'; plugin not installed → install hint" {
  with_git; with_python; with_claude
  run bash "$SC"
  [ "$status" -eq 0 ]
  has "✓ /critical-review reviewer: claude CLI on PATH, claude-"; has "(login not checked)"
  has "✗ Codex plugin for /plan --codex: not installed"
  has "→ /plugin marketplace add openai/codex-plugin-cc"
}

@test "setup-check: git or python3 missing → exit 1; without python3 the settings checks say so" {
  with_python
  run bash "$SC"
  [ "$status" -eq 1 ]
  has "✗ git: not on PATH"; has "→ install git with your package manager"
  rm "$TB/python3"; with_git
  run bash "$SC"
  [ "$status" -eq 1 ]
  has "✗ python3: not on PATH"
  has "– output style and hooks: can't read settings without python3"
}

@test "setup-check: macOS without the command-line tools → exit 1, the git/python3 stubs are never run" {
  fake uname 'echo Darwin'
  fake xcode-select 'exit 2'
  STUBS="$BATS_TEST_TMPDIR/stubs"; mkdir -p "$STUBS"
  printf '#!/bin/sh\ntouch "%s/ran-git"\n' "$BATS_TEST_TMPDIR" > "$STUBS/git"
  printf '#!/bin/sh\ntouch "%s/ran-python3"\n' "$BATS_TEST_TMPDIR" > "$STUBS/python3"
  chmod +x "$STUBS/git" "$STUBS/python3"
  export SETUP_CHECK_STUB_DIR="$STUBS" PATH="$FB:$STUBS:$TB"
  run bash "$SC"
  [ "$status" -eq 1 ]
  has "✗ git: $STUBS/git is the macOS stub, Xcode Command Line Tools are not installed"
  has "✗ python3: $STUBS/python3 is the macOS stub"
  has "→ xcode-select --install"
  [ ! -e "$BATS_TEST_TMPDIR/ran-git" ]
  [ ! -e "$BATS_TEST_TMPDIR/ran-python3" ]
  # positive control: with the tools installed, the same binaries are run
  fake xcode-select 'echo /Library/Developer/CommandLineTools'
  run bash "$SC"
  [ -e "$BATS_TEST_TMPDIR/ran-git" ]
}

@test "setup-check: node version boundaries follow chrome-devtools-mcp's engines (^20.19 || ^22.12 || >=23)" {
  with_git; with_python
  for v in v20.18.0 v21.7.3 v22.11.0 v19.9.0; do
    with_node "$v"; run bash "$SC"
    has "✗ node $v is outside chrome-devtools-mcp's range"
  done
  for v in v20.19.0 v22.12.0 v23.0.0 v24.1.0; do
    with_node "$v"; run bash "$SC"
    has "✓ node $v"
  done
  with_node garbage; run bash "$SC"
  has "✗ node: unreadable version 'garbage'"
}

@test "setup-check: plugin active + the same hook in user settings → exit 1 with event, matcher and command" {
  with_git; with_python
  settings '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /x/git-staging-guard.sh"}]}],
             "PostToolUse":[{"matcher":"Edit|Write|MultiEdit","hooks":[{"type":"command","command":"bash /x/format-file.sh"}]}]}}'
  run bash "$SC" --plugin-root "$ROOT"
  [ "$status" -eq 1 ]
  has "! hook runs twice: git-staging-guard (PreToolUse) is in the plugin AND in user settings (matcher Bash: bash /x/git-staging-guard.sh)"
  has "! hook runs twice: format-file (PostToolUse) is in the plugin AND in user settings (matcher Edit|Write|MultiEdit: bash /x/format-file.sh)"
  has "2 item(s) to fix"
  # same script on another event is not a duplicate of the plugin's hook
  settings '{"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /x/git-staging-guard.sh"}]}]}}'
  run bash "$SC" --plugin-root "$ROOT"
  [ "$status" -eq 0 ]
  hasnt "  ! "
}

@test "setup-check: same hook on a disjoint matcher is info; a shared name, a regex or a later overlapping entry is a duplicate" {
  with_git; with_python
  fmt() { printf '{"matcher":"%s","hooks":[{"type":"command","command":"bash /%s/format-file.sh"}]}' "$1" "$2"; }
  settings "{\"hooks\":{\"PostToolUse\":[$(fmt Bash x)],
             \"SessionStart\":[{\"matcher\":\"startup\",\"hooks\":[{\"type\":\"command\",\"command\":\"bash /x/compact-handoff-inject.sh\"}]}]}}"
  run bash "$SC" --plugin-root "$ROOT"
  [ "$status" -eq 0 ]
  hasnt "  ! "
  has "– same script on another matcher: format-file (PostToolUse) is matcher Edit|Write|MultiEdit in the plugin, Bash in user settings; not a duplicate"
  has "– same script on another matcher: compact-handoff-inject (SessionStart) is matcher compact in the plugin, startup in user settings"
  for m in Edit 'Edit.*'; do
    settings "{\"hooks\":{\"PostToolUse\":[$(fmt "$m" x)]}}"
    run bash "$SC" --plugin-root "$ROOT"
    [ "$status" -eq 1 ]
    has "! hook runs twice: format-file (PostToolUse) is in the plugin AND in user settings (matcher $m: bash /x/format-file.sh)"
  done
  # a disjoint entry first must not hide an overlapping one after it
  settings "{\"hooks\":{\"PostToolUse\":[$(fmt Bash x),$(fmt Write y)]}}"
  run bash "$SC" --plugin-root "$ROOT"
  [ "$status" -eq 1 ]
  has "! hook runs twice: format-file (PostToolUse) is in the plugin AND in user settings (matcher Write: bash /y/format-file.sh)"
  hasnt "same script on another matcher: format-file"
}

@test "setup-check: plugin active via claude plugin list (no --plugin-root) is detected too" {
  with_git; with_python; with_claude
  printf '[{"id":"guardrails@tillmeier","enabled":true}]\n' > "$FAKE_PLUGINS"
  settings '{"hooks":{"PreCompact":[{"hooks":[{"type":"command","command":"bash /x/precompact-handoff.sh"}]}]}}'
  run bash "$SC"
  [ "$status" -eq 1 ]
  has "plugin active"
  has "! hook runs twice: precompact-handoff (PreCompact)"
  # disabled plugin → hand-install view instead
  printf '[{"id":"guardrails@tillmeier","enabled":false}]\n' > "$FAKE_PLUGINS"
  run bash "$SC"
  [ "$status" -eq 0 ]
  has "– hooks wired in user settings: precompact-handoff"
}

@test "setup-check: command/skill overlap is info only (exit 0); without the plugin, wired hooks are listed" {
  with_git; with_python
  mkdir -p "$CLAUDE_CONFIG_DIR/commands" "$CLAUDE_CONFIG_DIR/skills/browser-mcp"
  : > "$CLAUDE_CONFIG_DIR/commands/plan.md"; : > "$CLAUDE_CONFIG_DIR/commands/verify.md"
  run bash "$SC" --plugin-root "$ROOT"
  [ "$status" -eq 0 ]
  has "– commands in both $CLAUDE_CONFIG_DIR/commands and the plugin: plan verify (they coexist"
  has "– skill browser-mcp exists in $CLAUDE_CONFIG_DIR/skills and in the plugin"
  hasnt "  ! "
  # not active: no overlap lines, the hook registration view instead
  settings '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /x/sql-guard.sh"}]}]}}'
  run bash "$SC"
  [ "$status" -eq 0 ]
  hasnt "commands in both"
  has "– hooks wired in user settings: sql-guard"
  has "not wired: session-start compact-handoff-inject git-staging-guard format-file precompact-handoff"
}

@test "setup-check: a hanging claude mcp list is cut off by PID — plain, TERM-ignoring, and with a grandchild holding stdout" {
  with_git; with_python; with_claude
  export SETUP_CHECK_TIMEOUT=2
  for mode in hang ignore-term grandchild; do
    rm -f "$FAKE_PIDFILE"
    export FAKE_MCP_MODE="$mode"
    start=$SECONDS
    run bash "$SC"
    took=$((SECONDS - start))
    has "✗ browser MCP servers: claude mcp list timed out after 2s"
    [ "$took" -le 7 ] || { echo "$mode took ${took}s" >&2; false; }
    [ -s "$FAKE_PIDFILE" ]
    ! kill -0 "$(cat "$FAKE_PIDFILE")" 2>/dev/null
  done
  export FAKE_MCP_MODE=fail
  run bash "$SC"
  has "✗ browser MCP servers: claude mcp list exited 7: boom"
}

@test "setup-check: mcp list outcomes stay distinct — empty, unrecognized, no chrome server, failed, needs auth" {
  with_git; with_python; with_claude
  printf 'No MCP servers configured. Use `claude mcp add` to add a server.\n' > "$FAKE_MCP"
  run bash "$SC"
  has "✗ browser MCP servers: no chrome-devtools-mcp server configured"
  has "→ claude mcp add -s user chrome-devtools -- npx -y chrome-devtools-mcp@1.10.1 --isolated"
  printf 'something else entirely\n' > "$FAKE_MCP"
  run bash "$SC"
  has "– browser MCP servers: claude mcp list printed nothing this check recognizes"
  hasnt "no chrome-devtools-mcp server configured"
  mcp 'ahrefs: https://example.invalid/mcp (HTTP) - ✔ Connected'
  run bash "$SC"
  has "✗ browser MCP servers: no chrome-devtools-mcp server configured"
  mcp 'cd: /x/chrome-devtools-mcp --isolated - ✘ Failed to connect' 'auth: /x/chrome-devtools-mcp - ! Needs authentication'
  run bash "$SC"
  has "✗ browser server 'cd' (isolated profile): ✘ Failed to connect"
  has "✗ browser server 'auth' (own persistent profile): ! Needs authentication"
  hasnt "no chrome-devtools-mcp server configured"
}

@test "setup-check: the Chrome 144 rule applies to --autoConnect only; macOS reads the version from Info.plist" {
  with_git; with_python; with_claude
  fake google-chrome 'echo Google Chrome 143.0.7000.1'
  mcp "$CD_LIVE"
  run bash "$SC"
  has "✗ 'chrome-live' uses --autoConnect, which needs Chrome 144+ (found 143)"
  mcp 'remote: npx chrome-devtools-mcp --browserUrl http://127.0.0.1:9222 - ✔ Connected'
  run bash "$SC"
  has "(attached to a debuggable Chrome by URL)"
  hasnt "needs Chrome 144+"
  # macOS: version from the app bundle
  rm "$FB/google-chrome"; fake uname 'echo Darwin'; fake xcode-select 'echo /Library/Developer/CommandLineTools'
  APP="$BATS_TEST_TMPDIR/Chrome.app"; mkdir -p "$APP/Contents"
  "$(real python3)" -c 'import plistlib,sys; plistlib.dump({"CFBundleShortVersionString":"156.0.8078.73"}, open(sys.argv[1],"wb"))' "$APP/Contents/Info.plist"
  export GUARDRAILS_CHROME_APP="$APP"
  run bash "$SC"
  has "✓ Chrome 156.0.8078.73 ($APP)"
  hasnt "needs Chrome 144+"
}

@test "setup-check: an unknown claude plugin list shape is '–', never ✓" {
  with_git; with_python; with_claude
  printf '{"plugins":[]}\n' > "$FAKE_PLUGINS"
  run bash "$SC"
  has "– Codex plugin: claude plugin list printed an unknown format, can't check"
  printf '[{"name":"codex"}]\n' > "$FAKE_PLUGINS"
  run bash "$SC"
  has "– Codex plugin: claude plugin list printed an unknown format"
  hasnt "Codex plugin for /plan --codex: enabled"
}

@test "setup-check wiring: the command's shell block finds the script as a plugin (from another cwd) and by hand" {
  with_git; with_python
  block=$(sed -n '/^```bash$/,/^```$/p' "$ROOT/commands/setup-check.md" | sed '1d;$d')
  [ -n "$block" ]
  plugin_block=${block//'${CLAUDE_PLUGIN_ROOT}'/$ROOT}
  cd "$BATS_TEST_TMPDIR"
  run bash -c "$plugin_block"
  has "plugin active"
  run bash -c "$block"                       # by hand: the variable stays unexpanded and empty
  has "setup-check.sh not found"
  ln -s "$ROOT" "$HOME/claude-code-guardrails"
  run bash -c "$block"
  has "plugin not active, checkout $HOME/claude-code-guardrails"
}

@test "setup-check wiring: the README's claude mcp add lines are the ones the script prints" {
  for v in ADD_ISOLATED ADD_ATTACHED; do
    line=$(sed -n "s/^$v='\(.*\)'$/\1/p" "$SC")
    [ -n "$line" ]
    grep -qF -- "$line" "$ROOT/README.md"
  done
}

@test "setup-check: usage errors exit 2" {
  run bash "$SC" --bogus
  [ "$status" -eq 2 ]
  run bash "$SC" --plugin-root
  [ "$status" -eq 2 ]
}
