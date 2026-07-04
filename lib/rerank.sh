#!/usr/bin/env bash
# rerank.sh - Model-judged reranking for FTS5 search results
#
# BM25 scores lexical overlap; it cannot judge relevance to the current
# work. This library passes over-fetched candidates through a fast model
# (claude -p) that reorders them against the query and working context.
#
# Contract: fail-silent. If the claude CLI is missing, times out, returns
# unparseable output, or returns no valid ids, candidates pass through
# unchanged in their original order and the caller never sees an error.
# Hallucinated ids are ignored. Candidates the model omits are appended
# after the ranked ones unless LORE_RERANK_FILTER=1.
#
# Environment:
#   LORE_RERANK=0          Kill switch — disables reranking everywhere
#   LORE_RERANK_TIMEOUT    Seconds before the model call is killed (default 45)
#   LORE_RERANK_MODEL      Model id (default claude-haiku-4-5-20251001)
#   LORE_RERANK_FILTER=1   Drop model-omitted candidates instead of appending
#   LORE_RERANK_SEARCH=1   Force reranking in search-index.sh searches
#                          (set by `lore resume` for its ranked-context block)
#
# Input shape: one candidate per line, field-separated. Field 1 is the
# record type, field 3 the content; the id field position is an argument
# (default 2). Matches both lore.sh _search_fts5 (tab-separated) and
# lib/search-index.sh search_query (pipe-separated) rows.

# Reranking is available: not killed, claude CLI present.
rerank_enabled() {
    [[ "${LORE_RERANK:-1}" == "0" ]] && return 1
    command -v claude >/dev/null 2>&1 || return 1
    return 0
}

# Build working context: project name plus recent commit subjects of cwd.
rerank_git_context() {
    local toplevel=""
    toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || toplevel=""
    if [[ -n "$toplevel" ]]; then
        echo "Project: $(basename "$toplevel")"
        echo "Recent commits:"
        git log --oneline -10 2>/dev/null | sed 's/^/  /' || true
    else
        echo "Project: $(basename "$(pwd)")"
    fi
}

# Invoke claude -p with a timeout. Prompt arrives on stdin.
# macOS ships no `timeout` command; fall back to the perl alarm pattern.
_rerank_invoke_claude() {
    local timeout_s="${LORE_RERANK_TIMEOUT:-45}"
    local model="${LORE_RERANK_MODEL:-claude-haiku-4-5-20251001}"
    if command -v timeout >/dev/null 2>&1; then
        timeout "$timeout_s" claude -p --model "$model" 2>/dev/null
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift @ARGV; exec @ARGV' "$timeout_s" \
            claude -p --model "$model" 2>/dev/null
    else
        claude -p --model "$model" 2>/dev/null
    fi
}

# Rerank candidate lines from stdin against a query and working context.
# Args: query, context (optional), field separator (default tab),
#       id field position (default 2).
# Emits candidate lines to stdout; always exits 0.
rerank_results() {
    local query="$1"
    local context="${2:-}"
    local sep="${3:-$(printf '\t')}"
    local id_field="${4:-2}"

    local input
    input=$(cat) || input=""
    [[ -z "$input" ]] && return 0

    if ! rerank_enabled; then
        printf '%s\n' "$input"
        return 0
    fi

    # Candidate list for the prompt: id: [type] content
    local candidates
    candidates=$(printf '%s\n' "$input" | awk -F"$sep" -v idf="$id_field" \
        '{ printf "%s: [%s] %s\n", $idf, $1, substr($3, 1, 200) }' 2>/dev/null) || candidates=""
    [[ -z "$candidates" ]] && { printf '%s\n' "$input"; return 0; }

    local prompt
    prompt="You rerank search results for a developer knowledge base.
Given this working context and query, return ONLY a JSON array of candidate ids ordered by relevance, most relevant first. Omit ids clearly irrelevant to the query and context. Output the JSON array and nothing else - no prose, no code fences.

Working context:
${context:-none}

Query: ${query}

Candidates (id: [type] text):
${candidates}"

    # Group with stderr silenced: on timeout the shell reports the
    # SIGALRM-killed child ("Alarm clock"), which must not leak
    local raw
    raw=$( { printf '%s' "$prompt" | _rerank_invoke_claude; } 2>/dev/null ) || raw=""
    [[ -z "$raw" ]] && { printf '%s\n' "$input"; return 0; }

    # Extract the JSON array of ids; tolerate fences and surrounding prose
    local ids
    ids=$(printf '%s' "$raw" | tr '\n' ' ' \
        | sed -n 's/.*\(\[[^][]*\]\).*/\1/p' \
        | jq -r '.[] | select(type == "string")' 2>/dev/null) || ids=""
    [[ -z "$ids" ]] && { printf '%s\n' "$input"; return 0; }

    # Reorder: ranked valid ids first, then omitted lines in original order
    # (dropped when LORE_RERANK_FILTER=1). If every returned id is
    # hallucinated, awk exits nonzero and the input passes through.
    local filter="${LORE_RERANK_FILTER:-0}"
    local reordered
    reordered=$(awk -F"$sep" -v idf="$id_field" -v filter="$filter" '
        NR == FNR { if (length($0)) order[++n] = $0; next }
        {
            total = FNR; lines[FNR] = $0
            if (!($idf in firstline)) firstline[$idf] = FNR
        }
        END {
            matched = 0
            for (i = 1; i <= n; i++) {
                id = order[i]
                if (id in firstline && !printed[firstline[id]]) {
                    print lines[firstline[id]]
                    printed[firstline[id]] = 1
                    matched++
                }
            }
            if (matched == 0) exit 3
            if (filter != "1")
                for (j = 1; j <= total; j++)
                    if (!printed[j]) print lines[j]
        }
    ' <(printf '%s\n' "$ids") <(printf '%s\n' "$input") 2>/dev/null) || reordered=""

    if [[ -z "$reordered" ]]; then
        printf '%s\n' "$input"
    else
        printf '%s\n' "$reordered"
    fi
    return 0
}
