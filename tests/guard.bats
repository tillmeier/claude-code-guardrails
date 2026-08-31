#!/usr/bin/env bats
# Shell tests for the guardrail hooks. Run from the repo root:
#   bats tests/
# Needs bats-core >= 1.5 (brew install bats-core · npm i -g bats · or git clone bats-core and use bin/bats).
# PreToolUse tests feed each hook the same JSON Claude Code sends on stdin.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GUARD="$ROOT/hooks/git-staging-guard.sh"
  SQL="$ROOT/hooks/sql-guard.sh"
  FMT="$ROOT/hooks/format-file.sh"
  START="$ROOT/hooks/session-start.sh"
  COMPACT="$ROOT/hooks/precompact-handoff.sh"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null   # no user hooks/aliases in temp repos
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
}

# Run a PreToolUse hook against one Bash command, exactly as Claude Code would.
#   run hook_bash "$GUARD" 'git add -A'
hook_bash() {
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$2" \
    | bash "$1"
}
# Same, with raw JSON (or garbage) on stdin.
hook_raw() { printf '%s' "$2" | bash "$1"; }

# After `run`: exit 2 with a BLOCKED reason (bats merges stderr into $output).
blocked() { [ "$status" -eq 2 ]; [[ "$output" == *"BLOCKED"* ]]; }
# After `run`: exit 0 and silent.
allowed() { [ "$status" -eq 0 ]; [ -z "$output" ]; }

new_repo() {  # $1 = name; leaves you inside a fresh repo with one commit
  cd "$BATS_TEST_TMPDIR" && git init -q "$1" && cd "$1" && git commit -q --allow-empty -m init
}

# ───────────────────────────── git-staging-guard ─────────────────────────────

@test "git guard: blocks the incident shape — add -A chained straight into commit" {
  run hook_bash "$GUARD" 'git add -A && git commit -F -'
  blocked
  [[ "$output" == *"offending segment: git add -A"* ]]
  [[ "$output" == *"git add <path>"* ]]          # the reason tells the model what to do instead
}

@test "git guard: blocks add -A even with a stash between add and commit" {
  run hook_bash "$GUARD" 'git add -A && git stash && git commit -m "x"'
  blocked
}

@test "git guard: blocks every bare sweep spelling" {
  for cmd in 'git add -A' 'git add --all' 'git add .' 'git add :/'; do
    run hook_bash "$GUARD" "$cmd"
    blocked
  done
}

@test "git guard: blocks sweeps behind git -C / -c / --no-pager" {
  run hook_bash "$GUARD" 'git -C /some/repo add -A'; blocked
  run hook_bash "$GUARD" 'git -c core.autocrlf=false add .'; blocked
  run hook_bash "$GUARD" 'git --no-pager add --all'; blocked
}

@test "git guard: blocks wrapper spellings — (…), \$(…), { …; }, cd x && …" {
  run hook_bash "$GUARD" '(git add -A)'; blocked
  run hook_bash "$GUARD" '$(git add -A)'; blocked
  run hook_bash "$GUARD" '{ git add -A; }'; blocked
  run hook_bash "$GUARD" 'cd /tmp/x && git add -A'; blocked
}

@test "git guard: blocks a sweep in the middle of a ; / | / newline chain" {
  run hook_bash "$GUARD" 'ls; git add .; ls'; blocked
  run hook_bash "$GUARD" 'true | git add -A'; blocked
  run hook_bash "$GUARD" $'echo one\ngit add -A\necho two'; blocked
}

@test "git guard: blocks commit -a in every spelling, including -a --amend and --all" {
  for cmd in 'git commit -a -m x' 'git commit -am x' 'git commit -sam x' 'git commit -a --amend' 'git commit --all -m x' '(git commit -a)'; do
    run hook_bash "$GUARD" "$cmd"
    blocked
  done
}

@test "git guard: allows staging by name" {
  run hook_bash "$GUARD" 'git add README.md hooks/git-staging-guard.sh'; allowed
  run hook_bash "$GUARD" 'git add -p src/'; allowed
}

@test "git guard: allows a sweep that carries an explicit -- pathspec section" {
  run hook_bash "$GUARD" "git add -A -- . ':(exclude,literal)secret.env'"; allowed
}

@test "git guard: allows commit without implicit staging" {
  for cmd in 'git commit -m "msg"' 'git commit -F -' 'git commit --amend --no-edit' 'git commit --author="a <a@b>" -m x' 'git commit --allow-empty -m x' 'git commit -S -m x'; do
    run hook_bash "$GUARD" "$cmd"
    allowed
  done
}

@test "git guard: allows other git and non-git commands (fast path)" {
  for cmd in 'git status' 'git diff --cached --name-only' 'git log --oneline' 'ls -la' 'npm test'; do
    run hook_bash "$GUARD" "$cmd"
    allowed
  done
}

@test "git guard: ignores a sweep that only appears inside a payload, not at command position" {
  run hook_bash "$GUARD" 'echo "never run git add -A on a shared repo"'; allowed
  run hook_bash "$GUARD" 'grep -rn "git commit -am" docs/'; allowed
  # Known, accepted residual (habit guard, not a sandbox): a sweep nested inside another command's
  # arguments is not at command position and passes. Documented in the script header.
  run hook_bash "$GUARD" 'echo $(git add -A)'; allowed
}

@test "git guard: only judges the Bash tool" {
  run hook_raw "$GUARD" '{"tool_name":"Edit","tool_input":{"file_path":"x.md","new_string":"git add -A"}}'
  allowed
}

@test "git guard: never blocks on its own bug — garbage and empty input pass" {
  run hook_raw "$GUARD" 'this is not json but mentions git add -A'; allowed
  run hook_raw "$GUARD" ''; allowed
}

# ───────────────────────────── sql-guard ─────────────────────────────

@test "sql guard: blocks DROP TABLE / DROP DATABASE / TRUNCATE TABLE, any case" {
  run hook_bash "$SQL" 'mysql -e "DROP TABLE users"'; blocked
  run hook_bash "$SQL" 'psql -c "drop database app"'; blocked
  run hook_bash "$SQL" 'mysql app -e "TRUNCATE TABLE sessions"'; blocked
}

@test "sql guard: blocks DELETE FROM with no WHERE clause" {
  run hook_bash "$SQL" 'mysql -e "DELETE FROM users"'; blocked
  run hook_bash "$SQL" 'mysql -e "DELETE FROM users;"'; blocked
}

@test "sql guard: allows DELETE with a WHERE clause and plain reads" {
  run hook_bash "$SQL" 'mysql -e "DELETE FROM users WHERE id = 1"'; allowed
  run hook_bash "$SQL" 'mysql -e "SELECT * FROM users"'; allowed
}

@test "sql guard: inspects every line, not just the first (the settings.json one-liner did not)" {
  run hook_bash "$SQL" $'echo preparing\nmysql -e "DROP TABLE users"'; blocked
}

@test "sql guard: fast path — commands without the keywords exit 0 silently" {
  run hook_bash "$SQL" 'ls -la'; allowed
  run hook_bash "$SQL" 'git status'; allowed
}

@test "sql guard: only judges the Bash tool and never blocks on garbage" {
  run hook_raw "$SQL" '{"tool_name":"Write","tool_input":{"content":"DROP TABLE x"}}'; allowed
  run hook_raw "$SQL" 'DROP TABLE not json'; allowed
}

# ───────────────────────────── format-file ─────────────────────────────

@test "format-file: no formatter configured in the repo → file untouched, exit 0" {
  new_repo fmt1
  printf 'const  a = 1\n' > a.js
  run bash "$FMT" "$PWD/a.js"
  [ "$status" -eq 0 ]
  [ "$(cat a.js)" = "const  a = 1" ]
}

@test "format-file: takes the path from the hook JSON on stdin when no arg is given" {
  new_repo fmt2
  printf 'const  a = 1\n' > a.js
  run bash -c "printf '%s' '{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$PWD/a.js\"}}' | bash '$FMT'"
  [ "$status" -eq 0 ]
  [ "$(cat a.js)" = "const  a = 1" ]
}

@test "format-file: config present but no binary → skip, never fail the edit" {
  new_repo fmt3
  echo '{}' > .prettierrc
  printf 'const  a = 1\n' > a.js
  run bash "$FMT" "$PWD/a.js"
  [ "$status" -eq 0 ]
  [ "$(cat a.js)" = "const  a = 1" ]
}

@test "format-file: outside a git repo, missing file, or CLAUDE_NO_FORMAT=1 → exit 0" {
  printf 'x' > "$BATS_TEST_TMPDIR/loose.js"
  run bash "$FMT" "$BATS_TEST_TMPDIR/loose.js"; [ "$status" -eq 0 ]
  run bash "$FMT" "$BATS_TEST_TMPDIR/does-not-exist.js"; [ "$status" -eq 0 ]
  run env CLAUDE_NO_FORMAT=1 bash "$FMT" "$BATS_TEST_TMPDIR/loose.js"; [ "$status" -eq 0 ]
  run bash "$FMT" </dev/null; [ "$status" -eq 0 ]
}

# ───────────────────────────── session-start ─────────────────────────────

@test "session-start: records HEAD in the marker file and in CLAUDE_ENV_FILE" {
  new_repo ss1
  head_sha=$(git rev-parse HEAD)
  envf="$BATS_TEST_TMPDIR/env"; : > "$envf"
  run env TMPDIR="$BATS_TEST_TMPDIR" CLAUDE_ENV_FILE="$envf" \
    bash -c "printf '%s' '{\"session_id\":\"test-sid-1\",\"cwd\":\"$PWD\"}' | bash '$START'"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/claude-session-start-commit-test-sid-1")" = "$head_sha" ]
  grep -q "^CLAUDE_SESSION_START_COMMIT=$head_sha\$" "$envf"
}

@test "session-start: uses cwd from the hook JSON, not the hook's own cwd" {
  new_repo ss2
  head_sha=$(git rev-parse HEAD)
  repo="$PWD"; cd "$BATS_TEST_TMPDIR"
  run env TMPDIR="$BATS_TEST_TMPDIR" bash -c "printf '%s' '{\"session_id\":\"test-sid-2\",\"cwd\":\"$repo\"}' | bash '$START'"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/claude-session-start-commit-test-sid-2")" = "$head_sha" ]
}

@test "session-start: no session id, no git repo, or a hostile id → exit 0 and no marker" {
  cd "$BATS_TEST_TMPDIR"
  run env TMPDIR="$BATS_TEST_TMPDIR" bash -c "printf '{}' | bash '$START'"; [ "$status" -eq 0 ]
  run env TMPDIR="$BATS_TEST_TMPDIR" bash -c "printf '%s' '{\"session_id\":\"test-sid-3\",\"cwd\":\"$BATS_TEST_TMPDIR\"}' | bash '$START'"
  [ "$status" -eq 0 ]; [ ! -e "$BATS_TEST_TMPDIR/claude-session-start-commit-test-sid-3" ]
  run env TMPDIR="$BATS_TEST_TMPDIR" bash -c "printf '%s' '{\"session_id\":\"../../etc/evil\"}' | bash '$START'"
  [ "$status" -eq 0 ]; [ -z "$(ls "$BATS_TEST_TMPDIR" | grep evil || true)" ]
}

# ───────────────────────────── precompact-handoff ─────────────────────────────

@test "precompact: snapshots branch, dirty files and the newest plan into the handoff file" {
  new_repo pc1
  mkdir -p .claude/plans; echo plan > .claude/plans/2026-01-01-thing.md; echo dirty > dirty.txt
  h="$BATS_TEST_TMPDIR/handoffs"
  run env CLAUDE_HANDOFF_DIR="$h" bash -c "printf '%s' '{\"session_id\":\"sid-p\"}' | bash '$COMPACT'"
  [ "$status" -eq 0 ]
  out="$h/sid-p.md"; [ -f "$out" ]
  grep -q '^## Compaction @' "$out"
  grep -q -- '- repo: ' "$out"
  grep -q 'dirty.txt' "$out"
  grep -q '2026-01-01-thing.md' "$out"
}

@test "precompact: appends — two compactions leave two sections; unknown session id still writes" {
  new_repo pc2
  h="$BATS_TEST_TMPDIR/handoffs2"
  for i in 1 2; do
    run env CLAUDE_HANDOFF_DIR="$h" bash -c "printf '%s' '{\"session_id\":\"sid-q\"}' | bash '$COMPACT'"
    [ "$status" -eq 0 ]
  done
  [ "$(grep -c '^## Compaction @' "$h/sid-q.md")" -eq 2 ]
  run env CLAUDE_HANDOFF_DIR="$h" bash -c "printf 'not json' | bash '$COMPACT'"
  [ "$status" -eq 0 ]; [ -f "$h/unknown.md" ]
}

@test "precompact: outside a git repo it records the cwd instead" {
  cd "$BATS_TEST_TMPDIR"
  h="$BATS_TEST_TMPDIR/handoffs3"
  run env CLAUDE_HANDOFF_DIR="$h" bash -c "printf '%s' '{\"session_id\":\"sid-r\"}' | bash '$COMPACT'"
  [ "$status" -eq 0 ]
  grep -q 'not in a git repo' "$h/sid-r.md"
}

# ───────────────────────────── wiring ─────────────────────────────

@test "wiring: every hook script parses (bash -n) and is executable" {
  for f in "$ROOT"/hooks/*.sh "$ROOT"/scripts/*.sh; do
    bash -n "$f"
    [ -x "$f" ]
  done
}

@test "wiring: hooks.json is valid and every command points at a script that exists" {
  python3 - "$ROOT" <<'PY'
import json, os, re, sys
root = sys.argv[1]
h = json.load(open(os.path.join(root, "hooks", "hooks.json")))
cmds = [x["command"] for ev in h["hooks"].values() for grp in ev for x in grp["hooks"]]
assert cmds, "no hook commands"
for c in cmds:
    m = re.search(r'\$\{CLAUDE_PLUGIN_ROOT\}/([^"]+)"', c)
    assert m, "command does not use ${CLAUDE_PLUGIN_ROOT}: " + c
    p = os.path.join(root, m.group(1))
    assert os.path.isfile(p), "missing " + p
assert set(h["hooks"]) == {"SessionStart", "PreToolUse", "PostToolUse", "PreCompact"}, sorted(h["hooks"])
PY
}

@test "wiring: plugin.json and marketplace.json agree on name and version" {
  python3 - "$ROOT" <<'PY'
import json, os, sys
root = sys.argv[1]
p = json.load(open(os.path.join(root, ".claude-plugin", "plugin.json")))
m = json.load(open(os.path.join(root, ".claude-plugin", "marketplace.json")))
entry = [e for e in m["plugins"] if e["name"] == p["name"]]
assert entry, "plugin %s not listed in marketplace.json" % p["name"]
assert entry[0]["version"] == p["version"], (entry[0]["version"], p["version"])
assert os.path.isdir(os.path.join(root, p["outputStyles"])), p["outputStyles"]
PY
}

@test "wiring: sync-commands.sh — --help needs no conf; a missing conf is a clear error, not a silent run" {
  run bash "$ROOT/scripts/sync-commands.sh" --conf="$BATS_TEST_TMPDIR/nope.conf" --help
  [ "$status" -eq 0 ]; [[ "$output" == *"--check"* ]]
  run bash "$ROOT/scripts/sync-commands.sh" --conf="$BATS_TEST_TMPDIR/nope.conf" --check
  [ "$status" -eq 1 ]; [[ "$output" == *"No config at"* ]]
}

@test "wiring: sync-commands.sh sources the conf and pre-flights hosts before touching anything" {
  conf="$BATS_TEST_TMPDIR/sync.conf"
  cat > "$conf" <<EOF
SERVERS=(nohost.invalid)
COMMANDS=(plan.md)
OUTPUT_STYLES=(terse.md)
ACTIVE_STYLE_NAME="Terse"; ACTIVE_STYLE_FILE="terse.md"
LOCAL_CLAUDE_DIR="$ROOT"
SSH_TIMEOUT=2
EOF
  run bash "$ROOT/scripts/sync-commands.sh" --conf="$conf" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"checking 1 server(s)"* ]]
  [[ "$output" == *"nohost.invalid (unreachable"* ]]
  [[ "$output" == *"No reachable servers"* ]]
  # a conf naming a file that does not exist locally is refused before any SSH happens
  printf 'SERVERS=(nohost.invalid)\nCOMMANDS=(does-not-exist.md)\nLOCAL_CLAUDE_DIR="%s"\n' "$ROOT" > "$conf"
  run bash "$ROOT/scripts/sync-commands.sh" --conf="$conf" --check
  [ "$status" -eq 1 ]; [[ "$output" == *"Missing locally"* ]]
}
