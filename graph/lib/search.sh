#!/usr/bin/env bash
# Search functionality for Memory Graph
# Full-text search with ranking, filtering, and fuzzy matching

set -euo pipefail

GRAPH_DIR="${GRAPH_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}"
GRAPH_FILE="${GRAPH_DIR}/data/graph.json"

# Source nodes.sh for init_graph
source "$(dirname "${BASH_SOURCE[0]}")/nodes.sh"

# Calculate Levenshtein distance for fuzzy matching
levenshtein() {
    local s1="$1"
    local s2="$2"

    # Use awk for efficient calculation
    awk -v s1="$s1" -v s2="$s2" 'BEGIN {
        len1 = length(s1)
        len2 = length(s2)

        for (i = 0; i <= len1; i++) d[i, 0] = i
        for (j = 0; j <= len2; j++) d[0, j] = j

        for (i = 1; i <= len1; i++) {
            for (j = 1; j <= len2; j++) {
                cost = (substr(s1, i, 1) != substr(s2, j, 1))
                d[i, j] = d[i-1, j] + 1
                if (d[i, j-1] + 1 < d[i, j]) d[i, j] = d[i, j-1] + 1
                if (d[i-1, j-1] + cost < d[i, j]) d[i, j] = d[i-1, j-1] + cost
            }
        }
        print d[len1, len2]
    }'
}

# Check if string matches with fuzzy tolerance
fuzzy_match() {
    local query="$1"
    local text="$2"
    local max_distance="${3:-2}"

    # Lowercase for comparison
    query=$(echo "$query" | tr '[:upper:]' '[:lower:]')
    text=$(echo "$text" | tr '[:upper:]' '[:lower:]')

    # Exact substring match
    if [[ "$text" == *"$query"* ]]; then
        echo "0"
        return 0
    fi

    # Check each word in text
    for word in $text; do
        local dist
        dist=$(levenshtein "$query" "$word")
        if [[ "$dist" -le "$max_distance" ]]; then
            echo "$dist"
            return 0
        fi
    done

    echo "-1"
    return 1
}

# Calculate search score for a node
calculate_score() {
    local query="$1"
    local name="$2"
    local data="$3"

    local score=0
    query=$(echo "$query" | tr '[:upper:]' '[:lower:]')
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    data=$(echo "$data" | tr '[:upper:]' '[:lower:]')

    # Exact name match: highest score
    if [[ "$name" == "$query" ]]; then
        score=$((score + 100))
    # Name contains query
    elif [[ "$name" == *"$query"* ]]; then
        score=$((score + 50))
    fi

    # Query word appears at start of name
    if [[ "$name" == "$query"* ]]; then
        score=$((score + 25))
    fi

    # Data contains query
    if [[ "$data" == *"$query"* ]]; then
        # Count occurrences
        local count
        count=$(echo "$data" | grep -o "$query" | wc -l)
        score=$((score + count * 10))
    fi

    echo "$score"
}

# Full-text search across all nodes
# Usage: search <query> [--type type] [--after date] [--before date] [--fuzzy] [--limit n]
search() {
    local query=""
    local type_filter=""
    local after_date=""
    local before_date=""
    local fuzzy="false"
    local limit="10"
    local tags=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type)
                type_filter="$2"
                shift 2
                ;;
            --after)
                after_date="$2"
                shift 2
                ;;
            --before)
                before_date="$2"
                shift 2
                ;;
            --fuzzy)
                fuzzy="true"
                shift
                ;;
            --limit)
                limit="$2"
                shift 2
                ;;
            --tags)
                tags="$2"
                shift 2
                ;;
            *)
                query="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$query" ]]; then
        echo "Error: Search query required" >&2
        return 1
    fi

    init_graph

    local query_lower
    query_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')

    # Build jq filter for type
    local type_jq=""
    if [[ -n "$type_filter" ]]; then
        type_jq="and .value.type == \"$type_filter\""
    fi

    # Build jq filter for date range
    local date_jq=""
    if [[ -n "$after_date" ]]; then
        date_jq="$date_jq and .value.created_at >= \"$after_date\""
    fi
    if [[ -n "$before_date" ]]; then
        date_jq="$date_jq and .value.created_at <= \"$before_date\""
    fi

    # Search and score results
    local results
    local jq_script
    jq_script='.nodes | to_entries[] |
        select(
            ((.value.name | ascii_downcase | contains($query)) or
             (.value.data | tostring | ascii_downcase | contains($query)))'

    # Add type filter if specified
    if [[ -n "$type_filter" ]]; then
        jq_script="$jq_script and .value.type == \$type_filter"
    fi

    # Add date filters
    if [[ -n "$after_date" ]]; then
        jq_script="$jq_script and .value.created_at >= \$after_date"
    fi
    if [[ -n "$before_date" ]]; then
        jq_script="$jq_script and .value.created_at <= \$before_date"
    fi

    jq_script="$jq_script"') |
        {
            id: .key,
            type: .value.type,
            name: .value.name,
            score: (
                (if (.value.name | ascii_downcase) == $query then 100
                 elif (.value.name | ascii_downcase | startswith($query)) then 75
                 elif (.value.name | ascii_downcase | contains($query)) then 50
                 else 0 end) +
                (((.value.data | tostring | ascii_downcase | split($query) | length) - 1) * 10)
            )
        }'

    results=$(jq -r --arg query "$query_lower" \
        --arg type_filter "$type_filter" \
        --arg after_date "$after_date" \
        --arg before_date "$before_date" \
        "$jq_script" "$GRAPH_FILE" 2>/dev/null)

    # If no results and fuzzy is enabled, try fuzzy search
    if [[ -z "$results" && "$fuzzy" == "true" ]]; then
        results=$(search_fuzzy "$query" "$type_filter" "$limit")
    fi

    # Sort by score and limit
    if [[ -n "$results" ]]; then
        echo "$results" | jq -s "sort_by(-.score) | .[:$limit][] | {id, type, name, score}"
    fi
}

# Fuzzy search using Levenshtein distance
search_fuzzy() {
    local query="$1"
    local type_filter="${2:-}"
    local limit="${3:-10}"
    local max_distance="${4:-2}"

    init_graph

    local query_lower
    query_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')

    # Get all nodes and check fuzzy matches
    local nodes
    nodes=$(jq -r '.nodes | to_entries[] | @base64' "$GRAPH_FILE")

    local matches=()

    for node_b64 in $nodes; do
        local node
        node=$(echo "$node_b64" | base64 -d)

        local id name type data
        id=$(echo "$node" | jq -r '.key')
        name=$(echo "$node" | jq -r '.value.name')
        type=$(echo "$node" | jq -r '.value.type')
        data=$(echo "$node" | jq -r '.value.data | tostring')

        # Skip if type filter doesn't match
        if [[ -n "$type_filter" && "$type" != "$type_filter" ]]; then
            continue
        fi

        local name_lower
        name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')

        # Check fuzzy match on name
        local dist
        dist=$(fuzzy_match "$query_lower" "$name_lower" "$max_distance") || dist="-1"

        if [[ "$dist" != "-1" ]]; then
            local score=$((100 - dist * 20))
            matches+=("{\"id\":\"$id\",\"type\":\"$type\",\"name\":\"$name\",\"score\":$score,\"fuzzy_distance\":$dist}")
        fi
    done

    # Output matches sorted by score
    if [[ ${#matches[@]} -gt 0 ]]; then
        printf '%s\n' "${matches[@]}" | jq -s "sort_by(-.score) | .[:$limit][]"
    fi
}

# Search by tags in node data
search_by_tags() {
    local tags="$1"
    local type_filter="${2:-}"

    init_graph

    IFS=',' read -ra tag_array <<< "$tags"

    local jq_filter=".nodes | to_entries[]"

    if [[ -n "$type_filter" ]]; then
        jq_filter="$jq_filter | select(.value.type == \"$type_filter\")"
    fi

    # Build tag filter
    local tag_conditions=""
    for tag in "${tag_array[@]}"; do
        tag=$(echo "$tag" | xargs)  # trim whitespace
        if [[ -n "$tag_conditions" ]]; then
            tag_conditions="$tag_conditions and"
        fi
        tag_conditions="$tag_conditions (.value.data.tags // [] | contains([\"$tag\"]))"
    done

    if [[ -n "$tag_conditions" ]]; then
        jq_filter="$jq_filter | select($tag_conditions)"
    fi

    jq -r "$jq_filter | {id: .key, type: .value.type, name: .value.name, tags: .value.data.tags}" "$GRAPH_FILE"
}

# Quick search - just returns node IDs matching query
quick_search() {
    local query="$1"
    init_graph

    local query_lower
    query_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')

    jq -r --arg query "$query_lower" '
        .nodes | to_entries[] |
        select(
            (.value.name | ascii_downcase | contains($query)) or
            (.value.data | tostring | ascii_downcase | contains($query))
        ) | .key
    ' "$GRAPH_FILE"
}

# Get recently updated nodes
recent_nodes() {
    local limit="${1:-10}"
    local type_filter="${2:-}"

    init_graph

    if [[ -n "$type_filter" ]]; then
        jq -r --arg type "$type_filter" --argjson limit "$limit" '
            .nodes | to_entries |
            map(select(.value.type == $type)) |
            sort_by(.value.updated_at) | reverse | .[:$limit][] |
            {id: .key, type: .value.type, name: .value.name, updated_at: .value.updated_at}
        ' "$GRAPH_FILE"
    else
        jq -r --argjson limit "$limit" '
            .nodes | to_entries |
            sort_by(.value.updated_at) | reverse | .[:$limit][] |
            {id: .key, type: .value.type, name: .value.name, updated_at: .value.updated_at}
        ' "$GRAPH_FILE"
    fi
}

export -f levenshtein fuzzy_match calculate_score search search_fuzzy search_by_tags quick_search recent_nodes
