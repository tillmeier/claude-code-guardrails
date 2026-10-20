#!/usr/bin/env python3
"""critical-review-stats.py — read-only summary of the /critical-review event log.

  python3 critical-review-stats.py [--json] [LOGFILE]

Default LOGFILE: ${CLAUDE_REVIEW_LOG_DIR:-~/.claude/logs}/critical-review.jsonl (written by
scripts/review-log.py). The log is a stream of immutable events:
  run · finding · decision · resolution · brief_drop · brief_drop_overruled
Everything is counted by DISTINCT id (fid / drop_id / run_id), never by row. A finding without a
decision event is UNRESOLVED — never guessed into accepted or declined. Rows written before the
event schema (no fid / no drop_id, e.g. v0.2's `verdict: null` rows) form a separate legacy bucket
and are not joined to anything. Rows that are not JSON objects, or whose ids / keys are not strings,
are counted as malformed. Host-local: each machine has its own log.
"""
import collections
import json
import os
import sys

# Fields used as ids, dict keys or labels; any other type makes the row malformed (it would crash
# the counting or silently merge buckets).
STR_FIELDS = ("event", "ts", "run_id", "fid", "drop_id", "repo", "model", "status", "decision")


def load(path):
    rows, malformed = [], 0
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except ValueError:
                malformed += 1
                continue
            if not isinstance(obj, dict) or any(k in obj and obj[k] is not None and not isinstance(obj[k], str)
                                                for k in STR_FIELDS):
                malformed += 1
                continue
            rows.append(obj)
    return rows, malformed


def as_int(v):
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def summarize(rows, malformed):
    runs, findings, drops = {}, {}, {}
    decisions, resolutions, overruled = {}, {}, set()
    dup_rows = 0
    legacy = collections.Counter()

    for r in rows:
        ev = r.get("event")
        if ev == "run" and r.get("run_id"):
            if r["run_id"] in runs:
                dup_rows += 1
            runs[r["run_id"]] = r
        elif ev == "finding" and r.get("fid"):
            if r["fid"] in findings:
                dup_rows += 1
            findings[r["fid"]] = r
        elif ev == "decision" and r.get("fid"):
            decisions[r["fid"]] = r          # last decision per finding wins
        elif ev == "resolution" and r.get("fid"):
            resolutions[r["fid"]] = r        # last resolution per finding wins
        elif ev == "brief_drop" and r.get("drop_id"):
            if r["drop_id"] in drops:
                dup_rows += 1
            drops[r["drop_id"]] = r
        elif ev == "brief_drop_overruled" and r.get("drop_id"):
            overruled.add(r["drop_id"])
        elif ev is None and "issue" in r:
            legacy["findings"] += 1
        elif ev == "auto_applied":
            legacy["auto_applied"] += 1
        elif ev == "brief_drop":
            legacy["brief_drop"] += 1
        else:
            legacy["other_events"] += 1

    def dims(fid):
        f = findings[fid]
        run = runs.get(f.get("run_id"), {})
        return (f.get("repo") or run.get("repo") or "unknown",
                (f.get("ts") or "")[:7] or "unknown",
                run.get("model") or "unknown")

    def bucket():
        return {"findings": 0, "accepted": 0, "declined": 0, "unresolved": 0, "auto_applied": 0}

    total = bucket()
    by = {"repo": collections.defaultdict(bucket), "month": collections.defaultdict(bucket),
          "model": collections.defaultdict(bucket)}
    for fid in findings:
        repo, month, model = dims(fid)
        dec = decisions.get(fid, {}).get("decision")
        state = dec if dec in ("accepted", "declined") else "unresolved"
        # Only a fix on a CURRENTLY accepted finding counts: a later "declined" supersedes the
        # acceptance, and its apply must not inflate "auto-applied of accepted".
        applied = 1 if (state == "accepted"
                        and resolutions.get(fid, {}).get("status") == "auto_applied") else 0
        for b in (total, by["repo"][repo], by["month"][month], by["model"][model]):
            b["findings"] += 1
            b[state] += 1
            b["auto_applied"] += applied

    res_status = collections.Counter(v.get("status") or "unknown" for k, v in resolutions.items() if k in findings)
    orphans = len([k for k in decisions if k not in findings]) + len([k for k in resolutions if k not in findings]) \
        + len([k for k in overruled if k not in drops])
    filt = {"reviewer_findings": 0, "kept": 0, "runs_with_counts": 0}
    for r in runs.values():
        # reviewer_findings since v0.3; codex_findings is the private copy's name for the same count
        c = as_int(r.get("reviewer_findings", r.get("codex_findings")))
        k = as_int(r.get("kept"))
        if c is None or k is None:
            continue
        filt["reviewer_findings"] += c
        filt["kept"] += k
        filt["runs_with_counts"] += 1

    return {
        "runs": len(runs), "total": total,
        "by": {k: {n: v for n, v in sorted(d.items())} for k, d in by.items()},
        "resolutions": dict(sorted(res_status.items())),
        "brief_drops": len(drops), "brief_drops_overruled": len([d for d in overruled if d in drops]),
        "filter": filt, "duplicate_rows": dup_rows, "orphan_events": orphans,
        "legacy": dict(sorted(legacy.items())), "malformed_rows": malformed,
    }


def pct(a, b):
    return "n/a" if not b else "%.0f%%" % (100.0 * a / b)


def render(s):
    t = s["total"]
    out = ["critical-review log — event schema (distinct ids)",
           "  runs: %d · findings: %d" % (s["runs"], t["findings"]),
           "  accepted: %d · declined: %d · unresolved: %d" % (t["accepted"], t["declined"], t["unresolved"]),
           "  acceptance (accepted / decided): %s   ← unresolved are NOT in the denominator"
           % pct(t["accepted"], t["accepted"] + t["declined"]),
           "  auto-applied of accepted: %s · resolutions: %s"
           % (pct(t["auto_applied"], t["accepted"]), s["resolutions"] or "{}"),
           "  brief drops: %d · overruled: %d (%s)"
           % (s["brief_drops"], s["brief_drops_overruled"], pct(s["brief_drops_overruled"], s["brief_drops"])),
           "  filter: kept %d of %d reviewer findings (%s) over %d run(s) with counts"
           % (s["filter"]["kept"], s["filter"]["reviewer_findings"],
              pct(s["filter"]["kept"], s["filter"]["reviewer_findings"]), s["filter"]["runs_with_counts"])]
    for dim in ("model", "repo", "month"):
        out.append("  by %s:" % dim)
        for name, b in s["by"][dim].items():
            out.append("    %-28s findings %3d · acc %3d · decl %3d · unres %3d · acceptance %s"
                       % (name, b["findings"], b["accepted"], b["declined"], b["unresolved"],
                          pct(b["accepted"], b["accepted"] + b["declined"])))
    out.append("hygiene: duplicate rows %d · orphan events %d · malformed rows %d"
               % (s["duplicate_rows"], s["orphan_events"], s["malformed_rows"]))
    out.append("legacy (rows from before the event schema, no ids — counted, never joined): %s" % (s["legacy"] or "{}"))
    return "\n".join(out)


def main(argv):
    args = [a for a in argv if a != "--json"]
    log_dir = os.environ.get("CLAUDE_REVIEW_LOG_DIR") or os.path.join(os.path.expanduser("~"), ".claude", "logs")
    path = args[0] if args else os.path.join(log_dir, "critical-review.jsonl")
    if not os.path.isfile(path):
        sys.stderr.write("log not found: %s\n" % path)
        return 2
    rows, malformed = load(path)
    s = summarize(rows, malformed)
    print(json.dumps(s, indent=2, sort_keys=True) if "--json" in argv else render(s))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
