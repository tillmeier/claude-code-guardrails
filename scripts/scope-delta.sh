#!/usr/bin/env bash
#
# scope-delta.sh — /critical-review Phase 1: which lines of each changed file belong to THIS session.
# One verdict per path, never a silent empty answer: a lookup that fails says so, and the file lands
# in the scope-unverifiable bucket instead of having its findings dropped as "out of scope".
#
#   scope-delta.sh [--dirty <list>] --blobs <file> [--now <rev>] -- <path>...
#
#   --dirty <list>  one repo-root-relative path per line: files already dirty at the baseline
#                   (claude-session-start-dirty-<sid>, or the gitStatus fallback list). Omitted →
#                   the paths of --blobs (the last-review baseline has no separate list).
#   --blobs <file>  <blob sha>TAB<path> per line, the baseline content of the dirty files.
#                   /dev/null = no snapshot (every dirty path becomes "not-snapshotted").
#   --now <rev>     compare against <rev>:<path> instead of the working-tree file (a file that was
#                   dirty at the baseline and then committed in this session).
#
# Output, per path in argument order:
#   VERDICT FULL <path>               + its @@ lines — not dirty at the baseline: whole diff vs HEAD
#   VERDICT DELTA <path>              + its @@ lines — dirty at the baseline: only what changed since
#   VERDICT UNCHANGED <path>          — no change since the baseline → exclude
#   VERDICT LIKELY <path> (<reason>)  — this session's share is unprovable → scope-unverifiable
# Exit 0 = one verdict per path. Exit 1 = usage error, exit 2 = a named baseline file does not exist
# (fall back to the gitStatus list) — both print nothing on stdout. Run inside the repo; paths are
# repo-root-relative.

set -uo pipefail

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

DIRTY=""; BLOBS=""; NOW_REV=""; HAVE_DIRTY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dirty) [ $# -ge 2 ] || usage; DIRTY="$2"; HAVE_DIRTY=1; shift 2 ;;
    --blobs) [ $# -ge 2 ] || usage; BLOBS="$2"; shift 2 ;;
    --now)   [ $# -ge 2 ] || usage; NOW_REV="$2"; shift 2 ;;
    --)      shift; break ;;
    -h|--help) usage ;;
    *) echo "scope-delta: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$BLOBS" ] && [ $# -ge 1 ] || usage

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
BLOBS=$(abs "$BLOBS"); [ $HAVE_DIRTY -eq 1 ] && DIRTY=$(abs "$DIRTY")
for f in "$BLOBS" ${DIRTY:+"$DIRTY"}; do
  [ -e "$f" ] || { echo "scope-delta: baseline file does not exist: $f" >&2; exit 2; }
done

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "scope-delta: not inside a git repository" >&2; exit 1; }
cd "$TOP" || exit 1

in_dirty() {   # $1 = path; exact line match against the dirty list
  if [ $HAVE_DIRTY -eq 1 ]; then grep -Fxq -- "$1" "$DIRTY"
  else cut -f2 "$BLOBS" | grep -Fxq -- "$1"; fi
}

# Prints the verdict for a finished diff. $1 = kind on success, $2 = path, $3 = diff text.
emit() {
  if [ -z "$3" ]; then echo "VERDICT UNCHANGED $2"
  elif ! printf '%s\n' "$3" | grep -q '^@@'; then echo "VERDICT LIKELY $2 (no-text-hunks)"
  else echo "VERDICT $1 $2"; printf '%s\n' "$3" | sed -n 's/^\(@@ [^@]* @@\).*/\1/p'; fi   # ranges only, no context text
}

for p in "$@"; do
  if ! in_dirty "$p"; then
    # Not dirty at the baseline: everything that differs from HEAD is this session's.
    if [ -n "$NOW_REV" ]; then
      echo "VERDICT LIKELY $p (broken: --now is only for files dirty at the baseline)"; continue
    fi
    if git ls-files --error-unmatch -- "$p" >/dev/null 2>&1 || git cat-file -e "HEAD:$p" 2>/dev/null; then
      if D=$(git diff --no-ext-diff --no-color --unified=0 HEAD -- "$p" 2>/dev/null); then emit FULL "$p" "$D"
      else echo "VERDICT LIKELY $p (broken: git diff HEAD failed)"; fi
    elif [ -e "$p" ] || [ -L "$p" ]; then
      # Untracked: `git diff HEAD` prints nothing for it, so diff against the empty file instead.
      D=$(git diff --no-ext-diff --no-color --no-index --unified=0 -- /dev/null "$p" 2>/dev/null); rc=$?
      if [ $rc -le 1 ]; then emit FULL "$p" "$D"
      else echo "VERDICT LIKELY $p (broken: git diff --no-index failed)"; fi
    else
      echo "VERDICT LIKELY $p (broken: path not on disk, not tracked)"
    fi
    continue
  fi

  # Dirty at the baseline: diff the baseline blob against the content now.
  THEN=$(F="$p" awk -F'\t' '$2 == ENVIRON["F"] { print $1; exit }' "$BLOBS" 2>/dev/null)
  if [ -z "$THEN" ]; then echo "VERDICT LIKELY $p (not-snapshotted)"; continue; fi
  if ! printf '%s' "$THEN" | grep -qE '^[0-9a-f]{40,64}$' || [ "$(git cat-file -t "$THEN" 2>/dev/null)" != "blob" ]; then
    echo "VERDICT LIKELY $p (broken: snapshot sha unusable: $THEN)"; continue
  fi
  if [ -n "$NOW_REV" ]; then
    NOW=$(git rev-parse --verify -q "${NOW_REV}:${p}" 2>/dev/null) \
      || { echo "VERDICT LIKELY $p (broken: not in $NOW_REV)"; continue; }
  elif [ -L "$p" ] || [ ! -f "$p" ]; then
    echo "VERDICT LIKELY $p (broken: file gone or not a regular file)"; continue
  else
    NOW=$(git hash-object -w -- "$p" 2>/dev/null)   # -w so git diff can resolve the blob
    [ -n "$NOW" ] || { echo "VERDICT LIKELY $p (broken: git hash-object failed)"; continue; }
  fi
  if [ "$THEN" = "$NOW" ]; then echo "VERDICT UNCHANGED $p"; continue; fi
  if D=$(git diff --no-ext-diff --no-color --unified=0 "$THEN" "$NOW" 2>/dev/null); then emit DELTA "$p" "$D"
  else echo "VERDICT LIKELY $p (broken: git diff of the two blobs failed)"; fi
done
exit 0
