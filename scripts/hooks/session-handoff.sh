#!/usr/bin/env bash
#
# session-handoff.sh - Auto-handoff hook for Claude Code
#
# Register under SessionEnd and PreCompact (see install-handoff-hook.sh).
# Reads hook JSON on stdin, summarizes the session transcript with a
# fast model, and records the result via `lore handoff` so the next
# `lore resume` starts with real context.
#
# Fail-silent contract: every exit path returns 0. This hook must never
# block Claude Code, and it never writes a partial or empty handoff.
#

set -u

LORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LORE_SH="${LORE_DIR}/lore.sh"

MIN_MESSAGES=10
MAX_MESSAGES=80
TIMEOUT_SECS=60
HANDOFF_MODEL="${LORE_HANDOFF_MODEL:-claude-haiku-4-5-20251001}"

bail() { exit 0; }

# Prerequisites -- skip silently when anything is missing
command -v python3 >/dev/null 2>&1 || bail
command -v claude >/dev/null 2>&1 || bail
[[ -f "${LORE_SH}" ]] || bail

# Read hook JSON from stdin
input=$(cat 2>/dev/null) || bail
[[ -n "${input}" ]] || bail

# Parse fields (transcript_path required; cwd falls back to PWD)
parsed=$(printf '%s' "${input}" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
print(data.get("transcript_path") or "")
print(data.get("cwd") or "")
' 2>/dev/null) || bail

transcript_path=$(printf '%s\n' "${parsed}" | sed -n 1p)
cwd=$(printf '%s\n' "${parsed}" | sed -n 2p)
[[ -n "${transcript_path}" && -f "${transcript_path}" ]] || bail
[[ -n "${cwd}" && -d "${cwd}" ]] || cwd="${PWD}"

# Extract the last user/assistant text messages from the transcript.
# Exits non-zero when the transcript is too small to summarize.
messages=$(python3 - "${transcript_path}" "${MAX_MESSAGES}" "${MIN_MESSAGES}" << 'PYEOF' 2>/dev/null
import json, sys

path, limit, minimum = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
msgs = []
with open(path, errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("type") not in ("user", "assistant"):
            continue
        message = entry.get("message") or {}
        role = message.get("role") or entry.get("type")
        content = message.get("content")
        parts = []
        if isinstance(content, str):
            parts.append(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    parts.append(block.get("text") or "")
        text = "\n".join(p for p in parts if p).strip()
        if not text:
            continue
        msgs.append("%s: %s" % (str(role).upper(), text[:2000]))

if len(msgs) < minimum:
    sys.exit(3)
print("\n\n".join(msgs[-limit:]))
PYEOF
) || bail
[[ -n "${messages}" ]] || bail

#######################################
# Run a command with a timeout.
# Uses `timeout` when available, else background + kill (bash 3.2 safe).
# Args: seconds, command...
#######################################
run_with_timeout() {
    local secs="$1"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout "${secs}" "$@"
        return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${secs}" "$@"
        return $?
    fi

    "$@" &
    local pid=$!
    ( sleep "${secs}"; kill "${pid}" 2>/dev/null ) &
    local killer=$!
    local rc=0
    wait "${pid}" 2>/dev/null || rc=$?
    kill "${killer}" 2>/dev/null
    wait "${killer}" 2>/dev/null || true
    return "${rc}"
}

prompt="You are writing a session handoff note for the next work session. \
Based on the transcript below, write a concise handoff (under 200 words) covering: \
1) What was accomplished. \
2) Next steps, in priority order. \
3) Blockers. \
4) Open questions. \
Use plain sentences, no markdown headers. Omit empty categories. \
Output only the handoff text, nothing else."

handoff=$(printf '%s\n' "${messages}" | \
    run_with_timeout "${TIMEOUT_SECS}" \
    claude -p "${prompt}" --model "${HANDOFF_MODEL}" 2>/dev/null) || bail

# Validate: never write empty or truncated junk
handoff=$(printf '%s' "${handoff}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
[[ "${#handoff}" -ge 40 ]] || bail

# Record from the session's working directory so the project name
# derives from its git root (or directory basename)
cd "${cwd}" 2>/dev/null || bail
"${LORE_SH}" transfer init >/dev/null 2>&1 || bail
"${LORE_SH}" handoff "${handoff}" >/dev/null 2>&1 || bail

exit 0
