#!/usr/bin/env bash
#
# session-handoff.sh - Auto-handoff hook for Claude Code
#
# Register under SessionEnd and PreCompact (see install-handoff-hook.sh).
# Reads hook JSON on stdin, enqueues a handoff request, and spawns a
# detached worker (handoff-worker.sh) to summarize and record it.
#
# The hook itself does no slow work: SessionEnd hooks get cancelled when
# they outrun the hook budget, so summarization runs in the worker,
# outside the hook's lifetime.
#
# Contract: always exits 0 (never blocks Claude Code) but never fails
# silently — every skip and error is logged to $LORE_DATA_DIR/logs/handoff.log.
#
# Modes:
#   (stdin JSON)   enqueue this session and spawn the worker
#   --drain        spawn the worker to drain any pending requests
#   --health       report pipeline health (delegates to worker)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LORE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${LORE_DIR}/lib/paths.sh"

WORKER="${SCRIPT_DIR}/handoff-worker.sh"
QUEUE_DIR="${LORE_TRANSFER_DATA}/pending-handoffs"
LOG_DIR="${LORE_DATA_DIR}/logs"
LOG_FILE="${LOG_DIR}/handoff.log"

# Transcripts below this line count are nested `claude -p` runs or
# trivial sessions — not worth a handoff.
MIN_TRANSCRIPT_LINES=10

log() {
    mkdir -p "${LOG_DIR}"
    printf '%s [hook] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${LOG_FILE}"
}

spawn_worker() {
    if [[ ! -x "${WORKER}" ]]; then
        log "ERROR worker missing or not executable: ${WORKER}"
        return 1
    fi
    mkdir -p "${LOG_DIR}"
    nohup "${WORKER}" >> "${LOG_FILE}" 2>&1 &
    disown 2>/dev/null || true
}

case "${1:-}" in
    --health)
        exec "${WORKER}" --health
        ;;
    --drain)
        spawn_worker || true
        exit 0
        ;;
esac

# --- Enqueue mode: hook JSON on stdin ---

input=$(cat 2>/dev/null || true)
if [[ -z "${input}" ]]; then
    log "SKIP empty stdin (no hook JSON)"
    exit 0
fi

parse_rc=0
parsed=$(printf '%s' "${input}" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
print(data.get("transcript_path") or "")
print(data.get("cwd") or "")
print(data.get("hook_event_name") or "")
' 2>/dev/null) || parse_rc=$?
if [[ "${parse_rc}" -ne 0 || -z "${parsed}" ]]; then
    log "ERROR unparseable hook JSON on stdin"
    exit 0
fi

transcript_path=$(printf '%s\n' "${parsed}" | sed -n 1p)
cwd=$(printf '%s\n' "${parsed}" | sed -n 2p)
event=$(printf '%s\n' "${parsed}" | sed -n 3p)
[[ -n "${cwd}" && -d "${cwd}" ]] || cwd="${PWD}"

if [[ -z "${transcript_path}" || ! -f "${transcript_path}" ]]; then
    log "SKIP no transcript (event=${event:-unknown})"
    exit 0
fi

lines=$(wc -l < "${transcript_path}" 2>/dev/null | tr -d ' ') || lines=""
if [[ -z "${lines}" || "${lines}" -lt "${MIN_TRANSCRIPT_LINES}" ]]; then
    log "SKIP tiny transcript (${lines:-0} lines, likely nested claude -p): $(basename "${transcript_path}")"
    exit 0
fi

# Enqueue: one JSON file per transcript, atomic write, latest wins.
mkdir -p "${QUEUE_DIR}"
entry_id="$(basename "${transcript_path}" .jsonl)"
entry="${QUEUE_DIR}/${entry_id}.json"
tmp="${entry}.tmp.$$"

if python3 - "${transcript_path}" "${cwd}" "${event:-unknown}" > "${tmp}" << 'PYEOF'
import json, sys
print(json.dumps({
    "transcript_path": sys.argv[1],
    "cwd": sys.argv[2],
    "event": sys.argv[3],
    "attempts": 0,
}))
PYEOF
then
    mv "${tmp}" "${entry}"
    log "ENQUEUED ${entry_id} (event=${event:-unknown}, ${lines} lines)"
else
    rm -f "${tmp}"
    log "ERROR failed to write queue entry for ${entry_id}"
    exit 0
fi

spawn_worker || true
exit 0
