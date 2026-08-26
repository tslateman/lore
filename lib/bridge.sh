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

# Engram's "never expires" sentinel (year 4001). Rows with expiresAt=0 read
# as expired-since-1970 and are filtered out of recall entirely.
_ENGRAM_NEVER_EXPIRES="64092211200"

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
# Tries macOS date -v, falls back to GNU date -d (Nix/Homebrew coreutils).
_parse_since() {
    local spec="$1"
    if [[ "$spec" =~ ^([0-9]+)h$ ]]; then
        date -u -v-"${BASH_REMATCH[1]}"H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
            || date -u -d "-${BASH_REMATCH[1]} hours" +"%Y-%m-%dT%H:%M:%SZ"
    elif [[ "$spec" =~ ^([0-9]+)d$ ]]; then
        date -u -v-"${BASH_REMATCH[1]}"d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
            || date -u -d "-${BASH_REMATCH[1]} days" +"%Y-%m-%dT%H:%M:%SZ"
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
        # DDL from sqlite_master lacks the trailing semicolon.
        # Strip sync_disabled() guards — that UDF is registered by Engram at
        # runtime and unavailable in raw sqlite3. Removing the guard lets the
        # trigger recreate; Engram re-registers it on restart.
        # Two forms: WHEN (sync_disabled() = 0) and WHEN ((sync_disabled() = 0) AND ...)
        local clean_ddl="$ddl"
        # Form 1: sole condition — remove entire WHEN clause
        clean_ddl="${clean_ddl//WHEN (sync_disabled() = 0)/}"
        # Form 2: first of multiple conditions — remove guard and leading AND
        clean_ddl="${clean_ddl//WHEN ((sync_disabled() = 0) AND /WHEN (}"
        sqlite3 "$db" "${clean_ddl};" 2>/dev/null && restored=$((restored + 1))
    done

    _TRIGGERS_DROPPED=false
    echo -e "${DIM}Restored ${restored}/${#_TRIGGER_DDL[@]} triggers${NC}" >&2
}

# --- Embedding backfill ---

# Re-embed zero-embedding shadows through the Engram MCP server.
# Raw sqlite3 writes cannot compute vectors, so they store zeroblob(0) and
# stay invisible to Engram's vector recall. The server's update tool
# recomputes the embedding in place, which keeps globalId and edges intact
# and routes the write through the server's audit layer.
# Call only with triggers restored so server writes are audited.
_embed_backfill() {
    local quiet="${1:-}"
    local db="${CLAUDE_MEMORY_DB}"
    local memory_bin="${CLAUDE_MEMORY_BIN:-${HOME}/.claude/bin/memory}"

    [[ -x "$memory_bin" ]] || return 0
    command -v jq &>/dev/null || return 0

    local rows
    rows=$(sqlite3 -json "$db" \
        "SELECT globalId, content FROM Memory WHERE source='lore-bridge' AND length(embedding)=0;" \
        2>/dev/null) || return 0
    [[ -z "$rows" || "$rows" == "[]" ]] && return 0

    local MEM MEM_PID resp line
    coproc MEM { "$memory_bin" 2>/dev/null; }

    printf '%s\n' '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"lore-bridge","version":"0.1.0"}}}' >&"${MEM[1]}" 2>/dev/null \
        || { kill "$MEM_PID" 2>/dev/null || true; return 0; }
    IFS= read -r -t 60 resp <&"${MEM[0]}" \
        || { kill "$MEM_PID" 2>/dev/null || true; return 0; }
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' >&"${MEM[1]}" 2>/dev/null \
        || { kill "$MEM_PID" 2>/dev/null || true; return 0; }

    local total=0 embedded=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        total=$((total + 1))
        printf '%s\n' "$(printf '%s' "$line" | jq -c '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:"update",arguments:{id:.globalId,content:.content}}}')" >&"${MEM[1]}" 2>/dev/null || break
        IFS= read -r -t 60 resp <&"${MEM[0]}" || break
        [[ "$resp" != *'"error"'* && "$resp" != *'"isError":true'* ]] && embedded=$((embedded + 1))
    done < <(printf '%s' "$rows" | jq -c '.[]')

    exec {MEM[1]}>&-
    wait "$MEM_PID" 2>/dev/null || true

    if [[ "$quiet" != "--quiet" ]]; then
        echo -e "${GREEN}Embedded${NC} ${embedded}/${total} shadows" >&2
    fi
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
                    sqlite3 "$db" "UPDATE Memory SET importance = 0, content = '${safe_content}', embedding = zeroblob(0) WHERE id = ${existing_id};"
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
                    sqlite3 "$db" "UPDATE Memory SET content = '${safe_content}', embedding = zeroblob(0) WHERE id = ${existing_id};"
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
                sqlite3 "$db" "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (${importance}, 0, ${epoch}, ${epoch}, 'lore', zeroblob(0), 'lore-bridge', 'lore-decisions', ${_ENGRAM_NEVER_EXPIRES}, '${safe_content}');"
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

    # One yq pass converts YAML to JSON; one jq pass filters by validity and
    # cutoff. Per-record extraction below only runs for records in the window.
    local records
    records=$(yq -o=json '.patterns // []' "$patterns_file" 2>/dev/null | jq -c --arg cutoff "$cutoff" '
        map(select((.id // "") != "" and (.name // "") != ""))
        | map(select((.created_at // "") == "" or .created_at >= $cutoff))
    ' 2>/dev/null) || return 0

    local count
    count=$(echo "$records" | jq 'length' 2>/dev/null) || return 0
    [[ "$count" -eq 0 ]] && return 0

    while IFS= read -r row; do
        local id name problem solution created_at
        id=$(echo "$row" | jq -r '.id')
        name=$(echo "$row" | jq -r '.name')
        problem=$(echo "$row" | jq -r '.problem // ""')
        solution=$(echo "$row" | jq -r '.solution // ""')
        created_at=$(echo "$row" | jq -r '.created_at // ""')

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
                sqlite3 "$db" "UPDATE Memory SET content = '${safe_content}', embedding = zeroblob(0) WHERE id = ${existing_id};"
                _UPDATED=$((_UPDATED + 1))
            fi
        else
            if [[ "$dry_run" == true ]]; then
                echo -e "  ${GREEN}[insert]${NC} ${id}: ${name:0:60}"
            else
                local safe_content="${content//\'/\'\'}"
                sqlite3 "$db" "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (3, 0, ${epoch}, ${epoch}, 'lore', zeroblob(0), 'lore-bridge', 'lore-patterns', ${_ENGRAM_NEVER_EXPIRES}, '${safe_content}');"
            fi
            _SYNCED_PATTERNS=$((_SYNCED_PATTERNS + 1))
        fi
    done < <(echo "$records" | jq -c '.[]')
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
                    sqlite3 "$db" "UPDATE Memory SET content = '${safe_content}', embedding = zeroblob(0) WHERE id = ${existing_id};"
                    _UPDATED=$((_UPDATED + 1))
                fi
            fi
        else
            if [[ "$dry_run" == true ]]; then
                echo -e "  ${GREEN}[insert]${NC} trigger-${safe_type}: ${error_type} x${ecount}"
            else
                local safe_content="${content//\'/\'\'}"
                sqlite3 "$db" "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (2, 0, ${epoch}, ${epoch}, 'lore', zeroblob(0), 'lore-bridge', 'lore-failures', ${_ENGRAM_NEVER_EXPIRES}, '${safe_content}');"
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
                    sqlite3 "$db" "UPDATE Memory SET content = '${safe_content}', embedding = zeroblob(0) WHERE id = ${existing_id};"
                    _UPDATED=$((_UPDATED + 1))
                fi
            fi
        else
            if [[ "$dry_run" == true ]]; then
                echo -e "  ${GREEN}[insert]${NC} sess-${session_id}: ${body:0:60}"
            else
                local safe_content="${content//\'/\'\'}"
                sqlite3 "$db" "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (2, 0, ${epoch}, ${epoch}, 'lore', zeroblob(0), 'lore-bridge', 'lore-sessions', ${_ENGRAM_NEVER_EXPIRES}, '${safe_content}');"
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
            sqlite3 "$db" "UPDATE Memory SET importance = 0, content = '${safe_content}', embedding = zeroblob(0) WHERE id = ${existing_id};" 2>/dev/null || true
        else
            local existing_hash
            existing_hash=$(_extract_hash "$existing_content")
            if [[ "$existing_hash" != "$hash" ]]; then
                local safe_content="${content//\'/\'\'}"
                sqlite3 "$db" "UPDATE Memory SET content = '${safe_content}', embedding = zeroblob(0) WHERE id = ${existing_id};" 2>/dev/null || true
            fi
        fi
    else
        local importance=3
        [[ "$outcome" == "retracted" || "$outcome" == "abandoned" ]] && importance=0
        local safe_content="${content//\'/\'\'}"
        sqlite3 "$db" "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (${importance}, 0, ${epoch}, ${epoch}, 'lore', zeroblob(0), 'lore-bridge', 'lore-decisions', ${_ENGRAM_NEVER_EXPIRES}, '${safe_content}');" 2>/dev/null || true
    fi

    _recreate_triggers 2>/dev/null
    _embed_backfill --quiet 2>/dev/null || true
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
            sqlite3 "$db" "UPDATE Memory SET content = '${safe_content}', embedding = zeroblob(0) WHERE id = ${existing_id};" 2>/dev/null || true
        fi
    else
        local safe_content="${content//\'/\'\'}"
        sqlite3 "$db" "INSERT INTO Memory (importance, accessCount, createdAt, lastAccessedAt, project, embedding, source, topic, expiresAt, content) VALUES (3, 0, ${epoch}, ${epoch}, 'lore', zeroblob(0), 'lore-bridge', 'lore-patterns', ${_ENGRAM_NEVER_EXPIRES}, '${safe_content}');" 2>/dev/null || true
    fi

    _recreate_triggers 2>/dev/null
    _embed_backfill --quiet 2>/dev/null || true
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

    # One jq pass filters to decision/pattern edges and resolves node names,
    # emitting one tab-separated row per edge. Node IDs and relations are
    # single tokens, so TSV is safe.
    local edges
    edges=$(jq -r '
        .nodes as $nodes
        | .edges[]
        | select((.from | test("^(decision|pattern)-")) and (.to | test("^(decision|pattern)-")))
        | [($nodes[.from].name // ""), ($nodes[.to].name // ""), .relation, (.bidirectional // false)]
        | @tsv
    ' "$graph_file" 2>/dev/null | tr '\t' '\037') || return 0
    [[ -z "$edges" ]] && return 0

    # Expand bidirectional edges, map relations, and build one VALUES list.
    # A single sqlite invocation resolves shadow IDs and inserts all missing
    # edges — per-edge sqlite spawns made this loop take minutes.
    local values="" edge_count=0
    while IFS=$'\x1f' read -r from_lore_id to_lore_id lore_relation bidirectional; do
        [[ -z "$from_lore_id" || -z "$to_lore_id" ]] && continue

        local engram_relation
        engram_relation=$(_map_lore_relation_to_engram "$lore_relation")

        [[ -n "$values" ]] && values="${values},"
        values="${values}('${from_lore_id//\'/\'\'}','${to_lore_id//\'/\'\'}','${engram_relation}')"
        edge_count=$((edge_count + 1))

        if [[ "$bidirectional" == "true" ]]; then
            values="${values},('${to_lore_id//\'/\'\'}','${from_lore_id//\'/\'\'}','${engram_relation}')"
            edge_count=$((edge_count + 1))
        fi
    done <<< "$edges"

    [[ "$edge_count" -eq 0 ]] && return 0

    local setup_sql="
CREATE TEMP TABLE _lore_edges (from_lid TEXT, to_lid TEXT, relation TEXT);
INSERT INTO _lore_edges VALUES ${values};
CREATE TEMP TABLE _resolved AS
    SELECT lid,
           (SELECT MIN(m.id) FROM Memory m WHERE m.content LIKE '[lore:' || lid || ']%') AS mem_id
    FROM (SELECT from_lid AS lid FROM _lore_edges UNION SELECT to_lid FROM _lore_edges);
"
    local match_sql="
FROM _lore_edges e
JOIN _resolved s ON s.lid = e.from_lid AND s.mem_id IS NOT NULL
JOIN _resolved t ON t.lid = e.to_lid AND t.mem_id IS NOT NULL
WHERE NOT EXISTS (
    SELECT 1 FROM Edge x
    WHERE x.sourceId = s.mem_id AND x.targetId = t.mem_id AND x.relation = e.relation
)"

    if [[ "$dry_run" == true ]]; then
        local pending
        pending=$(sqlite3 "$db" "${setup_sql}
SELECT DISTINCT s.mem_id || ' --[' || e.relation || ']--> ' || t.mem_id ${match_sql};" 2>/dev/null) || pending=""
        if [[ -n "$pending" ]]; then
            while IFS= read -r line; do
                echo "Would create edge: $line"
            done <<< "$pending"
            edges_created=$(echo "$pending" | wc -l | tr -d ' ')
        fi
        edges_skipped=$((edge_count - edges_created))
    else
        local created
        created=$(sqlite3 "$db" "${setup_sql}
INSERT INTO Edge (sourceId, targetId, relation, createdAt)
SELECT src, tgt, rel, unixepoch('subsec') FROM (
    SELECT DISTINCT s.mem_id AS src, t.mem_id AS tgt, e.relation AS rel ${match_sql}
);
SELECT changes();" 2>/dev/null) || created=0
        edges_created="${created:-0}"
        edges_skipped=$((edge_count - edges_created))
    fi

    if [[ "$dry_run" == true ]]; then
        [[ "$edges_created" -gt 0 ]] && echo "Would create $edges_created graph edges (${edges_skipped} skipped)"
    else
        [[ "$edges_created" -gt 0 ]] && echo -e "${GREEN}Projected${NC} ${edges_created} graph edges ${DIM}(${edges_skipped} skipped)${NC}" >&2
    fi
    return 0
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

    # Validate database exists (graceful skip if Engram not initialized)
    if [[ ! -f "$CLAUDE_MEMORY_DB" ]]; then
        echo -e "${YELLOW}Engram database not found — skipping sync${NC}" >&2
        return 0
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

    # Serialize real syncs: concurrent runs race on the trigger surgery.
    # Skip (don't queue) when another sync holds the lock; steal locks
    # older than 120s — no sync legitimately runs that long.
    local lock_dir="${CLAUDE_MEMORY_DB}.lore-sync.lock"
    if [[ "$dry_run" != true ]]; then
        if ! mkdir "$lock_dir" 2>/dev/null; then
            local lock_age
            lock_age=$(( $(date +%s) - $(stat -f %m "$lock_dir" 2>/dev/null || stat -c %Y "$lock_dir" 2>/dev/null || echo 0) ))
            if [[ "$lock_age" -gt 120 ]]; then
                rmdir "$lock_dir" 2>/dev/null || true
            fi
            if ! mkdir "$lock_dir" 2>/dev/null; then
                echo -e "${YELLOW}Another sync holds the lock (age ${lock_age}s) — skipping${NC}" >&2
                return 0
            fi
        fi

        # Capture and drop problematic triggers before any writes
        _capture_and_drop_triggers "$CLAUDE_MEMORY_DB"

        # Safety trap: recreate triggers and release the lock on any error
        trap '_recreate_triggers; rmdir "'"$lock_dir"'" 2>/dev/null' ERR
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
        # Restore triggers and release the sync lock
        _recreate_triggers
        trap - ERR
        _embed_backfill
        rmdir "$lock_dir" 2>/dev/null || true
    else
        local pending
        pending=$(sqlite3 "$CLAUDE_MEMORY_DB" "SELECT COUNT(*) FROM Memory WHERE source='lore-bridge' AND length(embedding)=0;" 2>/dev/null) || pending=0
        if [[ "$pending" -gt 0 ]]; then
            echo "Would embed ${pending} shadows"
        fi
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
