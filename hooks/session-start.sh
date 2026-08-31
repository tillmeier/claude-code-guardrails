#!/usr/bin/env bash
#
# session-start.sh — Claude Code SessionStart hook.
#
# Records the HEAD commit at session start so `/verify` can scope "what changed this session" to a
# real base instead of guessing from the working tree. Two outputs, because they reach different
# consumers:
#   1. a marker file  ${TMPDIR:-/tmp}/claude-session-start-commit-<session_id>
#      (read by /verify through the ${CLAUDE_SESSION_ID} substitution, and by anything else that
#      only sees the filesystem — this is the reliable path)
#   2. CLAUDE_SESSION_START_COMMIT=<hash> appended to $CLAUDE_ENV_FILE when the harness provides one
#      (env-file export is version-dependent; harmless when absent)
#
# Receives the hook JSON on stdin: {"session_id": "...", "cwd": "...", ...}. Always exits 0 — a
# SessionStart hook that fails must never cost the user their session.

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

if [ -n "$HEAD_COMMIT" ]; then
  printf '%s\n' "$HEAD_COMMIT" > "${MARKER_DIR}/claude-session-start-commit-${SESSION_ID}" 2>/dev/null || true
  if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    echo "CLAUDE_SESSION_START_COMMIT=${HEAD_COMMIT}" >> "$CLAUDE_ENV_FILE" 2>/dev/null || true
  fi
fi

# GC markers older than 7 days. Trailing slash required on macOS — /tmp is a symlink to /private/tmp.
find "${MARKER_DIR}/" -maxdepth 1 -name 'claude-session-start-commit-*' -mtime +7 -delete 2>/dev/null || true
exit 0
