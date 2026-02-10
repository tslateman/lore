#!/usr/bin/env bash
# lineage-client-base.sh - Shared client library for Lineage integration
#
# Source this in project-specific client libraries.
# All functions fail silently if Lineage is unavailable (non-blocking).
#
# Usage:
#   LINEAGE_DIR="${LINEAGE_DIR:-$HOME/dev/lineage}"
#   source "$LINEAGE_DIR/lib/lineage-client-base.sh"

LINEAGE_DIR="${LINEAGE_DIR:-$HOME/dev/lineage}"

# Check whether Lineage is available and functional
# Returns 0 if available, 1 if not (silent)
check_lineage() {
    [[ -x "$LINEAGE_DIR/lineage.sh" ]] && return 0
    return 1
}

# Record a decision in the journal
# Args: <decision> [--rationale "why"] [--tags "t1,t2"] [--type TYPE] [--files "f1,f2"]
lineage_record_decision() {
    check_lineage || return 0
    "$LINEAGE_DIR/journal/journal.sh" record "$@" 2>/dev/null || true
}

# Add a node to the knowledge graph
# Args: <type> <name> [--data '{}']
lineage_add_node() {
    check_lineage || return 0
    "$LINEAGE_DIR/graph/graph.sh" add "$@" 2>/dev/null || true
}

# Add an edge between graph nodes
# Args: <from> <to> --relation <type> [--weight N] [--bidirectional]
lineage_add_edge() {
    check_lineage || return 0
    "$LINEAGE_DIR/graph/graph.sh" link "$@" 2>/dev/null || true
}

# Capture a learned pattern
# Args: <pattern> [--context "when"] [--solution "how"] [--category CAT]
lineage_learn_pattern() {
    check_lineage || return 0
    "$LINEAGE_DIR/patterns/patterns.sh" capture "$@" 2>/dev/null || true
}

# Create a session handoff note
# Args: <message>
lineage_handoff() {
    check_lineage || return 0
    "$LINEAGE_DIR/transfer/transfer.sh" handoff "$@" 2>/dev/null || true
}

# Search across all Lineage components
# Args: <query>
lineage_search() {
    check_lineage || return 0
    "$LINEAGE_DIR/lineage.sh" search "$@" 2>/dev/null || true
}

# Get journal context for a file or topic
# Args: <file|topic>
lineage_context() {
    check_lineage || return 0
    "$LINEAGE_DIR/journal/journal.sh" context "$@" 2>/dev/null || true
}

# Get pattern suggestions for a context
# Args: <context> [--limit N]
lineage_suggest_patterns() {
    check_lineage || return 0
    "$LINEAGE_DIR/patterns/patterns.sh" suggest "$@" 2>/dev/null || true
}
