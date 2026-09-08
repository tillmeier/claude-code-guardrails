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
  # Empty files mean "hook ran, tree was clean". No cap: one git process hashes all paths. Paths git
  # quotes (quotes, control chars, non-ASCII under core.quotepath) are skipped and therefore land in
  # /critical-review's "scope unverifiable" bucket rather than being mistaken for clean.
  DIRTY_FILE="${MARKER_DIR}/claude-session-start-dirty-${SESSION_ID}"
  BLOBS_FILE="${MARKER_DIR}/claude-session-start-blobs-${SESSION_ID}"
  if : > "$DIRTY_FILE" 2>/dev/null && : > "$BLOBS_FILE" 2>/dev/null; then
    DIRTY_PATHS=$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=all 2>/dev/null \
      | sed -e 's/^...//' -e 's/^.* -> //' | grep -v '^"' | grep .)
    if [ -n "$DIRTY_PATHS" ]; then
      printf '%s\n' "$DIRTY_PATHS" > "$DIRTY_FILE"
      # regular files only — never hash through a symlink (its target may live outside the repo)
      EXISTING=$(printf '%s\n' "$DIRTY_PATHS" | while IFS= read -r p; do [ ! -L "$PROJECT_DIR/$p" ] && [ -f "$PROJECT_DIR/$p" ] && printf '%s\n' "$p"; done)
      if [ -n "$EXISTING" ]; then
        SHAS=$(printf '%s\n' "$EXISTING" | git -C "$PROJECT_DIR" hash-object -w --stdin-paths 2>/dev/null)
        # Only trust the pairing when every path produced a sha; otherwise leave the blobs file empty
        # and every dirty file becomes scope-unverifiable (safe direction).
        if [ "$(printf '%s\n' "$SHAS" | grep -c .)" -eq "$(printf '%s\n' "$EXISTING" | grep -c .)" ]; then
          paste <(printf '%s\n' "$SHAS") <(printf '%s\n' "$EXISTING") > "$BLOBS_FILE" 2>/dev/null || : > "$BLOBS_FILE"
        fi
      fi
    fi
  fi
fi

# GC session files older than 7 days (start markers, dirty/blob snapshots, /critical-review's
# last-review marker and brief). Trailing slash required on macOS — /tmp is a symlink to /private/tmp.
find "${MARKER_DIR}/" -maxdepth 1 \( -name 'claude-session-start-commit-*' -o -name 'claude-session-start-dirty-*' \
  -o -name 'claude-session-start-blobs-*' -o -name 'claude-session-last-review-commit-*' \
  -o -name 'claude-session-last-review-blobs-*' -o -name 'claude-review-brief-*' -o -name 'claude-review-result-*' \) \
  -mtime +7 -delete 2>/dev/null || true
exit 0
