#!/usr/bin/env bash
# check-links.sh - Resolve every relative markdown link against the disk
#
# External http(s) links are skipped by default: a network round trip in CI
# turns an unrelated outage into a red build. Pass --external to check them.
#
# Usage: scripts/check-links.sh [--external]

set -euo pipefail

LORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LORE_DIR"

CHECK_EXTERNAL=0
if [[ "${1:-}" == "--external" ]]; then
    CHECK_EXTERNAL=1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "check-links: python3 is not on PATH." >&2
    exit 1
fi

git ls-files -z '*.md' | CHECK_EXTERNAL="$CHECK_EXTERNAL" python3 -c '
import os, re, sys, subprocess
from urllib.parse import unquote, urlparse

root = os.getcwd()
files = [f for f in sys.stdin.buffer.read().decode().split("\0") if f]
check_external = os.environ["CHECK_EXTERNAL"] == "1"

FENCE = re.compile(r"^\s{0,3}(```|~~~)")
INLINE_CODE = re.compile(r"`[^`\n]*`")
INLINE_LINK = re.compile(r"!?\[[^\]]*\]\(\s*([^)\s]+(?:\s+\"[^\"]*\")?)\s*\)")
ANGLE_LINK = re.compile(r"!?\[[^\]]*\]\(\s*<([^>]*)>\s*\)")
REF_DEF = re.compile(r"^[ ]{0,3}\[[^\]]+\]:[ \t]*(\S+)", re.MULTILINE)

def blank(match):
    return re.sub(r"[^\n]", " ", match.group(0))

def readable(path):
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    out, in_fence = [], False
    for line in lines:
        if FENCE.match(line):
            in_fence = not in_fence
            out.append("")
            continue
        out.append("" if in_fence else line)
    return INLINE_CODE.sub(blank, "\n".join(out))

broken, external, anchors, checked = [], [], 0, 0

for path in files:
    text = readable(path)
    found = []
    for m in ANGLE_LINK.finditer(text):
        found.append((m.start(), m.group(1)))
    for m in INLINE_LINK.finditer(ANGLE_LINK.sub(blank, text)):
        found.append((m.start(), m.group(1).split(" ", 1)[0]))
    for m in REF_DEF.finditer(text):
        found.append((m.start(), m.group(1)))

    for offset, target in found:
        lineno = text.count("\n", 0, offset) + 1
        target = target.strip().strip("\"")
        if not target:
            continue
        scheme = urlparse(target).scheme
        if scheme in ("http", "https"):
            external.append((path, lineno, target))
            continue
        if scheme or target.startswith("//"):
            continue
        if target.startswith("#"):
            anchors += 1
            continue
        rel = unquote(target.split("#", 1)[0].split("?", 1)[0])
        if not rel:
            anchors += 1
            continue
        base = root if rel.startswith("/") else os.path.dirname(os.path.join(root, path))
        resolved = os.path.normpath(os.path.join(base, rel.lstrip("/")))
        checked += 1
        if not os.path.exists(resolved):
            broken.append((path, lineno, target))

for path, lineno, target in sorted(broken):
    print("%s:%d: broken link: %s" % (path, lineno, target))

failed = len(broken)

if check_external:
    seen, dead = {}, []
    for path, lineno, target in external:
        if target not in seen:
            rc = subprocess.run(
                ["curl", "-sSL", "-o", os.devnull, "-w", "%{http_code}",
                 "--max-time", "20", "-A", "lore-check-links", target],
                capture_output=True, text=True,
            )
            seen[target] = rc.stdout.strip() or "000"
        if not seen[target].startswith(("2", "3")):
            dead.append((path, lineno, target, seen[target]))
    for path, lineno, target, code in dead:
        print("%s:%d: external link returned %s: %s" % (path, lineno, target, code))
    failed += len(dead)
    print()
    print("check-links: %d external links checked, %d dead" % (len(seen), len(dead)))
else:
    print()
    print("check-links: %d external http(s) links SKIPPED (run with --external to check them)"
          % len({t for _, _, t in external}))

print("check-links: %d relative links resolved against disk across %d files" % (checked, len(files)))
print("check-links: %d in-page anchors not checked" % anchors)

if failed:
    print("check-links: %d broken." % failed)
    sys.exit(1)
print("check-links: no broken links")
'
