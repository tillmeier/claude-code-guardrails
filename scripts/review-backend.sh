#!/usr/bin/env bash
#
# review-backend.sh — run a read-only code review through whichever reviewer is available, and say
# which one ran. The only vendor-specific file behind /critical-review.
#
#   review-backend.sh --detect                       # print "<backend> <model>" or exit 3
#   review-backend.sh --scope working-tree           # review staged + unstaged + untracked
#   review-backend.sh --base <ref> [--focus "text"]  # review <ref>..HEAD
#   review-backend.sh --print-prompt ...             # show the assembled prompt, run nothing
#
# Backends (REVIEWER=codex|claude|custom, else auto-detected — see review-backend.conf.example):
#   codex   native mode: `codex exec review` (the CLI's built-in reviewer) — default when no focus;
#           prompt mode: `codex exec --sandbox read-only` with the prompt below + a JSON schema.
#   claude  prompt mode only: `claude -p --restricted` with Read/Grep/Glob and every write tool disallowed.
#   custom  prompt mode only: $REVIEW_CUSTOM_CMD, prompt on stdin, review on stdout.
#
# What every backend gets is the same: the git diff, assembled here, plus the optional focus text.
# There is deliberately no input for the task brief or any other statement of author intent — a
# reviewer told what the change is "supposed" to do finds fewer real bugs (arXiv 2603.18740), so the
# brief is applied downstream by the caller, after the review, behind a source re-read.
#
# Output: stdout = the review only (JSON per review-findings.schema.json in prompt mode; the native
#         reviewer's text otherwise). stderr = one status line before the run; the backend's own
#         output only when it failed.
# Exit:   0 review produced · 1 usage/config error · 3 no usable backend · 4 backend ran and failed.
# Config precedence: flag > environment > conf file > built-in default.
# bash 3.2 compatible. Dependencies: bash, git, python3 (only to unwrap claude's JSON envelope).

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SCHEMA_FILE="$SCRIPT_DIR/review-findings.schema.json"
MAX_UNTRACKED_BYTES=200000

# ── built-in defaults ─────────────────────────────────────────────────────────────────────────────
DEFAULT_CODEX_MODEL="gpt-5.6-sol"
DEFAULT_CLAUDE_MODEL="claude-opus-5"
DEFAULT_CLAUDE_MAX_TURNS=30

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--detect] [--backend codex|claude|custom] [--mode auto|native|prompt]
                         [--scope working-tree | --base <ref>] [--focus <text>] [--conf <file>]
                         [--print-prompt] [--verbose]

  --detect          Print "<backend> <model>" and exit 0, or exit 3 with what was checked. Runs nothing.
  --backend <name>  Force a backend (overrides REVIEWER). Unavailable → exit 3, never a substitute.
  --mode <m>        auto (default: native for codex without focus text, prompt otherwise) | native | prompt.
                    native on a backend without a built-in reviewer falls back to prompt and says so.
  --scope working-tree   Review staged + unstaged + untracked changes (default when the tree is dirty).
  --base <ref>      Review <ref>..HEAD (commit, tag, branch; anything git rev-parse accepts).
  --focus <text>    Steer the reviewer; forces prompt mode.
  --conf <file>     Config file (default: \$REVIEW_BACKEND_CONF, ~/.claude/review-backend.conf,
                    then review-backend.conf next to this script). See review-backend.conf.example.
  --print-prompt    Print the assembled prompt-mode prompt and exit 0 without calling any backend.
  --verbose         Stream the backend's own output to stderr while it runs.
USAGE
}

die_usage() { echo "review-backend: $*" >&2; usage >&2; exit 1; }

# ── flags ─────────────────────────────────────────────────────────────────────────────────────────
DETECT=0; PRINT_PROMPT=0; VERBOSE=0
FLAG_BACKEND=""; MODE="auto"; SCOPE=""; BASE_REF=""; FOCUS=""; CONF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --detect)        DETECT=1; shift ;;
    --print-prompt)  PRINT_PROMPT=1; shift ;;
    --verbose)       VERBOSE=1; shift ;;
    --backend)       [ $# -ge 2 ] || die_usage "--backend needs a value"; FLAG_BACKEND="$2"; shift 2 ;;
    --backend=*)     FLAG_BACKEND="${1#--backend=}"; shift ;;
    --mode)          [ $# -ge 2 ] || die_usage "--mode needs a value"; MODE="$2"; shift 2 ;;
    --mode=*)        MODE="${1#--mode=}"; shift ;;
    --scope)         [ $# -ge 2 ] || die_usage "--scope needs a value"; SCOPE="$2"; shift 2 ;;
    --scope=*)       SCOPE="${1#--scope=}"; shift ;;
    --base)          [ $# -ge 2 ] || die_usage "--base needs a value"; BASE_REF="$2"; SCOPE="base"; shift 2 ;;
    --base=*)        BASE_REF="${1#--base=}"; SCOPE="base"; shift ;;
    --focus)         [ $# -ge 2 ] || die_usage "--focus needs a value"; FOCUS="$2"; shift 2 ;;
    --focus=*)       FOCUS="${1#--focus=}"; shift ;;
    --conf)          [ $# -ge 2 ] || die_usage "--conf needs a value"; CONF="$2"; shift 2 ;;
    --conf=*)        CONF="${1#--conf=}"; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               die_usage "unknown argument: $1" ;;
  esac
done
case "$MODE" in auto|native|prompt) ;; *) die_usage "--mode must be auto, native or prompt" ;; esac
case "$SCOPE" in ""|working-tree|base) ;; *) die_usage "--scope must be working-tree (or use --base <ref>)" ;; esac

# ── config: env beats conf, conf beats defaults ───────────────────────────────────────────────────
ENV_REVIEWER="${REVIEWER:-}"; ENV_CODEX_MODEL="${CODEX_REVIEW_MODEL:-}"; ENV_CLAUDE_MODEL="${CLAUDE_REVIEW_MODEL:-}"
ENV_CLAUDE_TURNS="${CLAUDE_REVIEW_MAX_TURNS:-}"; ENV_CUSTOM="${REVIEW_CUSTOM_CMD:-}"
REVIEWER=""; CODEX_REVIEW_MODEL=""; CLAUDE_REVIEW_MODEL=""; CLAUDE_REVIEW_MAX_TURNS=""; REVIEW_CUSTOM_CMD=""

if [ -z "$CONF" ]; then
  for candidate in "${REVIEW_BACKEND_CONF:-}" "$HOME/.claude/review-backend.conf" "$SCRIPT_DIR/review-backend.conf"; do
    [ -n "$candidate" ] && [ -f "$candidate" ] && { CONF="$candidate"; break; }
  done
fi
if [ -n "$CONF" ]; then
  [ -f "$CONF" ] || { echo "review-backend: config not found: $CONF" >&2; exit 1; }
  # shellcheck source=review-backend.conf.example
  . "$CONF" || { echo "review-backend: failed to source $CONF" >&2; exit 1; }
fi
[ -n "$ENV_REVIEWER" ]     && REVIEWER="$ENV_REVIEWER"
[ -n "$ENV_CODEX_MODEL" ]  && CODEX_REVIEW_MODEL="$ENV_CODEX_MODEL"
[ -n "$ENV_CLAUDE_MODEL" ] && CLAUDE_REVIEW_MODEL="$ENV_CLAUDE_MODEL"
[ -n "$ENV_CLAUDE_TURNS" ] && CLAUDE_REVIEW_MAX_TURNS="$ENV_CLAUDE_TURNS"
[ -n "$ENV_CUSTOM" ]       && REVIEW_CUSTOM_CMD="$ENV_CUSTOM"
[ -n "$FLAG_BACKEND" ]     && REVIEWER="$FLAG_BACKEND"
: "${CODEX_REVIEW_MODEL:=$DEFAULT_CODEX_MODEL}"
: "${CLAUDE_REVIEW_MODEL:=$DEFAULT_CLAUDE_MODEL}"
: "${CLAUDE_REVIEW_MAX_TURNS:=$DEFAULT_CLAUDE_MAX_TURNS}"

# ── backend detection ─────────────────────────────────────────────────────────────────────────────
# Sets BACKEND and MODEL, or exits 3 with every check that was made. Never substitutes.
codex_ok()  { command -v codex  >/dev/null 2>&1 && codex login status </dev/null >/dev/null 2>&1; }
claude_ok() { command -v claude >/dev/null 2>&1; }

no_backend() {
  echo "review-backend: no usable reviewer — $*" >&2
  echo "review-backend: install the Codex CLI (npm i -g @openai/codex && codex login) or the Claude Code CLI, or set REVIEW_CUSTOM_CMD; see review-backend.conf.example" >&2
  exit 3
}

resolve_backend() {
  case "$REVIEWER" in
    codex)
      command -v codex >/dev/null 2>&1 || no_backend "REVIEWER=codex but codex is not on PATH"
      codex login status </dev/null >/dev/null 2>&1 || no_backend "REVIEWER=codex but 'codex login status' failed (run: codex login)"
      BACKEND=codex; MODEL="$CODEX_REVIEW_MODEL" ;;
    claude)
      claude_ok || no_backend "REVIEWER=claude but claude is not on PATH"
      BACKEND=claude; MODEL="$CLAUDE_REVIEW_MODEL" ;;
    custom)
      [ -n "$REVIEW_CUSTOM_CMD" ] || no_backend "REVIEWER=custom but REVIEW_CUSTOM_CMD is empty"
      BACKEND=custom; MODEL="custom" ;;
    "")
      if [ -n "$REVIEW_CUSTOM_CMD" ]; then BACKEND=custom; MODEL="custom"; return; fi
      checked=""
      if command -v codex >/dev/null 2>&1; then
        if codex login status </dev/null >/dev/null 2>&1; then BACKEND=codex; MODEL="$CODEX_REVIEW_MODEL"; return; fi
        checked="codex on PATH but 'codex login status' failed (run: codex login)"
      else
        checked="codex not on PATH"
      fi
      if claude_ok; then BACKEND=claude; MODEL="$CLAUDE_REVIEW_MODEL"; return; fi
      no_backend "checked: REVIEW_CUSTOM_CMD unset; ${checked}; claude not on PATH" ;;
    *)
      echo "review-backend: unknown REVIEWER '$REVIEWER' (codex | claude | custom)" >&2; exit 1 ;;
  esac
}

BACKEND=""; MODEL=""
resolve_backend
if [ $DETECT -eq 1 ]; then echo "$BACKEND $MODEL"; exit 0; fi

# ── scope ─────────────────────────────────────────────────────────────────────────────────────────
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "review-backend: not inside a git repository" >&2; exit 1; }
git_r() { git -C "$REPO_ROOT" "$@"; }

if [ -z "$SCOPE" ]; then
  if [ -n "$(git_r status --porcelain --untracked-files=all 2>/dev/null)" ]; then SCOPE="working-tree"
  else echo "review-backend: working tree is clean — pass --base <ref> to review committed work" >&2; exit 1; fi
fi
BASE_SHA=""
if [ "$SCOPE" = "base" ]; then
  BASE_SHA=$(git_r rev-parse --verify --quiet "${BASE_REF}^{commit}" 2>/dev/null) || { echo "review-backend: --base '$BASE_REF' is not a commit" >&2; exit 1; }
  SHORT_BASE=$(git_r rev-parse --short "$BASE_SHA")
  if [ "$BASE_REF" = "$BASE_SHA" ] || [ "$BASE_REF" = "$SHORT_BASE" ]; then SCOPE_LABEL="base ${SHORT_BASE} → HEAD"
  else SCOPE_LABEL="base ${SHORT_BASE} (${BASE_REF}) → HEAD"; fi
else
  SCOPE_LABEL="working tree (staged + unstaged + untracked)"
fi

# ── mode ──────────────────────────────────────────────────────────────────────────────────────────
if [ $PRINT_PROMPT -eq 1 ] && [ "$MODE" != "prompt" ]; then MODE="prompt"; fi   # there is nothing to print in native mode
if [ "$MODE" = "auto" ]; then
  if [ "$BACKEND" = "codex" ] && [ -z "$FOCUS" ]; then MODE="native"; else MODE="prompt"; fi
elif [ "$MODE" = "native" ]; then
  if [ "$BACKEND" != "codex" ]; then
    echo "review-backend: no native reviewer for backend '$BACKEND' — using prompt mode" >&2; MODE="prompt"
  elif [ -n "$FOCUS" ]; then
    echo "review-backend: focus text needs prompt mode — switching (the native reviewer takes no steering)" >&2; MODE="prompt"
  fi
fi

# ── review input (prompt mode) ────────────────────────────────────────────────────────────────────
section() { printf '## %s\n\n' "$1"; if [ -n "$2" ]; then printf '%s\n\n' "$2"; else printf '(none)\n\n'; fi; }

untracked_body() {  # $1 = path relative to REPO_ROOT
  local f="$REPO_ROOT/$1" size
  printf '### %s\n' "$1"
  # -L first: -f follows symlinks, and an untracked link to a file outside the repo (a credential,
  # a home-directory file) must never have its target shipped to an external reviewer.
  if [ -L "$f" ]; then printf '(skipped: symbolic link)\n\n'; return; fi
  if [ ! -f "$f" ]; then printf '(skipped: not a regular file)\n\n'; return; fi
  size=$(wc -c < "$f" | tr -d ' ')
  if [ "$size" -gt "$MAX_UNTRACKED_BYTES" ]; then printf '(skipped: %s bytes exceeds %s byte limit)\n\n' "$size" "$MAX_UNTRACKED_BYTES"; return; fi
  if [ "$size" -eq 0 ]; then printf '(empty file)\n\n'; return; fi
  if ! grep -qI '' "$f" 2>/dev/null; then printf '(skipped: binary file)\n\n'; return; fi
  printf '```\n'; cat "$f"; printf '\n```\n\n'
}

review_input() {
  if [ "$SCOPE" = "working-tree" ]; then
    section "Git status" "$(git_r status --short --untracked-files=all)"
    section "Staged diff" "$(git_r diff --cached --no-ext-diff)"
    section "Unstaged diff" "$(git_r diff --no-ext-diff)"
    printf '## Untracked files\n\n'
    local any=0 p
    while IFS= read -r p; do [ -n "$p" ] || continue; any=1; untracked_body "$p"; done <<UNTRACKED
$(git_r ls-files --others --exclude-standard)
UNTRACKED
    [ $any -eq 1 ] || printf '(none)\n\n'
  else
    section "Commits (${BASE_SHA}..HEAD)" "$(git_r log --oneline --no-decorate "${BASE_SHA}..HEAD")"
    section "Diff stat" "$(git_r diff --stat "${BASE_SHA}..HEAD")"
    section "Diff" "$(git_r diff --no-ext-diff "${BASE_SHA}..HEAD")"
  fi
}

build_prompt() {
  cat <<PROMPT
You are a skeptical senior engineer reviewing a change you did not write, by an author you cannot
ask. Find the strongest reasons this change should not ship yet. The change is in the repository
context below; you may read other files in the repository to confirm or dismiss a suspicion, but do
not modify anything.

Scope: ${SCOPE_LABEL}
Focus: ${FOCUS:-none — review the whole change}
(If a focus is given, weight it heavily, but still report any other material issue you can defend.)

Attack surface, in priority order:
- auth, permissions, trust boundaries
- data loss, corruption, irreversible state changes
- race conditions, ordering assumptions, stale state, re-entrancy
- empty-state, null, timeout and degraded-dependency behaviour
- schema drift, migration hazards, compatibility regressions
- failures that would be silent or hard to recover from

Method: try to disprove the change. Trace bad input, retries, concurrent actions and partially
completed operations through the new code. Behaviour that only holds on the happy path is a weakness.

Report only material findings you can defend from the code: what goes wrong, why this path is
vulnerable, the likely impact, and one concrete change that reduces the risk. No style, naming or
speculative comments. One strong finding beats three weak ones; if the change looks safe, say so and
return an empty findings list. Every finding names the file and a line range in the CURRENT version
of that file (post-change numbering) and a confidence between 0 and 1. If a conclusion rests on an
inference rather than on code you read, say so in the body and keep the confidence honest.

Output: exactly one JSON object matching this schema and nothing else:

$(cat "$SCHEMA_FILE")

# Repository context

$(review_input)
PROMPT
}

if [ $PRINT_PROMPT -eq 1 ]; then build_prompt; exit 0; fi

# ── run ───────────────────────────────────────────────────────────────────────────────────────────
WORK=$(mktemp -d "${TMPDIR:-/tmp}/review-backend.XXXXXX") || { echo "review-backend: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
PROMPT_FILE="$WORK/prompt.md"; OUT_FILE="$WORK/review.out"; LOG_FILE="$WORK/backend.log"
[ "$MODE" = "prompt" ] && build_prompt > "$PROMPT_FILE"

echo "review-backend: ${BACKEND} · ${MODEL} · ${MODE} mode · ${SCOPE_LABEL}" >&2

# Runs "$@" with stdin already redirected by the caller; backend chatter goes to LOG_FILE (and to
# stderr with --verbose). Returns the backend's exit status.
run_backend() {
  if [ $VERBOSE -eq 1 ]; then "$@" 2>&1 | tee "$LOG_FILE" >&2; return "${PIPESTATUS[0]}"
  else "$@" > "$LOG_FILE" 2>&1; fi
}

fail_backend() {  # $1 = message; prints the backend log tail, exits 4
  echo "review-backend: ${BACKEND} failed — $1" >&2
  if [ -s "$LOG_FILE" ]; then echo "── ${BACKEND} output (last 40 lines) ──" >&2; tail -n 40 "$LOG_FILE" >&2; fi
  exit 4
}

STATUS=0
case "$BACKEND" in
  codex)
    if [ "$MODE" = "native" ]; then
      if [ "$SCOPE" = "working-tree" ]; then target=(--uncommitted); else target=(--base "$BASE_SHA"); fi
      # </dev/null: `codex exec` reads instructions from stdin when none are given and hangs on a tty.
      ( cd "$REPO_ROOT" && run_backend codex exec review "${target[@]}" -m "$MODEL" --ephemeral -o "$OUT_FILE" </dev/null ) || STATUS=$?
    else
      # `-` = read the prompt from stdin; stdin is the prompt file, so nothing waits on a tty.
      ( cd "$REPO_ROOT" && run_backend codex exec --sandbox read-only --ephemeral -m "$MODEL" \
          --output-schema "$SCHEMA_FILE" -o "$OUT_FILE" - < "$PROMPT_FILE" ) || STATUS=$?
    fi
    [ $STATUS -eq 0 ] || fail_backend "exit $STATUS"
    [ -s "$OUT_FILE" ] || fail_backend "no final message written"
    cat "$OUT_FILE" ;;

  claude)
    # Read-only by construction: --restricted drops the command/code tools and ignores user, project
    # and local settings (so no hooks or plugins of the caller's profile run inside the reviewer),
    # only Read/Grep/Glob exist, every write/exec tool is denied again by name, nothing can prompt
    # (--permission-prompts none), no MCP servers, no session on disk.
    ( cd "$REPO_ROOT" && run_backend claude -p --restricted --model "$MODEL" \
        --tools "Read,Grep,Glob" \
        --disallowedTools "Edit,Write,MultiEdit,NotebookEdit,Bash,WebFetch,WebSearch,Agent" \
        --permission-mode dontAsk --permission-prompts none --no-session-persistence --strict-mcp-config \
        --max-turns "$CLAUDE_REVIEW_MAX_TURNS" --output-format json --json-schema "$(cat "$SCHEMA_FILE")" \
        < "$PROMPT_FILE" ) || STATUS=$?
    [ $STATUS -eq 0 ] || fail_backend "exit $STATUS"
    # Unwrap the JSON envelope: structured_output when the schema was honoured, else the text result.
    python3 - "$LOG_FILE" "$OUT_FILE" <<'PY' || fail_backend "could not parse claude's JSON envelope"
import json, sys
raw = open(sys.argv[1]).read()
try:
    d = json.loads(raw)
except ValueError:
    # progress lines may precede the envelope; take the last line that parses
    d = None
    for line in reversed(raw.splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                d = json.loads(line); break
            except ValueError:
                continue
    if d is None:
        sys.exit(1)
if d.get("is_error"):
    sys.stderr.write(str(d.get("result", "")) + "\n"); sys.exit(2)
so = d.get("structured_output")
out = json.dumps(so, indent=2) if isinstance(so, dict) else str(d.get("result") or "")
if not out.strip():
    sys.stderr.write("claude returned an envelope without a result\n"); sys.exit(3)
open(sys.argv[2], "w").write(out + "\n")
PY
    [ -s "$OUT_FILE" ] || fail_backend "empty result"
    cat "$OUT_FILE" ;;

  custom)
    export REVIEW_SCOPE="$SCOPE" REVIEW_BASE="$BASE_SHA" REVIEW_REPO_ROOT="$REPO_ROOT" REVIEW_SCHEMA="$SCHEMA_FILE" REVIEW_FOCUS="$FOCUS"
    ( cd "$REPO_ROOT" && bash -c "$REVIEW_CUSTOM_CMD" < "$PROMPT_FILE" > "$OUT_FILE" 2> "$LOG_FILE" ) || STATUS=$?
    [ $VERBOSE -eq 1 ] && [ -s "$LOG_FILE" ] && cat "$LOG_FILE" >&2
    [ $STATUS -eq 0 ] || fail_backend "exit $STATUS"
    [ -s "$OUT_FILE" ] || fail_backend "printed nothing"
    cat "$OUT_FILE" ;;
esac
exit 0
