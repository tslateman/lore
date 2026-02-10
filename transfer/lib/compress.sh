#!/usr/bin/env bash
#
# Compress - Smart context compression
#
# Identifies what's essential vs nice-to-have
# Compresses verbose context into key points
# Preserves decision rationale even when compressing
# Never loses lessons learned
#

#######################################
# Compress a session to its essential elements
# Returns a condensed version suitable for quick loading
#######################################
compress_session() {
    local session_id="$1"
    local session_file="${SESSIONS_DIR}/${session_id}.json"

    if [[ ! -f "${session_file}" ]]; then
        echo "Session not found: ${session_id}"
        return 1
    fi

    echo "Compressing session: ${session_id}"

    # Create compressed version
    local compressed
    compressed=$(jq '
        # Keep essential metadata
        {
            id: .id,
            started_at: .started_at,
            ended_at: .ended_at,
            summary: .summary,

            # Keep all goals - these define what was attempted
            goals_addressed: .goals_addressed,

            # Keep all decisions - rationale is valuable
            decisions_made: .decisions_made,

            # NEVER compress patterns - these are lessons learned
            patterns_learned: .patterns_learned,

            # Keep open threads - they represent unfinished work
            open_threads: .open_threads,

            # Keep full handoff - this is the succession plan
            handoff: .handoff,

            # Compress git state to essentials
            git_state: {
                branch: .git_state.branch,
                # Keep only first 5 commits
                commits: (.git_state.commits // [])[:5],
                # Keep uncommitted files list
                uncommitted: .git_state.uncommitted
            },

            # Compress context
            context: {
                # Keep only top 10 active files
                active_files: (.context.active_files // [])[:10],
                # Drop environment details
                environment: {
                    pwd: .context.environment.pwd
                }
            },

            # Keep related links
            related: .related,

            # Mark as compressed
            compressed: true,
            compressed_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
        }
    ' "${session_file}")

    # Calculate compression stats
    local original_size compressed_size
    original_size=$(wc -c < "${session_file}")
    compressed_size=$(echo "${compressed}" | wc -c)
    local ratio
    ratio=$(echo "scale=1; (1 - ${compressed_size}/${original_size}) * 100" | bc 2>/dev/null || echo "N/A")

    # Save compressed version
    local compressed_file="${SESSIONS_DIR}/${session_id}.compressed.json"
    echo "${compressed}" > "${compressed_file}"

    echo "Compression complete:"
    echo "  Original: ${original_size} bytes"
    echo "  Compressed: ${compressed_size} bytes"
    echo "  Reduction: ${ratio}%"
    echo "  Saved to: ${compressed_file}"
    echo ""
    echo "Preserved:"
    echo "  - All goals addressed"
    echo "  - All decisions made"
    echo "  - All patterns learned (never compressed)"
    echo "  - All open threads"
    echo "  - Full handoff notes"
    echo ""
    echo "Trimmed:"
    echo "  - Git commits (kept last 5)"
    echo "  - Active files (kept top 10)"
    echo "  - Environment details"
}

#######################################
# Extract only the most critical information
# For situations with very limited context windows
#######################################
extract_critical() {
    local session_id="$1"
    local session_file="${SESSIONS_DIR}/${session_id}.json"

    if [[ ! -f "${session_file}" ]]; then
        echo "Session not found: ${session_id}"
        return 1
    fi

    # Extract only the most critical elements
    jq '
        {
            summary: .summary,

            # Top 3 most important items from each category
            key_goals: (.goals_addressed // [])[:3],
            key_decisions: (.decisions_made // [])[:3],

            # ALL patterns - never trim these
            all_patterns: .patterns_learned,

            # Open threads are critical
            open_threads: .open_threads,

            # Top 3 next steps
            priority_next: (.handoff.next_steps // [])[:3],

            # All blockers - these are blocking work
            blockers: .handoff.blockers,

            # Current state
            branch: .git_state.branch,
            uncommitted_count: (.git_state.uncommitted // []) | length
        }
    ' "${session_file}"
}

#######################################
# Generate a one-line summary suitable for logs
#######################################
one_line_summary() {
    local session_id="$1"
    local session_file="${SESSIONS_DIR}/${session_id}.json"

    if [[ ! -f "${session_file}" ]]; then
        echo "Session not found: ${session_id}"
        return 1
    fi

    local summary goals_count decisions_count threads_count
    summary=$(jq -r '.summary // "no summary"' "${session_file}")
    goals_count=$(jq '.goals_addressed | length' "${session_file}")
    decisions_count=$(jq '.decisions_made | length' "${session_file}")
    threads_count=$(jq '.open_threads | length' "${session_file}")

    echo "[${session_id}] ${summary} (goals:${goals_count}, decisions:${decisions_count}, open:${threads_count})"
}

#######################################
# Merge multiple sessions into a consolidated summary
# Useful for understanding a body of work
#######################################
merge_sessions() {
    local output_id="$1"
    shift
    local session_ids=("$@")

    if [[ ${#session_ids[@]} -lt 2 ]]; then
        echo "Need at least 2 sessions to merge."
        return 1
    fi

    echo "Merging ${#session_ids[@]} sessions into ${output_id}"

    # Collect all sessions
    local all_sessions='[]'
    for sid in "${session_ids[@]}"; do
        local sfile="${SESSIONS_DIR}/${sid}.json"
        if [[ -f "${sfile}" ]]; then
            all_sessions=$(echo "${all_sessions}" | jq --slurpfile s "${sfile}" '. + $s')
        fi
    done

    # Merge into consolidated view
    local merged
    merged=$(echo "${all_sessions}" | jq '
        {
            id: "'"${output_id}"'",
            type: "merged",
            source_sessions: [.[].id],
            created_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),

            # Timespan
            started_at: ([.[].started_at] | sort | first),
            ended_at: ([.[].ended_at // empty] | sort | last),

            # Aggregate goals (deduplicated)
            goals_addressed: ([.[].goals_addressed] | flatten | unique),

            # Aggregate decisions (keep all - context matters)
            decisions_made: ([.[].decisions_made] | flatten),

            # Aggregate patterns (deduplicated - these are learnings)
            patterns_learned: ([.[].patterns_learned] | flatten | unique),

            # Collect all open threads (deduplicated)
            open_threads: ([.[].open_threads] | flatten | unique),

            # Take handoff from most recent session
            handoff: (sort_by(.ended_at // .started_at) | last | .handoff),

            # Take git state from most recent
            git_state: (sort_by(.ended_at // .started_at) | last | .git_state)
        }
    ')

    local merged_file="${SESSIONS_DIR}/${output_id}.json"
    echo "${merged}" > "${merged_file}"

    echo "Merged session saved to: ${merged_file}"
    echo ""
    echo "Stats:"
    echo "  Source sessions: ${#session_ids[@]}"
    echo "  Total goals: $(echo "${merged}" | jq '.goals_addressed | length')"
    echo "  Total decisions: $(echo "${merged}" | jq '.decisions_made | length')"
    echo "  Patterns learned: $(echo "${merged}" | jq '.patterns_learned | length')"
    echo "  Open threads: $(echo "${merged}" | jq '.open_threads | length')"
}

#######################################
# Prune old sessions, keeping essential information
#######################################
prune_old_sessions() {
    local days_old="${1:-30}"
    local keep_patterns="${2:-true}"

    echo "Pruning sessions older than ${days_old} days..."

    local pruned_count=0
    local patterns_preserved=0

    find "${SESSIONS_DIR}" -name "*.json" -mtime "+${days_old}" | while read -r session_file; do
        local session_id
        session_id=$(basename "${session_file}" .json)

        # Skip already compressed files
        [[ "${session_id}" == *.compressed ]] && continue

        # Extract patterns before pruning (we never lose these)
        if [[ "${keep_patterns}" == "true" ]]; then
            local patterns
            patterns=$(jq -r '.patterns_learned[]' "${session_file}" 2>/dev/null)
            if [[ -n "${patterns}" ]]; then
                # Append to patterns archive
                echo "# From session ${session_id}" >> "${DATA_DIR}/patterns_archive.txt"
                echo "${patterns}" >> "${DATA_DIR}/patterns_archive.txt"
                echo "" >> "${DATA_DIR}/patterns_archive.txt"
                ((patterns_preserved++))
            fi
        fi

        # Compress and archive
        compress_session "${session_id}" >/dev/null

        # Remove original (keep compressed version)
        rm "${session_file}"

        ((pruned_count++))
        echo "  Pruned: ${session_id}"
    done

    echo ""
    echo "Pruning complete:"
    echo "  Sessions pruned: ${pruned_count}"
    echo "  Patterns preserved: ${patterns_preserved}"
}

#######################################
# Calculate what percentage of a session is essential
#######################################
calculate_essence_ratio() {
    local session_id="$1"
    local session_file="${SESSIONS_DIR}/${session_id}.json"

    if [[ ! -f "${session_file}" ]]; then
        echo "Session not found: ${session_id}"
        return 1
    fi

    # Essential: goals, decisions, patterns, open_threads, handoff
    # Non-essential: detailed context, full git history, environment

    local essential non_essential
    essential=$(jq '
        (.goals_addressed | length) +
        (.decisions_made | length) +
        (.patterns_learned | length) +
        (.open_threads | length) +
        (.handoff.next_steps | length) +
        (.handoff.blockers | length) +
        (.handoff.questions | length)
    ' "${session_file}")

    non_essential=$(jq '
        (.git_state.commits | length) +
        (.context.active_files | length) +
        (if .context.environment then 5 else 0 end)
    ' "${session_file}")

    local total=$((essential + non_essential))
    if [[ ${total} -eq 0 ]]; then
        echo "Session is empty."
        return 0
    fi

    local ratio
    ratio=$(echo "scale=1; ${essential} * 100 / ${total}" | bc 2>/dev/null || echo "N/A")

    echo "Session ${session_id}:"
    echo "  Essential items: ${essential}"
    echo "  Non-essential items: ${non_essential}"
    echo "  Essence ratio: ${ratio}%"
}
