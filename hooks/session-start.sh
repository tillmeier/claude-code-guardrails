#!/usr/bin/env bash
#
# session-start.sh — Claude Code SessionStart hook.
#
# Records the HEAD commit at session start so `/verify` and `/critical-review` can scope "what changed
# this session" to a real base instead of guessing from the working tree. Two outputs, because they
# reach different consumers:
#   1. a marker file  ${TMPDIR:-/tmp}/claude-session-start-commit-<session_id>
#      (read by /verify through the ${CLAUDE_SESSION_ID} substitution, and by anything else that
#      only sees the filesystem — this is the reliable path)
#   2. CLAUDE_SESSION_START_COMMIT=<hash> appended to $CLAUDE_ENV_FILE when the harness provides one
#      (env-file export is version-dependent; harmless when absent)
#
# Receives the hook JSON on stdin: {"session_id": "...", "cwd": "...", "source": "startup|resume|clear|compact", ...}.
# SessionStart also fires after a compaction and on resume, with the SAME session id — so the files
# are written once per session id and never overwritten: a mid-session re-fire must not move the
# baseline to "now", which would hide this session's earlier edits from /verify and /critical-review.
# Always exits 0 — a SessionStart hook that fails must never cost the user their session.

set -uo pipefail

MARKER_DIR="${TMPDIR:-/tmp}"
NL=$'\n'

# Writes the dirty list ($2) and the blob pairs ($3) for repo $1. Non-zero = no trustworthy list
# (the caller removes both files). A failed hash only empties the blobs file: the list stays complete
# and every dirty path becomes LIKELY (not-snapshotted), the safe direction.
snapshot_dirty() {
  local raw rec p skip=0 paths="" existing shas
  raw=$(mktemp "${MARKER_DIR%/}/claude-snapshot.XXXXXX" 2>/dev/null) || return 1
  if ! git -C "$1" status --porcelain -z --untracked-files=all > "$raw" 2>/dev/null; then
    rm -f "$raw"; return 1
  fi
  # -z records: "XY path"; a rename or copy is followed by one more record, the old path (man git-status).
  while IFS= read -r -d '' rec; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    p=${rec:3}
    case "${rec:0:2}" in *R*|*C*) skip=1 ;; esac
    case "$p" in ""|*"$NL"*|*$'\t'*) rm -f "$raw"; return 1 ;; esac   # the files are line- and TAB-separated
    paths="${paths}${p}${NL}"
  done < "$raw"
  rm -f "$raw"
  printf '%s' "$paths" > "$2" 2>/dev/null && : > "$3" 2>/dev/null || return 1
  # regular files only — never hash through a symlink (its target may live outside the repo)
  existing=$(printf '%s' "$paths" | while IFS= read -r p; do [ ! -L "$1/$p" ] && [ -f "$1/$p" ] && printf '%s\n' "$p"; done)
  [ -n "$existing" ] || return 0
  # "./" prefix: --stdin-paths C-unquotes a line that starts with a double quote, so a file named
  # "x.txt" (quotes included) would be hashed as x.txt — a wrong blob with matching counts.
  shas=$(printf '%s\n' "$existing" | sed 's#^#./#' | git -C "$1" hash-object -w --stdin-paths 2>/dev/null) || shas=""
  # Only trust the pairing when every path produced a sha; otherwise the blobs file stays empty.
  if [ "$(printf '%s\n' "$shas" | grep -c .)" -eq "$(printf '%s\n' "$existing" | grep -c .)" ]; then
    paste <(printf '%s\n' "$shas") <(printf '%s\n' "$existing") > "$3" 2>/dev/null || : > "$3"
  fi
  return 0
}

INPUT=$(cat)

PARSED=$(printf '%s' "$INPUT" | python3 -c 'import sys, json
d = json.loads(sys.stdin.read() or "{}")
print(d.get("session_id", "") or "")
print(d.get("cwd", "") or "")' 2>/dev/null || printf '\n\n')
SESSION_ID=$(printf '%s\n' "$PARSED" | sed -n 1p)
SESSION_CWD=$(printf '%s\n' "$PARSED" | sed -n 2p)

[ -z "$SESSION_ID" ] && exit 0
case "$SESSION_ID" in *[!A-Za-z0-9._-]*) exit 0 ;; esac   # never build a path from an odd id

[ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ] && cd "$SESSION_CWD" 2>/dev/null

PROJECT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
HEAD_COMMIT=""
if [ -n "$PROJECT_DIR" ]; then
  HEAD_COMMIT=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "")
fi

COMMIT_FILE="${MARKER_DIR}/claude-session-start-commit-${SESSION_ID}"
if [ -s "$COMMIT_FILE" ]; then
  # Re-fire (compact / resume): keep the recorded baseline, just re-export it for the new process.
  if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    echo "CLAUDE_SESSION_START_COMMIT=$(cat "$COMMIT_FILE")" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
  fi
  HEAD_COMMIT=""
fi

if [ -n "$HEAD_COMMIT" ]; then
  printf '%s\n' "$HEAD_COMMIT" > "$COMMIT_FILE" 2>/dev/null || true
  if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    echo "CLAUDE_SESSION_START_COMMIT=${HEAD_COMMIT}" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
  fi
  # Files already modified or untracked when the session began, plus a blob of each one's content,
  # so /critical-review can diff "the file at session start" against "the file now" and review only
  # what THIS session added to a file that was dirty before it — instead of dropping the file.
  #   claude-session-start-dirty-<sid>   one repo-root-relative path per line (renames: the new path)
  #   claude-session-start-blobs-<sid>   <blob sha>TAB<path> for every dirty path that is a regular file;
  #                                      hash-object -w so `git diff <sha> <sha>` resolves later
  # Empty files mean "hook ran, tree was clean". No cap: one git process hashes all paths.
  # The dirty list must be COMPLETE: scope-delta.sh calls any path missing from it FULL, i.e. this
  # session's work. So the list is written only when `git status` succeeded and every path fits the
  # line format; otherwise neither file exists, scope-delta exits 2 and /critical-review falls back
  # to the gitStatus list. `-z` gives paths verbatim (no C-quoting of non-ASCII, quotes, backslashes).
  DIRTY_FILE="${MARKER_DIR}/claude-session-start-dirty-${SESSION_ID}"
  BLOBS_FILE="${MARKER_DIR}/claude-session-start-blobs-${SESSION_ID}"
  snapshot_dirty "$PROJECT_DIR" "$DIRTY_FILE" "$BLOBS_FILE" || rm -f "$DIRTY_FILE" "$BLOBS_FILE" 2>/dev/null
fi

# GC session files older than 7 days (start markers, dirty/blob snapshots, /critical-review's
# last-review marker, brief and dirty-list fallback). Trailing slash required on macOS — /tmp is a symlink to /private/tmp.
find "${MARKER_DIR}/" -maxdepth 1 \( -name 'claude-session-start-commit-*' -o -name 'claude-session-start-dirty-*' \
  -o -name 'claude-session-start-blobs-*' -o -name 'claude-session-last-review-commit-*' \
  -o -name 'claude-session-last-review-dirty-*' \
  -o -name 'claude-session-last-review-blobs-*' -o -name 'claude-review-brief-*' -o -name 'claude-review-result-*' \
  -o -name 'claude-review-dirty-fallback-*' -o -name 'claude-snapshot.*' \) \
  -mtime +7 -delete 2>/dev/null || true
exit 0
