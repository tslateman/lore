#!/usr/bin/env bash
#
# Prune - Archive sessions that carry no signal
#
# A session carries no signal when its summary, handoff (message, next
# steps, blockers, questions), accomplishments (goals, decisions,
# patterns), and open threads are all empty.
#
# Prune backs up ALL session files to a tar.gz in the data directory,
# then moves empty sessions older than the age window (default 7 days)
# to sessions/archive/. Nothing is deleted. The current session is
# never pruned.
#

#######################################
# Check whether a session file carries no signal
# Returns 0 (empty) when every content field is blank.
# Invalid JSON counts as signal (conservative: keep it).
# Args: session_file path
#######################################
is_session_empty() {
    local session_file="$1"

    jq -e '
        ((.summary // "") == "" or (.summary // "") == "(no summary)")
        and ((.handoff.message // "") == "")
        and (((.handoff.next_steps // []) | length) == 0)
        and (((.handoff.blockers // []) | length) == 0)
        and (((.handoff.questions // []) | length) == 0)
        and (((.goals_addressed // []) | length) == 0)
        and (((.decisions_made // []) | length) == 0)
        and (((.patterns_learned // []) | length) == 0)
        and (((.open_threads // []) | length) == 0)
    ' "${session_file}" >/dev/null 2>&1
}

#######################################
# Archive empty sessions older than N days
# Usage: prune_sessions [--days N] [--dry-run]
#######################################
prune_sessions() {
    local days=7
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --days)
                shift
                days="${1:-}"
                ;;
            --dry-run)
                dry_run=true
                ;;
            *)
                echo "Unknown option: $1" >&2
                echo "Usage: transfer.sh prune [--days N] [--dry-run]" >&2
                return 1
                ;;
        esac
        shift
    done

    if ! [[ "${days}" =~ ^[0-9]+$ ]]; then
        echo "Invalid --days value: ${days}" >&2
        return 1
    fi

    if [[ ! -d "${SESSIONS_DIR}" ]]; then
        echo "No sessions directory: ${SESSIONS_DIR}"
        return 0
    fi

    local archive_dir="${SESSIONS_DIR}/archive"

    # The current session is never pruned
    local current_session=""
    [[ -f "${CURRENT_SESSION_FILE}" ]] && current_session=$(cat "${CURRENT_SESSION_FILE}")

    # Back up everything before moving anything
    if [[ "${dry_run}" == "false" ]]; then
        local backup_file="${DATA_DIR}/sessions-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
        if ! tar -czf "${backup_file}" -C "${DATA_DIR}" sessions 2>/dev/null; then
            echo "Backup failed; aborting prune." >&2
            rm -f "${backup_file}"
            return 1
        fi
        echo "Backup: ${backup_file}"
        mkdir -p "${archive_dir}"
    fi

    local now
    now=$(date +%s)

    local total=0 archived=0 kept_signal=0 kept_recent=0

    local session_file
    for session_file in "${SESSIONS_DIR}"/*.json; do
        [[ -f "${session_file}" ]] || continue
        total=$((total + 1))

        local session_id
        session_id=$(basename "${session_file}" .json)

        if [[ -n "${current_session}" && "${session_id}" == "${current_session}" ]]; then
            kept_recent=$((kept_recent + 1))
            continue
        fi

        # Age gate: keep files modified within the window
        local mtime age_days
        mtime=$(stat -f %m "${session_file}" 2>/dev/null || stat -c %Y "${session_file}" 2>/dev/null) || {
            kept_signal=$((kept_signal + 1))
            continue
        }
        age_days=$(( (now - mtime) / 86400 ))
        if [[ "${age_days}" -lt "${days}" ]]; then
            kept_recent=$((kept_recent + 1))
            continue
        fi

        if ! is_session_empty "${session_file}"; then
            kept_signal=$((kept_signal + 1))
            continue
        fi

        if [[ "${dry_run}" == "true" ]]; then
            echo "Would archive: ${session_id}"
        else
            mv "${session_file}" "${archive_dir}/"
        fi
        archived=$((archived + 1))
    done

    echo ""
    if [[ "${dry_run}" == "true" ]]; then
        echo "Dry run: ${archived} of ${total} sessions would be archived."
    else
        echo "Archived ${archived} of ${total} sessions to ${archive_dir}"
    fi
    echo "Kept: ${kept_signal} with signal, ${kept_recent} recent or current."
}
