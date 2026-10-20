#!/usr/bin/env bats
# Tests for the /critical-review helpers: scripts/scope-delta.sh (which lines are this session's),
# scripts/review-log.py (the event log) and scripts/critical-review-stats.py (its reader).
# Run from the repo root: bats tests/

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SD="$ROOT/scripts/scope-delta.sh"
  RL="$ROOT/scripts/review-log.py"
  STATS="$ROOT/scripts/critical-review-stats.py"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export TMPDIR="$BATS_TEST_TMPDIR"
  export CLAUDE_REVIEW_LOG_DIR="$BATS_TEST_TMPDIR/logs"
  LOG="$CLAUDE_REVIEW_LOG_DIR/critical-review.jsonl"
}

# A repo whose baseline (the moment the "session" starts) has:
#   pre.txt   tracked, dirty at the baseline (snapshotted)   kept.txt  tracked, dirty, never touched again
#   nosnap.txt tracked, dirty, in the dirty list but not in the blobs file
#   gone.txt  tracked, dirty at the baseline, deleted afterwards
#   clean.txt tracked, clean at the baseline
# Writes $DIRTY / $BLOBS like hooks/session-start.sh does.
baseline_repo() {
  cd "$BATS_TEST_TMPDIR" && git init -q "$1" && cd "$1"
  printf 'p1\np2\np3\n' > pre.txt; printf 'k1\n' > kept.txt; printf 'n1\n' > nosnap.txt
  printf 'g1\n' > gone.txt; printf 'c1\nc2\nc3\n' > clean.txt
  git add .; git commit -qm init
  printf 'p1\np2-pre\np3\n' > pre.txt; printf 'k1-pre\n' > kept.txt; printf 'n1-pre\n' > nosnap.txt; printf 'g1-pre\n' > gone.txt
  DIRTY="$BATS_TEST_TMPDIR/dirty-$1"; BLOBS="$BATS_TEST_TMPDIR/blobs-$1"
  printf '%s\n' pre.txt kept.txt nosnap.txt gone.txt > "$DIRTY"
  : > "$BLOBS"
  for f in pre.txt kept.txt gone.txt; do printf '%s\t%s\n' "$(git hash-object -w "$f")" "$f" >> "$BLOBS"; done
}

# ───────────────────────────── scope-delta.sh ─────────────────────────────

@test "scope-delta: one verdict per path, in order — FULL, DELTA, UNCHANGED, LIKELY" {
  baseline_repo sd1
  printf 'p1\np2-pre\np3\np4-session\n' > pre.txt        # this session adds one line to a pre-dirty file
  printf 'c1\nc2-session\nc3\n' > clean.txt              # and changes a clean one
  rm gone.txt
  run bash "$SD" --dirty "$DIRTY" --blobs "$BLOBS" -- clean.txt pre.txt kept.txt nosnap.txt gone.txt
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^VERDICT ')" -eq 5 ]
  [ "$(printf '%s\n' "$output" | grep '^VERDICT ' | cut -d' ' -f2-3 | tr '\n' '|')" = "FULL clean.txt|DELTA pre.txt|UNCHANGED kept.txt|LIKELY nosnap.txt|LIKELY gone.txt|" ]
  # the hunks: clean.txt line 2 vs HEAD; pre.txt ONLY the session's line 4, not the pre-session line 2
  [[ "$output" == *$'VERDICT FULL clean.txt\n@@ -2 +2 @@'* ]]
  [[ "$output" == *$'VERDICT DELTA pre.txt\n@@ -3,0 +4 @@'* ]]
  [[ "$output" == *"LIKELY nosnap.txt (not-snapshotted)"* ]]
  [[ "$output" == *"LIKELY gone.txt (broken: file gone"* ]]
}

@test "scope-delta: an untracked new file gets a whole-file hunk (git diff HEAD prints nothing for it)" {
  baseline_repo sd2
  printf 'u1\nu2\nu3\n' > fresh.txt
  [ -z "$(git diff HEAD -- fresh.txt)" ]                 # the gap this closes
  run bash "$SD" --dirty "$DIRTY" --blobs "$BLOBS" -- fresh.txt
  [ "$status" -eq 0 ]
  [ "$output" = $'VERDICT FULL fresh.txt\n@@ -0,0 +1,3 @@' ]
}

@test "scope-delta: a broken snapshot sha is LIKELY, never an empty delta — the old inline lookup printed nothing" {
  baseline_repo sd3
  printf 'p1\np2-pre\np3\np4-session\n' > pre.txt
  bad="$BATS_TEST_TMPDIR/blobs-bad"
  printf '%s\tpre.txt\n' "0123456789abcdef0123456789abcdef01234567" > "$bad"     # valid shape, no such object
  printf '%s\tkept.txt\n' "not-a-sha" >> "$bad"
  run bash "$SD" --dirty "$DIRTY" --blobs "$bad" -- pre.txt kept.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERDICT LIKELY pre.txt (broken: snapshot sha unusable: 0123456789abcdef"* ]]
  [[ "$output" == *"VERDICT LIKELY kept.txt (broken: snapshot sha unusable: not-a-sha)"* ]]
  # Negative control: the v0.2 lookup (critical-review.md, Phase 1 case 2) on the same input — empty
  # stdout, which the command then treated as "no hunks" and dropped every finding in the file.
  THEN_SHA=$(awk -F'\t' -v f="pre.txt" '{ if ($NF == f) { print $(NF-1); exit } }' "$bad")
  NOW_SHA=$(git hash-object -w -- "pre.txt")
  run bash -c "git diff --unified=0 $THEN_SHA $NOW_SHA 2>/dev/null"
  [ -z "$output" ]; [ "$status" -ne 0 ]
}

@test "scope-delta: --now compares a pre-dirty file against the commit it was committed in" {
  baseline_repo sd4
  printf 'p1\np2-pre\np3\np4-session\n' > pre.txt
  git add pre.txt; git commit -qm session-commit
  printf 'p1\np2-pre\np3\np4-session\np5-later\n' > pre.txt          # dirty again afterwards
  run bash "$SD" --dirty "$DIRTY" --blobs "$BLOBS" --now HEAD -- pre.txt
  [ "$status" -eq 0 ]; [ "$output" = $'VERDICT DELTA pre.txt\n@@ -3,0 +4 @@' ]   # the committed share only
  run bash "$SD" --dirty "$DIRTY" --blobs "$BLOBS" --now HEAD -- nosnap.txt
  [[ "$output" == "VERDICT LIKELY nosnap.txt (not-snapshotted)" ]]
  run bash "$SD" --dirty "$DIRTY" --blobs "$BLOBS" --now HEAD -- clean.txt
  [[ "$output" == "VERDICT LIKELY clean.txt (broken: --now is only for files dirty at the baseline)" ]]
}

@test "scope-delta: binary content is LIKELY (no-text-hunks), an unchanged clean file is UNCHANGED" {
  baseline_repo sd5
  printf 'b\000in\001ary\n' > bin.dat
  run bash "$SD" --dirty "$DIRTY" --blobs "$BLOBS" -- bin.dat clean.txt
  [ "$status" -eq 0 ]
  [ "$output" = $'VERDICT LIKELY bin.dat (no-text-hunks)\nVERDICT UNCHANGED clean.txt' ]
}

@test "scope-delta: no snapshot at all — the gitStatus fallback list with /dev/null blobs makes every listed path LIKELY" {
  baseline_repo sd6
  printf '%s\n' pre.txt kept.txt > "$BATS_TEST_TMPDIR/fallback"
  run bash "$SD" --dirty "$BATS_TEST_TMPDIR/fallback" --blobs /dev/null -- pre.txt kept.txt clean.txt
  [ "$status" -eq 0 ]
  [ "$output" = $'VERDICT LIKELY pre.txt (not-snapshotted)\nVERDICT LIKELY kept.txt (not-snapshotted)\nVERDICT UNCHANGED clean.txt' ]
}

@test "scope-delta: last-review baseline — no --dirty, the blobs file's paths are the dirty list" {
  baseline_repo sd7
  printf 'p1\np2-pre\np3\np4-session\n' > pre.txt
  run bash "$SD" --blobs "$BLOBS" -- pre.txt nosnap.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERDICT DELTA pre.txt"* ]]
  [[ "$output" == *"VERDICT FULL nosnap.txt"* ]]   # not in this baseline → whole diff vs HEAD is in scope
}

@test "scope-delta: usage errors and a missing baseline file print nothing on stdout" {
  baseline_repo sd8
  run bash -c "bash '$SD' 2>/dev/null"; [ "$status" -eq 1 ]; [ -z "$output" ]
  run bash -c "bash '$SD' --blobs '$BLOBS' 2>/dev/null"; [ "$status" -eq 1 ]; [ -z "$output" ]
  run bash -c "bash '$SD' --bogus x -- a 2>/dev/null"; [ "$status" -eq 1 ]; [ -z "$output" ]
  run bash -c "bash '$SD' --dirty '$BATS_TEST_TMPDIR/nope' --blobs '$BLOBS' -- pre.txt 2>/dev/null"; [ "$status" -eq 2 ]; [ -z "$output" ]
  run bash -c "bash '$SD' --blobs '$BATS_TEST_TMPDIR/nope' -- pre.txt 2>/dev/null"; [ "$status" -eq 2 ]; [ -z "$output" ]
}

@test "scope-delta: works from a subdirectory and with a relative baseline path" {
  baseline_repo sd9
  printf 'c1\nc2-session\nc3\n' > clean.txt
  mkdir -p sub; cp "$BLOBS" sub/blobs.rel; cp "$DIRTY" sub/dirty.rel; cd sub
  run bash "$SD" --dirty dirty.rel --blobs blobs.rel -- clean.txt
  [ "$status" -eq 0 ]; [[ "$output" == $'VERDICT FULL clean.txt\n@@ -2 +2 @@' ]]
}

# ───────────────────────────── review-log.py ─────────────────────────────

@test "review-log: run prints a fresh id; finding / brief_drop derive fid / drop_id from it; types are coerced" {
  run python3 "$RL" run session=sid-1 repo=r model="codex gpt-6.1-sol" reviewer_findings=4 kept=2 brief_active=1
  [ "$status" -eq 0 ]; [[ "$output" =~ ^sid-1-[0-9]+-[0-9a-f]{6}$ ]]; rid="$output"
  run python3 "$RL" finding session=sid-1 run_id="$rid" n=2 file=a.sh line_start=3 line_end=5 issue="x"
  [ "$status" -eq 0 ]; [ "$output" = "$rid-2" ]
  run python3 "$RL" finding session=sid-1 run_id="$rid" n=L1 file=b.sh line_start=1 line_end=1
  [ "$output" = "$rid-L1" ]
  run python3 "$RL" brief_drop session=sid-1 run_id="$rid" k=1 brief_excerpt="do not flag y"
  [ "$status" -eq 0 ]; [ "$output" = "$rid-D1" ]
  python3 - "$LOG" "$rid" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
assert [r["event"] for r in rows] == ["run", "finding", "finding", "brief_drop"], rows
run, f = rows[0], rows[1]
assert run["run_id"] == sys.argv[2] and run["kept"] == 2 and run["reviewer_findings"] == 4 and run["brief_active"] is True, run
assert f["fid"] == sys.argv[2] + "-2" and f["line_start"] == 3 and f["line_end"] == 5 and "n" not in f, f
assert rows[3]["drop_id"] == sys.argv[2] + "-D1" and "k" not in rows[3], rows[3]
PY
}

@test "review-log: a late reply about an EARLIER review is credited to that review, not the newest one" {
  a=$(python3 "$RL" run session=sid-2 reviewer_findings=1 kept=1)
  python3 "$RL" finding session=sid-2 run_id="$a" n=1 >/dev/null
  b=$(python3 "$RL" run session=sid-2 reviewer_findings=1 kept=1)     # same session, same second: the random part keeps ids apart
  python3 "$RL" finding session=sid-2 run_id="$b" n=1 >/dev/null
  [ "$a" != "$b" ]
  python3 "$RL" decision session=sid-2 run_id="$a" n=1 decision=accepted via=go_ahead >/dev/null
  python3 "$STATS" --json "$LOG" > "$BATS_TEST_TMPDIR/s.json"
  python3 - "$LOG" "$BATS_TEST_TMPDIR/s.json" "$a" <<'PY'
import json, sys
dec = [json.loads(l) for l in open(sys.argv[1]) if json.loads(l)["event"] == "decision"]
assert len(dec) == 1 and dec[0]["fid"] == sys.argv[3] + "-1", dec        # run A's finding, not run B's
s = json.load(open(sys.argv[2]))
assert s["runs"] == 2 and s["total"]["findings"] == 2, s
assert s["total"]["accepted"] == 1 and s["total"]["unresolved"] == 1 and s["orphan_events"] == 0, s
PY
}

@test "review-log: rejects what would corrupt the log — nothing is written" {
  rid=$(python3 "$RL" run session=sid-3)
  before=$(wc -l < "$LOG")
  run python3 "$RL" finding session=sid-3 n=1;                                   [ "$status" -eq 1 ]   # no run_id
  run python3 "$RL" finding session=sid-3 run_id="$rid";                         [ "$status" -eq 1 ]   # no n
  run python3 "$RL" decision session=sid-3 run_id="$rid" n=1 decision=maybe via=go_ahead;   [ "$status" -eq 1 ]
  run python3 "$RL" resolution session=sid-3 run_id="$rid" n=1 status=done;     [ "$status" -eq 1 ]
  run python3 "$RL" finding session=sid-3 run_id="$rid" n=1 line_start=abc;     [ "$status" -eq 1 ]
  run python3 "$RL" finding session=sid-3 run_id="$rid" n=1 fid=forged;         [ "$status" -eq 1 ]
  run python3 "$RL" run session=sid-3 run_id=forged;                             [ "$status" -eq 1 ]
  run python3 "$RL" verdict session=sid-3;                                       [ "$status" -eq 1 ]
  run python3 "$RL" run session='../../etc/x';                                   [ "$status" -eq 1 ]
  run python3 "$RL" run;                                                         [ "$status" -eq 1 ]
  run python3 "$RL";                                                             [ "$status" -eq 1 ]
  [ "$(wc -l < "$LOG")" -eq "$before" ]
}

@test "review-log: decision, resolution and overrule vocabulary is accepted as documented" {
  rid=$(python3 "$RL" run session=sid-4)
  for v in plan_approval go_ahead plan_request pushback; do
    run python3 "$RL" decision session=sid-4 run_id="$rid" n=1 decision=accepted via=$v; [ "$status" -eq 0 ]
  done
  for st in auto_applied skipped failed abandoned; do
    run python3 "$RL" resolution session=sid-4 run_id="$rid" n=1 status=$st reason=r; [ "$status" -eq 0 ]
  done
  run python3 "$RL" brief_drop_overruled session=sid-4 run_id="$rid" k=2 reason="brief was wrong"
  [ "$status" -eq 0 ]; [ "$output" = "$rid-D2" ]
}

# ───────────────────────────── critical-review-stats.py ─────────────────────────────

@test "stats: fixture → hand-computed numbers (distinct ids, last decision wins, unresolved never guessed, malformed counted)" {
  run python3 "$STATS" --json "$ROOT/tests/fixtures/critical-review-log.jsonl"
  [ "$status" -eq 0 ]
  printf '%s' "$output" > "$BATS_TEST_TMPDIR/stats.json"
  python3 - "$BATS_TEST_TMPDIR/stats.json" <<'PY'
import json, sys
got = json.load(open(sys.argv[1]))
B = lambda f, a, d, u, ap: {"findings": f, "accepted": a, "declined": d, "unresolved": u, "auto_applied": ap}
EXPECT = {
    "runs": 3,                                  # R-num (numeric ts) is malformed, not a run
    "total": B(6, 3, 2, 1, 1),                  # S1-2000-2-1 re-decided → accepted; S2-3000-3-2 accepted+applied, LATER declined → its apply does not count
    "resolutions": {"auto_applied": 2, "failed": 1, "skipped": 1},
    "brief_drops": 2, "brief_drops_overruled": 1,
    "filter": {"reviewer_findings": 8, "kept": 4, "runs_with_counts": 2},   # run 2 uses the private name codex_findings; run 3 has no counts
    "duplicate_rows": 1, "orphan_events": 1,
    "malformed_rows": 5,                        # not JSON, a JSON list, a list-typed fid, a numeric ts, a numeric event
    "legacy": {"auto_applied": 1, "brief_drop": 1, "findings": 2},   # incl. one v0.2 public-shape row (reviewer + verdict:null)
    "by": {
        "model": {"codex gpt-6.1-sol": B(4, 2, 2, 0, 1), "claude claude-opus-5": B(2, 1, 0, 1, 0)},
        "repo": {"alpha": B(4, 2, 1, 1, 1), "beta": B(2, 1, 1, 0, 0)},
        "month": {"2026-08": B(2, 1, 1, 0, 1), "2026-09": B(4, 2, 1, 1, 0)},
    },
}
bad = ["%s: expected %s, got %s" % (k, EXPECT[k], got.get(k)) for k in EXPECT if got.get(k) != EXPECT[k]]
assert not bad, "\n".join(bad)
PY
}

@test "stats: text render runs; a missing log is exit 2; the default path honours CLAUDE_REVIEW_LOG_DIR" {
  run python3 "$STATS" "$ROOT/tests/fixtures/critical-review-log.jsonl"
  [ "$status" -eq 0 ]; [[ "$output" == *"runs: 3 · findings: 6"* ]]; [[ "$output" == *"malformed rows 5"* ]]
  run python3 "$STATS" "$BATS_TEST_TMPDIR/nope.jsonl"; [ "$status" -eq 2 ]
  run python3 "$STATS"; [ "$status" -eq 2 ]; [[ "$output" == *"$CLAUDE_REVIEW_LOG_DIR/critical-review.jsonl"* ]]
  python3 "$RL" run session=sid-5 >/dev/null
  run python3 "$STATS"; [ "$status" -eq 0 ]; [[ "$output" == *"runs: 1"* ]]
}
