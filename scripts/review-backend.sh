#!/usr/bin/env bash
#
# review-backend.sh — run a read-only code review through whichever reviewer is available, and say
# which one ran. The only vendor-specific file behind /critical-review.
#
#   review-backend.sh --detect                       # print "<backend> <model>" or exit 3
#   review-backend.sh --scope working-tree           # review staged + unstaged + untracked
#   review-backend.sh --base <ref> [--focus "text"]  # review <ref>..HEAD
#   review-backend.sh --spec <file> [--focus "text"] # review a design spec before any code exists (/plan --codex)
#   review-backend.sh --print-prompt ...             # show the assembled prompt, run nothing
#
# Spec mode is the one input that is intent, so it never goes next to a diff: --spec excludes --scope,
# --base, --detect and --mode native. The answer is plain text (a spec has no diff lines to cite).
#
# Backends (REVIEWER=codex|claude|gemini|custom, else auto-detected — see review-backend.conf.example):
#   codex   native mode: `codex exec review` (the CLI's built-in reviewer) — default when no focus;
#           prompt mode: `codex exec --sandbox read-only` with the prompt below + a JSON schema.
#   claude  prompt mode only: `claude -p --restricted` with Read/Grep/Glob and every write tool disallowed.
#   gemini  prompt mode only, never auto-detected: the Antigravity CLI (`agy`) in an EMPTY directory with
#           per-run deny rules for file reads, writes, commands, web and MCP; the diff goes inline with 25
#           lines of context, each line numbered as in the current file. A run in which a tool did anything,
#           another model answered, or the answer is not JSON is exit 4. Docs: docs/review-backend.md.
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
DEFAULT_CODEX_MODEL="gpt-6.2-sol"   # needs codex CLI 0.170 (tested 0.170.0; 0.163 does not know it)
DEFAULT_CODEX_EFFORT="high"   # `codex exec review` has no --effort flag; without a pin the model's own default applies
DEFAULT_CLAUDE_MODEL="claude-opus-5"
DEFAULT_CLAUDE_MAX_TURNS=30
DEFAULT_GEMINI_MODEL="gemini-4-neon-high"   # an `agy models` slug; the effort is part of the slug
DEFAULT_GEMINI_TIMEOUT=900                  # seconds; a large diff took 4.5 min in testing

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--detect] [--backend codex|claude|gemini|custom] [--mode auto|native|prompt]
                         [--scope working-tree | --base <ref> | --spec <file>] [--focus <text>]
                         [--conf <file>] [--print-prompt] [--verbose]

  --detect          Print "<backend> <model>" and exit 0, or exit 3 with what was checked. Runs nothing.
  --backend <name>  Force a backend (overrides REVIEWER). Unavailable → exit 3, never a substitute.
  --mode <m>        auto (default: native for codex without focus text, prompt otherwise) | native | prompt.
                    native on a backend without a built-in reviewer falls back to prompt and says so.
  --scope working-tree   Review staged + unstaged + untracked changes (default when the tree is dirty).
  --base <ref>      Review <ref>..HEAD (commit, tag, branch; anything git rev-parse accepts).
  --spec <file>     Review a design spec (a regular file, at most 200000 bytes) instead of code; the
                    reviewer may read the files it cites. Plain-text answer. Not with --scope/--base/--detect.
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
FLAG_BACKEND=""; MODE="auto"; SCOPE=""; BASE_REF=""; FOCUS=""; CONF=""; SPEC=""; SPEC_ABS=""
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
    # An empty value must not fall back to a code review of the working tree.
    --spec)          [ $# -ge 2 ] && [ -n "$2" ] || die_usage "--spec needs a file"; SPEC="$2"; shift 2 ;;
    --spec=*)        SPEC="${1#--spec=}"; [ -n "$SPEC" ] || die_usage "--spec needs a file"; shift ;;
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

# Spec mode: checked before any backend is looked up, so a bad spec never reaches a reviewer.
MAX_SPEC_BYTES=200000
if [ -n "$SPEC" ]; then
  [ -z "$SCOPE" ]    || die_usage "--spec cannot be combined with --scope or --base (a spec never goes next to a diff)"
  [ $DETECT -eq 0 ]  || die_usage "--spec cannot be combined with --detect"
  [ "$MODE" != native ] || die_usage "--spec needs prompt mode (the native reviewer only reviews code)"
  spec_err() { echo "review-backend: --spec '$SPEC' $1" >&2; exit 1; }
  [ ! -L "$SPEC" ] || spec_err "is a symbolic link"
  [ -f "$SPEC" ]   || spec_err "is not a regular file"
  [ -r "$SPEC" ]   || spec_err "is not readable"
  [ -s "$SPEC" ]   || spec_err "is empty"
  spec_size=$(wc -c < "$SPEC" | tr -d ' ')
  [ "$spec_size" -le "$MAX_SPEC_BYTES" ] || spec_err "has $spec_size bytes, more than $MAX_SPEC_BYTES"
  # absolute before any cd: the reviewer runs from the repository root
  # CDPATH= : with CDPATH set, cd prints the directory, which would land in SPEC_ABS
  SPEC_ABS="$(CDPATH='' cd "$(dirname "$SPEC")" && pwd -P)/$(basename "$SPEC")" || spec_err "cannot be resolved"
  MODE="prompt"
fi

# ── config: env beats conf, conf beats defaults ───────────────────────────────────────────────────
ENV_REVIEWER="${REVIEWER:-}"; ENV_CODEX_MODEL="${CODEX_REVIEW_MODEL:-}"; ENV_CLAUDE_MODEL="${CLAUDE_REVIEW_MODEL:-}"
ENV_CLAUDE_TURNS="${CLAUDE_REVIEW_MAX_TURNS:-}"; ENV_CUSTOM="${REVIEW_CUSTOM_CMD:-}"
ENV_GEMINI_MODEL="${GEMINI_REVIEW_MODEL:-}"; ENV_GEMINI_TIMEOUT="${GEMINI_REVIEW_TIMEOUT:-}"
ENV_CODEX_EFFORT_SET=0; ENV_CODEX_EFFORT=""; [ -n "${CODEX_REVIEW_EFFORT+x}" ] && { ENV_CODEX_EFFORT_SET=1; ENV_CODEX_EFFORT="$CODEX_REVIEW_EFFORT"; }
REVIEWER=""; CODEX_REVIEW_MODEL=""; CLAUDE_REVIEW_MODEL=""; CLAUDE_REVIEW_MAX_TURNS=""; REVIEW_CUSTOM_CMD=""
GEMINI_REVIEW_MODEL=""; GEMINI_REVIEW_TIMEOUT=""
CODEX_REVIEW_EFFORT="$DEFAULT_CODEX_EFFORT"   # empty in the conf or the env = leave it to ~/.codex/config.toml

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
[ -n "$ENV_GEMINI_MODEL" ] && GEMINI_REVIEW_MODEL="$ENV_GEMINI_MODEL"
[ -n "$ENV_GEMINI_TIMEOUT" ] && GEMINI_REVIEW_TIMEOUT="$ENV_GEMINI_TIMEOUT"
[ "$ENV_CODEX_EFFORT_SET" -eq 1 ] && CODEX_REVIEW_EFFORT="$ENV_CODEX_EFFORT"
[ -n "$FLAG_BACKEND" ]     && REVIEWER="$FLAG_BACKEND"
: "${CODEX_REVIEW_MODEL:=$DEFAULT_CODEX_MODEL}"
: "${CLAUDE_REVIEW_MODEL:=$DEFAULT_CLAUDE_MODEL}"
: "${CLAUDE_REVIEW_MAX_TURNS:=$DEFAULT_CLAUDE_MAX_TURNS}"
: "${GEMINI_REVIEW_MODEL:=$DEFAULT_GEMINI_MODEL}"
: "${GEMINI_REVIEW_TIMEOUT:=$DEFAULT_GEMINI_TIMEOUT}"

# ── backend detection ─────────────────────────────────────────────────────────────────────────────
# Sets BACKEND and MODEL, or exits 3 with every check that was made. Never substitutes.
codex_ok()  { command -v codex  >/dev/null 2>&1 && codex login status </dev/null >/dev/null 2>&1; }
claude_ok() { command -v claude >/dev/null 2>&1; }
# The agy to run: $AGY_BIN, else the first `agy` on PATH that is not a terminal's wrapper script (cmux
# ships one in its app bundle and per-session shims; they install the terminal's own hooks first).
find_agy() {
  # an executable FILE, returned as an absolute path: the run happens after `cd` into an empty directory
  if [ -n "${AGY_BIN:-}" ]; then
    [ -f "$AGY_BIN" ] && [ -x "$AGY_BIN" ] && { (cd "$(dirname "$AGY_BIN")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$AGY_BIN")"); return 0; }
    return 1
  fi
  local d IFS=:
  for d in $PATH; do
    case "$d" in *cmux.app*|*/.cmuxterm/*) continue ;; esac
    [ -x "$d/agy" ] && [ -f "$d/agy" ] && { (cd "$d" && printf '%s/agy\n' "$(pwd -P)"); return 0; }
  done
  return 1
}

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
    gemini)
      # Explicit only: auto-detection never sends code to a reviewer the user did not name.
      AGY=$(find_agy) || no_backend "REVIEWER=gemini but agy (Antigravity CLI) is not on PATH (or \$AGY_BIN)"
      BACKEND=gemini; MODEL="$GEMINI_REVIEW_MODEL" ;;
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
      echo "review-backend: unknown REVIEWER '$REVIEWER' (codex | claude | gemini | custom)" >&2; exit 1 ;;
  esac
}

BACKEND=""; MODEL=""
resolve_backend
if [ $DETECT -eq 1 ]; then echo "$BACKEND $MODEL"; exit 0; fi

# ── scope ─────────────────────────────────────────────────────────────────────────────────────────
git_r() { git -C "$REPO_ROOT" "$@"; }
IN_GIT=1
if [ -n "$SPEC" ]; then
  # A spec may live outside any repository (/plan falls back to ~/.claude/plans); the reviewer then
  # runs in the current directory.
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { REPO_ROOT=$(pwd -P); IN_GIT=0; }
  SCOPE="spec"; SCOPE_LABEL="spec ${SPEC_ABS}"
else
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "review-backend: not inside a git repository" >&2; exit 1; }
fi

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
elif [ "$SCOPE" = "working-tree" ]; then
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

# gemini has no file access: it gets more context and a line number on every line it may cite.
DIFF_CTX=()
[ "$BACKEND" = gemini ] && DIFF_CTX=(-U25)
numbered() {  # stdin = a unified diff; prefixes context and added lines with their line in the new file
  if [ "$BACKEND" != gemini ]; then cat; return; fi
  python3 -c '
import re, sys
new = None
for line in sys.stdin.read().splitlines():
    m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
    if m:
        new = int(m.group(1)); print(line)
    elif new is not None and line[:1] in (" ", "+"):        # inside a hunk "+++i;" is an added "++i;"
        print("%6d %s" % (new, line)); new += 1
    elif new is not None and line[:1] == "-":
        print("%6s %s" % ("", line))
    else:
        if line.startswith("diff --git"):
            new = None
        print(line)
'
}

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
  if [ "$BACKEND" = gemini ]; then printf '```\n'; awk '{ printf "%6d  %s\n", NR, $0 }' "$f"; printf '```\n\n'
  else printf '```\n'; cat "$f"; printf '\n```\n\n'; fi
}

review_input() {
  if [ "$SCOPE" = "working-tree" ]; then
    section "Git status" "$(git_r status --short --untracked-files=all)"
    if [ "$BACKEND" = gemini ]; then
      # one diff against HEAD, so every number is a line of the file on disk (a staged diff numbers the
      # index, which is off by any unstaged change above it)
      section "Diff against HEAD (staged + unstaged)" "$(git_r diff HEAD --no-ext-diff ${DIFF_CTX[@]+"${DIFF_CTX[@]}"} | numbered)"
    else
      section "Staged diff" "$(git_r diff --cached --no-ext-diff)"
      section "Unstaged diff" "$(git_r diff --no-ext-diff)"
    fi
    printf '## Untracked files\n\n'
    local any=0 p
    while IFS= read -r p; do [ -n "$p" ] || continue; any=1; untracked_body "$p"; done <<UNTRACKED
$(git_r ls-files --others --exclude-standard)
UNTRACKED
    [ $any -eq 1 ] || printf '(none)\n\n'
  else
    section "Commits (${BASE_SHA}..HEAD)" "$(git_r log --oneline --no-decorate "${BASE_SHA}..HEAD")"
    section "Diff stat" "$(git_r diff --stat "${BASE_SHA}..HEAD")"
    section "Diff" "$(git_r diff --no-ext-diff ${DIFF_CTX[@]+"${DIFF_CTX[@]}"} "${BASE_SHA}..HEAD" | numbered)"
  fi
}

build_prompt() {
  local access="you may read other files in the repository to confirm or dismiss a suspicion, but do
not modify anything."
  [ "$BACKEND" = gemini ] && access="it is everything you get: you have no tools, do not try to call any.
The number in front of a diff line is its line in the CURRENT file; cite those numbers."
  cat <<PROMPT
You are a skeptical senior engineer reviewing a change you did not write, by an author you cannot
ask. Find the strongest reasons this change should not ship yet. The change is in the repository
context below; ${access}

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

# Spec mode. The spec text is appended by cat, never expanded, so backticks and $(…) in it stay inert.
build_spec_prompt() {
  local access="The files it cites are in your working directory: read them to check the citations
and assumptions, but do not modify anything."
  [ "$BACKEND" = gemini ] && access="You have no tools and no file access: judge only from the spec, do not try
to call any tool, and say where a claim could not be checked."
  cat <<PROMPT
Review-only, do not edit any files. Adversarially review this DESIGN SPEC before implementation.
There is no code yet. ${access}

Find: wrong or unstated assumptions, missing edge cases, a simpler approach that gets the same
outcome, hidden blast radius, and anything in the Verification plan that wouldn't actually prove
the goal. Be blunt. If the approach is sound, say so in one line — don't invent problems.
Focus: ${FOCUS:-none — review the whole spec}

Answer in plain text, not JSON.

===== SPEC =====
PROMPT
  cat "$SPEC_ABS"
}

make_prompt() { if [ -n "$SPEC" ]; then build_spec_prompt; else build_prompt; fi; }

if [ $PRINT_PROMPT -eq 1 ]; then make_prompt || { echo "review-backend: could not build the prompt" >&2; exit 1; }; exit 0; fi

# ── run ───────────────────────────────────────────────────────────────────────────────────────────
WORK=$(mktemp -d "${TMPDIR:-/tmp}/review-backend.XXXXXX") || { echo "review-backend: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
PROMPT_FILE="$WORK/prompt.md"; OUT_FILE="$WORK/review.out"; LOG_FILE="$WORK/backend.log"
if [ "$MODE" = "prompt" ]; then
  make_prompt > "$PROMPT_FILE" || { echo "review-backend: could not build the prompt" >&2; exit 1; }
fi
# A review is text: empty or whitespace-only output is a failed run, not an empty review.
has_text() { grep -q '[^[:space:]]' "$1" 2>/dev/null; }

EFFORT_ARGS=(); EFFORT_LABEL=""
if [ "$BACKEND" = codex ] && [ -n "$CODEX_REVIEW_EFFORT" ]; then EFFORT_ARGS=(-c "model_reasoning_effort=$CODEX_REVIEW_EFFORT"); EFFORT_LABEL=" · effort $CODEX_REVIEW_EFFORT"; fi
echo "review-backend: ${BACKEND} · ${MODEL}${EFFORT_LABEL} · ${MODE} mode · ${SCOPE_LABEL}" >&2

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
# Spec mode answers in plain text: no findings schema for codex or claude.
CODEX_MODE_ARGS=(--output-schema "$SCHEMA_FILE"); CLAUDE_SCHEMA_ARGS=(--json-schema "$(cat "$SCHEMA_FILE")")
# Spec mode also switches codex hooks off: an enabled, trusted hook runs outside the read-only sandbox.
if [ -n "$SPEC" ]; then CODEX_MODE_ARGS=(--disable hooks); CLAUDE_SCHEMA_ARGS=(); fi
CODEX_REPO_ARGS=(); [ "$IN_GIT" -eq 1 ] || CODEX_REPO_ARGS=(--skip-git-repo-check)
case "$BACKEND" in
  codex)
    if [ "$MODE" = "native" ]; then
      if [ "$SCOPE" = "working-tree" ]; then target=(--uncommitted); else target=(--base "$BASE_SHA"); fi
      # </dev/null: `codex exec` reads instructions from stdin when none are given and hangs on a tty.
      ( cd "$REPO_ROOT" && run_backend codex exec review "${target[@]}" -m "$MODEL" ${EFFORT_ARGS[@]+"${EFFORT_ARGS[@]}"} --ephemeral -o "$OUT_FILE" </dev/null ) || STATUS=$?
    else
      # `-` = read the prompt from stdin; stdin is the prompt file, so nothing waits on a tty.
      ( cd "$REPO_ROOT" && run_backend codex exec --sandbox read-only --ephemeral ${CODEX_REPO_ARGS[@]+"${CODEX_REPO_ARGS[@]}"} \
          -m "$MODEL" ${EFFORT_ARGS[@]+"${EFFORT_ARGS[@]}"} ${CODEX_MODE_ARGS[@]+"${CODEX_MODE_ARGS[@]}"} \
          -o "$OUT_FILE" - < "$PROMPT_FILE" ) || STATUS=$?
    fi
    [ $STATUS -eq 0 ] || fail_backend "exit $STATUS"
    has_text "$OUT_FILE" || fail_backend "no final message written"
    if [ -n "$SPEC" ]; then
      # What ran, from codex's own run header, not from the flags this script passed. Only the
      # header block (between the first two "--------" lines) counts: the rest of the transcript
      # echoes the prompt and the answer, and a spec line "sandbox: read-only" must not pass.
      HDR="$WORK/codex-header"
      awk '/^--------$/{n++; next} n==1' "$LOG_FILE" > "$HDR"
      grep -qx 'sandbox: read-only' "$HDR" || fail_backend "the run header does not show 'sandbox: read-only'"
      grep -qxF "model: $MODEL" "$HDR"     || fail_backend "the run header does not show 'model: $MODEL'"
      if [ -n "$CODEX_REVIEW_EFFORT" ]; then
        grep -qxF "reasoning effort: $CODEX_REVIEW_EFFORT" "$HDR" || fail_backend "the run header does not show 'reasoning effort: $CODEX_REVIEW_EFFORT'"
      fi
    fi
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
        --max-turns "$CLAUDE_REVIEW_MAX_TURNS" --output-format json ${CLAUDE_SCHEMA_ARGS[@]+"${CLAUDE_SCHEMA_ARGS[@]}"} \
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
    has_text "$OUT_FILE" || fail_backend "empty result"
    cat "$OUT_FILE" ;;

  gemini)
    # agy runs in an EMPTY directory with per-run deny rules (passed with --settings, never saved): without
    # them a headless agy wrote a file, ran a command and read a file outside its workspace (agy 1.5.16).
    GWS="$WORK/gemini-workspace"; mkdir -p "$GWS"
    SETTINGS='{"permissions":{"deny":["read_file(*)","write_file(*)","command(*)","read_url(*)","execute_url(*)","mcp(*)"]}}'
    python3 -c 'import json, sys; print(json.dumps({"event": "user", "message": {"content": sys.stdin.read()}}))' \
      < "$PROMPT_FILE" > "$WORK/gemini.in" || fail_backend "could not build the input"
    # `-p=` with an attached empty value: a bare -p takes the next argument as the prompt.
    ( cd "$GWS" && run_backend "$AGY" --model "$MODEL" --settings "$SETTINGS" --disable-slash-commands \
        --input-format stream-json --output-format stream-json --print-timeout "${GEMINI_REVIEW_TIMEOUT}s" -p= \
        < "$WORK/gemini.in" ) || STATUS=$?
    LEFT=$(ls -A "$GWS")
    [ -z "$LEFT" ] || fail_backend "files appeared in the empty workspace: $LEFT"
    python3 - "$LOG_FILE" "$OUT_FILE" "$MODEL" "$STATUS" "$SCHEMA_FILE" "${SPEC:+spec}" <<'PY' || fail_backend "see above"
import json, re, sys
log, out, model, status = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
spec_mode = sys.argv[6] == "spec"
final, seen, tools, anon = None, None, {}, 0
for ln in open(log, errors="replace").read().splitlines():
    ln = ln.strip()
    if not ln.startswith("{"):
        continue
    try:
        ev = json.loads(ln)
    except ValueError:
        continue
    kind = ev.get("event") if isinstance(ev, dict) else None
    body = ev.get(kind) if isinstance(ev.get(kind) if kind else None, dict) else {}
    if kind == "init":
        seen = body.get("model") or seen
    elif kind == "step_update" and body.get("step_type") == "tool":
        key = body.get("step_index")
        if key is None:
            anon += 1; key = "anon-%d" % anon
        t = tools.setdefault(key, {"name": body.get("tool_name"), "states": set(), "last": None, "error": ""})
        t["states"].add(body.get("state")); t["last"] = body.get("state")
        err = (body.get("tool_info") or {}).get("error") or {}
        if err:
            t["error"] = str(err.get("message", ""))[:200]
    elif kind == "result":
        final = body
def fail(msg):
    sys.stderr.write("review-backend: gemini: " + msg + "\n"); sys.exit(1)
# Only an explicit "Permission denied" counts as blocked; DONE, any other error or an open step may have acted.
ran = [t["name"] for t in tools.values()
       if not (t["last"] == "ERROR" and "DONE" not in t["states"]
               and re.search(r"permission denied for \w+\(.*user-configured deny rule", t["error"], re.I | re.S))]
if ran:
    fail("a tool may have run despite the deny rules: " + ", ".join(map(str, ran)))
if not final:
    fail("no result event (exit %d)" % status)
st = str(final.get("status", "")).upper()
if status != 0 or st not in ("SUCCESS", ""):
    fail("status %s, exit %d: %s" % (st or "-", status, str(final.get("error") or "")[:300]))
if seen != model:
    fail("asked for %s, the run reports %s" % (model, seen or "no model"))
text = (final.get("response") or "").strip()
if spec_mode:
    # Plain text is the answer here, so a refusal must be caught by its wording: a content-filter
    # block comes back as status SUCCESS with prose.
    if re.search(r"blocked by Gemini.s filters", text):
        fail("the answer is a content-filter refusal: " + text[:200])
    if not text:
        fail("the answer is empty")
    open(out, "w").write(text + "\n")
    sys.exit(0)
def extract(t):
    try:
        return json.loads(t)
    except ValueError:
        pass
    m = re.match(r"^[^{`]*```(?:json)?\s*(\{.*\})\s*```\s*$", t, re.S)
    if m:
        return json.loads(m.group(1))
    i, j = t.find("{"), t.rfind("}")
    if i >= 0 and j > i:
        return json.loads(t[i:j + 1])
    raise ValueError("no JSON object")
try:
    review = extract(text)
except ValueError:
    # a content-filter refusal comes back as status SUCCESS with prose
    fail("the answer is not a JSON review" + (" (content filter)" if re.search(r"blocked by Gemini.s filters", text) else "")
         + ": " + text[:200])
if not isinstance(review, dict):
    fail("the answer is not a JSON object")
# the review contract (scripts/review-findings.schema.json): exit 0 only with a schema-shaped review
schema = json.load(open(sys.argv[5]))
def shape(obj, sch, where):
    for k in sch.get("required", []):
        if k not in obj:
            fail("the review lacks %s%s" % (where, k))
    for k, sub in sch.get("properties", {}).items():
        if k not in obj:
            continue
        v, t = obj[k], sub.get("type")
        ok = {"string": isinstance(v, str), "array": isinstance(v, list), "object": isinstance(v, dict),
              "number": isinstance(v, (int, float)) and not isinstance(v, bool),
              "integer": isinstance(v, int) and not isinstance(v, bool), "boolean": isinstance(v, bool)}.get(t, True)
        if not ok:
            fail("%s%s is not a %s" % (where, k, t))
        if "enum" in sub and v not in sub["enum"]:
            fail("%s%s is %r, not one of %s" % (where, k, v, sub["enum"]))
        if t == "array" and isinstance(sub.get("items"), dict) and sub["items"].get("type") == "object":
            for i, item in enumerate(v):
                if not isinstance(item, dict):
                    fail("%s%s[%d] is not an object" % (where, k, i))
                shape(item, sub["items"], "%s%s[%d]." % (where, k, i))
shape(review, schema, "")
open(out, "w").write(json.dumps(review, indent=2) + "\n")
PY
    has_text "$OUT_FILE" || fail_backend "empty result"
    cat "$OUT_FILE" ;;

  custom)
    # Spec mode: REVIEW_SCOPE=spec, REVIEW_SPEC set, REVIEW_SCHEMA empty (plain-text answer wanted).
    CUSTOM_SCHEMA="$SCHEMA_FILE"; [ -n "$SPEC" ] && CUSTOM_SCHEMA=""
    export REVIEW_SCOPE="$SCOPE" REVIEW_BASE="$BASE_SHA" REVIEW_REPO_ROOT="$REPO_ROOT" REVIEW_SCHEMA="$CUSTOM_SCHEMA" \
           REVIEW_FOCUS="$FOCUS" REVIEW_SPEC="$SPEC_ABS"
    ( cd "$REPO_ROOT" && bash -c "$REVIEW_CUSTOM_CMD" < "$PROMPT_FILE" > "$OUT_FILE" 2> "$LOG_FILE" ) || STATUS=$?
    [ $VERBOSE -eq 1 ] && [ -s "$LOG_FILE" ] && cat "$LOG_FILE" >&2
    [ $STATUS -eq 0 ] || fail_backend "exit $STATUS"
    has_text "$OUT_FILE" || fail_backend "printed nothing"
    cat "$OUT_FILE" ;;
esac
exit 0
