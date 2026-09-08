#!/usr/bin/env bats
# Tests for scripts/review-backend.sh — the reviewer adapter behind /critical-review.
# No model is ever called: backends are fake `codex` / `claude` executables on PATH that record
# their argv and stdin, or a custom shell command. Run from the repo root: bats tests/

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RB="$ROOT/scripts/review-backend.sh"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"        # no real ~/.claude/review-backend.conf
  export TMPDIR="$BATS_TEST_TMPDIR"
  unset REVIEWER CODEX_REVIEW_MODEL CLAUDE_REVIEW_MODEL CLAUDE_REVIEW_MAX_TURNS REVIEW_CUSTOM_CMD REVIEW_BACKEND_CONF
  export FAKE_LOG="$BATS_TEST_TMPDIR/fake"; mkdir -p "$FAKE_LOG"
  FAKEBIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$FAKEBIN"
  BARE="/usr/bin:/bin"                                          # git + python3, but no codex / claude
  export PATH="$BARE"
  APPROVE='{"verdict":"approve","summary":"nothing material","findings":[]}'
}

# Fake codex: records argv + stdin, honours `login status`, writes canned output to the -o file.
fake_codex() {
  cat > "$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_LOG/codex.argv"
[ "${1:-}" = login ] && exit "${FAKE_CODEX_LOGIN_EXIT:-0}"
cat > "$FAKE_LOG/codex.stdin"
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && [ -z "${FAKE_CODEX_NO_OUTPUT:-}" ] && printf '%s\n' "${FAKE_CODEX_OUTPUT:-fake codex review text}" > "$out"
exit "${FAKE_CODEX_EXIT:-0}"
SH
  chmod +x "$FAKEBIN/codex"; export PATH="$FAKEBIN:$BARE"
}
# Fake claude: records argv + stdin, prints a `claude -p --output-format json` envelope.
fake_claude() {
  cat > "$FAKEBIN/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_LOG/claude.argv"
cat > "$FAKE_LOG/claude.stdin"
DEFAULT='{"type":"result","is_error":false,"result":"text","structured_output":{"verdict":"approve","summary":"fake claude","findings":[]}}'
printf '%s\n' "${FAKE_CLAUDE_OUTPUT:-$DEFAULT}"
exit "${FAKE_CLAUDE_EXIT:-0}"
SH
  chmod +x "$FAKEBIN/claude"; export PATH="$FAKEBIN:$BARE"
}

# A repo with two commits and a dirty tree. Sets BASE (= first commit).
#   c1: old.txt (old-marker)   c2: new.txt (new-marker)   dirty: a.txt unstaged, untracked.txt
new_repo() {
  cd "$BATS_TEST_TMPDIR" && git init -q "$1" && cd "$1"
  printf 'old-marker\n' > old.txt; printf 'alpha\n' > a.txt; git add old.txt a.txt; git commit -qm c1
  BASE=$(git rev-parse HEAD)
  printf 'new-marker\n' > new.txt; git add new.txt; git commit -qm c2
  printf 'alpha\nunstaged-marker\n' > a.txt
  printf 'untracked-marker\n' > untracked.txt
}

# ───────────────────────────── detection ─────────────────────────────

@test "backend: nothing installed → exit 3 naming every check, nothing runs" {
  new_repo d1
  run bash "$RB" --detect
  [ "$status" -eq 3 ]
  [[ "$output" == *"REVIEW_CUSTOM_CMD unset"* ]]; [[ "$output" == *"codex not on PATH"* ]]; [[ "$output" == *"claude not on PATH"* ]]
  run bash "$RB" --scope working-tree
  [ "$status" -eq 3 ]
}

@test "backend: auto-detect order — custom cmd, then codex (logged in), then claude" {
  new_repo d2; fake_codex; fake_claude
  run bash "$RB" --detect;                          [ "$status" -eq 0 ]; [ "$output" = "codex gpt-5.6-sol" ]
  run env FAKE_CODEX_LOGIN_EXIT=1 bash "$RB" --detect; [ "$status" -eq 0 ]; [ "$output" = "claude claude-opus-5" ]
  run env REVIEW_CUSTOM_CMD='cat' bash "$RB" --detect; [ "$status" -eq 0 ]; [ "$output" = "custom custom" ]
}

@test "backend: an explicitly named backend that is unavailable is exit 3, never a substitute" {
  new_repo d3; fake_claude
  run env REVIEWER=codex bash "$RB" --detect
  [ "$status" -eq 3 ]; [[ "$output" == *"REVIEWER=codex but codex is not on PATH"* ]]
  fake_codex
  run env REVIEWER=codex FAKE_CODEX_LOGIN_EXIT=1 bash "$RB" --detect
  [ "$status" -eq 3 ]; [[ "$output" == *"codex login status"* ]]
  run env REVIEWER=custom bash "$RB" --detect
  [ "$status" -eq 3 ]; [[ "$output" == *"REVIEW_CUSTOM_CMD is empty"* ]]
  run env REVIEWER=nonsense bash "$RB" --detect
  [ "$status" -eq 1 ]
  # --backend beats REVIEWER
  run env REVIEWER=codex bash "$RB" --backend claude --detect
  [ "$status" -eq 0 ]; [ "$output" = "claude claude-opus-5" ]
}

@test "backend: config precedence — flag > environment > conf file > built-in default" {
  new_repo d4; fake_codex
  conf="$BATS_TEST_TMPDIR/rb.conf"; printf 'CODEX_REVIEW_MODEL="from-conf"\n' > "$conf"
  run bash "$RB" --detect;                                             [ "$output" = "codex gpt-5.6-sol" ]
  run bash "$RB" --conf "$conf" --detect;                              [ "$output" = "codex from-conf" ]
  run env CODEX_REVIEW_MODEL=from-env bash "$RB" --conf "$conf" --detect; [ "$output" = "codex from-env" ]
  run env REVIEW_BACKEND_CONF="$conf" bash "$RB" --detect;             [ "$output" = "codex from-conf" ]
  mkdir -p "$HOME/.claude"; printf 'CODEX_REVIEW_MODEL="from-home"\n' > "$HOME/.claude/review-backend.conf"
  run bash "$RB" --detect;                                             [ "$output" = "codex from-home" ]
  run bash "$RB" --conf "$BATS_TEST_TMPDIR/missing.conf" --detect;     [ "$status" -eq 1 ]
}

# ───────────────────────────── prompt assembly ─────────────────────────────

@test "prompt: working tree → status, unstaged hunk, untracked body and the focus text; runs nothing" {
  new_repo p1
  run env REVIEW_CUSTOM_CMD='cat' bash "$RB" --print-prompt --scope working-tree --focus 'look-at-locking'
  [ "$status" -eq 0 ]
  [[ "$output" == *"+unstaged-marker"* ]]; [[ "$output" == *"### untracked.txt"* ]]; [[ "$output" == *"untracked-marker"* ]]
  [[ "$output" == *"Focus: look-at-locking"* ]]; [[ "$output" == *'"verdict"'* ]]     # schema embedded
  [[ "$output" != *"new-marker"* ]]                                                    # committed work stays out
}

@test "prompt: an untracked symlink is never followed — its target stays out of the reviewer's input" {
  new_repo p5
  printf 'SECRET-OUTSIDE-REPO\n' > "$BATS_TEST_TMPDIR/outside.txt"
  ln -s "$BATS_TEST_TMPDIR/outside.txt" leak.txt
  run env REVIEW_CUSTOM_CMD='cat' bash "$RB" --print-prompt --scope working-tree
  [ "$status" -eq 0 ]
  [[ "$output" == *"### leak.txt"* ]]; [[ "$output" == *"(skipped: symbolic link)"* ]]
  [[ "$output" != *"SECRET-OUTSIDE-REPO"* ]]
}

@test "prompt: --print-prompt always shows the prompt-mode prompt, even when codex would run natively" {
  new_repo p6; fake_codex
  run bash "$RB" --print-prompt --base "$BASE"
  [ "$status" -eq 0 ]; [[ "$output" == *"+new-marker"* ]]; [[ "$output" == *'"verdict"'* ]]
  ! grep -q '^exec$' "$FAKE_LOG/codex.argv"                                            # only `login status` ran, no review
}

@test "prompt: --base <ref> → only base..HEAD, uncommitted changes stay out; bad ref is a usage error" {
  new_repo p2; git stash -q -u
  run env REVIEW_CUSTOM_CMD='cat' bash "$RB" --print-prompt --base "$BASE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"+new-marker"* ]]; [[ "$output" != *"old-marker"* ]]; [[ "$output" != *"unstaged-marker"* ]]
  run env REVIEW_CUSTOM_CMD='cat' bash "$RB" --print-prompt --base no-such-ref
  [ "$status" -eq 1 ]; [[ "$output" == *"not a commit"* ]]
}

@test "prompt: the task brief never reaches the reviewer — no flag for it, planted brief files are not read" {
  new_repo p3
  mkdir -p "$HOME/.claude/logs"
  for f in "$TMPDIR/claude-review-brief-anysession.md" "$HOME/.claude/logs/brief.md" "$BATS_TEST_TMPDIR/p3/BRIEF.md"; do
    printf 'CANARY-INTENT-DO-NOT-FLAG\n' > "$f"
  done
  git rm -q --cached BRIEF.md 2>/dev/null || true   # it is untracked; the prompt may quote it as a file, so exclude it
  echo BRIEF.md > .git/info/exclude
  run env REVIEW_CUSTOM_CMD="cat > $FAKE_LOG/custom.stdin; printf '%s' '$APPROVE'" bash "$RB" --scope working-tree
  [ "$status" -eq 0 ]
  ! grep -q CANARY "$FAKE_LOG/custom.stdin"
  run bash "$RB" --brief "$TMPDIR/claude-review-brief-anysession.md" --scope working-tree
  [ "$status" -eq 1 ]; [[ "$output" == *"unknown argument"* ]]
}

@test "prompt: clean tree without --base is a usage error, not an empty review" {
  new_repo p4; git stash -q -u
  run env REVIEW_CUSTOM_CMD='cat' bash "$RB"
  [ "$status" -eq 1 ]; [[ "$output" == *"clean"* ]]
}

# ───────────────────────────── custom backend ─────────────────────────────

@test "custom: prompt on stdin, review on stdout verbatim, scope in the environment, status line on stderr" {
  new_repo c1
  cmd='n=$(wc -c < /dev/stdin); printf "{\"verdict\":\"approve\",\"summary\":\"%s bytes scope=%s base=%s root=%s\",\"findings\":[]}" "$n" "$REVIEW_SCOPE" "${REVIEW_BASE:0:7}" "$(basename "$REVIEW_REPO_ROOT")"'
  run env REVIEW_CUSTOM_CMD="$cmd" bash "$RB" --base "$BASE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"review-backend: custom · custom · prompt mode · base"* ]]
  [[ "$output" == *"scope=base base=${BASE:0:7} root=c1"* ]]
  [[ "$output" != *'"0 bytes'* ]]     # the prompt actually arrived (summary starts with the byte count)
  # stdout carries only the review; the status line is stderr
  out=$(env REVIEW_CUSTOM_CMD="$cmd" bash "$RB" --base "$BASE" 2>/dev/null)
  [[ "$out" == '{"verdict":"approve"'* ]]
}

@test "custom: a failing or silent reviewer is exit 4 with its stderr shown, never an empty 'review'" {
  new_repo c2
  run env REVIEW_CUSTOM_CMD='echo "auth token expired" >&2; exit 7' bash "$RB" --scope working-tree
  [ "$status" -eq 4 ]; [[ "$output" == *"custom failed — exit 7"* ]]; [[ "$output" == *"auth token expired"* ]]
  run env REVIEW_CUSTOM_CMD='cat > /dev/null' bash "$RB" --scope working-tree
  [ "$status" -eq 4 ]; [[ "$output" == *"printed nothing"* ]]
}

@test "custom: --mode native degrades to prompt mode and says so" {
  new_repo c3
  run env REVIEW_CUSTOM_CMD="printf '%s' '$APPROVE'" bash "$RB" --mode native --scope working-tree
  [ "$status" -eq 0 ]; [[ "$output" == *"no native reviewer for backend 'custom' — using prompt mode"* ]]
}

# ───────────────────────────── codex backend ─────────────────────────────

@test "codex: native mode = 'codex exec review' with the pinned model, empty stdin, -o result printed" {
  new_repo x1; fake_codex
  run bash "$RB" --base "$BASE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"review-backend: codex · gpt-5.6-sol · native mode"* ]]
  [[ "$output" == *"fake codex review text"* ]]
  argv=$(tr '\n' ' ' < "$FAKE_LOG/codex.argv")
  [[ "$argv" == "exec review --base $BASE -m gpt-5.6-sol --ephemeral -o "* ]]
  [ ! -s "$FAKE_LOG/codex.stdin" ]                     # </dev/null — nothing can hang on a tty
  run bash "$RB" --scope working-tree
  argv=$(tr '\n' ' ' < "$FAKE_LOG/codex.argv"); [[ "$argv" == "exec review --uncommitted -m gpt-5.6-sol "* ]]
}

@test "codex: focus text or --mode prompt = read-only 'codex exec' with the schema and the prompt on stdin" {
  new_repo x2; fake_codex
  run env FAKE_CODEX_OUTPUT="$APPROVE" bash "$RB" --scope working-tree --focus 'race conditions'
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex · gpt-5.6-sol · prompt mode"* ]]; [[ "$output" == *'"verdict":"approve"'* ]]
  argv=$(tr '\n' ' ' < "$FAKE_LOG/codex.argv")
  [[ "$argv" == "exec --sandbox read-only --ephemeral -m gpt-5.6-sol --output-schema $ROOT/scripts/review-findings.schema.json -o "* ]]
  [[ "$argv" == *" - " ]]
  grep -q 'Focus: race conditions' "$FAKE_LOG/codex.stdin"; grep -q '+unstaged-marker' "$FAKE_LOG/codex.stdin"
  run bash "$RB" --mode prompt --base "$BASE"
  argv=$(tr '\n' ' ' < "$FAKE_LOG/codex.argv"); [[ "$argv" == "exec --sandbox read-only "* ]]
}

@test "codex: non-zero exit or no final message → exit 4 with the backend log" {
  new_repo x3; fake_codex
  run env FAKE_CODEX_EXIT=2 bash "$RB" --base "$BASE"
  [ "$status" -eq 4 ]; [[ "$output" == *"codex failed — exit 2"* ]]
  run env FAKE_CODEX_NO_OUTPUT=1 bash "$RB" --base "$BASE"
  [ "$status" -eq 4 ]; [[ "$output" == *"no final message"* ]]
}

# ───────────────────────────── claude backend ─────────────────────────────

@test "claude: prompt mode only, read-only tool set, nothing can prompt, structured output unwrapped" {
  new_repo l1; fake_claude
  run bash "$RB" --scope working-tree
  [ "$status" -eq 0 ]
  [[ "$output" == *"review-backend: claude · claude-opus-5 · prompt mode"* ]]
  [[ "$output" == *'"summary": "fake claude"'* ]]
  argv=$(tr '\n' ' ' < "$FAKE_LOG/claude.argv")
  [[ "$argv" == "-p --restricted --model claude-opus-5 --tools Read,Grep,Glob --disallowedTools "* ]]
  for t in Edit Write MultiEdit NotebookEdit Bash WebFetch WebSearch Agent; do [[ "$argv" == *"--disallowedTools "*"$t"* ]]; done
  [[ "$argv" == *"--permission-mode dontAsk --permission-prompts none --no-session-persistence --strict-mcp-config --max-turns 30 --output-format json --json-schema "* ]]
  grep -q '+unstaged-marker' "$FAKE_LOG/claude.stdin"
  run env CLAUDE_REVIEW_MODEL=claude-sonnet-5 CLAUDE_REVIEW_MAX_TURNS=5 bash "$RB" --mode native --scope working-tree
  [[ "$output" == *"no native reviewer for backend 'claude'"* ]]
  argv=$(tr '\n' ' ' < "$FAKE_LOG/claude.argv"); [[ "$argv" == "-p --restricted --model claude-sonnet-5 "* ]]; [[ "$argv" == *"--max-turns 5 "* ]]
}

@test "claude: an error envelope, an empty envelope or a crash is exit 4; a text-only result is passed through" {
  new_repo l2; fake_claude
  run env FAKE_CLAUDE_OUTPUT='{"type":"result","is_error":true,"result":"Invalid API key"}' bash "$RB" --scope working-tree
  [ "$status" -eq 4 ]; [[ "$output" == *"Invalid API key"* ]]
  # a well-formed envelope with nothing in it must not pass as a review (found by the claude backend reviewing itself)
  run env FAKE_CLAUDE_OUTPUT='{"type":"result","is_error":false,"result":""}' bash "$RB" --scope working-tree
  [ "$status" -eq 4 ]; [[ "$output" == *"without a result"* ]]
  run env FAKE_CLAUDE_OUTPUT='{"type":"result","is_error":false,"result":null,"structured_output":null}' bash "$RB" --scope working-tree
  [ "$status" -eq 4 ]
  run env FAKE_CLAUDE_EXIT=1 bash "$RB" --scope working-tree
  [ "$status" -eq 4 ]
  run env FAKE_CLAUDE_OUTPUT='{"type":"result","is_error":false,"result":"plain text review"}' bash "$RB" --scope working-tree
  [ "$status" -eq 0 ]; [[ "$output" == *"plain text review"* ]]
}
