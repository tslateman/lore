#!/usr/bin/env bash
# subtraction.sh - Active subtraction checks for resume
# Surfaces contradictions, stale decisions, low-confidence patterns

set -euo pipefail

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${LORE_DIR}/lib/paths.sh"

# Colors
YELLOW="${YELLOW:-\033[1;33m}"
DIM="${DIM:-\033[2m}"
NC="${NC:-\033[0m}"

subtraction_check() {
    local any_issues=false

    # 1. Contradicted decisions
    source "${LORE_DIR}/lib/conflict.sh" 2>/dev/null || true
    if type find_contradictions &>/dev/null; then
        local contradictions
        contradictions=$(find_contradictions 2>/dev/null) || true
        if [[ -n "$contradictions" ]]; then
            local contra_count
            contra_count=$(echo "$contradictions" | grep -c . || true)
            echo -e "${YELLOW}⚠ ${contra_count} decision contradiction(s) detected. Run \`lore review\` to resolve.${NC}"
            any_issues=true
        fi
    fi

    # 2. Stale pending decisions (>14 days)
    local decisions_file="${LORE_DECISIONS_FILE}"
    if [[ -f "$decisions_file" ]]; then
        local now_epoch
        now_epoch=$(date +%s)
        local stale_count=0

        local pending
        pending=$(jq -s '
            group_by(.id) | map(.[-1])
            | map(select((.status // "active") == "active" and .outcome == "pending"))
            | map({id, decision, timestamp})
            | .[]
        ' -c "$decisions_file" 2>/dev/null) || true

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local timestamp
            timestamp=$(echo "$line" | jq -r '.timestamp // empty')
            [[ -z "$timestamp" ]] && continue

            # Convert ISO timestamp to epoch (macOS date -j)
            local record_epoch
            # Strip sub-second precision if present
            local clean_ts="${timestamp%%.*}Z"
            clean_ts="${clean_ts%%Z*}Z"
            record_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$clean_ts" +%s 2>/dev/null) || continue

            local age_days=$(( (now_epoch - record_epoch) / 86400 ))
            if [[ "$age_days" -gt 14 ]]; then
                stale_count=$((stale_count + 1))
            fi
        done <<< "$pending"

        if [[ "$stale_count" -gt 0 ]]; then
            echo -e "${YELLOW}⚠ ${stale_count} pending decision(s) older than 14 days. Review or resolve them.${NC}"
            any_issues=true
        fi
    fi

    # 3. Low-confidence patterns (confidence < 0.3, validations == 0)
    local patterns_file="${LORE_PATTERNS_FILE}"
    if [[ -f "$patterns_file" ]]; then
        local low_conf_count
        low_conf_count=$(awk '
            BEGIN { in_patterns = 0; count = 0; conf = -1; vals = -1 }
            /^patterns:/ { in_patterns = 1; next }
            /^anti_patterns:/ { in_patterns = 0 }
            in_patterns && /- id:/ {
                # Flush previous entry
                if (conf >= 0 && conf < 0.3 && vals == 0) count++
                conf = -1; vals = -1
            }
            in_patterns && /confidence:/ {
                gsub(/.*confidence: /, "")
                conf = $0 + 0
            }
            in_patterns && /validations:/ {
                gsub(/.*validations: /, "")
                vals = $0 + 0
            }
            END {
                # Flush last entry
                if (conf >= 0 && conf < 0.3 && vals == 0) count++
                print count
            }
        ' "$patterns_file" 2>/dev/null) || low_conf_count=0

        if [[ "$low_conf_count" -gt 0 ]]; then
            echo -e "${YELLOW}⚠ ${low_conf_count} low-confidence pattern(s) with no validations. Validate or remove them.${NC}"
            any_issues=true
        fi
    fi

    # 4. Deprecated but unreplaced patterns
    if [[ -f "$patterns_file" ]]; then
        local deprecated_names
        deprecated_names=$(awk '
            BEGIN { in_patterns = 0 }
            /^patterns:/ { in_patterns = 1; next }
            /^anti_patterns:/ { in_patterns = 0 }
            in_patterns && /name:/ && /DEPRECATED/ {
                gsub(/.*name: "/, "")
                gsub(/".*/, "")
                # Strip the [DEPRECATED] prefix for matching
                name = $0
                gsub(/\[DEPRECATED\] */, "", name)
                print name
            }
        ' "$patterns_file" 2>/dev/null) || true

        if [[ -n "$deprecated_names" ]]; then
            local unreplaced_count=0
            while IFS= read -r dep_name; do
                [[ -z "$dep_name" ]] && continue
                # Check if anti_patterns section has a matching entry
                local has_anti
                has_anti=$(awk -v name="$dep_name" '
                    BEGIN { in_anti = 0; found = 0 }
                    /^anti_patterns:/ { in_anti = 1; next }
                    in_anti && /name:/ && index($0, name) > 0 { found = 1 }
                    END { print found }
                ' "$patterns_file" 2>/dev/null) || has_anti=0

                if [[ "$has_anti" -eq 0 ]]; then
                    unreplaced_count=$((unreplaced_count + 1))
                fi
            done <<< "$deprecated_names"

            if [[ "$unreplaced_count" -gt 0 ]]; then
                echo -e "${YELLOW}⚠ ${unreplaced_count} deprecated pattern(s) without anti-pattern replacements.${NC}"
                any_issues=true
            fi
        fi
    fi

    [[ "$any_issues" == true ]] && echo ""
}
