#!/usr/bin/env bash
# format-file.sh — Claude Code PostToolUse hook (matcher: Edit|Write|MultiEdit).
# Arg 1: absolute path of the file Claude just edited. With no arg, the path is taken from the
# hook JSON on stdin (tool_input.file_path), which is how hooks.json wires it.
#
# Detection: walks up from the file's directory to the git repo root,
# looking for Biome or Prettier config at any ancestor level. The NEAREST
# config wins. Binary must be installed in some ancestor's node_modules.
# No config → SKIP (never impose a formatter on an un-opinionated project).
#
# Precedence for JS/TS/JSON/CSS/GraphQL:
#   1. biome.json[c] found         → Biome
#   2. Any Prettier config found   → Prettier
#   3. None found                  → skip
#
# .md/.yaml/.yml in a Biome-only project → skip (Biome v2 can't format them).
# .py / .php use their standard global toolchains (black/ruff/isort, php-cs-fixer).
#
# Kill switch: export CLAUDE_NO_FORMAT=1 to disable the hook entirely.

set -u
[ -n "${CLAUDE_NO_FORMAT:-}" ] && exit 0

fp="${1:-}"
if [ -z "$fp" ] && [ ! -t 0 ]; then
  fp=$(python3 -c 'import json,sys
try:
    print((json.load(sys.stdin).get("tool_input") or {}).get("file_path") or "")
except Exception:
    print("")' 2>/dev/null || true)
fi
[ -z "$fp" ] && exit 0
[ ! -f "$fp" ] && exit 0

# Canonicalize path — macOS symlinks (/tmp → /private/tmp) would otherwise
# cause the walk-up loops to miss the git-root ceiling and spin forever.
fp=$(cd "$(dirname "$fp")" 2>/dev/null && pwd -P)/$(basename "$fp")
file_dir=$(dirname "$fp")

# Git repo root is the ceiling of the walk. Outside a git repo = scratch file,
# don't impose anything.
git_root=$(cd "$file_dir" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)

has_prettier_in_dir() {
  local d="$1"
  [ -f "$d/.prettierrc" ] || [ -f "$d/.prettierrc.json" ] \
    || [ -f "$d/.prettierrc.js" ] || [ -f "$d/.prettierrc.yaml" ] \
    || [ -f "$d/.prettierrc.yml" ] || [ -f "$d/prettier.config.js" ] \
    || [ -f "$d/prettier.config.mjs" ] \
    || { [ -f "$d/package.json" ] && grep -q '"prettier"' "$d/package.json" 2>/dev/null; }
}

# --- find nearest config (walking up, ceiling = git root or filesystem root) ---
config_dir=""
formatter=""
if [ -n "$git_root" ]; then
  dir="$file_dir"
  while :; do
    if [ -f "$dir/biome.json" ] || [ -f "$dir/biome.jsonc" ]; then
      config_dir="$dir"; formatter="biome"; break
    fi
    if has_prettier_in_dir "$dir"; then
      config_dir="$dir"; formatter="prettier"; break
    fi
    [ "$dir" = "$git_root" ] && break
    [ "$dir" = "/" ] && break
    dir=$(dirname "$dir")
  done
fi

# --- find nearest binary for the chosen formatter ---
find_bin() {
  local name="$1"
  [ -z "$git_root" ] && return 1
  local dir="$file_dir"
  while :; do
    if [ -x "$dir/node_modules/.bin/$name" ]; then
      printf '%s\n' "$dir/node_modules/.bin/$name"
      return 0
    fi
    [ "$dir" = "$git_root" ] && return 1
    [ "$dir" = "/" ] && return 1
    dir=$(dirname "$dir")
  done
}

case "$fp" in
  *.py)
    command -v black        >/dev/null 2>&1 && black --quiet "$fp"             >/dev/null 2>&1 || true
    command -v ruff         >/dev/null 2>&1 && ruff check --fix --quiet "$fp"  >/dev/null 2>&1 || true
    command -v isort        >/dev/null 2>&1 && isort --quiet "$fp"             >/dev/null 2>&1 || true
    ;;
  *.php)
    command -v php-cs-fixer >/dev/null 2>&1 && php-cs-fixer fix "$fp" --quiet  >/dev/null 2>&1 || true
    ;;
  *.js|*.jsx|*.ts|*.tsx|*.json|*.jsonc|*.css|*.scss|*.graphql)
    [ -z "$formatter" ] && exit 0
    bin=$(find_bin "$formatter") || exit 0
    if [ "$formatter" = "biome" ]; then
      (cd "$config_dir" && "$bin" format --write "$fp" >/dev/null 2>&1) || true
    else
      (cd "$config_dir" && "$bin" --write "$fp"        >/dev/null 2>&1) || true
    fi
    ;;
  *.md|*.yaml|*.yml)
    # Biome v2 doesn't format these. Prettier only, if configured.
    [ "$formatter" != "prettier" ] && exit 0
    bin=$(find_bin "prettier") || exit 0
    (cd "$config_dir" && "$bin" --write "$fp" >/dev/null 2>&1) || true
    ;;
esac

exit 0
