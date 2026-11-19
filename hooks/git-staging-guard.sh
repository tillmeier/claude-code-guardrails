#!/usr/bin/env bash
#
# git-staging-guard.sh — Claude Code PreToolUse hook (matcher: Bash).
#
# Fires before every Bash tool call; self-gates and only acts on git staging/commit commands.
# Denies the "sweep everything" spellings that let a concurrent session's work ride into a
# Claude-issued commit (real incident: commit 9cc724e, 2026-08-19 — see docs/git-staging-safety.md).
#
#   DENIED : git add -A | --all | -u | --update        (no pathspec: the whole tree)
#            git add . | :/ | -- .                     (a whole-tree pathspec, with or without `--`)
#            git commit -a | -am | -a -m                                 (stages while committing)
#            ...including `git -C <dir> ...` forms and inside && / ; / | chains
#   ALLOWED: git add <path>...            (explicit — what a disciplined commit step does)
#            git add -u -- <path>...      (a sweep flag narrowed to named paths)
#            git add -A -- . ':(exclude,literal)<p>'   (tolerated: the exclude is deliberate narrowing)
#            git commit -m ...            (index already curated)
#
# This is a HABIT guard, not a sandbox: an unusual spelling or a wrapper can evade it
# (`bash -c 'git add -A'`, `eval`, a script file; accepted, see docs/git-staging-safety.md). The rest of
# the safety is procedural — a hard gate on a clean index before you start, then staging BY NAME —
# see docs/git-staging-safety.md.
#
# Contract: exit 2 blocks the tool call and shows stderr to Claude as the reason. Exit 1 does NOT
# block — it is a non-blocking error. The sibling gitleaks hook returned 1 on secrets found and so
# never blocked anything from the day it was written (fixed to 2, then removed entirely 2026-08-19
# because it cost ~63 ms on EVERY Bash call; a grep over the staged diff replaced it).

set -uo pipefail
INPUT=$(cat)

# FAST PATH (pure bash, ~1 ms): this hook fires on EVERY Bash call, so it must cost ~nothing on the
# calls it does not care about. Spawning python3 unconditionally cost ~67 ms per call — the same tax
# that got gitleaks removed on 2026-08-19. Only pay it when the payload could possibly match.
case "$INPUT" in
  *git*) ;;                 # might be relevant, fall through
  *) exit 0 ;;
esac
case "$INPUT" in
  *add*|*commit*) ;;        # only `add` / `commit` are guarded
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
if "git" not in cmd:
    sys.exit(0)

# Split chained commands; each segment is judged on its own.
segments = re.split(r"&&|\|\||;|\||\n", cmd)

# Match only at COMMAND POSITION — the start of a segment, after optional wrappers like
# `(`, `{`, `$(`. Searching anywhere in the segment produced false positives on any command whose
# PAYLOAD merely mentions the string: writing documentation about this guard, or a commit message
# describing it, got blocked. Anchoring also still catches the wrapper evasions `(git add -A)`,
# `$(git add -A)` and `cd x && git add -A`, which a plain `(^|\s)` anchor missed.
# Residual, accepted: a heredoc line that itself BEGINS with `git add -A` still trips it — write
# such files with the Edit/Write tool (not inspected: this hook only sees Bash) or via a file.
LEAD = r"^[\s({]*\$?[\s({]*"
GIT_PREFIX = LEAD + r"git\s+(?:(?:-C|-c|--git-dir|--work-tree)\s+\S+\s+|--no-pager\s+)*"

def deny(reason, seg):
    sys.stderr.write(
        "BLOCKED by git-staging-guard: %s\n\n"
        "  offending segment: %s\n\n"
        "Stage explicitly instead — name the files:\n"
        "  git add <path> [<path>...]\n"
        "  git diff --cached --name-only     # then read the index back before committing\n\n"
        "Why: this repo can have other sessions writing to it. A bare sweep commits their work\n"
        "under your message (incident 9cc724e: 225 lines of a parallel session's rewrite, plus\n"
        "CLAUDE.md, settings.json and a stray .bak). You cannot accidentally NAME someone else's\n"
        "file — which is the whole point of staging by name.\n\n"
        "If this is a doc/commit-message payload rather than a real command, write it with the\n"
        "Edit/Write tool: this guard only inspects Bash.\n" % (reason, seg.strip())
    )
    sys.exit(2)

# End-of-token boundary. Must include ) and } or a wrapped `(git add -A)` / `$(git add -A)` slips
# through: the trailing paren means `-A` is not followed by whitespace-or-end.
END = r"(\s|$|[)}])"

# Pathspecs that name the whole tree (from the repo root or the cwd), and the flags that stage
# every tracked or untracked change when no pathspec narrows them. Short clusters count too
# (`-Av`, `-uv`); `-p`, `-N`, `-f`, `-n`, `-v` alone do not.
WHOLE_TREE = {".", "./", ":/", ":/.", ":/./", "*"}
SWEEP_FLAG = re.compile(r"--all|--update|-[a-zA-Z]*[Au][a-zA-Z]*")
EXCLUDE = re.compile(r"^:(\(exclude|\(top,exclude|!|\^)")

for seg in segments:
    m = re.search(GIT_PREFIX + r"add(\s+.*)?$", seg)
    if m:
        # Per shell word, quotes stripped; everything after a bare `--` is a pathspec. Shell-only
        # parts never reach git, so they must not count as a narrowing pathspec: a redirect goes
        # with its target (`2>&1`, `>/dev/null`, `> log`, and a quoted target with spaces,
        # `2> "build output.log"`), and a comment ends the list. Words are split quote-aware, so a
        # quoted path with spaces stays one word.
        WORD = r'''"[^"]*"|'[^']*'|\S+'''
        args = re.sub(r"(?:^|(?<=\s))[0-9&]*(?:>>?|<)&?[ \t]*(?:" + WORD + r")?", " ", m.group(1) or "")
        tokens = []
        for t in re.findall(WORD, args):
            if t.startswith("#"):
                break
            t = t.rstrip(")}").strip("'\"")
            if t:                      # a lone `)` left behind by a removed redirect is not a path
                tokens.append(t)
        if "--" in tokens:
            opts, specs = tokens[:tokens.index("--")], tokens[tokens.index("--") + 1:]
        else:
            opts = [t for t in tokens if t.startswith("-")]
            specs = [t for t in tokens if not t.startswith("-")]
        sweep_flag = any(SWEEP_FLAG.fullmatch(t) for t in opts)
        whole_tree = any(t in WHOLE_TREE for t in specs)
        # `git add -A -- . ':(exclude)<p>'` stays allowed: the exclude is the deliberate narrowing.
        narrowed = any(EXCLUDE.match(t) for t in specs)
        # A dry run (`-n` / `--dry-run`) only lists what would be staged; `-N` is intent-to-add.
        dry_run = any(t == "--dry-run" or re.fullmatch(r"-[a-zA-Z]*n[a-zA-Z]*", t) for t in opts)
        if not narrowed and not dry_run and (whole_tree or (sweep_flag and not specs)):
            deny("bare `git add` sweep (-A / --all / -u / --update / . / :/) with no narrowing pathspec", seg)

    m = re.search(GIT_PREFIX + r"commit(\s+.*)?$", seg)
    if m:
        args = (m.group(1) or "").strip()
        # -a as its own flag or bundled in a short cluster (-am, -sam), or the long form --all.
        # Judged per token so `--amend`, `--author=` and `--allow-empty` never count as `-a`, and
        # so `-a --amend` cannot hide behind them. (Public port: the private copy exempted any
        # `--a…` option from the whole check and did not know `--all` at all.)
        tokens = [t.rstrip(")}") for t in re.split(r"\s+", args) if t]
        if any(re.fullmatch(r"-[a-zA-Z]*a[a-zA-Z]*", t) or t == "--all" for t in tokens):
            deny("`git commit -a` / `--all` stages tracked changes implicitly", seg)

sys.exit(0)
PY
