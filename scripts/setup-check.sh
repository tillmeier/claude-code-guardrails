#!/usr/bin/env bash
#
# setup-check.sh — what of the guardrails plugin is set up on this machine, and the exact fix for
# the rest. Every ✓ says what it rests on and nothing more ("login not checked", "browser launch
# not tested"). Installs nothing. `claude mcp list` starts each configured MCP server once for a
# health check, as every Claude Code session start does (an npx server may fetch its package then).
#
#   setup-check.sh [--plugin-root <dir>]    # --plugin-root = the plugin is installed and active
#
#   ✓ verified (and what was verified)   ✗ missing or failing → fix   ! conflict → fix   – info
# Exit 0 = git + python3 present and no hook registered twice; 1 = one of those needs fixing;
# 2 = usage. Optional parts that are not set up print ✗ but never fail the run.
# Test hooks: SETUP_CHECK_TIMEOUT (s per external call, default 20), SETUP_CHECK_STUB_DIR (where the
# macOS command-line-tool stubs live, default /usr/bin), GUARDRAILS_CHROME_APP (a Chrome .app).

set -uo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

PLUGIN_ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plugin-root) [ $# -ge 2 ] && [ -n "$2" ] || usage; PLUGIN_ROOT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "setup-check: unknown argument: $1" >&2; exit 2 ;;
  esac
done

SD=$(cd "$(dirname "$0")" && pwd)
ROOT="${PLUGIN_ROOT:-$(dirname "$SD")}"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
LIMIT="${SETUP_CHECK_TIMEOUT:-20}"
STUB_DIR="${SETUP_CHECK_STUB_DIR:-/usr/bin}"
ADD_ISOLATED='claude mcp add -s user chrome-devtools -- npx -y chrome-devtools-mcp@1.10.1 --isolated --screenshotMaxWidth 1280 --screenshotMaxHeight 2000'
ADD_ATTACHED='claude mcp add -s user chrome-live -- npx -y chrome-devtools-mcp@1.10.1 --autoConnect --redactNetworkHeaders --screenshotMaxWidth 1280 --screenshotMaxHeight 2000'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/setup-check.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
FAILS=0

# ── output ────────────────────────────────────────────────────────────────────────────────────────
fixes() {   # $1 = fix text, may hold several lines; first gets the arrow
  local first=1 l
  while IFS= read -r l; do
    if [ $first -eq 1 ]; then printf '      → %s\n' "$l"; first=0; else printf '        %s\n' "$l"; fi
  done <<EOF
$1
EOF
}
ok()   { printf '  ✓ %s\n' "$1"; }
miss() { printf '  ✗ %s\n' "$1"; [ -z "${2:-}" ] || fixes "$2"; }
need() { miss "$@"; FAILS=$((FAILS+1)); }
dup()  { printf '  ! %s\n' "$1"; [ -z "${2:-}" ] || fixes "$2"; FAILS=$((FAILS+1)); }
info() { printf '  – %s\n' "$1"; [ -z "${2:-}" ] || fixes "$2"; }
first_line() { sed -n '/./{p;q;}' "$1" 2>/dev/null | cut -c1-200; }

# run_bounded <name> <cmd...>: stdout → $TMP/<name>, stderr → $TMP/<name>.err. Files, not a pipe, so
# a grandchild that inherits them cannot keep a read open. TERM after LIMIT s, KILL 2 s later,
# always by PID. Returns the command's status, or 124 on timeout.
run_bounded() {
  local out="$TMP/$1" pid i=0 j=0; shift
  "$@" >"$out" 2>"$out.err" </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ $i -ge $((LIMIT * 10)) ]; then
      kill -TERM "$pid" 2>/dev/null
      while kill -0 "$pid" 2>/dev/null && [ $j -lt 20 ]; do sleep 0.1; j=$((j+1)); done
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.1; i=$((i+1))
  done
  wait "$pid"
}

UNAME=$(uname -s 2>/dev/null || echo unknown)
HAVE_PY=0; HAVE_CLAUDE=0
command -v claude >/dev/null 2>&1 && HAVE_CLAUDE=1

# ── 1. required: git, python3 ────────────────────────────────────────────────────────────────────
CLT_MISSING=0
if [ "$UNAME" = Darwin ] && ! xcode-select -p >/dev/null 2>&1; then CLT_MISSING=1; fi
REQ_OUT=""
for tool in git python3; do
  p=$(command -v "$tool" 2>/dev/null || true)
  if [ -z "$p" ]; then
    if [ "$UNAME" = Darwin ]; then fix="xcode-select --install"; else fix="install $tool with your package manager"; fi
    REQ_OUT="${REQ_OUT}need|$tool: not on PATH|$fix
"; continue
  fi
  if [ $CLT_MISSING -eq 1 ] && [ "$(dirname "$p")" = "$STUB_DIR" ]; then
    # The stub opens an installer dialog when run — do not run it.
    REQ_OUT="${REQ_OUT}need|$tool: $p is the macOS stub, Xcode Command Line Tools are not installed|xcode-select --install
"; continue
  fi
  if run_bounded "ver-$tool" "$p" --version; then
    REQ_OUT="${REQ_OUT}ok|$tool: $(first_line "$TMP/ver-$tool")|
"
    [ "$tool" = python3 ] && HAVE_PY=1
  else
    REQ_OUT="${REQ_OUT}need|$tool: $p --version failed|reinstall $tool
"
  fi
done

py() { python3 -I -c "$@" 2>/dev/null; }   # only called when HAVE_PY=1

# Can two hook matchers select the same tool or source? Plain names and A|B lists are compared by
# name. "*", empty or anything regex-like counts as overlapping, so a real duplicate is never missed.
matchers_overlap() {
  local m a b IFS='|'
  for m in "$1" "$2"; do
    case "$m" in ''|'*') return 0 ;; esac
    [ -z "${m//[A-Za-z0-9_|]/}" ] || return 0
  done
  for a in $1; do
    for b in $2; do [ "$a" = "$b" ] && return 0; done
  done
  return 1
}

VERSION="?"
if [ $HAVE_PY -eq 1 ]; then
  VERSION=$(py 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/.claude-plugin/plugin.json") || VERSION="?"
fi

# Plugin list once: is the Codex plugin / guardrails itself enabled?
PL_STATE="no-claude"; CODEX_ON=0; GUARD_ON=0
if [ $HAVE_CLAUDE -eq 1 ]; then
  run_bounded plugins claude plugin list --json; rc=$?
  if [ $rc -eq 124 ]; then PL_STATE="timeout"
  elif [ $rc -ne 0 ]; then PL_STATE="failed:$rc"
  elif [ $HAVE_PY -eq 0 ]; then PL_STATE="no-python"
  else
    r=$(py '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    assert isinstance(d, list) and all(isinstance(e, dict) and isinstance(e.get("id"), str) and isinstance(e.get("enabled"), bool) for e in d)
except Exception:
    print("bad"); sys.exit()
on = lambda p: int(any(e["id"].startswith(p) and e["enabled"] for e in d))
print("ok %d %d" % (on("codex@"), on("guardrails@")))' "$TMP/plugins")
    case "$r" in
      "ok "*) PL_STATE="ok"; set -- $r; CODEX_ON=$2; GUARD_ON=$3 ;;
      *) PL_STATE="bad" ;;
    esac
  fi
fi
PLUGIN_ON=0
if [ -n "$PLUGIN_ROOT" ] || [ "$GUARD_ON" = 1 ]; then PLUGIN_ON=1; fi

if [ $PLUGIN_ON -eq 1 ]; then MODE="plugin active"; else MODE="plugin not active, checkout $ROOT"; fi
echo "guardrails $VERSION setup check · $UNAME · $MODE · config $CFG"
echo
echo "Required"
while IFS='|' read -r kind msg fix; do
  [ -n "$kind" ] || continue
  if [ "$kind" = ok ]; then ok "$msg"; else need "$msg" "$fix"; fi
done <<EOF
$REQ_OUT
EOF

# ── 2. reviewer and Codex plugin ─────────────────────────────────────────────────────────────────
echo
echo "Reviewer and plugins"
if [ -f "$SD/review-backend.sh" ]; then
  run_bounded detect bash "$SD/review-backend.sh" --detect; rc=$?
  if [ $rc -eq 0 ]; then
    read -r RB_BACKEND RB_MODEL < "$TMP/detect" || true
    case "${RB_BACKEND:-}" in
      codex)  ok "/critical-review reviewer: codex ${RB_MODEL:-} (codex login checked)" ;;
      claude) ok "/critical-review reviewer: claude CLI on PATH${RB_MODEL:+, $RB_MODEL} (login not checked)" ;;
      custom) ok "/critical-review reviewer: custom command configured (not run)" ;;
      *)      miss "/critical-review reviewer: unexpected answer from review-backend.sh --detect: $(first_line "$TMP/detect")" ;;
    esac
  elif [ $rc -eq 3 ]; then
    miss "/critical-review reviewer: none usable — $(sed -n 's/^review-backend: //p' "$TMP/detect.err" | head -1 | cut -c1-200)" \
      "npm i -g @openai/codex && codex login   (or install the Claude Code CLI)"
  elif [ $rc -eq 124 ]; then
    miss "/critical-review reviewer: review-backend.sh --detect timed out after ${LIMIT}s"
  else
    miss "/critical-review reviewer: review-backend.sh --detect exited $rc: $(first_line "$TMP/detect.err")"
  fi
else
  miss "/critical-review reviewer: $SD/review-backend.sh not found"
fi

case "$PL_STATE" in
  ok) if [ "$CODEX_ON" = 1 ]; then ok "Codex plugin for /plan --codex: enabled"
      else miss "Codex plugin for /plan --codex: not installed (/plan works without it)" \
        "/plugin marketplace add openai/codex-plugin-cc
then /plugin install codex@openai-codex   (type both in Claude Code)"; fi ;;
  no-claude) info "Codex plugin: can't check without the claude CLI on PATH" "/plugin in Claude Code" ;;
  timeout)   miss "Codex plugin: claude plugin list timed out after ${LIMIT}s" ;;
  failed:*)  miss "Codex plugin: claude plugin list exited ${PL_STATE#failed:}: $(first_line "$TMP/plugins.err")" ;;
  no-python) info "Codex plugin: can't parse claude plugin list without python3" ;;
  *)         info "Codex plugin: claude plugin list printed an unknown format, can't check" "/plugin in Claude Code" ;;
esac

# ── 3. browser: Node, Chrome, MCP servers ────────────────────────────────────────────────────────
echo
echo "Browser (the browser-mcp skill and /verify --ui)"
if p=$(command -v node 2>/dev/null) && [ -n "$p" ]; then
  if run_bounded node "$p" --version; then
    v=$(first_line "$TMP/node"); n=${v#v}; maj=${n%%.*}; rest=${n#*.}; min=${rest%%.*}
    case "$maj$min" in *[!0-9]*|"") miss "node: unreadable version '$v'" ;; *)
      if { [ "$maj" -eq 20 ] && [ "$min" -ge 19 ]; } || { [ "$maj" -eq 22 ] && [ "$min" -ge 12 ]; } || [ "$maj" -ge 23 ]; then
        ok "node $v (chrome-devtools-mcp needs ^20.19, ^22.12 or ≥23)"
      else NODE_BAD="node $v is outside chrome-devtools-mcp's range ^20.19, ^22.12 or ≥23"; fi ;;
    esac
  else NODE_BAD="node: $p --version failed"; fi
else NODE_BAD="node: not on PATH (needed to run chrome-devtools-mcp)"; fi
if [ -n "${NODE_BAD:-}" ]; then
  if command -v brew >/dev/null 2>&1; then miss "$NODE_BAD" "brew install node"
  else miss "$NODE_BAD" "install Node 22.12 or newer from https://nodejs.org"; fi
fi

CHROME_MAJOR=""
if [ "$UNAME" = Darwin ]; then
  for app in "${GUARDRAILS_CHROME_APP:-}" "/Applications/Google Chrome.app" "$HOME/Applications/Google Chrome.app"; do
    [ -n "$app" ] && [ -f "$app/Contents/Info.plist" ] || continue
    if [ $HAVE_PY -eq 0 ]; then info "Chrome: found $app, can't read its version without python3"; CHROME_MAJOR="?"; break; fi
    cv=$(py 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleShortVersionString"])' "$app/Contents/Info.plist") || cv=""
    if [ -n "$cv" ]; then ok "Chrome $cv ($app)"; CHROME_MAJOR=${cv%%.*}; else info "Chrome: found $app, version unreadable"; CHROME_MAJOR="?"; fi
    break
  done
else
  for b in google-chrome google-chrome-stable chromium chromium-browser; do
    bp=$(command -v "$b" 2>/dev/null) || continue
    if run_bounded chrome "$bp" --version; then
      cv=$(grep -oE '[0-9]+(\.[0-9]+)+' "$TMP/chrome" | head -1)
      if [ -n "$cv" ]; then ok "Chrome $cv ($bp)"; CHROME_MAJOR=${cv%%.*}; else info "Chrome: $bp printed no version"; CHROME_MAJOR="?"; fi
    else info "Chrome: $bp --version failed"; CHROME_MAJOR="?"; fi
    break
  done
fi
[ -n "$CHROME_MAJOR" ] || miss "Chrome: not found" "install Google Chrome from https://www.google.com/chrome/"

if [ $HAVE_CLAUDE -eq 0 ]; then
  info "browser MCP servers: can't list without the claude CLI on PATH" "/mcp in Claude Code"
else
  run_bounded mcp claude mcp list; rc=$?
  if [ $rc -eq 124 ]; then
    miss "browser MCP servers: claude mcp list timed out after ${LIMIT}s" "/mcp in Claude Code"
  elif [ $rc -ne 0 ]; then
    miss "browser MCP servers: claude mcp list exited $rc: $(first_line "$TMP/mcp.err")"
  else
    N_LINES=0; N_CHROME=0; EMPTY=0
    grep -q '^No MCP servers configured' "$TMP/mcp" && EMPTY=1
    while IFS= read -r line; do
      case "$line" in *": "*" - "*) ;; *) continue ;; esac
      N_LINES=$((N_LINES+1))
      case "$line" in *chrome-devtools-mcp*) ;; *) continue ;; esac
      N_CHROME=$((N_CHROME+1))
      name=${line%%: *}; rest=${line#*: }; status=${rest##* - }; cmd=${rest% - *}
      AUTO=0
      case " $cmd " in
        *" --autoConnect "*) kind="attached to your running Chrome, --autoConnect"; AUTO=1 ;;
        *" --browserUrl "*|*" -u "*|*" --wsEndpoint "*|*" -w "*) kind="attached to a debuggable Chrome by URL" ;;
        *" --isolated "*) kind="isolated profile" ;;
        *) kind="own persistent profile" ;;
      esac
      case "$status" in
        "✔"*|Connected*) ok "browser server '$name' ($kind): MCP handshake ok, browser launch not tested" ;;
        *) miss "browser server '$name' ($kind): $status" "/mcp in Claude Code shows why" ;;
      esac
      if [ $AUTO -eq 1 ]; then
        case "$CHROME_MAJOR" in
          ""|"?") info "'$name' uses --autoConnect, which needs Chrome 144+; local Chrome version unknown" ;;
          *) [ "$CHROME_MAJOR" -ge 144 ] 2>/dev/null || miss "'$name' uses --autoConnect, which needs Chrome 144+ (found $CHROME_MAJOR)" "update Google Chrome" ;;
        esac
      fi
    done < "$TMP/mcp"
    if [ $N_CHROME -eq 0 ] && { [ $EMPTY -eq 1 ] || [ $N_LINES -gt 0 ]; }; then
      miss "browser MCP servers: no chrome-devtools-mcp server configured" "$ADD_ISOLATED
optional, acts with your logins (Chrome 144+, enable chrome://inspect/#remote-debugging):
$ADD_ATTACHED
then restart Claude Code"
    elif [ $N_LINES -eq 0 ]; then
      info "browser MCP servers: claude mcp list printed nothing this check recognizes" "/mcp in Claude Code"
    fi
  fi
fi

# ── 4. settings: output style, hooks, overlap ────────────────────────────────────────────────────
echo
echo "Settings and hooks (user settings: $CFG/settings.json; project/local settings can override)"
SETTINGS="$CFG/settings.json"
if [ $HAVE_PY -eq 0 ]; then
  info "output style and hooks: can't read settings without python3"
else
  st=$(py 'import json,sys; print(json.load(open(sys.argv[1])).get("outputStyle") or "(not set)")' "$SETTINGS") || st="(no readable settings.json)"
  case "$st" in
    Terse|*:Terse) ok "output style in user settings: $st" ;;
    *) info "output style in user settings: $st" "/output-style Terse   (optional, type it in Claude Code)" ;;
  esac

  # Plugin hooks (event, matcher, script stem) from hooks.json; user-settings hooks (event, matcher,
  # command).
  py '
import json, re, sys
for ev, groups in json.load(open(sys.argv[1]))["hooks"].items():
    for g in groups:
        for h in g.get("hooks", []):
            m = re.search(r"hooks/([A-Za-z0-9_-]+)\.sh", h.get("command", ""))
            if m: print(ev + "\t" + (g.get("matcher") or "*") + "\t" + m.group(1))' "$ROOT/hooks/hooks.json" > "$TMP/plugin-hooks"
  py '
import json, sys
try: hooks = json.load(open(sys.argv[1])).get("hooks") or {}
except Exception: sys.exit()
for ev, groups in hooks.items():
    for g in groups if isinstance(groups, list) else []:
        for h in g.get("hooks", []) if isinstance(g, dict) else []:
            c = (h.get("command") or "").replace("\t", " ").replace("\n", " ")
            print(ev + "\t" + (g.get("matcher") or "*") + "\t" + c)' "$SETTINGS" > "$TMP/user-hooks"

  WIRED=""; UNWIRED=""
  while IFS="$(printf '\t')" read -r pev pmatch stem; do
    [ -n "$stem" ] || continue
    hit=0; hit_m=""; hit_c=""; other_m=""
    while IFS="$(printf '\t')" read -r uev umatch ucmd; do
      [ "$uev" = "$pev" ] || continue
      case "$ucmd" in *"$stem"*) ;; *) continue ;; esac
      if matchers_overlap "$pmatch" "$umatch"; then hit=1; hit_m="$umatch"; hit_c="$ucmd"; break; fi
      [ -n "$other_m" ] || other_m="$umatch"
    done < "$TMP/user-hooks"
    if [ $PLUGIN_ON -eq 1 ] && [ $hit -eq 1 ]; then
      dup "hook runs twice: $stem ($pev) is in the plugin AND in user settings (matcher $hit_m: $(printf '%s' "$hit_c" | cut -c1-120))" \
        "remove that entry from $SETTINGS, or disable the plugin"
    elif [ $PLUGIN_ON -eq 1 ] && [ -n "$other_m" ]; then
      info "same script on another matcher: $stem ($pev) is matcher $pmatch in the plugin, $other_m in user settings; not a duplicate"
    elif [ $hit -eq 1 ] || [ -n "$other_m" ]; then WIRED="$WIRED $stem"
    else UNWIRED="$UNWIRED $stem"; fi
  done < "$TMP/plugin-hooks"
  if [ $PLUGIN_ON -eq 0 ]; then
    info "hooks wired in user settings:${WIRED:- none}" "${UNWIRED:+not wired:$UNWIRED (README, 'By hand')}"
  fi
fi

if [ $PLUGIN_ON -eq 1 ]; then
  OVER=""
  for f in "$ROOT"/commands/*.md; do
    [ -f "$f" ] || continue; n=$(basename "$f" .md)
    [ -f "$CFG/commands/$n.md" ] && OVER="$OVER $n"
  done
  [ -z "$OVER" ] || info "commands in both $CFG/commands and the plugin:$OVER (they coexist as /<name> and /guardrails:<name>; nothing runs twice)"
  for d in "$ROOT"/skills/*/; do
    [ -d "$d" ] || continue; n=$(basename "$d")
    [ -d "$CFG/skills/$n" ] && info "skill $n exists in $CFG/skills and in the plugin (both load; their descriptions compete)"
  done
fi

echo
if [ $FAILS -eq 0 ]; then echo "Nothing required is missing and no hook runs twice."
else echo "$FAILS item(s) to fix (✗ under Required, or !)."; fi
[ $FAILS -eq 0 ]
