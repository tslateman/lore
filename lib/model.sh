#!/usr/bin/env bash
# model.sh - Shared isolation flags for one-shot `claude -p` helper calls
#
# Helper spawns (rerank, librarian, validate, handoff) need none of the
# interactive session's machinery. A bare `claude -p` boots every
# configured MCP server — remote connectors, browser automation — before
# answering a one-shot prompt: tens of seconds when cold, then the
# caller's timeout kills it fail-silent. Measured on 2026-07-22:
# bare spawn 8.3s warm / 45s+ cold; isolated spawn 3.2s.
#
# LORE_CLAUDE_ISOLATION strips that: no MCP servers, no settings sources
# (hooks, plugins), and no session persisted to disk — so throwaway
# helper transcripts never pollute the session store.
#
# Usage: source this file, then append to any claude -p invocation:
#   claude -p --model "$MODEL" "${LORE_CLAUDE_ISOLATION[@]}"

LORE_CLAUDE_ISOLATION=(
    --strict-mcp-config
    --setting-sources ""
    --no-session-persistence
)
