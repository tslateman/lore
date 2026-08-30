#!/usr/bin/env bash
#
# handoff-worker.sh - Drain pending handoff requests queued by
# session-handoff.sh. Runs detached from Claude Code hooks, so it can
# afford the slow parts: transcript summarization via `claude -p` and
# recording via `lore handoff`.
#
# Loud by design: every stage logs to $LORE_DATA_DIR/logs/handoff.log.
# Queue entries are removed only after a successful handoff write;
# after MAX_ATTEMPTS failures they move to failed/ for inspection.
#
# Modes:
#   (default)   drain the queue
#   --health    report queue depth, last success age, recent log lines

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${LORE_DIR}/lib/paths.sh"
source "${LORE_DIR}/lib/model.sh"
LORE_SH="${LORE_DIR}/lore.sh"

QUEUE_DIR="${LORE_TRANSFER_DATA}/pending-handoffs"
FAILED_DIR="${QUEUE_DIR}/failed"
LOCK_DIR="${QUEUE_DIR}/.lock"
LOG_DIR="${LORE_DATA_DIR}/logs"
LOG_FILE="${LOG_DIR}/handoff.log"
SUCCESS_STAMP="${LOG_DIR}/handoff.last-success"

MIN_MESSAGES=10
MAX_MESSAGES=80
MAX_ATTEMPTS=3
TIMEOUT_SECS=90
LOCK_STALE_SECS=600
LOG_MAX_LINES=5000
HANDOFF_MODEL="${LORE_HANDOFF_MODEL:-claude-haiku-4-5-20251001}"

log() {
    mkdir -p "${LOG_DIR}"
    printf '%s [worker] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${LOG_FILE}"
}

#######################################
# Health report — human-facing, prints to stdout.
#######################################
if [[ "${1:-}" == "--health" ]]; then
    pending=$(ls "${QUEUE_DIR}"/*.json 2>/dev/null | wc -l | tr -d ' ') || pending=0
    failed=$(ls "${FAILED_DIR}"/*.json 2>/dev/null | wc -l | tr -d ' ') || failed=0
    echo "Handoff pipeline health"
    echo "  Pending queue: ${pending}"
    echo "  Failed (needs inspection): ${failed}"
    if [[ -f "${SUCCESS_STAMP}" ]]; then
        last=$(cat "${SUCCESS_STAMP}")
        age_secs=$(( $(date +%s) - $(stat -f %m "${SUCCESS_STAMP}") ))
        age_days=$(( age_secs / 86400 ))
        echo "  Last success: ${last} (${age_days}d ago)"
        [[ "${age_days}" -ge 7 ]] && echo "  WARNING: no successful handoff in ${age_days} days — pipeline may be broken"
    else
        echo "  Last success: never recorded"
        echo "  WARNING: no successful handoff on record — pipeline may be broken"
    fi
    if [[ -f "${LOG_FILE}" ]]; then
        echo "  Recent log:"
        tail -10 "${LOG_FILE}" | sed 's/^/    /'
    fi
    exit 0
fi

# --- Drain mode ---

command -v python3 >/dev/null 2>&1 || { log "ERROR python3 not found"; exit 1; }
command -v claude  >/dev/null 2>&1 || { log "ERROR claude CLI not found on PATH"; exit 1; }
[[ -f "${LORE_SH}" ]] || { log "ERROR lore.sh not found at ${LORE_SH}"; exit 1; }

mkdir -p "${QUEUE_DIR}" "${FAILED_DIR}" "${LOG_DIR}"

# Single-worker lock; steal if stale (previous worker died).
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
    lock_age=$(( $(date +%s) - $(stat -f %m "${LOCK_DIR}" 2>/dev/null || echo 0) ))
    if [[ "${lock_age}" -lt "${LOCK_STALE_SECS}" ]]; then
        log "SKIP another worker holds the lock (age ${lock_age}s)"
        exit 0
    fi
    log "WARN stealing stale lock (age ${lock_age}s)"
fi
trap 'rmdir "${LOCK_DIR}" 2>/dev/null || true' EXIT

#######################################
# Run a command with a timeout (bash 3.2 / macOS safe).
#######################################
run_with_timeout() {
    local secs="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then timeout "${secs}" "$@"; return $?; fi
    if command -v gtimeout >/dev/null 2>&1; then gtimeout "${secs}" "$@"; return $?; fi
    local out rc=0
    out=$(mktemp "${TMPDIR:-/tmp}/lore-timeout.XXXXXX")
    "$@" >"${out}" &
    local pid=$!
    ( sleep "${secs}"; kill "${pid}" 2>/dev/null ) >/dev/null 2>&1 &
    local killer=$!
    wait "${pid}" 2>/dev/null || rc=$?
    kill "${killer}" 2>/dev/null
    wait "${killer}" 2>/dev/null || true
    cat "${out}"
    rm -f "${out}"
    return "${rc}"
}

#######################################
# Process one queue entry. Returns 0 on success or permanent skip
# (entry removed), 1 on retryable failure (entry kept, attempts bumped).
#######################################
process_entry() {
    local entry="$1"
    local id
    id=$(basename "${entry}" .json)

    local parsed transcript_path cwd attempts
    parsed=$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("transcript_path") or "")
print(d.get("cwd") or "")
print(d.get("attempts") or 0)
' "${entry}" 2>/dev/null)
    if [[ -z "${parsed}" ]]; then
        log "DROP ${id}: unreadable queue entry"
        mv "${entry}" "${FAILED_DIR}/" 2>/dev/null || rm -f "${entry}"
        return 0
    fi
    transcript_path=$(printf '%s\n' "${parsed}" | sed -n 1p)
    cwd=$(printf '%s\n' "${parsed}" | sed -n 2p)
    attempts=$(printf '%s\n' "${parsed}" | sed -n 3p)

    if [[ ! -f "${transcript_path}" ]]; then
        log "DROP ${id}: transcript gone (${transcript_path})"
        rm -f "${entry}"
        return 0
    fi
    [[ -d "${cwd}" ]] || cwd="${HOME}"

    # Extract recent user/assistant text; exit 3 = too small to summarize.
    local messages rc=0
    messages=$(python3 - "${transcript_path}" "${MAX_MESSAGES}" "${MIN_MESSAGES}" << 'PYEOF'
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
    ) || rc=$?
    if [[ "${rc}" -eq 3 ]]; then
        log "DROP ${id}: transcript too small to summarize"
        rm -f "${entry}"
        return 0
    fi
    if [[ "${rc}" -ne 0 || -z "${messages}" ]]; then
        log "FAIL ${id}: transcript extraction failed (rc=${rc})"
        return 1
    fi

    local prompt="You are writing a session handoff note for the next work session. \
Based on the transcript below, write a concise handoff (under 200 words) covering: \
1) What was accomplished. \
2) Next steps, in priority order. \
3) Blockers. \
4) Open questions. \
Use plain sentences, no markdown headers. Omit empty categories. \
Output only the handoff text, nothing else."

    local handoff err
    err=$(mktemp "${TMPDIR:-/tmp}/handoff-err.XXXXXX")
    handoff=$(printf '%s\n' "${messages}" | \
        run_with_timeout "${TIMEOUT_SECS}" \
        claude -p "${prompt}" --model "${HANDOFF_MODEL}" \
        "${LORE_CLAUDE_ISOLATION[@]}" 2> "${err}")
    rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        log "FAIL ${id}: claude -p rc=${rc}: $(tail -1 "${err}" 2>/dev/null)"
        rm -f "${err}"
        return 1
    fi
    rm -f "${err}"

    handoff=$(printf '%s' "${handoff}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [[ "${#handoff}" -lt 40 ]]; then
        log "FAIL ${id}: summary too short (${#handoff} chars)"
        return 1
    fi

    # Record from the session's working directory so the project name
    # derives from its git root.
    local out
    if ! out=$(cd "${cwd}" && "${LORE_SH}" transfer init 2>&1 >/dev/null); then
        log "FAIL ${id}: lore transfer init: ${out}"
        return 1
    fi
    if ! out=$(cd "${cwd}" && "${LORE_SH}" handoff "${handoff}" 2>&1 >/dev/null); then
        log "FAIL ${id}: lore handoff: ${out}"
        return 1
    fi

    rm -f "${entry}"
    date -u +%Y-%m-%dT%H:%M:%SZ > "${SUCCESS_STAMP}"
    log "OK ${id}: handoff recorded (${#handoff} chars, project cwd ${cwd})"
    return 0
}

drained=0
for entry in "${QUEUE_DIR}"/*.json; do
    [[ -f "${entry}" ]] || continue
    if process_entry "${entry}"; then
        drained=$((drained + 1))
        continue
    fi
    # Retryable failure: bump attempts, retire after MAX_ATTEMPTS.
    attempts=$(python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["attempts"] = int(d.get("attempts") or 0) + 1
json.dump(d, open(p, "w"))
print(d["attempts"])
' "${entry}" 2>/dev/null || echo "${MAX_ATTEMPTS}")
    if [[ "${attempts}" -ge "${MAX_ATTEMPTS}" ]]; then
        log "RETIRE $(basename "${entry}" .json): ${attempts} failed attempts, moving to failed/"
        mv "${entry}" "${FAILED_DIR}/" 2>/dev/null || true
    fi
done
remaining=$(ls "${QUEUE_DIR}"/*.json 2>/dev/null | wc -l | tr -d ' ') || remaining=0
log "DONE drained=${drained} pending=${remaining}"

# Cheap log rotation: keep the tail when the log grows large.
if [[ -f "${LOG_FILE}" ]] && [[ $(wc -l < "${LOG_FILE}") -gt "${LOG_MAX_LINES}" ]]; then
    tail -n $((LOG_MAX_LINES / 2)) "${LOG_FILE}" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "${LOG_FILE}"
fi
exit 0
