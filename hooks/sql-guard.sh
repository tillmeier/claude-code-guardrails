#!/usr/bin/env bash
#
# sql-guard.sh — Claude Code PreToolUse hook (matcher: Bash).
#
# Blocks the three SQL spellings that destroy data without a WHERE clause when they appear in a Bash
# tool call: DROP TABLE / DROP DATABASE, TRUNCATE [TABLE] <table>, and DELETE FROM <table> with
# nothing after the table name. A habit guard, not a sandbox: it inspects text, so `mysql -e "..."` and a heredoc
# feeding a client are caught, an .sql file on disk is not, and a `grep "DROP TABLE"` is a false
# positive (accepted — write such payloads with Edit/Write; this hook only sees Bash).
#
# Contract: exit 2 blocks the call and shows stderr to Claude as the reason; exit 0 lets it through.
# Never exit 1 here — that is a NON-blocking error and the call proceeds (docs/git-staging-safety.md).
#
# Port notes: the original was a jq one-liner in settings.json. Two changes: (1) a pure-bash
# prefilter so the JSON parse only runs when the payload could possibly match — this hook fires on
# EVERY Bash call; (2) the whole command is inspected. The one-liner piped `jq -r` into `read`,
# which only ever saw the first line of a multi-line command.

set -uo pipefail
INPUT=$(cat)

# FAST PATH (pure bash): bail unless one of the three keywords occurs at all, any case.
case "$INPUT" in
  *[Dd][Rr][Oo][Pp]*|*[Tt][Rr][Uu][Nn][Cc][Aa][Tt][Ee]*|*[Dd][Ee][Ll][Ee][Tt][Ee]*) ;;
  *) exit 0 ;;
esac

python3 - "$INPUT" <<'PY'
import json, re, sys

try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)                      # unparseable input: never block on our own bug
if data.get("tool_name") != "Bash":
    sys.exit(0)
cmd = (data.get("tool_input") or {}).get("command") or ""

# A table name (optionally schema-qualified, backtick- or double-quoted), then the END of the SQL
# statement: line end, `;`, the closing shell quote, or a shell operator (`2>&1`, `| cat`, `)`).
# The old `\S+\s*;?\s*$` swallowed the closing quote into the name and needed the line to end
# there, so `mysql -e "DELETE FROM t" 2>&1` got through.
# Inside a double-quoted shell argument a quoted identifier arrives escaped: `\"User\"`.
# A `|` ends the statement only after whitespace (`… FROM t | cat`). Glued to the name it is a
# regex alternation, `grep -E "x|DELETE FROM t|y"`: 7 false blocks in 30 days of real calls.
# A name may be interpolated: `{t}` in an f-string, `${T}` in the shell, `%s`.
NAME = r'(?:\\"[^"\\\n]+\\"|`[^`\n]+`|"[^"\n]+"|[\w${}%]+)'
TABLE = NAME + r"(?:\." + NAME + r")*"
STMT_END = r"(?:\s*(?=$|[;\"'`&<>)]|\\\")|\s+(?=\|))"
# The bare form (no TABLE keyword) only counts at a statement start — line start, or right after
# `;`, a quote or `(` — so a commit message ending in "fix truncate behavior" is not SQL. Residual,
# accepted: a two-word message such as -m "truncate output" still looks like a statement.
STMT_START = r"(?:^|(?<=[;\"'`(]))\s*"
PATTERN = re.compile(
    r"\bDROP\s+(TABLE|DATABASE)\b"
    r"|\bTRUNCATE\s+TABLE\b"
    r"|" + STMT_START + r"TRUNCATE\s+" + TABLE + STMT_END +   # MySQL/Postgres accept TRUNCATE without TABLE
    r"|\bDELETE\s+FROM\s+" + TABLE + STMT_END,               # nothing after the table name = no WHERE clause
    re.IGNORECASE | re.MULTILINE,
)
m = PATTERN.search(cmd)
if m:
    sys.stderr.write(
        "BLOCKED by sql-guard: dangerous SQL without a WHERE clause.\n\n"
        "  matched: %s\n\n"
        "Add a WHERE clause, or use a safer alternative (rename the table, back it up first).\n"
        "If this text is a payload rather than a command (docs, a grep pattern, a commit message),\n"
        "write it with the Edit/Write tool: this guard only inspects Bash.\n" % m.group(0).strip()
    )
    sys.exit(2)
sys.exit(0)
PY
