#!/usr/bin/env python3
"""review-log.py — append ONE event to the /critical-review log.

  python3 review-log.py <event> session=<sid> [key=value ...]

The log (${CLAUDE_REVIEW_LOG_DIR:-~/.claude/logs}/critical-review.jsonl) is a stream of immutable
events joined by ids. Nobody edits rows; a decision is its own event, written when it happens, and a
finding without one is unresolved — never guessed.

  run                   prints a new run id (<session>-<epoch>-<hex>) on stdout; carry the counts
                        reviewer_findings kept dropped_scope dropped_judgment dropped_brief
  finding               run_id=<id> n=<N|LN>   → fid <run_id>-<N>  (N/Total or L1.. as rendered)
  decision              run_id= n= decision=accepted|declined via=plan_approval|go_ahead|plan_request|pushback
  resolution            run_id= n= status=auto_applied|skipped|failed|abandoned
  brief_drop            run_id=<id> k=<K>      → drop_id <run_id>-D<K>
  brief_drop_overruled  run_id= k=

Every event except `run` needs the run_id of the review it belongs to — the one printed with that
review — so a reply to an earlier review in the same session is never credited to a later one.
Exit 0 = written (prints the run id / fid / drop_id), exit 1 = rejected, nothing written.
"""
import json
import os
import re
import secrets
import sys
import time

EVENTS = {"run", "finding", "decision", "resolution", "brief_drop", "brief_drop_overruled"}
SAFE_ID = re.compile(r"^[A-Za-z0-9._-]+$")
NUMERIC = {"line_start", "line_end", "reviewer_findings", "kept", "dropped_scope", "dropped_judgment", "dropped_brief"}
VOCAB = {
    "decision": {"decision": {"accepted", "declined"}, "via": {"plan_approval", "go_ahead", "plan_request", "pushback"}},
    "resolution": {"status": {"auto_applied", "skipped", "failed", "abandoned"}},
}
RESERVED = {"ts", "event", "fid", "drop_id"}


def fail(msg):
    sys.stderr.write("review-log: %s — nothing written\n" % msg)
    sys.exit(1)


def main(argv):
    if not argv or argv[0] not in EVENTS:
        fail("first argument must be one of: %s" % " ".join(sorted(EVENTS)))
    event, fields = argv[0], {}
    for arg in argv[1:]:
        key, sep, value = arg.partition("=")
        if not sep or not re.match(r"^[a-z_]+$", key):
            fail("expected key=value with a lowercase key, got %r" % arg)
        if key in RESERVED:
            fail("%s is set by this script, not by the caller" % key)
        fields[key] = value

    session = fields.get("session", "")
    if not SAFE_ID.match(session):
        fail("session= missing or not [A-Za-z0-9._-]: %r" % session)

    if event == "run":
        if "run_id" in fields:
            fail("run generates its own run_id")
        fields["run_id"] = "%s-%d-%s" % (session, int(time.time()), secrets.token_hex(3))
        out = fields["run_id"]
    else:
        run_id = fields.get("run_id", "")
        if not SAFE_ID.match(run_id):
            fail("run_id= missing or malformed: %r — use the id printed with the review" % run_id)
        if event in ("finding", "decision", "resolution"):
            n = fields.pop("n", "")
            if not re.match(r"^L?[0-9]+$", n):
                fail("n= must be the finding's number as rendered (3, or L2 for likely-in-scope), got %r" % n)
            fields["fid"] = out = "%s-%s" % (run_id, n)
        else:
            k = fields.pop("k", "")
            if not re.match(r"^[0-9]+$", k):
                fail("k= must be the brief drop's number, got %r" % k)
            fields["drop_id"] = out = "%s-D%s" % (run_id, k)
        for key, allowed in VOCAB.get(event, {}).items():
            if fields.get(key) not in allowed:
                fail("%s= must be one of %s, got %r" % (key, "|".join(sorted(allowed)), fields.get(key)))

    for key in NUMERIC & set(fields):
        try:
            fields[key] = int(fields[key])
        except ValueError:
            fail("%s= must be an integer, got %r" % (key, fields[key]))
    if "brief_active" in fields:
        fields["brief_active"] = fields["brief_active"] in ("1", "true")

    entry = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "event": event}
    entry.update(fields)
    log_dir = os.environ.get("CLAUDE_REVIEW_LOG_DIR") or os.path.join(os.path.expanduser("~"), ".claude", "logs")
    try:
        os.makedirs(log_dir, exist_ok=True)
        with open(os.path.join(log_dir, "critical-review.jsonl"), "a", encoding="utf-8") as fh:
            fh.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError as e:
        fail("cannot append to the log: %s" % e)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
