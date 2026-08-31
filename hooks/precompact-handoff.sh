#!/usr/bin/env bash
# PreCompact hook: snapshot volatile work-state to disk before context compaction,
# so nothing load-bearing is silently compressed away. Claude's in-head reasoning
# is gone after compaction; this preserves the concrete work state (branch, dirty
# files, recent commits, active plan) as a durable breadcrumb.
#
# Receives Claude Code hook JSON on stdin: {"session_id": "...", ...}
# Writes to $CLAUDE_HANDOFF_DIR/<session>.md (default ~/.claude/handoffs/ — runtime state, keep it
# out of git).

set -uo pipefail

INPUT=$(cat)
SID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('session_id',''))" 2>/dev/null || echo "")
[ -z "$SID" ] && SID="unknown"

HANDOFF_DIR="${CLAUDE_HANDOFF_DIR:-$HOME/.claude/handoffs}"
mkdir -p "$HANDOFF_DIR"
OUT="${HANDOFF_DIR}/${SID}.md"
TS=$(date '+%Y-%m-%d %H:%M:%S')

{
  echo ""
  echo "## Compaction @ ${TS}"
  ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -n "$ROOT" ]; then
    echo "- repo: ${ROOT} @ $(git -C "$ROOT" branch --show-current 2>/dev/null)"
    echo "- recent commits:"
    git -C "$ROOT" log --oneline -3 2>/dev/null | sed 's/^/    /'
    DIRTY=$(git -C "$ROOT" status --short 2>/dev/null)
    if [ -n "$DIRTY" ]; then
      echo "- uncommitted:"
      echo "$DIRTY" | sed 's/^/    /'
    fi
    PLAN=$(ls -t "$ROOT/.claude/plans/"*.md 2>/dev/null | head -1)
    [ -n "$PLAN" ] && echo "- active plan spec: ${PLAN}"
  else
    echo "- (not in a git repo; cwd: $(pwd))"
  fi
} >> "$OUT"

# GC handoff files older than 14 days (trailing slash: /tmp-style symlink safety not needed here,
# but keep -maxdepth 1 to avoid descending).
find "${HANDOFF_DIR}/" -maxdepth 1 -name '*.md' -mtime +14 -delete 2>/dev/null || true

exit 0
