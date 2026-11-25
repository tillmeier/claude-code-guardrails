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
import json, re, shlex, sys

try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)                      # unparseable input: never block on our own bug

if data.get("tool_name") != "Bash":
    sys.exit(0)
cmd = (data.get("tool_input") or {}).get("command") or ""
if "git" not in cmd:
    sys.exit(0)

# Split chained commands; each segment is judged on its own. Only UNQUOTED `&&` `||` `;` `|` split: a
# plain regex split also cut `git add -A > "audit;log"` inside the quotes, and the half with the open
# quote was then skipped as payload (Codex review 25.11.2026). A line break always splits and resets the
# quote state, as before - otherwise an apostrophe in a heredoc body (`don't`) would swallow every
# command after it. Backslash-newline is a continuation, not a break.
def split_segments(text):
    text = text.replace("\\\n", " ")
    segs, cur, q, i = [], [], None, 0
    while i < len(text):
        ch = text[i]
        if ch == "\n":
            segs.append("".join(cur)); cur, q = [], None
        elif q == "'":
            cur.append(ch); q = None if ch == "'" else q
        elif q == '"':
            cur.append(ch)
            if ch == "\\" and i + 1 < len(text) and text[i + 1] != "\n":
                cur.append(text[i + 1]); i += 1
            elif ch == '"':
                q = None
        elif ch == "\\" and i + 1 < len(text):
            cur.append(ch); cur.append(text[i + 1]); i += 1
        elif ch in "'\"":
            cur.append(ch); q = ch
        elif text.startswith("&&", i) or text.startswith("||", i):
            segs.append("".join(cur)); cur = []; i += 1
        elif ch in ";|":
            segs.append("".join(cur)); cur = []
        else:
            cur.append(ch)
        i += 1
    segs.append("".join(cur))
    return segs


segments = split_segments(cmd)

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

def shell_words(args):
    """The words git would see, as the shell builds them (shlex, 25.11.2026). The hand-built splitter before
    it broke `"$TMPDIR"/git.log` into two words (so a redirect target counted as a narrowing pathspec)
    and read `"."/src/a.sh` as `.`, the whole tree - four gaps in the same spot, found by Gemini.
    Redirect operators (`>`, `>>`, `<`, `<>`, `<<<`, `>&`, `&>` ...) take their target with them, a file
    descriptor written directly before one is not a word, a word starting with `#` ends the list, and the
    closing `)` of `(git add …)` / `$(git add …)` is dropped. Unbalanced quotes return None: the segment
    split cut through a quoted string (`grep -E '… && git add -A )'`), so this is payload, not a command
    the shell would run - the only new block in a 30-day replay of 8,510 real calls."""
    args = mask_substitutions(strip_comment(args))
    args = re.sub(r"(?:^|(?<=\s))\d+(?=[<>])", " ", args)
    try:
        lx = shlex.shlex(args, posix=True, punctuation_chars=True)
        lx.whitespace_split = True
        lx.commenters = ""
        raw = list(lx)
    except ValueError:
        return None
    words, i = [], 0
    while i < len(raw):
        t = raw[i]
        if re.fullmatch(r"[<>&|;()]+", t):
            i += 2 if ("<" in t or ">" in t) else 1      # a redirect consumes its target; `)` `&` stand alone
            continue
        words.append(t.rstrip(")}"))
        i += 1
    return [w for w in words if w]


def mask_substitutions(args):
    """Replace `$(…)`, `$((…))` and backticks (outside single quotes) by one placeholder word, so the
    substitution stays part of the word it is glued to: `2>$(mktemp -d)/x` is one redirect target, not
    a target plus a "pathspec" `/x` (punctuation_chars would split the parentheses apart)."""
    out, i, q = [], 0, None
    while i < len(args):
        ch = args[i]
        if q == "'":
            q = None if ch == "'" else q
        elif ch == "'" and q is None:
            q = "'"
        elif ch == '"':
            q = None if q == '"' else '"'
        elif ch == "`" or (ch == "$" and args[i + 1:i + 2] == "("):
            j, depth = i + 1, 0
            if ch == "`":
                j = args.find("`", i + 1)
                j = len(args) if j < 0 else j + 1
            else:
                while j < len(args):
                    depth += {"(": 1, ")": -1}.get(args[j], 0)
                    j += 1
                    if depth == 0:
                        break
            out.append("SUBST")
            i = j
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def strip_comment(args):
    """Cut a shell comment: `#` at the start of a word, outside quotes. Done before shlex because an
    apostrophe inside a comment (`# don't`) is an unbalanced quote to shlex (Gemini review of v0.6.7),
    and after shlex a quoted `"#x"` would look like a comment."""
    q, prev = None, " "
    for i, ch in enumerate(args):
        if q:
            if ch == q:
                q = None
        elif ch in "'\"":
            q = ch
        elif ch == "#" and prev.isspace():
            return args[:i]
        prev = ch
    return args


for seg in segments:
    m = re.search(GIT_PREFIX + r"add(\s+.*)?$", seg)
    if m:
        # Per shell word, quotes stripped; everything after a bare `--` is a pathspec. Shell-only
        # parts never reach git, so they must not count as a narrowing pathspec: a redirect goes
        # with its target (`2>&1`, `>/dev/null`, `> log`, and a quoted target with spaces,
        # `2> "build output.log"`), and a comment ends the list. Words are split quote-aware, so a
        # quoted path with spaces stays one word.
        tokens = shell_words(m.group(1) or "")
        if tokens is None:
            continue
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
        # Shell words, not whitespace pieces: a quoted message such as "… for every -abc suffix" is ONE
        # word and no flag (a whitespace split read `-abc` as `-a`). The value after -m/-F/-C/-c and the
        # other value-taking options is skipped too, so a message "-a" is not a flag either.
        words = shell_words(args)
        if words is None:
            words = []
        tokens, skip = [], False
        for t in words:
            if skip:
                skip = False
                continue
            if t in ("-m", "-F", "-C", "-c", "-t", "--message", "--file", "--author", "--date", "--template",
                     "--reuse-message", "--reedit-message", "--fixup", "--squash", "--cleanup", "--trailer"):
                skip = True
                continue
            tokens.append(t)
        if any(re.fullmatch(r"-[a-zA-Z]*a[a-zA-Z]*", t) or t == "--all" for t in tokens):
            deny("`git commit -a` / `--all` stages tracked changes implicitly", seg)

sys.exit(0)
PY
