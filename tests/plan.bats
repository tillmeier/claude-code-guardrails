#!/usr/bin/env bats
# /plan Phase 2.5: the shell block in commands/plan.md, extracted and run the way the harness runs it
# (${CLAUDE_PLUGIN_ROOT} substituted, the spec path filled in). Reviewers are fakes; no model is called.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
  export TMPDIR="$BATS_TEST_TMPDIR"
  unset REVIEWER CODEX_REVIEW_MODEL CODEX_REVIEW_EFFORT CLAUDE_REVIEW_MODEL REVIEW_CUSTOM_CMD REVIEW_BACKEND_CONF REVIEW_BACKEND AGY_BIN
  export PATH="/usr/bin:/bin"                                   # no codex, no claude
  SPEC="$BATS_TEST_TMPDIR/spec.md"; printf '# Plan: demo\nSPEC-MARKER\n' > "$SPEC"
  cd "$BATS_TEST_TMPDIR"
}

has()   { case "$output" in *"$1"*) return 0 ;; esac; printf 'expected in output: %s\n---\n%s\n' "$1" "$output" >&2; return 1; }
hasnt() { case "$output" in *"$1"*) printf 'unexpected in output: %s\n---\n%s\n' "$1" "$output" >&2; return 1 ;; esac; }

# $1 = what the harness puts in for ${CLAUDE_PLUGIN_ROOT}, $2 = the spec path
# $2 is inserted as the model writes it: already escaped for single quotes ('\'' for a ').
plan_block() {
  python3 - "$ROOT/commands/plan.md" "$1" "$2" <<'EXTRACT'
import re, sys
text = open(sys.argv[1]).read()
block = re.search(r"^bash <<'PLANREVIEW'\n.*?^PLANREVIEW$", text, re.S | re.M).group(0)
print(block.replace("${CLAUDE_PLUGIN_ROOT}", sys.argv[2]).replace("<spec path from Phase 2>", sys.argv[3]))
EXTRACT
}

@test "plan 2.5: the block exists and fills in the spec path" {
  [ -n "$(plan_block "$ROOT" "$SPEC")" ]
  plan_block "$ROOT" "$SPEC" | grep -qF "PLAN_FILE='$SPEC'"
}

@test "plan 2.5: a review on exit 0 is PLAN REVIEWED, with the status line naming the reviewer" {
  run env REVIEW_CUSTOM_CMD='grep -q SPEC-MARKER && echo "the spec misses X"' bash -c "$(plan_block "$ROOT" "$SPEC")"
  [ "$status" -eq 0 ]
  has "PLAN REVIEWED (custom · custom · prompt mode · spec "; has "the spec misses X"
}

@test "plan 2.5: every other exit is PLAN NOT REVIEWED — failed reviewer (4), none (3), bad spec (1)" {
  run env REVIEW_CUSTOM_CMD='exit 9' bash -c "$(plan_block "$ROOT" "$SPEC")"
  has "PLAN NOT REVIEWED (exit 4)"; hasnt "PLAN REVIEWED"
  run bash -c "$(plan_block "$ROOT" "$SPEC")"
  has "PLAN NOT REVIEWED (exit 3)"; has "no usable reviewer"; hasnt "PLAN REVIEWED"
  : > "$BATS_TEST_TMPDIR/empty.md"
  run env REVIEW_CUSTOM_CMD='echo text' bash -c "$(plan_block "$ROOT" "$BATS_TEST_TMPDIR/empty.md")"
  has "PLAN NOT REVIEWED (exit 1)"; has "is empty"; hasnt "PLAN REVIEWED"
}

@test "plan 2.5: no plugin root → REVIEW_BACKEND, and a missing script is PLAN NOT REVIEWED" {
  run env REVIEW_BACKEND="$ROOT/scripts/review-backend.sh" REVIEW_CUSTOM_CMD='echo fine' bash -c "$(plan_block "" "$SPEC")"
  has "PLAN REVIEWED"; has "fine"
  run env REVIEW_CUSTOM_CMD='echo fine' bash -c "$(plan_block "/nonexistent" "$SPEC")"
  has "PLAN NOT REVIEWED: scripts/review-backend.sh not found"; hasnt "PLAN REVIEWED"
}

@test "plan 2.5: a spec path with an apostrophe, written escaped, still reaches the reviewer" {
  mkdir -p "$BATS_TEST_TMPDIR/it's here"; cp "$SPEC" "$BATS_TEST_TMPDIR/it's here/spec.md"
  escaped=$(printf '%s' "$BATS_TEST_TMPDIR/it's here/spec.md" | sed "s/'/'\\\\''/g")
  run env REVIEW_CUSTOM_CMD='grep -q SPEC-MARKER && echo read-the-spec' bash -c "$(plan_block "$ROOT" "$escaped")"
  has "PLAN REVIEWED"; has "read-the-spec"
}

@test "plan 2.5: an empty spec path is PLAN NOT REVIEWED, and a failure keeps the adapter's reason" {
  run env REVIEW_CUSTOM_CMD='echo text' bash -c "$(plan_block "$ROOT" "")"
  has "PLAN NOT REVIEWED: no spec path"; hasnt "PLAN REVIEWED"
  run env REVIEW_CUSTOM_CMD='for i in $(seq 50); do echo noise-$i >&2; done; exit 3' bash -c "$(plan_block "$ROOT" "$SPEC")"
  has "PLAN NOT REVIEWED (exit 4)"; has "custom failed — exit 3"; has "noise-50"
}
