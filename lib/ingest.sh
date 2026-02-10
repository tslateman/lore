#!/usr/bin/env bash
# ingest.sh - Bulk import from external project formats into Lineage
#
# Parses Monarch relationships.yaml, HANDOFF.md, and pattern_sharing
# entries into Lineage journal decisions, graph nodes, and patterns.

set -euo pipefail

LINEAGE_DIR="${LINEAGE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Ingest Monarch relationships.yaml into graph nodes + edges
# Usage: ingest_relationships <project_name> <relationships_yaml>
ingest_relationships() {
    local project="$1"
    local yaml_file="$2"

    if [[ ! -f "$yaml_file" ]]; then
        echo "Error: File not found: $yaml_file" >&2
        return 1
    fi

    echo "Ingesting relationships from: $yaml_file"

    local count=0

    # Extract project dependency relationships using yq or fallback to grep/sed
    if command -v yq &>/dev/null; then
        # Parse YAML with yq - extract depends_on entries
        local projects
        projects=$(yq -r 'keys[]' "$yaml_file" 2>/dev/null || true)

        for proj in $projects; do
            # Add project node
            "$LINEAGE_DIR/graph/graph.sh" add project "$proj" \
                --data "{\"source\": \"$project\", \"ingested_from\": \"$yaml_file\"}" 2>/dev/null || true

            # Extract depends_on relationships
            local deps
            deps=$(yq -r ".${proj}.depends_on[]? // empty" "$yaml_file" 2>/dev/null || true)

            for dep in $deps; do
                local dep_name
                dep_name=$(echo "$dep" | sed 's/ (.*//')
                "$LINEAGE_DIR/graph/graph.sh" add project "$dep_name" \
                    --data '{"source": "'"$project"'"}' 2>/dev/null || true

                local from_id to_id
                from_id=$("$LINEAGE_DIR/graph/graph.sh" add project "$proj" 2>/dev/null | tail -1)
                to_id=$("$LINEAGE_DIR/graph/graph.sh" add project "$dep_name" 2>/dev/null | tail -1)

                if [[ -n "$from_id" && -n "$to_id" ]]; then
                    "$LINEAGE_DIR/graph/graph.sh" link "$from_id" "$to_id" \
                        --relation depends_on 2>/dev/null || true
                fi
            done

            count=$((count + 1))
        done
    else
        # Fallback: line-by-line grep for simple patterns
        local current_project=""
        while IFS= read -r line; do
            # Match top-level project keys (no leading whitespace, ends with :)
            if [[ "$line" =~ ^[a-zA-Z_-]+:$ ]]; then
                current_project="${line%:}"
                "$LINEAGE_DIR/graph/graph.sh" add project "$current_project" \
                    --data "{\"source\": \"$project\", \"ingested_from\": \"$yaml_file\"}" 2>/dev/null || true
                count=$((count + 1))
            fi
        done < "$yaml_file"
    fi

    echo "Ingested $count project relationships"
}

# Ingest markdown handoff entries into journal decisions
# Usage: ingest_handoffs <project_name> <handoff_md>
ingest_handoffs() {
    local project="$1"
    local md_file="$2"

    if [[ ! -f "$md_file" ]]; then
        echo "Error: File not found: $md_file" >&2
        return 1
    fi

    echo "Ingesting handoffs from: $md_file"

    local count=0
    local current_heading=""
    local current_body=""

    while IFS= read -r line; do
        # Match markdown headings (## or ###)
        if [[ "$line" =~ ^##[[:space:]]+(.*) ]]; then
            # Store previous entry if we have one
            if [[ -n "$current_heading" && -n "$current_body" ]]; then
                "$LINEAGE_DIR/journal/journal.sh" record "$current_heading" \
                    --rationale "$current_body" \
                    --tags "$project,handoff,ingested" \
                    --type "context" 2>/dev/null || true
                count=$((count + 1))
            fi
            current_heading="${BASH_REMATCH[1]}"
            current_body=""
        elif [[ -n "$current_heading" ]]; then
            current_body="${current_body:+$current_body }$(echo "$line" | sed 's/^[[:space:]]*//')"
        fi
    done < "$md_file"

    # Store final entry
    if [[ -n "$current_heading" && -n "$current_body" ]]; then
        "$LINEAGE_DIR/journal/journal.sh" record "$current_heading" \
            --rationale "$current_body" \
            --tags "$project,handoff,ingested" \
            --type "context" 2>/dev/null || true
        count=$((count + 1))
    fi

    echo "Ingested $count handoff entries"
}

# Ingest pattern_sharing entries from relationships.yaml into patterns
# Usage: ingest_patterns <project_name> <relationships_yaml>
ingest_patterns() {
    local project="$1"
    local yaml_file="$2"

    if [[ ! -f "$yaml_file" ]]; then
        echo "Error: File not found: $yaml_file" >&2
        return 1
    fi

    echo "Ingesting patterns from: $yaml_file"

    local count=0

    if command -v yq &>/dev/null; then
        local patterns
        patterns=$(yq -r '.pattern_sharing[]?.pattern // empty' "$yaml_file" 2>/dev/null || true)

        while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue

            local description
            description=$(yq -r ".pattern_sharing[] | select(.pattern == \"$pattern\") | .description // \"\"" "$yaml_file" 2>/dev/null || true)

            "$LINEAGE_DIR/patterns/patterns.sh" capture "$pattern" \
                --context "$description" \
                --category "architecture" 2>/dev/null || true

            count=$((count + 1))
        done <<< "$patterns"
    else
        # Fallback: grep for pattern_sharing entries
        local in_patterns=false
        while IFS= read -r line; do
            if [[ "$line" =~ ^pattern_sharing: ]]; then
                in_patterns=true
                continue
            fi
            if [[ "$in_patterns" == true ]]; then
                if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+pattern:[[:space:]]+(.*) ]]; then
                    local pattern="${BASH_REMATCH[1]}"
                    "$LINEAGE_DIR/patterns/patterns.sh" capture "$pattern" \
                        --category "architecture" 2>/dev/null || true
                    count=$((count + 1))
                elif [[ "$line" =~ ^[a-zA-Z] ]]; then
                    in_patterns=false
                fi
            fi
        done < "$yaml_file"
    fi

    echo "Ingested $count patterns"
}

# Main dispatcher for ingest subcommand
cmd_ingest() {
    if [[ $# -lt 3 ]]; then
        echo "Usage: lineage ingest <project> <type> <file>"
        echo ""
        echo "Types:"
        echo "  relationships  Parse relationships.yaml into graph"
        echo "  handoffs       Parse markdown handoff docs into journal"
        echo "  patterns       Parse pattern_sharing entries into patterns"
        return 1
    fi

    local project="$1"
    local type="$2"
    local file="$3"

    case "$type" in
        relationships) ingest_relationships "$project" "$file" ;;
        handoffs)      ingest_handoffs "$project" "$file" ;;
        patterns)      ingest_patterns "$project" "$file" ;;
        *)
            echo "Unknown ingest type: $type" >&2
            echo "Valid types: relationships, handoffs, patterns" >&2
            return 1
            ;;
    esac
}
