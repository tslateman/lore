#!/usr/bin/env bash
# bridge.sh - Sync Lore records to Engram as shadow memories
#
# Projects decisions, patterns, failure triggers, and session handoffs into
# ~/.claude/memory.sqlite so that Claude's built-in recall surfaces Lore
# knowledge without manual context injection.
#
# Usage:
#   source lib/bridge.sh; sync_to_claude_memory [--since 8h] [--dry-run] [--type decisions]
#
# Shadow memories use a [lore:{id}] prefix for dedup and traceability.
# Only FTS5 triggers are kept during writes; audit and vec triggers are
# captured, dropped, then recreated to avoid custom-function errors.

set -euo pipefail

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${LORE_DIR}/lib/paths.sh"

# Colors (match lore.sh)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

CLAUDE_MEMORY_DB="${CLAUDE_MEMORY_DB:-${HOME}/.claude/memory.sqlite}"

# Counters
_SYNCED_DECISIONS=0
_SYNCED_PATTERNS=0
_SYNCED_TRIGGERS=0
_SYNCED_SESSIONS=0
_SKIPPED=0
_UPDATED=0

# Captured trigger DDL for safe restore
_TRIGGER_DDL=()
_TRIGGER_NAMES=()
_TRIGGERS_DROPPED=false

# --- Timestamp helpers ---

# Convert a --since spec ("2h", "8h", "7d", "2024-01-01") to ISO8601.
# Uses macOS date -v syntax.
_parse_since() {
    local spec="$1"
    if [[ "$spec" =~ ^([0-9]+)h$ ]]; then
        date -u -v-"${BASH_REMATCH[1]}"H +"%Y-%m-%dT%H:%M:%SZ"
    elif [[ "$spec" =~ ^([0-9]+)d$ ]]; then
        date -u -v-"${BASH_REMATCH[1]}"d +"%Y-%m-%dT%H:%M:%SZ"
    else
        # Treat as a date string; normalize to ISO8601
        if [[ "$spec" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            echo "${spec}T00:00:00Z"
        else
            echo "$spec"
        fi
    fi
}

# Convert ISO8601 timestamp to Unix epoch (float) for Engram.
# Handles both "Z" and "+00:00" suffixes.
_iso_to_epoch() {
    local ts="$1"
    # Strip trailing Z for macOS date parsing
    ts="${ts%Z}"
    ts="${ts%+00:00}"
    date -jf "%Y-%m-%dT%H:%M:%S" "$ts" +%s 2>/dev/null || date -d "$1" +%s 2>/dev/null || echo "0"
}

# Check if a timestamp is after the cutoff
_is_after() {
    local ts="$1" cutoff="$2"
    [[ "$ts" > "$cutoff" || "$ts" == "$cutoff" ]]
}

# --- Trigger surgery ---

# Capture DDL for problematic triggers, then drop them.
# Keeps FTS triggers intact (they use standard FTS5).
_capture_and_drop_triggers() {
    local db="$1"

    # Query for triggers that reference sync_disabled() or embedding_vec on Memory and Edge tables
    local trigger_data
    trigger_data=$(sqlite3 "$db" \
        "SELECT name, sql FROM sqlite_master WHERE type='trigger' AND (tbl_name='Memory' OR tbl_name='Edge') AND (sql LIKE '%sync_disabled%' OR name LIKE '%embedding_vec%');" \
        2>/dev/null) || true

    if [[ -z "$trigger_data" ]]; then
        echo -e "${YELLOW}Warning: No problematic triggers found (schema may have changed)${NC}" >&2
        return 0
    fi

    _TRIGGER_DDL=()
    _TRIGGER_NAMES=()

    while IFS='|' read -r name ddl; do
        [[ -z "$name" ]] && continue
        _TRIGGER_NAMES+=("$name")
        _TRIGGER_DDL+=("$ddl")
    done <<< "$trigger_data"

    # Drop each trigger
    for name in "${_TRIGGER_NAMES[@]}"; do
        sqlite3 "$db" "DROP TRIGGER IF EXISTS \"${name}\";" 2>/dev/null
    done

    _TRIGGERS_DROPPED=true
    echo -e "${DIM}Dropped ${#_TRIGGER_NAMES[@]} triggers for safe writes${NC}" >&2
}

# Recreate triggers from captured DDL
_recreate_triggers() {
    local db="${CLAUDE_MEMORY_DB}"

    if [[ "$_TRIGGERS_DROPPED" != true ]]; then
        return 0
    fi

    local restored=0
    for ddl in "${_TRIGGER_DDL[@]}"; do
        [[ -z "$ddl" ]] && continue
        # DDL from sqlite_master lacks the trailing semicolon
        sqlite3 "$db" "${ddl};" 2>/dev/null && restored=$((restored + 1))
    done

    _TRIGGERS_DROPPED=false
    echo -e "${DIM}Restored ${restored}/${#_TRIGGER_DDL[@]} triggers${NC}" >&2
}

# --- Dedup helpers ---

# Compute md5 hash of a string (macOS md5, fallback to md5sum).
_content_hash() {
    local input="$1"
    if command -v md5 &>/dev/null; then
        echo -n "$input" | md5
    else
        echo -n "$input" | md5sum | cut -d' ' -f1
    fi
}

# Check if a shadow memory with the given lore ID prefix exists.
# Returns: "id|content" if found, empty if not.
_find_shadow() {
    local db="$1" lore_id="$2"
    # Escape for SQL LIKE
    local safe_id="${lore_id//\'/\'\'}"
    sqlite3 -separator '|' "$db" \
        "SELECT id, content FROM Memory WHERE content LIKE '[${safe_id}]%' LIMIT 1;" \
        2>/dev/null || true
}

# Extract the hash from a shadow content string with trailing <!-- hash:... -->
_extract_hash() {
    local content="$1"
    if [[ "$content" =~ \<!--\ hash:([a-f0-9]+)\ --\>$ ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# --- Sync functions per source type ---

_sync_decisions() {
    local db="$1" cutoff="$2" dry_run="$3"
    local decisions_file="${LORE_DECISIONS_FILE}"

    if [[ ! -f "$decisions_file" || ! -s "$decisions_file" ]]; then
        return 0
    fi

    # Read decisions, deduplicate by id (take latest), filter by timestamp
    local records
    records=$(jq -sc '
        group_by(.id) | map(.[-1])
        | map(select(.timestamp >= "'"${cutoff}"'"))
    ' "$decisions_file" 2>/dev/null) || return 0

    local count
    count=$(echo "$records" | jq 'length' 2>/dev/null) || return 0
    [[ "$count" -eq 0 ]] && return 0

    while IFS= read -r row; do
        local id decision rationale outcome timestamp
        id=$(echo "$row" | jq -r '.id')
        decision=$(echo "$row" | jq -r '.decision // ""')
        rationale=$(echo "$row" | jq -r '.rationale // ""')
        outcome=$(echo "$row" | jq -r '.outcome // "pending"')
        timestamp=$(echo "$row" | jq -r '.timestamp')

        local lore_id="lore:${id}"
        local body="[${lore_id}] ${decision}. Why: ${rationale}"
        local hash
        hash=$(_content_hash "$body")
        local content="${body} <!-- hash:${hash} -->"
        local epoch
        epoch=$(_iso_to_epoch "$timestamp")

        local existing
        existing=$(_find_shadow "$db" "$lore_id")

        if [[ -n "$existing" ]]; then
            local existing_id existing_content
            existing_id="${existing%%|*}"
            existing_content="${existing#*|}"

            if [[ "$outcome" == "retracted" || "$outcome" == "abandoned" ]]; then
                if [[ "$dry_run" == true ]]; then
                    echo -e "  ${YELLOW}[retract]${NC} ${id}: ${decision:0:60}"
                else
                    local safe_content="${content//\'/\'\'}"
                    sqlite3 "$db" "UPDATE Memory SET importance = 0, content = '${safe_content}' WHERE id = ${existing_id};"
                    _UPDATED=$((_UPDATED + 1))
                fi
            else
                local existing_hash
                existing_hash=$(_extract_hash "$existing_content")
                if [[ "$existing_hash" == "$hash" ]]; then
                    _SKIPPED=$((_SKIPPED + 1))
                elif [[ "$dry_run" == true ]]; then
                    echo -e "  ${CYAN}[update]${NC} ${id}: ${decision:0:60}"
                else
                    local safe_content="${content//\'/\'\'}"
                    sqlite3 "$db" "UPDATE Memory SET content = '${safe_content}' WHERE id = ${existing_id};"
                    _UPDATED=$((_UPDATED + 1))
                fi
            fi
        else
            if [[ "$dry_run" == true ]]; then
                echo -e "  ${GREEN}[insert]${NC} ${id}: ${decision:0:60}"
            else
                local importance=3
                [[ "$outcome" == "retracted" || "$outcome" == "abandoned" ]] && importance=0
                local safe_content="${content//\'/\'\'}"
                sqlite3 "$db" "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (${importance}, 0, ${epoch}, ${epoch}, 'lore', zeroblob(0), 'lore-bridge', 'lore-decisions', 0, '${safe_content}');"
            fi
            _SYNCED_DECISIONS=$((_SYNCED_DECISIONS + 1))
        fi
    done < <(echo "$records" | jq -c '.[]')
}

_sync_patterns() {
    local db="$1" cutoff="$2" dry_run="$3"
    local patterns_file="${LORE_PATTERNS_FILE}"

    if [[ ! -f "$patterns_file" ]]; then
        return 0
    fi

    # Check yq is available
    if ! command -v yq &>/dev/null; then
        echo -e "${YELLOW}Warning: yq not found, skipping patterns${NC}" >&2
        return 0
    fi

    local count
    count=$(yq '.patterns | length' "$patterns_file" 2>/dev/null) || return 0
    [[ "$count" -eq 0 ]] && return 0

    local i=0
    while [[ "$i" -lt "$count" ]]; do
        local id name problem solution created_at
        id=$(yq -r ".patterns[$i].id // \"\"" "$patterns_file")
        name=$(yq -r ".patterns[$i].name // \"\"" "$patterns_file")
        problem=$(yq -r ".patterns[$i].problem // \"\"" "$patterns_file")
        solution=$(yq -r ".patterns[$i].solution // \"\"" "$patterns_file")
        created_at=$(yq -r ".patterns[$i].created_at // \"\"" "$patterns_file")

        i=$((i + 1))

        [[ -z "$id" || -z "$name" ]] && continue

        # Filter by cutoff
        if [[ -n "$created_at" ]] && ! _is_after "$created_at" "$cutoff"; then
            continue
        fi

        local lore_id="lore:${id}"
        local body="[${lore_id}] ${name}: ${problem} -> ${solution}"
        local hash
        hash=$(_content_hash "$body")
        local content="${body} <!-- hash:${hash} -->"
        local epoch
        epoch=$(_iso_to_epoch "${created_at:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}")

        local existing
        existing=$(_find_shadow "$db" "$lore_id")

        if [[ -n "$existing" ]]; then
            local existing_id existing_content
            existing_id="${existing%%|*}"
            existing_content="${existing#*|}"

            local existing_hash
            existing_hash=$(_extract_hash "$existing_content")
            if [[ "$existing_hash" == "$hash" ]]; then
                _SKIPPED=$((_SKIPPED + 1))
            elif [[ "$dry_run" == true ]]; then
                echo -e "  ${CYAN}[update]${NC} ${id}: ${name:0:60}"
            else
                local safe_content="${content//\'/\'\'}"
                sqlite3 "$db" "UPDATE Memory SET content = '${safe_content}' WHERE id = ${existing_id};"
                _UPDATED=$((_UPDATED + 1))
            fi
        else
            if [[ "$dry_run" == true ]]; then
                echo -e "  ${GREEN}[insert]${NC} ${id}: ${name:0:60}"
            else
                local safe_content="${content//\'/\'\'}"
                sqlite3 "$db" "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (3, 0, ${epoch}, ${epoch}, 'lore', zeroblob(0), 'lore-bridge', 'lore-patterns', 0, '${safe_content}');"
            fi
            _SYNCED_PATTERNS=$((_SYNCED_PATTERNS + 1))
        fi
    done
}

_sync_failures() {
    local db="$1" cutoff="$2" dry_run="$3"
    local failures_file="${LORE_FAILURES_DATA}/failures.jsonl"

    if [[ ! -f "$failures_file" || ! -s "$failures_file" ]]; then
        return 0
    fi

    # Group all failures by error_type, keep types with 3+ occurrences,
    # then filter by cutoff on the latest occurrence timestamp
    local triggers
    triggers=$(jq -sc '
        group_by(.error_type)
        | map(select(length >= 3))
        | map({
            error_type: .[0].error_type,
            count: length,
            latest: (map(.timestamp) | sort | last),
            sample: .[0].error_message
          })
        | map(select(.latest >= "'"${cutoff}"'"))
    ' "$failures_file" 2>/dev/null) || return 0

    local count
    count=$(echo "$triggers" | jq 'length' 2>/dev/null) || return 0
    [[ "$count" -eq 0 ]] && return 0

    while IFS= read -r row; do
        local error_type ecount latest
        error_type=$(echo "$row" | jq -r '.error_type')
        ecount=$(echo "$row" | jq -r '.count')
        latest=$(echo "$row" | jq -r '.latest')

        # Sanitize error_type for ID use (strip trailing dashes)
        local safe_type
        safe_type=$(echo "$error_type" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '-' | sed 's/-*$//')
        local lore_id="lore:trigger-${safe_type}"
        local content="[${lore_id}] ${error_type} x${ecount}"
        local epoch
        epoch=$(_iso_to_epoch "$latest")

        local existing
        existing=$(_find_shadow "$db" "$lore_id")

        if [[ -n "$existing" ]]; then
            local existing_id existing_content
            existing_id="${existing%%|*}"
            existing_content="${existing#*|}"

            if [[ "$existing_content" == "$content" ]]; then
                _SKIPPED=$((_SKIPPED + 1))
            else
                if [[ "$dry_run" == true ]]; then
                    echo -e "  ${CYAN}[update]${NC} trigger-${safe_type}: ${error_type} x${ecount}"
                else
                    local safe_content="${content//\'/\'\'}"
                    sqlite3 "$db" "UPDATE Memory SET content = '${safe_content}' WHERE id = ${existing_id};"
                    _UPDATED=$((_UPDATED + 1))
                fi
            fi
        else
            if [[ "$dry_run" == true ]]; then
                echo -e "  ${GREEN}[insert]${NC} trigger-${safe_type}: ${error_type} x${ecount}"
            else
                local safe_content="${content//\'/\'\'}"
                sqlite3 "$db" "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (2, 0, ${epoch}, ${epoch}, 'lore', zeroblob(0), 'lore-bridge', 'lore-failures', 0, '${safe_content}');"
            fi
            _SYNCED_TRIGGERS=$((_SYNCED_TRIGGERS + 1))
        fi
    done < <(echo "$triggers" | jq -c '.[]')
}

_sync_sessions() {
    local db="$1" cutoff="$2" dry_run="$3"
    local sessions_dir="${LORE_TRANSFER_DATA}/sessions"

    if [[ ! -d "$sessions_dir" ]]; then
        return 0
    fi

    local session_files
    session_files=$(ls "$sessions_dir"/*.json 2>/dev/null) || return 0
    [[ -z "$session_files" ]] && return 0

    while IFS= read -r file; do
        [[ -f "$file" ]] || continue

        local session_id timestamp
        session_id=$(jq -r '.id // .session_id // ""' "$file" 2>/dev/null) || continue
        timestamp=$(jq -r '.started_at // .handoff.created_at // .timestamp // .created_at // ""' "$file" 2>/dev/null) || continue

        [[ -z "$session_id" ]] && continue

        # Filter by cutoff
        if [[ -n "$timestamp" ]] && ! _is_after "$timestamp" "$cutoff"; then
            continue
        fi

        # Build shadow content from summary or handoff message
        local summary handoff_msg next_steps
        summary=$(jq -r '.summary // ""' "$file" 2>/dev/null) || true
        handoff_msg=$(jq -r '.handoff.message // ""' "$file" 2>/dev/null) || true
        next_steps=$(jq -r '(.handoff.next_steps // []) | join("; ")' "$file" 2>/dev/null) || true

        # Prefer summary, fall back to handoff message
        local body="${summary:-$handoff_msg}"
        [[ -z "$body" ]] && continue

        local lore_id="lore:sess-${session_id}"
        local content="[${lore_id}] ${body}"
        [[ -n "$next_steps" ]] && content="${content}. Next: ${next_steps}"

        local epoch
        epoch=$(_iso_to_epoch "${timestamp:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}")

        local existing
        existing=$(_find_shadow "$db" "$lore_id")

        if [[ -n "$existing" ]]; then
            local existing_content
            existing_content="${existing#*|}"

            if [[ "$existing_content" == "$content" ]]; then
                _SKIPPED=$((_SKIPPED + 1))
            else
                if [[ "$dry_run" == true ]]; then
                    echo -e "  ${CYAN}[update]${NC} sess-${session_id}: ${body:0:60}"
                else
                    local existing_id="${existing%%|*}"
                    local safe_content="${content//\'/\'\'}"
                    sqlite3 "$db" "UPDATE Memory SET content = '${safe_content}' WHERE id = ${existing_id};"
                    _UPDATED=$((_UPDATED + 1))
                fi
            fi
        else
            if [[ "$dry_run" == true ]]; then
                echo -e "  ${GREEN}[insert]${NC} sess-${session_id}: ${body:0:60}"
            else
                local safe_content="${content//\'/\'\'}"
                sqlite3 "$db" "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (2, 0, ${epoch}, ${epoch}, 'lore', zeroblob(0), 'lore-bridge', 'lore-sessions', 0, '${safe_content}');"
            fi
            _SYNCED_SESSIONS=$((_SYNCED_SESSIONS + 1))
        fi
    done <<< "$session_files"
}

# --- Single-record sync functions ---

# Sync one decision immediately after capture.
# Args: JSON record (as argument or piped via stdin)
# Fail-silent: returns 0 on any error.
sync_single_decision() {
    local record="${1:-$(cat)}"
    [[ -z "$record" ]] && return 0
    [[ ! -f "$CLAUDE_MEMORY_DB" ]] && return 0

    local id decision rationale outcome timestamp
    id=$(echo "$record" | jq -r '.id // ""' 2>/dev/null) || return 0
    [[ -z "$id" ]] && return 0
    decision=$(echo "$record" | jq -r '.decision // ""' 2>/dev/null) || return 0
    rationale=$(echo "$record" | jq -r '.rationale // ""' 2>/dev/null) || return 0
    outcome=$(echo "$record" | jq -r '.outcome // "pending"' 2>/dev/null) || return 0
    timestamp=$(echo "$record" | jq -r '.timestamp // ""' 2>/dev/null) || return 0

    local lore_id="lore:${id}"
    local body="[${lore_id}] ${decision}. Why: ${rationale}"
    local hash
    hash=$(_content_hash "$body") || return 0
    local content="${body} <!-- hash:${hash} -->"
    local epoch
    epoch=$(_iso_to_epoch "${timestamp:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}") || return 0

    local db="$CLAUDE_MEMORY_DB"

    _capture_and_drop_triggers "$db" 2>/dev/null
    trap '_recreate_triggers 2>/dev/null' RETURN

    local existing
    existing=$(_find_shadow "$db" "$lore_id")

    if [[ -n "$existing" ]]; then
        local existing_id existing_content
        existing_id="${existing%%|*}"
        existing_content="${existing#*|}"

        if [[ "$outcome" == "retracted" || "$outcome" == "abandoned" ]]; then
            local safe_content="${content//\'/\'\'}"
            sqlite3 "$db" "UPDATE Memory SET importance = 0, content = '${safe_content}' WHERE id = ${existing_id};" 2>/dev/null || true
        else
            local existing_hash
            existing_hash=$(_extract_hash "$existing_content")
            if [[ "$existing_hash" != "$hash" ]]; then
                local safe_content="${content//\'/\'\'}"
                sqlite3 "$db" "UPDATE Memory SET content = '${safe_content}' WHERE id = ${existing_id};" 2>/dev/null || true
            fi
        fi
    else
        local importance=3
        [[ "$outcome" == "retracted" || "$outcome" == "abandoned" ]] && importance=0
        local safe_content="${content//\'/\'\'}"
        sqlite3 "$db" "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (${importance}, 0, ${epoch}, ${epoch}, 'lore', zeroblob(0), 'lore-bridge', 'lore-decisions', 0, '${safe_content}');" 2>/dev/null || true
    fi
}

# Sync one pattern immediately after capture.
# Args: id, name, problem, solution
# Fail-silent: returns 0 on any error.
sync_single_pattern() {
    local id="${1:-}" name="${2:-}" problem="${3:-}" solution="${4:-}"
    [[ -z "$id" || -z "$name" ]] && return 0
    [[ ! -f "$CLAUDE_MEMORY_DB" ]] && return 0

    local lore_id="lore:${id}"
    local body="[${lore_id}] ${name}: ${problem} -> ${solution}"
    local hash
    hash=$(_content_hash "$body") || return 0
    local content="${body} <!-- hash:${hash} -->"
    local epoch
    epoch=$(date +%s)

    local db="$CLAUDE_MEMORY_DB"

    _capture_and_drop_triggers "$db" 2>/dev/null
    trap '_recreate_triggers 2>/dev/null' RETURN

    local existing
    existing=$(_find_shadow "$db" "$lore_id")

    if [[ -n "$existing" ]]; then
        local existing_id existing_content
        existing_id="${existing%%|*}"
        existing_content="${existing#*|}"

        local existing_hash
        existing_hash=$(_extract_hash "$existing_content")
        if [[ "$existing_hash" != "$hash" ]]; then
            local safe_content="${content//\'/\'\'}"
            sqlite3 "$db" "UPDATE Memory SET content = '${safe_content}' WHERE id = ${existing_id};" 2>/dev/null || true
        fi
    else
        local safe_content="${content//\'/\'\'}"
        sqlite3 "$db" "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (3, 0, ${epoch}, ${epoch}, 'lore', zeroblob(0), 'lore-bridge', 'lore-patterns', 0, '${safe_content}');" 2>/dev/null || true
    fi
}

# Invalidate a shadow when its Lore record is revised or abandoned.
# Args: lore_id (e.g., "dec-abc123")
# Fail-silent: returns 0 on any error.
retract_shadow() {
    local lore_id="${1:-}"
    [[ -z "$lore_id" ]] && return 0
    [[ ! -f "$CLAUDE_MEMORY_DB" ]] && return 0

    local db="$CLAUDE_MEMORY_DB"

    local existing
    existing=$(_find_shadow "$db" "lore:${lore_id}")
    [[ -z "$existing" ]] && return 0

    local existing_id
    existing_id="${existing%%|*}"

    _capture_and_drop_triggers "$db" 2>/dev/null
    trap '_recreate_triggers 2>/dev/null' RETURN

    sqlite3 "$db" "UPDATE Memory SET importance = 0 WHERE id = ${existing_id};" 2>/dev/null || true
}

# Compare shadow count against Lore record counts.
# Prints a summary only when mismatch detected.
# Returns 0 always (advisory).
shadow_health_check() {
    [[ ! -f "$CLAUDE_MEMORY_DB" ]] && { echo -e "${YELLOW}Engram database not found${NC}" >&2; return 0; }

    local db="$CLAUDE_MEMORY_DB"

    # Count shadows by topic
    local shadow_decisions shadow_patterns shadow_failures shadow_sessions
    shadow_decisions=$(sqlite3 "$db" "SELECT COUNT(*) FROM Memory WHERE source='lore-bridge' AND topic='lore-decisions';" 2>/dev/null) || shadow_decisions=0
    shadow_patterns=$(sqlite3 "$db" "SELECT COUNT(*) FROM Memory WHERE source='lore-bridge' AND topic='lore-patterns';" 2>/dev/null) || shadow_patterns=0
    shadow_failures=$(sqlite3 "$db" "SELECT COUNT(*) FROM Memory WHERE source='lore-bridge' AND topic='lore-failures';" 2>/dev/null) || shadow_failures=0
    shadow_sessions=$(sqlite3 "$db" "SELECT COUNT(*) FROM Memory WHERE source='lore-bridge' AND topic='lore-sessions';" 2>/dev/null) || shadow_sessions=0

    # Count source records
    local src_decisions=0 src_patterns=0 src_failures=0 src_sessions=0

    if [[ -f "$LORE_DECISIONS_FILE" && -s "$LORE_DECISIONS_FILE" ]]; then
        src_decisions=$(jq -sc 'group_by(.id) | length' "$LORE_DECISIONS_FILE" 2>/dev/null) || src_decisions=0
    fi

    if [[ -f "$LORE_PATTERNS_FILE" ]]; then
        if command -v yq &>/dev/null; then
            src_patterns=$(yq '.patterns | length' "$LORE_PATTERNS_FILE" 2>/dev/null) || src_patterns=0
        fi
    fi

    local failures_file="${LORE_FAILURES_DATA}/failures.jsonl"
    if [[ -f "$failures_file" && -s "$failures_file" ]]; then
        src_failures=$(jq -sc 'group_by(.error_type) | map(select(length >= 3)) | length' "$failures_file" 2>/dev/null) || src_failures=0
    fi

    local sessions_dir="${LORE_TRANSFER_DATA}/sessions"
    if [[ -d "$sessions_dir" ]]; then
        src_sessions=$(ls "$sessions_dir"/*.json 2>/dev/null | wc -l | tr -d ' ') || src_sessions=0
    fi

    local total_shadows=$((shadow_decisions + shadow_patterns + shadow_failures + shadow_sessions))
    local total_sources=$((src_decisions + src_patterns + src_failures + src_sessions))
    local missing=$((total_sources - total_shadows))
    [[ "$missing" -lt 0 ]] && missing=0

    if [[ "$total_shadows" -eq "$total_sources" ]]; then
        # All synced, print nothing
        return 0
    fi

    echo -e "${BOLD}shadows:${NC} ${total_shadows}/${total_sources} synced (${missing} missing)"
    # Per-type delta
    local details=()
    [[ "$shadow_decisions" -ne "$src_decisions" ]] && details+=("decisions: ${shadow_decisions}/${src_decisions}")
    [[ "$shadow_patterns" -ne "$src_patterns" ]] && details+=("patterns: ${shadow_patterns}/${src_patterns}")
    [[ "$shadow_failures" -ne "$src_failures" ]] && details+=("failures: ${shadow_failures}/${src_failures}")
    [[ "$shadow_sessions" -ne "$src_sessions" ]] && details+=("sessions: ${shadow_sessions}/${src_sessions}")

    if [[ ${#details[@]} -gt 0 ]]; then
        local IFS=', '
        echo -e "  ${DIM}${details[*]}${NC}"
    fi
    echo -e "  ${DIM}Run 'lore sync' to reconcile${NC}"
    return 0
}

# --- Graph edge projection ---

# Map Lore relation types to Engram relation types
_map_lore_relation_to_engram() {
    local lore_relation="$1"

    case "$lore_relation" in
        relates_to)     echo "relates_to" ;;
        learned_from)   echo "derived_from" ;;
        references)     echo "relates_to" ;;
        derived_from)   echo "derived_from" ;;
        contradicts)    echo "contradicts" ;;
        supersedes)     echo "supersedes" ;;
        part_of)        echo "part_of" ;;
        implements)     echo "relates_to" ;;
        *)              echo "relates_to" ;;  # Default fallback
    esac
}

# Get Engram Memory.id for a Lore shadow by lore_id
# Returns empty if not found
_get_shadow_memory_id() {
    local db="$1"
    local lore_id="$2"

    sqlite3 "$db" "SELECT id FROM Memory WHERE content LIKE '[lore:${lore_id}]%' LIMIT 1;" 2>/dev/null || echo ""
}

# Create an edge in Engram between two shadows
# Returns 0 if successful, 1 if edge already exists or nodes not found
_create_engram_edge() {
    local db="$1"
    local source_id="$2"
    local target_id="$3"
    local relation="$4"
    local dry_run="$5"

    # Check if both nodes exist
    [[ -z "$source_id" || -z "$target_id" ]] && return 1

    # Check if edge already exists
    local existing
    existing=$(sqlite3 "$db" \
        "SELECT COUNT(*) FROM Edge WHERE sourceId = $source_id AND targetId = $target_id AND relation = '$relation';" \
        2>/dev/null) || existing=0

    if [[ "$existing" -gt 0 ]]; then
        return 1  # Edge already exists
    fi

    if [[ "$dry_run" == true ]]; then
        echo "Would create edge: $source_id --[$relation]--> $target_id"
        return 0
    fi

    # Create the edge
    sqlite3 "$db" <<SQL
INSERT INTO Edge (sourceId, targetId, relation, createdAt)
VALUES ($source_id, $target_id, '$relation', unixepoch('subsec'));
SQL

    return 0
}

# Sync graph edges from Lore to Engram
# Projects edges between shadow memories
_sync_graph_edges() {
    local db="$1"
    local dry_run="$2"

    local graph_file="${LORE_GRAPH_FILE:-$LORE_DIR/graph/data/graph.json}"
    [[ ! -f "$graph_file" ]] && return 0

    local edges_created=0
    local edges_skipped=0

    # Read all edges from Lore graph
    local edges
    edges=$(jq -c '.edges[]' "$graph_file" 2>/dev/null) || return 0

    while IFS= read -r edge; do
        [[ -z "$edge" ]] && continue

        # Extract edge data
        local from to lore_relation
        from=$(echo "$edge" | jq -r '.from')
        to=$(echo "$edge" | jq -r '.to')
        lore_relation=$(echo "$edge" | jq -r '.relation')

        # Skip if nodes are not decision or pattern types (only those get synced as shadows)
        [[ ! "$from" =~ ^(decision|pattern)- ]] && continue
        [[ ! "$to" =~ ^(decision|pattern)- ]] && continue

        # Get Lore record IDs from node names
        # Need to look up the node in the graph to get its name (journal_id)
        local from_lore_id to_lore_id
        from_lore_id=$(jq -r --arg nid "$from" '.nodes[$nid].name // empty' "$graph_file" 2>/dev/null)
        to_lore_id=$(jq -r --arg nid "$to" '.nodes[$nid].name // empty' "$graph_file" 2>/dev/null)

        [[ -z "$from_lore_id" || -z "$to_lore_id" ]] && continue

        # Get Engram Memory IDs for the shadows
        local from_mem_id to_mem_id
        from_mem_id=$(_get_shadow_memory_id "$db" "$from_lore_id")
        to_mem_id=$(_get_shadow_memory_id "$db" "$to_lore_id")

        # Skip if either shadow doesn't exist
        [[ -z "$from_mem_id" || -z "$to_mem_id" ]] && { edges_skipped=$((edges_skipped + 1)); continue; }

        # Map Lore relation to Engram relation
        local engram_relation
        engram_relation=$(_map_lore_relation_to_engram "$lore_relation")

        # Create the edge
        if _create_engram_edge "$db" "$from_mem_id" "$to_mem_id" "$engram_relation" "$dry_run"; then
            edges_created=$((edges_created + 1))
        else
            edges_skipped=$((edges_skipped + 1))
        fi

        # If bidirectional, create reverse edge
        local bidirectional
        bidirectional=$(echo "$edge" | jq -r '.bidirectional // false')
        if [[ "$bidirectional" == "true" ]]; then
            if _create_engram_edge "$db" "$to_mem_id" "$from_mem_id" "$engram_relation" "$dry_run"; then
                edges_created=$((edges_created + 1))
            else
                edges_skipped=$((edges_skipped + 1))
            fi
        fi
    done <<< "$edges"

    if [[ "$dry_run" == true ]]; then
        [[ "$edges_created" -gt 0 ]] && echo "Would create $edges_created graph edges (${edges_skipped} skipped)"
    else
        [[ "$edges_created" -gt 0 ]] && echo -e "${GREEN}Projected${NC} ${edges_created} graph edges ${DIM}(${edges_skipped} skipped)${NC}" >&2
    fi
}

# --- Main entry point ---

sync_to_claude_memory() {
    local since="8h"
    local dry_run=false
    local type_filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --since)
                since="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --type)
                type_filter="$2"
                shift 2
                ;;
            -*)
                echo -e "${RED}Unknown option: $1${NC}" >&2
                echo "Usage: sync_to_claude_memory [--since TIMESPEC] [--dry-run] [--type TYPE]" >&2
                echo "  TIMESPEC: 2h, 8h, 24h, 7d, 2024-01-01 (default: 8h)" >&2
                echo "  TYPE: decisions, patterns, failures, sessions" >&2
                return 1
                ;;
            *)
                echo -e "${RED}Unexpected argument: $1${NC}" >&2
                return 1
                ;;
        esac
    done

    # Validate type filter
    if [[ -n "$type_filter" ]]; then
        case "$type_filter" in
            decisions|patterns|failures|sessions) ;;
            *)
                echo -e "${RED}Unknown type: ${type_filter}${NC}" >&2
                echo "Valid types: decisions, patterns, failures, sessions" >&2
                return 1
                ;;
        esac
    fi

    # Validate database exists
    if [[ ! -f "$CLAUDE_MEMORY_DB" ]]; then
        echo -e "${RED}Engram database not found: ${CLAUDE_MEMORY_DB}${NC}" >&2
        return 1
    fi

    local cutoff
    cutoff=$(_parse_since "$since")

    # Reset counters
    _SYNCED_DECISIONS=0
    _SYNCED_PATTERNS=0
    _SYNCED_TRIGGERS=0
    _SYNCED_SESSIONS=0
    _SKIPPED=0
    _UPDATED=0

    if [[ "$dry_run" == true ]]; then
        echo -e "${BOLD}Dry run: Lore -> Engram (since ${since}, cutoff ${cutoff})${NC}"
        echo ""
    else
        echo -e "${BOLD}Syncing Lore -> Engram (since ${since})${NC}" >&2
    fi

    if [[ "$dry_run" != true ]]; then
        # Capture and drop problematic triggers before any writes
        _capture_and_drop_triggers "$CLAUDE_MEMORY_DB"

        # Safety trap: recreate triggers on any error
        trap '_recreate_triggers' ERR
    fi

    # Run syncs (type_filter gates which run)
    if [[ -z "$type_filter" || "$type_filter" == "decisions" ]]; then
        _sync_decisions "$CLAUDE_MEMORY_DB" "$cutoff" "$dry_run"
    fi
    if [[ -z "$type_filter" || "$type_filter" == "patterns" ]]; then
        _sync_patterns "$CLAUDE_MEMORY_DB" "$cutoff" "$dry_run"
    fi
    if [[ -z "$type_filter" || "$type_filter" == "failures" ]]; then
        _sync_failures "$CLAUDE_MEMORY_DB" "$cutoff" "$dry_run"
    fi
    if [[ -z "$type_filter" || "$type_filter" == "sessions" ]]; then
        _sync_sessions "$CLAUDE_MEMORY_DB" "$cutoff" "$dry_run"
    fi

    # Sync graph edges (only if no type filter or full sync)
    if [[ -z "$type_filter" ]]; then
        _sync_graph_edges "$CLAUDE_MEMORY_DB" "$dry_run"
    fi

    if [[ "$dry_run" != true ]]; then
        # Restore triggers
        _recreate_triggers
        trap - ERR
    fi

    # Summary
    local total=$((_SYNCED_DECISIONS + _SYNCED_PATTERNS + _SYNCED_TRIGGERS + _SYNCED_SESSIONS))
    if [[ "$dry_run" == true ]]; then
        echo ""
        echo -e "${BOLD}Would sync:${NC} ${total} records (${_SKIPPED} unchanged, ${_UPDATED} to update)"
    else
        echo -e "${GREEN}Synced${NC} ${_SYNCED_DECISIONS} decisions, ${_SYNCED_PATTERNS} patterns, ${_SYNCED_TRIGGERS} triggers, ${_SYNCED_SESSIONS} sessions ${DIM}(${_SKIPPED} skipped, ${_UPDATED} updated)${NC}" >&2
    fi
}

# Allow direct invocation
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    sync_to_claude_memory "$@"
fi
