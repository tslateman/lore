#!/usr/bin/env bash
# lore-client-base.sh - Shared client library for Lore integration
#
# Source this in project-specific client libraries.
# All functions fail silently if Lore is unavailable (non-blocking).
#
# Usage:
#   LORE_DIR="${LORE_DIR:-$HOME/dev/lore}"
#   source "$LORE_DIR/lib/lore-client-base.sh"

LORE_DIR="${LORE_DIR:-$HOME/dev/lore}"

# Check whether Lore is available and functional
# Returns 0 if available, 1 if not (silent)
check_lore() {
    [[ -x "$LORE_DIR/lore.sh" ]] && return 0
    return 1
}

# Record a decision in the journal
# Args: <decision> [--rationale "why"] [--tags "t1,t2"] [--type TYPE] [--files "f1,f2"]
lore_record_decision() {
    check_lore || return 0
    "$LORE_DIR/journal/journal.sh" record "$@" 2>/dev/null || true
}

# Add a node to the knowledge graph
# Args: <type> <name> [--data '{}']
lore_add_node() {
    check_lore || return 0
    "$LORE_DIR/graph/graph.sh" add "$@" 2>/dev/null || true
}

# Add an edge between graph nodes
# Args: <from> <to> --relation <type> [--weight N] [--bidirectional]
lore_add_edge() {
    check_lore || return 0
    "$LORE_DIR/graph/graph.sh" link "$@" 2>/dev/null || true
}

# Capture a learned pattern
# Args: <pattern> [--context "when"] [--solution "how"] [--category CAT]
lore_learn_pattern() {
    check_lore || return 0
    "$LORE_DIR/patterns/patterns.sh" capture "$@" 2>/dev/null || true
}

# Create a session handoff note
# Args: <message>
lore_handoff() {
    check_lore || return 0
    "$LORE_DIR/transfer/transfer.sh" handoff "$@" 2>/dev/null || true
}

# Search across all Lore components
# Args: <query>
lore_search() {
    check_lore || return 0
    "$LORE_DIR/lore.sh" search "$@" 2>/dev/null || true
}

# Get journal context for a file or topic
# Args: <file|topic>
lore_context() {
    check_lore || return 0
    "$LORE_DIR/journal/journal.sh" context "$@" 2>/dev/null || true
}

# Get pattern suggestions for a context
# Args: <context> [--limit N]
lore_suggest_patterns() {
    check_lore || return 0
    "$LORE_DIR/patterns/patterns.sh" suggest "$@" 2>/dev/null || true
}

# Capture a raw observation to inbox
# Args: <text> [--source <source>] [--tags <tags>]
lore_observe() {
    check_lore || return 0
    "$LORE_DIR/lore.sh" observe "$@" 2>/dev/null || true
}

# Create a goal
# Args: <name> [--priority P] [--tags "t1,t2"]
lore_create_goal() {
    check_lore || return 0
    "$LORE_DIR/lore.sh" goal create "$@" 2>/dev/null || true
}

# Show enriched project details from registry
# Args: <project>
lore_registry_show() {
    check_lore || return 0
    "$LORE_DIR/lore.sh" registry show "$@" 2>/dev/null || true
}

# Run comprehensive registry validation
# Returns 0 even on failure (fail-silent for integration)
lore_validate() {
    check_lore || return 0
    "$LORE_DIR/lore.sh" validate "$@" 2>/dev/null || true
}
