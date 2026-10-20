#!/usr/bin/env bash
# SessionStart hook (matcher "compact"): feed the work state that precompact-handoff.sh wrote right
# before this compaction back into the fresh context as additionalContext. Without it the handoff
# file is write-only — the breadcrumb exists, but the compacted session never sees it.
#
# Receives Claude Code hook JSON on stdin: {"session_id": "...", "source": "compact", ...}
# Reads $CLAUDE_HANDOFF_DIR/<session>.md (default ~/.claude/handoffs/, same rule as the PreCompact
# hook) and injects only its LAST "## Compaction @" section, capped at 2500 characters.
# Always exits 0 and prints nothing unless there is something to inject.

set -uo pipefail

INPUT=$(cat)
PARSED=$(printf '%s' "$INPUT" | python3 -c 'import sys, json
d = json.loads(sys.stdin.read() or "{}")
print(d.get("session_id", "") or "")
print(d.get("source", "") or "")' 2>/dev/null || printf '\n\n')
SID=$(printf '%s\n' "$PARSED" | sed -n 1p)
SOURCE=$(printf '%s\n' "$PARSED" | sed -n 2p)

[ "$SOURCE" = "compact" ] || exit 0          # the matcher already filters; this keeps a mis-wiring silent
[ -n "$SID" ] || exit 0
case "$SID" in *[!A-Za-z0-9._-]*) exit 0 ;; esac   # never build a path from an odd id

FILE="${CLAUDE_HANDOFF_DIR:-$HOME/.claude/handoffs}/${SID}.md"
[ -f "$FILE" ] && [ -s "$FILE" ] || exit 0

python3 - "$FILE" <<'PY' 2>/dev/null || true
import json, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
idx = text.rfind("## Compaction @")
section = (text[idx:] if idx >= 0 else text).strip()[:2500]
if section:
    ctx = ("Work state captured by the PreCompact hook right before this compaction "
           "(branch, recent commits, uncommitted files, active plan). Re-check it before acting:\n\n" + section)
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": ctx}}))
PY
exit 0
