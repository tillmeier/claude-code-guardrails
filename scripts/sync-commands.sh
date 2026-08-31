#!/usr/bin/env bash
#
# sync-commands.sh — push selected ~/.claude/commands/*.md files, selected
# ~/.claude/skills/<name>/ directories AND ~/.claude/output-styles/*.md to remote servers, and
# audit the fleet for drift (--check).
#
# Usage:
#   sync-commands.sh                   # sync all configured commands + skills to all reachable servers
#   sync-commands.sh --check           # audit only: MISSING / DRIFT / unmanaged files; exit 2 if anything is off
#   sync-commands.sh --dry-run         # show what would be sent without sending
#   sync-commands.sh --only=plan,verify
#   sync-commands.sh --only=my-skill   # works for skills too (matched as directory name)
#   sync-commands.sh --only=helper.py  # works for scripts
#   sync-commands.sh --only=terse      # works for output styles too
#   sync-commands.sh --conf=/path/to/sync-commands.conf
#   sync-commands.sh --help
#
# Config (sync-commands.conf next to this script — start from sync-commands.conf.example):
#   - SERVERS array: SSH-config aliases / hostnames
#   - COMMANDS array: filenames at $LOCAL_COMMANDS_DIR/<name>.md → $REMOTE_COMMANDS_DIR/<name>.md
#   - SKILLS array: directory names at $LOCAL_SKILLS_DIR/<name>/ → $REMOTE_SKILLS_DIR/<name>/
#   - SCRIPTS array: filenames at $LOCAL_SCRIPTS_DIR/<name> → $REMOTE_SCRIPTS_DIR/<name>
#                    (helpers that commands invoke via !`...`-syntax — must travel together)
#   - OUTPUT_STYLES array: filenames at $LOCAL_OUTPUT_STYLES_DIR/<name>.md → $REMOTE_OUTPUT_STYLES_DIR/<name>.md
#   - ACTIVE_STYLE_NAME/FILE: the one style that also gets ACTIVATED remotely by writing
#                    "outputStyle" into $REMOTE_CLAUDE_DIR/settings.json. Set ACTIVE_STYLE_NAME=""
#                    to transfer style files without switching any server over.
#   - LOCAL_CLAUDE_DIR / REMOTE_CLAUDE_DIR: the ~/.claude trees on each side. LOCAL_CLAUDE_DIR can
#                    point at a checkout of this repo — its commands/ and output-styles/ match.
#
# Notes:
# - Pre-flight SSH check (3s timeout, BatchMode) skips unreachable hosts cleanly.
# - "Unreachable" usually means: DNS doesn't resolve OR host key not yet accepted
#   (run `ssh <host>` manually once to accept the host key).
# - Skills sync the entire directory (e.g. SKILL.md + examples.md). No --delete by
#   design — files only on remote stay untouched, so per-server tweaks are safe.
# - Scripts sync single files with rsync -a, which preserves the executable bit.
# - Output styles: copying the .md file alone changes NOTHING — a style is inert until
#   "outputStyle": "<name>" is set in settings.json. That activation is a real behavior
#   change on the host, so it is backed up, idempotent, reported per server, and skipped
#   entirely under --dry-run. The remote value is compared in --check.
# - The name a style is activated under comes from its frontmatter `name:` field (falling
#   back to the file name), NOT from the file name itself — hence two config values.

set -uo pipefail

# === CONFIG ===
# Everything site-specific (hosts, which files, remote paths) lives in sync-commands.conf next to
# this script, or the file named by $SYNC_COMMANDS_CONF / --conf=<path>. It is plain bash and is
# sourced, so arrays and comments work. Start from sync-commands.conf.example. Keep the real conf
# out of version control — it names your hosts.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${SYNC_COMMANDS_CONF:-$SCRIPT_DIR/sync-commands.conf}"
for arg in "$@"; do case "$arg" in --conf=*) CONF="${arg#--conf=}" ;; esac; done

# Defaults; the conf overrides any of them.
SERVERS=()
COMMANDS=()
SKILLS=()
SCRIPTS=()
OUTPUT_STYLES=()
# Files that legitimately live on the servers without being managed here. --check treats these as
# expected instead of warning about them forever — a warning that always fires teaches you to ignore
# warnings, which is how year-old legacy forks survived on 9 hosts unnoticed. Keep it EMPTY unless
# you can write the reason next to the entry: an entry here is a warning you will never see again.
ALLOWED_UNMANAGED=()
# The one style that also gets ACTIVATED remotely ("outputStyle" in the remote settings.json).
# Must match the style's frontmatter `name:` — terse.md declares `name: Terse`. Empty = ship the
# style files, switch nothing.
ACTIVE_STYLE_NAME=""
ACTIVE_STYLE_FILE=""
LOCAL_CLAUDE_DIR="$HOME/.claude"
REMOTE_CLAUDE_DIR="/root/.claude"
SSH_TIMEOUT=3

# The conf is sourced after the flag loop below, so --help works without one.
load_conf() {
  if [[ ! -f "$CONF" ]]; then
    echo "No config at $CONF — copy sync-commands.conf.example to sync-commands.conf and fill in SERVERS/COMMANDS." >&2
    exit 1
  fi
  # shellcheck source=sync-commands.conf.example
  . "$CONF"
  if [[ -z "${SERVERS[*]:-}" ]]; then
    echo "SERVERS is empty in $CONF — nothing to sync to." >&2
    exit 1
  fi
  LOCAL_COMMANDS_DIR="$LOCAL_CLAUDE_DIR/commands"
  LOCAL_SKILLS_DIR="$LOCAL_CLAUDE_DIR/skills"
  LOCAL_SCRIPTS_DIR="$LOCAL_CLAUDE_DIR/scripts"
  LOCAL_OUTPUT_STYLES_DIR="$LOCAL_CLAUDE_DIR/output-styles"
  REMOTE_COMMANDS_DIR="$REMOTE_CLAUDE_DIR/commands"
  REMOTE_SKILLS_DIR="$REMOTE_CLAUDE_DIR/skills"
  REMOTE_SCRIPTS_DIR="$REMOTE_CLAUDE_DIR/scripts"
  REMOTE_OUTPUT_STYLES_DIR="$REMOTE_CLAUDE_DIR/output-styles"
  REMOTE_SETTINGS="$REMOTE_CLAUDE_DIR/settings.json"
  REMOTE_BACKUP_DIR="$REMOTE_CLAUDE_DIR/backups"
}

# === FLAGS ===
DRY_RUN=0
CHECK=0
NO_ACTIVATE=0
ONLY=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [--check] [--dry-run] [--only=name1,name2,...] [--conf=<file>]

  --check, -c            AUDIT ONLY: compare every configured file's content against the servers
                         (POSIX cksum) and list MISSING / DRIFT plus any unmanaged files sitting in
                         the remote commands dir. Transfers nothing. Exit 2 if anything is off.
  --dry-run, -n          Show what would be synced without actually sending.
  --only=name1,name2     Only sync the named entries. Match against COMMANDS (with or without .md
                         suffix), SKILLS (directory name), SCRIPTS and OUTPUT_STYLES.
                         Composes with --check.
  --no-activate          Transfer output-style files but do NOT touch any server's
                         settings.json (no "outputStyle" switch).
  --conf=<file>          Config file (default: sync-commands.conf next to this script, or
                         \$SYNC_COMMANDS_CONF). See sync-commands.conf.example.
  -h, --help             Show this help.

Site config (SERVERS, COMMANDS, SKILLS, SCRIPTS, OUTPUT_STYLES, remote dir) lives in the conf
file, not in this script.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    --check|-c)   CHECK=1 ;;
    --no-activate) NO_ACTIVATE=1 ;;
    --conf=*)     ;;   # consumed above, before the config was sourced
    --only=*)     ONLY="${arg#--only=}" ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "Unknown arg: $arg" >&2; usage; exit 1 ;;
  esac
done

load_conf

# === FILTER COMMANDS + SKILLS + SCRIPTS BY --only ===
if [[ -n "$ONLY" ]]; then
  IFS=',' read -ra REQUESTED <<< "$ONLY"
  FILTERED_COMMANDS=()
  FILTERED_SKILLS=()
  FILTERED_SCRIPTS=()
  FILTERED_STYLES=()
  for item in "${REQUESTED[@]}"; do
    item_stripped="${item%.md}"
    cmd_file="${item_stripped}.md"
    if [[ -f "$LOCAL_COMMANDS_DIR/$cmd_file" ]]; then
      FILTERED_COMMANDS+=("$cmd_file")
      continue
    fi
    if [[ -d "$LOCAL_SKILLS_DIR/$item_stripped" ]]; then
      FILTERED_SKILLS+=("$item_stripped")
      continue
    fi
    # Scripts may be requested with or without their extension
    if [[ -f "$LOCAL_SCRIPTS_DIR/$item" ]]; then
      FILTERED_SCRIPTS+=("$item")
      continue
    fi
    # Try common script extensions if user passed bare name
    for ext in .py .sh; do
      if [[ -f "$LOCAL_SCRIPTS_DIR/${item_stripped}${ext}" ]]; then
        FILTERED_SCRIPTS+=("${item_stripped}${ext}")
        continue 2
      fi
    done
    # Output styles last: a command and a style could share a base name, and the command
    # is the older, more likely intent. Rename one of them if that ever collides for real.
    if [[ -f "$LOCAL_OUTPUT_STYLES_DIR/$cmd_file" ]]; then
      FILTERED_STYLES+=("$cmd_file")
      continue
    fi
    echo "  ✗ '$item' not found as command, skill, script, or output style — skipping" >&2
  done
  COMMANDS=("${FILTERED_COMMANDS[@]:-}")
  SKILLS=("${FILTERED_SKILLS[@]:-}")
  SCRIPTS=("${FILTERED_SCRIPTS[@]:-}")
  OUTPUT_STYLES=("${FILTERED_STYLES[@]:-}")
fi

# Bash 3-friendly empty-set tests
HAS_COMMANDS=0
HAS_SKILLS=0
HAS_SCRIPTS=0
HAS_STYLES=0
[[ -n "${COMMANDS[*]:-}" ]] && HAS_COMMANDS=1
[[ -n "${SKILLS[*]:-}" ]] && HAS_SKILLS=1
[[ -n "${SCRIPTS[*]:-}" ]] && HAS_SCRIPTS=1
[[ -n "${OUTPUT_STYLES[*]:-}" ]] && HAS_STYLES=1

if [[ $HAS_COMMANDS -eq 0 && $HAS_SKILLS -eq 0 && $HAS_SCRIPTS -eq 0 && $HAS_STYLES -eq 0 ]]; then
  echo "Nothing to sync (COMMANDS, SKILLS, SCRIPTS and OUTPUT_STYLES all empty after filtering)." >&2
  exit 1
fi

# Activation only makes sense when the active style is actually part of this run.
ACTIVATE=0
if [[ -n "$ACTIVE_STYLE_NAME" && $NO_ACTIVATE -eq 0 && $HAS_STYLES -eq 1 ]]; then
  for st in "${OUTPUT_STYLES[@]}"; do
    [[ "$st" == "$ACTIVE_STYLE_FILE" ]] && ACTIVATE=1
  done
fi

# Verify all configured COMMANDS exist locally
MISSING=()
if [[ $HAS_COMMANDS -eq 1 ]]; then
  for cmd in "${COMMANDS[@]}"; do
    [[ -z "$cmd" ]] && continue
    [[ -f "$LOCAL_COMMANDS_DIR/$cmd" ]] || MISSING+=("command: $LOCAL_COMMANDS_DIR/$cmd")
  done
fi
if [[ $HAS_SKILLS -eq 1 ]]; then
  for skill in "${SKILLS[@]}"; do
    [[ -z "$skill" ]] && continue
    if [[ ! -d "$LOCAL_SKILLS_DIR/$skill" ]]; then
      MISSING+=("skill: $LOCAL_SKILLS_DIR/$skill (directory)")
    elif [[ ! -f "$LOCAL_SKILLS_DIR/$skill/SKILL.md" ]]; then
      MISSING+=("skill: $LOCAL_SKILLS_DIR/$skill/SKILL.md (no SKILL.md inside)")
    fi
  done
fi
if [[ $HAS_SCRIPTS -eq 1 ]]; then
  for s in "${SCRIPTS[@]}"; do
    [[ -z "$s" ]] && continue
    [[ -f "$LOCAL_SCRIPTS_DIR/$s" ]] || MISSING+=("script: $LOCAL_SCRIPTS_DIR/$s")
  done
fi
if [[ $HAS_STYLES -eq 1 ]]; then
  for st in "${OUTPUT_STYLES[@]}"; do
    [[ -z "$st" ]] && continue
    [[ -f "$LOCAL_OUTPUT_STYLES_DIR/$st" ]] || MISSING+=("output style: $LOCAL_OUTPUT_STYLES_DIR/$st")
  done
fi
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Missing locally (edit COMMANDS / SKILLS / SCRIPTS / OUTPUT_STYLES array or fix paths):" >&2
  for m in "${MISSING[@]}"; do echo "  - $m" >&2; done
  exit 1
fi

# === PRE-FLIGHT: which servers are reachable? ===
echo "==> Pre-flight: checking ${#SERVERS[@]} server(s)..."
REACHABLE=()
UNREACHABLE=()
for srv in "${SERVERS[@]}"; do
  if ssh -o ConnectTimeout=$SSH_TIMEOUT -o BatchMode=yes "$srv" true 2>/dev/null; then
    REACHABLE+=("$srv")
    echo "  ✓ $srv"
  else
    UNREACHABLE+=("$srv")
    echo "  ✗ $srv (unreachable: DNS, key, or auth)"
  fi
done

if [[ ${#REACHABLE[@]} -eq 0 ]]; then
  echo
  echo "No reachable servers. Aborting." >&2
  echo "Tip: try 'ssh <host>' manually for each unreachable host to debug." >&2
  exit 1
fi

# === OUTPUT-STYLE ACTIVATION HELPERS ===
# A style file on disk is inert. These two read/write the "outputStyle" key in the remote
# settings.json — the only thing that actually switches a host over.

# Print the remote outputStyle value, or "(none)" / "(no settings.json)" / "(unparseable)".
remote_style_of() {
  local srv="$1"
  ssh -o ConnectTimeout=$SSH_TIMEOUT "$srv" "CC_SETTINGS='$REMOTE_SETTINGS' python3 -" 2>/dev/null <<'PYSTYLE'
import json, os
from pathlib import Path
p = Path(os.environ["CC_SETTINGS"])
if not p.is_file():
    print("(no settings.json)")
else:
    try:
        print(json.loads(p.read_text()).get("outputStyle") or "(none)")
    except Exception:
        print("(unparseable)")
PYSTYLE
}

# Idempotently set outputStyle on one host. Backs up first; never touches anything else.
activate_style_on() {
  local srv="$1" style="$2"
  ssh -o ConnectTimeout=$SSH_TIMEOUT "$srv" "CC_STYLE='$style' CC_SETTINGS='$REMOTE_SETTINGS' CC_BACKUPS='$REMOTE_BACKUP_DIR' python3 -" <<'PYACT'
import json, os, shutil, sys, time
from pathlib import Path

want = os.environ.get("CC_STYLE", "")
if not want:
    print("SKIP — no style name given"); sys.exit(0)

p = Path(os.environ["CC_SETTINGS"])
s = {}
if p.is_file():
    try:
        s = json.loads(p.read_text())
    except json.JSONDecodeError as exc:
        # Refuse rather than clobber a settings file someone hand-edited badly.
        print("FAIL — cannot parse %s: %s" % (p, exc)); sys.exit(2)

if s.get("outputStyle") == want:
    print("NOOP — outputStyle already %s" % want); sys.exit(0)

if p.is_file():
    bdir = Path(os.environ["CC_BACKUPS"]); bdir.mkdir(parents=True, exist_ok=True)
    dst = bdir / ("settings.json.bak-outputstyle-%s" % time.strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(p, dst)
    print("backup → %s" % dst)

prev = s.get("outputStyle") or "(none)"
s["outputStyle"] = want
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(s, indent=2) + "\n")
print("OK — outputStyle: %s → %s" % (prev, want))
PYACT
}

# === CHECK MODE (read-only: no transfers, no writes) ===
# Exists because the sync had no verification step: a single failed transfer on 2026-07-18 left
# implement.md missing on one host for three weeks, and a pile of 2025 command files nobody
# noticed sat alongside the managed ones. Compares content, not just presence.
if [[ $CHECK -eq 1 ]]; then
  echo
  echo "==> Check mode — comparing against local (POSIX cksum, identical on macOS and Linux). No transfers."
  echo

  # Expected files as "local_path|remote_path"
  PAIRS=()
  if [[ $HAS_COMMANDS -eq 1 ]]; then
    for cmd in "${COMMANDS[@]}"; do
      [[ -n "$cmd" ]] && PAIRS+=("$LOCAL_COMMANDS_DIR/$cmd|$REMOTE_COMMANDS_DIR/$cmd")
    done
  fi
  if [[ $HAS_SCRIPTS -eq 1 ]]; then
    for s in "${SCRIPTS[@]}"; do
      [[ -n "$s" ]] && PAIRS+=("$LOCAL_SCRIPTS_DIR/$s|$REMOTE_SCRIPTS_DIR/$s")
    done
  fi
  if [[ $HAS_STYLES -eq 1 ]]; then
    for st in "${OUTPUT_STYLES[@]}"; do
      [[ -n "$st" ]] && PAIRS+=("$LOCAL_OUTPUT_STYLES_DIR/$st|$REMOTE_OUTPUT_STYLES_DIR/$st")
    done
  fi
  if [[ $HAS_SKILLS -eq 1 ]]; then
    for skill in "${SKILLS[@]}"; do
      [[ -z "$skill" ]] && continue
      while IFS= read -r rel; do
        PAIRS+=("$LOCAL_SKILLS_DIR/$skill/$rel|$REMOTE_SKILLS_DIR/$skill/$rel")
      done < <(cd "$LOCAL_SKILLS_DIR/$skill" && find . -type f | sed 's|^\./||')
    done
  fi

  # Managed + explicitly-tolerated command basenames, for spotting anything else on the remote side
  MANAGED=$(printf '%s\n' "${COMMANDS[@]:-}" "${ALLOWED_UNMANAGED[@]:-}" | grep -v '^$' | sort -u)

  PROBLEMS=0
  for srv in "${REACHABLE[@]}"; do
    echo "── $srv"

    REMOTE_OUT=$(printf '%s\n' "${PAIRS[@]}" | cut -d'|' -f2 \
      | ssh -o ConnectTimeout=$SSH_TIMEOUT "$srv" \
          'while IFS= read -r f; do
             if [ -f "$f" ]; then printf "%s %s\n" "$f" "$(cksum < "$f" | cut -d" " -f1)";
             else printf "%s MISSING\n" "$f"; fi
           done' 2>/dev/null)

    for pair in "${PAIRS[@]}"; do
      lpath="${pair%%|*}"; rpath="${pair##*|}"
      lsum=$(cksum < "$lpath" | cut -d' ' -f1)
      rsum=$(printf '%s\n' "$REMOTE_OUT" | awk -v p="$rpath" '$1==p{print $2}')
      if [[ -z "$rsum" ]]; then
        echo "   ? $(basename "$rpath") — no answer from host"; PROBLEMS=$((PROBLEMS+1))
      elif [[ "$rsum" == "MISSING" ]]; then
        echo "   ✗ $(basename "$rpath") MISSING"; PROBLEMS=$((PROBLEMS+1))
      elif [[ "$rsum" != "$lsum" ]]; then
        echo "   ✗ $(basename "$rpath") DRIFT (remote content differs)"; PROBLEMS=$((PROBLEMS+1))
      fi
    done

    # Unmanaged files sitting in the remote commands dir — not an error, but this is how
    # year-old forks of a commit command went unnoticed on 9 hosts.
    # Skipped under --only, where COMMANDS is filtered down and every real command would
    # be reported as "unmanaged" — a warning that always fires is a warning you learn to ignore.
    if [[ -z "$ONLY" ]]; then
      EXTRA=$(ssh -o ConnectTimeout=$SSH_TIMEOUT "$srv" "ls '$REMOTE_COMMANDS_DIR' 2>/dev/null" 2>/dev/null \
              | sort | comm -23 - <(printf '%s\n' "$MANAGED"))
      [[ -n "$EXTRA" ]] && echo "   ⚠ unmanaged (not in COMMANDS): $(echo $EXTRA | tr '\n' ' ')"
    fi

    # The file being present proves nothing — check what settings.json actually activates.
    if [[ -n "$ACTIVE_STYLE_NAME" ]]; then
      RSTYLE=$(remote_style_of "$srv")
      if [[ "$RSTYLE" != "$ACTIVE_STYLE_NAME" ]]; then
        echo "   ✗ outputStyle is '$RSTYLE', expected '$ACTIVE_STYLE_NAME' (style file present but NOT active)"
        PROBLEMS=$((PROBLEMS+1))
      fi
    fi
  done

  echo
  echo "==> Check summary"
  echo "  Reachable servers:   ${#REACHABLE[@]}/${#SERVERS[@]}"
  [[ ${#UNREACHABLE[@]} -gt 0 ]] && echo "  Unreachable servers: ${UNREACHABLE[*]}"
  if [[ $PROBLEMS -gt 0 ]]; then
    echo "  Problems found:      $PROBLEMS  (run without --check to push, or --only=<name> for one file)"
    exit 2
  fi
  echo "  All configured files match local content."
  [[ -n "$ACTIVE_STYLE_NAME" ]] && echo "  outputStyle active everywhere: $ACTIVE_STYLE_NAME"
  exit 0
fi

# === SYNC ===
NUM_COMMANDS=0
NUM_SKILLS=0
NUM_SCRIPTS=0
NUM_STYLES=0
[[ $HAS_COMMANDS -eq 1 ]] && NUM_COMMANDS=${#COMMANDS[@]}
[[ $HAS_SKILLS -eq 1 ]] && NUM_SKILLS=${#SKILLS[@]}
[[ $HAS_SCRIPTS -eq 1 ]] && NUM_SCRIPTS=${#SCRIPTS[@]}
[[ $HAS_STYLES -eq 1 ]] && NUM_STYLES=${#OUTPUT_STYLES[@]}

echo
echo "==> Syncing ${NUM_COMMANDS} command(s) + ${NUM_SKILLS} skill(s) + ${NUM_SCRIPTS} script(s) + ${NUM_STYLES} output style(s) → ${#REACHABLE[@]} server(s)"
[[ $DRY_RUN -eq 1 ]] && echo "    (DRY RUN — no file contents transfer; missing remote dirs ARE created)"
if [[ $ACTIVATE -eq 1 ]]; then
  echo "    Will also set \"outputStyle\": \"$ACTIVE_STYLE_NAME\" in $REMOTE_SETTINGS on each host"
  [[ $DRY_RUN -eq 1 ]] && echo "    (DRY RUN — settings.json will NOT be touched)"
elif [[ -n "$ACTIVE_STYLE_NAME" && $NO_ACTIVATE -eq 1 ]]; then
  echo "    --no-activate: style files ship, but no server is switched over"
fi
echo

RSYNC_BASE_FLAGS=(-avz --progress)
[[ $DRY_RUN -eq 1 ]] && RSYNC_BASE_FLAGS+=(--dry-run)

FAILURES=()
TRANSFERRED=0
ACTIVATED=0

for srv in "${REACHABLE[@]}"; do
  echo "── $srv ──"

  # Ensure remote dirs exist (cheap, one SSH call). This runs on --dry-run TOO: rsync
  # --dry-run still errors out with "change_dir failed" when the destination directory is
  # missing, which made dry-run report 10/10 bogus failures the first time output-styles
  # was added. An empty config dir changes no behavior, so creating it is the lesser evil.
  ssh -o ConnectTimeout=$SSH_TIMEOUT "$srv" \
      "mkdir -p '$REMOTE_COMMANDS_DIR' '$REMOTE_SKILLS_DIR' '$REMOTE_SCRIPTS_DIR' '$REMOTE_OUTPUT_STYLES_DIR'" 2>/dev/null || \
    echo "  ⚠ failed to ensure remote dirs on $srv (continuing anyway)" >&2

  # Sync each command (single file)
  if [[ $HAS_COMMANDS -eq 1 ]]; then
    for cmd in "${COMMANDS[@]}"; do
      [[ -z "$cmd" ]] && continue
      src="$LOCAL_COMMANDS_DIR/$cmd"
      dst="$srv:$REMOTE_COMMANDS_DIR/$cmd"
      if rsync "${RSYNC_BASE_FLAGS[@]}" "$src" "$dst"; then
        TRANSFERRED=$((TRANSFERRED + 1))
      else
        FAILURES+=("$srv:command:$cmd (rsync exit $?)")
        echo "  ✗ command $cmd → $srv FAILED" >&2
      fi
    done
  fi

  # Sync each skill (whole directory; trailing slash on src copies contents into dst dir)
  if [[ $HAS_SKILLS -eq 1 ]]; then
    for skill in "${SKILLS[@]}"; do
      [[ -z "$skill" ]] && continue
      src="$LOCAL_SKILLS_DIR/$skill/"
      dst="$srv:$REMOTE_SKILLS_DIR/$skill/"
      if rsync "${RSYNC_BASE_FLAGS[@]}" "$src" "$dst"; then
        TRANSFERRED=$((TRANSFERRED + 1))
      else
        FAILURES+=("$srv:skill:$skill (rsync exit $?)")
        echo "  ✗ skill $skill → $srv FAILED" >&2
      fi
    done
  fi

  # Sync each standalone script (single file, executable bit preserved by rsync -a)
  if [[ $HAS_SCRIPTS -eq 1 ]]; then
    for s in "${SCRIPTS[@]}"; do
      [[ -z "$s" ]] && continue
      src="$LOCAL_SCRIPTS_DIR/$s"
      dst="$srv:$REMOTE_SCRIPTS_DIR/$s"
      if rsync "${RSYNC_BASE_FLAGS[@]}" "$src" "$dst"; then
        TRANSFERRED=$((TRANSFERRED + 1))
      else
        FAILURES+=("$srv:script:$s (rsync exit $?)")
        echo "  ✗ script $s → $srv FAILED" >&2
      fi
    done
  fi

  # Sync each output style (single .md file)
  STYLE_SENT=0
  if [[ $HAS_STYLES -eq 1 ]]; then
    for st in "${OUTPUT_STYLES[@]}"; do
      [[ -z "$st" ]] && continue
      src="$LOCAL_OUTPUT_STYLES_DIR/$st"
      dst="$srv:$REMOTE_OUTPUT_STYLES_DIR/$st"
      if rsync "${RSYNC_BASE_FLAGS[@]}" "$src" "$dst"; then
        TRANSFERRED=$((TRANSFERRED + 1))
        [[ "$st" == "$ACTIVE_STYLE_FILE" ]] && STYLE_SENT=1
      else
        FAILURES+=("$srv:output-style:$st (rsync exit $?)")
        echo "  ✗ output style $st → $srv FAILED" >&2
      fi
    done
  fi

  # Activate — only after the file actually landed, so we never point settings.json at a
  # style that isn't there (Claude Code would fall back to Default and say nothing).
  if [[ $ACTIVATE -eq 1 && $DRY_RUN -eq 0 ]]; then
    if [[ $STYLE_SENT -eq 1 ]]; then
      ACT_OUT=$(activate_style_on "$srv" "$ACTIVE_STYLE_NAME" 2>&1)
      ACT_RC=$?
      if [[ $ACT_RC -ne 0 || "$ACT_OUT" == FAIL* ]]; then
        FAILURES+=("$srv:activate:$ACTIVE_STYLE_NAME ($ACT_OUT)")
        echo "  ✗ activate outputStyle → $srv FAILED: $ACT_OUT" >&2
      else
        ACTIVATED=$((ACTIVATED + 1))
        while IFS= read -r l; do [[ -n "$l" ]] && echo "  · $l"; done <<< "$ACT_OUT"
      fi
    else
      echo "  ⚠ $ACTIVE_STYLE_FILE did not transfer — skipping activation on $srv" >&2
    fi
  fi
  echo
done

# === SUMMARY ===
echo "==> Summary"
echo "  Commands configured: ${NUM_COMMANDS}"
echo "  Skills configured:   ${NUM_SKILLS}"
echo "  Scripts configured:  ${NUM_SCRIPTS}"
echo "  Output styles:       ${NUM_STYLES}"
if [[ $ACTIVATE -eq 1 ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  Activated:           0 (dry run — would set outputStyle=$ACTIVE_STYLE_NAME on ${#REACHABLE[@]} host(s))"
  else
    echo "  Activated:           $ACTIVATED/${#REACHABLE[@]} host(s) → outputStyle=$ACTIVE_STYLE_NAME"
  fi
fi
echo "  Reachable servers:   ${#REACHABLE[@]}/${#SERVERS[@]}"
[[ ${#UNREACHABLE[@]} -gt 0 ]] && echo "  Unreachable servers: ${UNREACHABLE[*]}"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "  Transfer failures:"
  for f in "${FAILURES[@]}"; do echo "    - $f"; done
  EXIT_CODE=2
else
  EXIT_CODE=0
fi
if [[ $DRY_RUN -eq 1 ]]; then
  echo "  (Dry run — nothing actually transferred.)"
  echo "  Total transfers:     $TRANSFERRED (would-be)"
else
  echo "  Total transfers:     $TRANSFERRED"
fi

exit $EXIT_CODE
