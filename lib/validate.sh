#!/usr/bin/env bash
# validate.sh - Comprehensive registry and documentation validation
#
# Checks consistency across mani.yaml, metadata.yaml, clusters.yaml,
# relationships.yaml, and contracts.yaml, plus prose drift in markdown
# (dead path references, unknown lore subcommands). Sourced by lore.sh.
#
# `lore validate --prose-deep` emits a JSON manifest of architectural
# claims for judged review (optionally piped to claude -p when
# LORE_VALIDATE_DEEP=1).

set -euo pipefail

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${LORE_DIR}/lib/paths.sh"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$LORE_DIR/.." && pwd)}"
MANI_FILE="${MANI_FILE:-$WORKSPACE_ROOT/mani.yaml}"

DATA_DIR="${LORE_REGISTRY_DATA}"
METADATA_FILE="$DATA_DIR/metadata.yaml"
CLUSTERS_FILE="$DATA_DIR/clusters.yaml"
RELATIONSHIPS_FILE="$DATA_DIR/relationships.yaml"
CONTRACTS_FILE="$DATA_DIR/contracts.yaml"

# Colors (reuse parent's if already set)
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
BOLD="${BOLD:-\033[1m}"
DIM="${DIM:-\033[2m}"
NC="${NC:-\033[0m}"

ERRORS=0
WARNINGS=0

# Check dependencies
_check_deps() {
    local missing=0
    for cmd in yq jq; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}Error: $cmd is required but not installed${NC}" >&2
            ((missing++)) || true
        fi
    done
    return "$missing"
}

# Helper: query YAML via yq -> JSON, then jq
yqj() {
    yq -o=json '.' "$2" 2>/dev/null | jq -r "$1"
}

# Check if project exists in mani.yaml
_project_exists() {
    local project="$1"
    local exists
    exists=$(yqj ".projects | has(\"${project}\")" "$MANI_FILE")
    [[ "$exists" == "true" ]]
}

# Get a prefixed tag value from mani tags
_get_tag() {
    local project="$1" prefix="$2"
    yqj ".projects.\"${project}\".tags[]? // empty" "$MANI_FILE" \
        | grep "^${prefix}" | head -1 | sed "s/^${prefix}//" || true
}

_pass() { echo -e "  ${GREEN}PASS${NC}  $1"; }
_fail() { echo -e "  ${RED}FAIL${NC}  $1"; ((ERRORS++)) || true; }
_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; ((WARNINGS++)) || true; }

# ── Check 1: metadata.yaml projects exist in mani ───────────────────────
check_metadata_vs_mani() {
    [[ -f "$METADATA_FILE" ]] || { _warn "metadata.yaml not found"; return 0; }

    local projects
    projects=$(yqj '.metadata | keys[]' "$METADATA_FILE" 2>/dev/null) || true
    local ok=true
    while IFS= read -r project; do
        [[ -z "$project" ]] && continue
        if ! _project_exists "$project"; then
            _fail "'$project' in metadata.yaml but not in mani.yaml"
            ok=false
        fi
    done <<< "$projects"
    if [[ "$ok" == true ]]; then _pass "metadata.yaml projects exist in mani.yaml"; fi
}

# ── Check 2: clusters.yaml components exist in mani ─────────────────────
check_clusters_vs_mani() {
    [[ -f "$CLUSTERS_FILE" ]] || { _warn "clusters.yaml not found"; return 0; }

    local components
    components=$(yqj '.clusters | to_entries[] | .value.components | keys[]' "$CLUSTERS_FILE" 2>/dev/null) || true
    local ok=true
    while IFS= read -r component; do
        [[ -z "$component" ]] && continue
        if ! _project_exists "$component"; then
            _fail "cluster component '$component' not in mani.yaml"
            ok=false
        fi
    done <<< "$components"
    if [[ "$ok" == true ]]; then _pass "clusters.yaml components exist in mani.yaml"; fi
}

# ── Check 3: relationships.yaml targets exist in mani ────────────────────
check_relationships_vs_mani() {
    [[ -f "$RELATIONSHIPS_FILE" ]] || { _warn "relationships.yaml not found"; return 0; }

    local dep_projects
    dep_projects=$(yqj '.dependencies | keys[]' "$RELATIONSHIPS_FILE" 2>/dev/null) || true
    local ok=true
    while IFS= read -r project; do
        [[ -z "$project" ]] && continue
        if ! _project_exists "$project"; then
            _fail "'$project' in relationships.yaml but not in mani.yaml"
            ok=false
        fi
    done <<< "$dep_projects"

    # Also check dependency targets (the depends_on.project values)
    local dep_targets
    dep_targets=$(yqj '.dependencies | to_entries[] | .value.depends_on[]? | .project' "$RELATIONSHIPS_FILE" 2>/dev/null) || true
    while IFS= read -r target; do
        [[ -z "$target" ]] && continue
        if ! _project_exists "$target"; then
            _fail "dependency target '$target' in relationships.yaml but not in mani.yaml"
            ok=false
        fi
    done <<< "$dep_targets"

    if [[ "$ok" == true ]]; then _pass "relationships.yaml references exist in mani.yaml"; fi
}

# ── Check 4: contracts.yaml paths exist on disk ─────────────────────────
check_contract_paths() {
    [[ -f "$CONTRACTS_FILE" ]] || { _warn "contracts.yaml not found"; return 0; }

    local ok=true
    local contracts
    contracts=$(yqj '.contracts | to_entries[] | "\(.key)\t\(.value.location)"' "$CONTRACTS_FILE" 2>/dev/null) || true
    while IFS=$'\t' read -r name location; do
        [[ -z "$name" ]] && continue
        local full_path="$WORKSPACE_ROOT/$location"
        if [[ ! -f "$full_path" ]]; then
            _fail "contract '$name' points to missing file: $location"
            ok=false
        fi
    done <<< "$contracts"
    if [[ "$ok" == true ]]; then _pass "contracts.yaml paths exist on disk"; fi
}

# ── Check 5: stale names in tracked files ────────────────────────────────
check_stale_names() {
    local stale_names=("monarch" "lineage" "lens" "neo" "ralph")

    local ok=true
    for name in "${stale_names[@]}"; do
        local hits
        hits=$(grep -rli "$name" "$LORE_DIR" \
            --include="*.md" --include="*.sh" \
            --exclude-dir=".git" --exclude-dir=".entire" \
            --exclude-dir="node_modules" --exclude-dir="_archive" \
            2>/dev/null || true)

        while IFS= read -r hit; do
            [[ -z "$hit" ]] && continue
            # Skip known-OK references (memory, plans, archived, this script)
            case "$hit" in
                */MEMORY.md|*/memory/*|*/plans/*|*archived*|*/RENAME*|*/validate.sh|*/validate.md|*/wire-project-edges.sh|*/CHANGELOG*|*/patterns/data/*|*/graph/data/*|*/journal/data/*|*/.research/*|*/tests/*)
                    continue ;;
            esac
            local rel="${hit#"$LORE_DIR"/}"
            _warn "stale name '$name' in $rel"
            ok=false
        done <<< "$hits"
    done
    if [[ "$ok" == true ]]; then _pass "no stale names (monarch, lineage, lens, neo, ralph) in active files"; fi
}

# ── Check 6: cluster tag consistency ─────────────────────────────────────
check_tag_cluster_consistency() {
    [[ -f "$CLUSTERS_FILE" ]] || { _warn "clusters.yaml not found"; return 0; }

    local projects
    projects=$(yqj '.projects | keys[]' "$MANI_FILE") || true
    local ok=true
    local project cluster_tag cluster_exists in_cluster
    while IFS= read -r project; do
        [[ -z "$project" ]] && continue
        cluster_tag=$(_get_tag "$project" "cluster:")

        if [[ -n "$cluster_tag" ]]; then
            # Verify cluster exists in clusters.yaml
            cluster_exists=$(yqj ".clusters | has(\"${cluster_tag}\")" "$CLUSTERS_FILE")
            if [[ "$cluster_exists" != "true" ]]; then
                _fail "'$project' has cluster:$cluster_tag tag but cluster '$cluster_tag' missing from clusters.yaml"
                ok=false
            fi

            # Verify project appears as a component in that cluster
            in_cluster=$(yqj ".clusters.\"${cluster_tag}\".components | has(\"${project}\")" "$CLUSTERS_FILE" 2>/dev/null) || true
            if [[ "$in_cluster" != "true" ]]; then
                _warn "'$project' tagged cluster:$cluster_tag but not listed in clusters.yaml components"
                ok=false
            fi
        fi
    done <<< "$projects"
    if [[ "$ok" == true ]]; then _pass "cluster tags match clusters.yaml components"; fi
}

# ── Check 7: archived projects have no cluster tags ──────────────────────
check_archived_no_cluster() {
    local projects
    projects=$(yqj '.projects | keys[]' "$MANI_FILE") || true
    local ok=true
    local project status cluster_tag
    while IFS= read -r project; do
        [[ -z "$project" ]] && continue
        status=$(_get_tag "$project" "status:")
        cluster_tag=$(_get_tag "$project" "cluster:")

        if [[ "$status" == "archived" && -n "$cluster_tag" ]]; then
            _fail "archived project '$project' still has cluster:$cluster_tag tag"
            ok=false
        fi
    done <<< "$projects"
    if [[ "$ok" == true ]]; then _pass "archived projects have no cluster tags"; fi
}

# ── Check 8: mani projects have required tags ────────────────────────────
check_required_tags() {
    local projects
    projects=$(yqj '.projects | keys[]' "$MANI_FILE") || true
    local ok=true
    local project proj_type status
    while IFS= read -r project; do
        [[ -z "$project" ]] && continue
        proj_type=$(_get_tag "$project" "type:")
        status=$(_get_tag "$project" "status:")

        if [[ -z "$proj_type" ]]; then
            _fail "'$project' missing type: tag"
            ok=false
        fi
        if [[ -z "$status" ]]; then
            _fail "'$project' missing status: tag"
            ok=false
        fi
    done <<< "$projects"
    if [[ "$ok" == true ]]; then _pass "all projects have type: and status: tags"; fi
}

# ── Check 9: active initiative staleness ───────────────────────────────
check_active_initiatives() {
    local initiatives_dir="$WORKSPACE_ROOT/council/initiatives"
    [[ -d "$initiatives_dir" ]] || { _warn "council/initiatives/ not found"; return 0; }

    # Build a map: initiative title -> status
    # Uses associative array keyed by lowercase title
    local -A title_to_status
    local -A title_to_file
    local init_files
    init_files=$(ls "$initiatives_dir"/*.md 2>/dev/null) || true
    [[ -z "$init_files" ]] && { _warn "no initiative files found"; return 0; }

    while IFS= read -r init_file; do
        [[ -z "$init_file" ]] && continue
        local title status
        title=$(head -1 "$init_file" | sed 's/^# //')
        status=$(grep -m1 '^\*\*Status' "$init_file" | sed 's/^\*\*Status:\*\* //' || true)
        [[ -z "$title" || -z "$status" ]] && continue
        local key
        key=$(echo "$title" | tr '[:upper:]' '[:lower:]')
        title_to_status["$key"]="$status"
        title_to_file["$key"]="$(basename "$init_file")"
    done <<< "$init_files"

    # Find CLAUDE.md files across workspace
    local claude_files
    claude_files=$(find "$WORKSPACE_ROOT" -name "CLAUDE.md" \
        -not -path "*/.git/*" \
        -not -path "*/node_modules/*" \
        -not -path "*/.entire/*" \
        -not -path "*/_archive/*" \
        2>/dev/null) || true

    local ok=true
    while IFS= read -r claude_file; do
        [[ -z "$claude_file" ]] && continue

        # Extract initiative names from "## Active Initiatives" section
        local in_section=false
        while IFS= read -r line; do
            if [[ "$line" =~ ^##[[:space:]]+Active[[:space:]]+Initiatives ]]; then
                in_section=true
                continue
            fi
            if [[ "$in_section" == true && "$line" =~ ^## ]]; then
                break
            fi
            if [[ "$in_section" == true && "$line" =~ ^\-[[:space:]]+\*\*([^*]+)\*\* ]]; then
                local init_name="${BASH_REMATCH[1]}"
                local init_key
                init_key=$(echo "$init_name" | tr '[:upper:]' '[:lower:]')

                if [[ -n "${title_to_status[$init_key]+x}" ]]; then
                    local init_status="${title_to_status[$init_key]}"
                    # Check if status starts with Active
                    if [[ ! "$init_status" =~ ^Active ]]; then
                        local rel="${claude_file#"$WORKSPACE_ROOT"/}"
                        _warn "$rel lists '$init_name' as active but status is '$init_status'"
                        ok=false
                    fi
                fi
            fi
        done < "$claude_file"
    done <<< "$claude_files"
    if [[ "$ok" == true ]]; then _pass "CLAUDE.md active initiative references match initiative status"; fi
}

# ── Prose helpers ────────────────────────────────────────────────────────

# List markdown files to scan, repo-relative, one per line.
# Prefers git-tracked files; falls back to find when not a git repo.
_tracked_md_files() {
    local files
    files=$(git -C "$LORE_DIR" ls-files '*.md' 2>/dev/null) || true
    if [[ -z "$files" ]]; then
        files=$(cd "$LORE_DIR" && find . -name '*.md' \
            -not -path '*/.git/*' -not -path '*/.entire/*' \
            -not -path '*/node_modules/*' -not -path '*/_archive/*' \
            2>/dev/null | sed 's|^\./||') || true
    fi
    echo "$files"
}

# Clean and filter one candidate path reference. Echoes "kind ref"
# when it looks checkable; returns 1 otherwise. Conservative: skip when unsure.
_clean_path_ref() {
    local kind="$1" ref="${2%%#*}"    # strip anchor
    [[ -z "$ref" ]] && return 1
    case "$ref" in
        http://*|https://*|mailto:*) return 1 ;;    # URLs
        *path/to/*) return 1 ;;                     # placeholder
    esac
    # Conservative charset: reject spans with spaces, globs, variables
    echo "$ref" | grep -qE '^[A-Za-z0-9._~/-]+$' || return 1
    echo "$kind $ref"
    return 0
}

# Emit candidate path references from a markdown file, one per line,
# prefixed "link " or "tick ". Sources: markdown link targets and
# backtick-quoted repo-file-like paths.
_extract_path_refs() {
    local file="$1"
    local ref
    # Markdown link targets: [text](target)
    grep -oE '\]\([^)]+\)' "$file" 2>/dev/null | sed 's/^](//; s/)$//' \
        | while IFS= read -r ref; do
            _clean_path_ref "link" "$ref" || true
        done
    # Backtick spans: need a slash plus a file-like shape (extension on
    # the basename, multi-segment trailing slash, or known top-level dir)
    grep -oE '`[^`]+`' "$file" 2>/dev/null | sed 's/`//g' \
        | while IFS= read -r ref; do
            case "$ref" in */*) ;; *) continue ;; esac
            case "$ref" in
                */)
                    # dir ref: require multi-segment (skip generic `data/` mentions)
                    case "${ref%/}" in */*) ;; *) continue ;; esac
                    ;;
                plans/*|lib/*|docs/*|tests/*|agents/*|commands/*|scripts/*) ;;
                *)
                    case "${ref##*/}" in *.*) ;; *) continue ;; esac
                    ;;
            esac
            _clean_path_ref "tick" "$ref" || true
        done
}

# For backtick refs: only judge paths whose leading directory is known.
# Example paths (`src/main.rs`, `myproject/state/`) get skipped.
_leading_dir_known() {
    local ref="$1" basedir="$2" rel_dir="$3"
    local head="${ref%%/*}"
    [[ -z "$head" ]] && return 0
    [[ -d "$basedir/$head" || -d "$LORE_DIR/$head" ]] && return 0
    [[ -n "${WORKSPACE_ROOT:-}" && -d "$WORKSPACE_ROOT/$head" ]] && return 0
    if [[ -n "${LORE_DATA_DIR:-}" ]]; then
        [[ -d "$LORE_DATA_DIR/$head" ]] && return 0
        [[ -n "$rel_dir" && -d "$LORE_DATA_DIR/$rel_dir/$head" ]] && return 0
    fi
    return 1
}

# Return 0 when a path reference resolves (or cannot be judged locally)
_path_ref_resolves() {
    local ref="$1" basedir="$2" rel_dir="$3"
    case "$ref" in
        "~/"*)
            [[ -e "${HOME}/${ref#\~/}" ]] && return 0
            return 1 ;;
        "~"*|/*) return 0 ;;    # other-user or machine-absolute: skip
    esac
    [[ -e "$basedir/$ref" ]] && return 0
    [[ -e "$LORE_DIR/$ref" ]] && return 0
    [[ -n "${WORKSPACE_ROOT:-}" && -e "$WORKSPACE_ROOT/$ref" ]] && return 0
    if [[ -n "${LORE_DATA_DIR:-}" ]]; then
        # Externalized data: component data/ dirs live under LORE_DATA_DIR
        [[ -e "$LORE_DATA_DIR/$ref" ]] && return 0
        [[ -n "$rel_dir" && -e "$LORE_DATA_DIR/$rel_dir/$ref" ]] && return 0
    fi
    return 1
}

# Extract case labels from the dispatch table inside a named function
_case_labels() {
    local file="$1" func="$2"
    awk -v fn="$func" '
        $0 ~ "^" fn "\\(\\) \\{" { infunc = 1 }
        infunc && /^\}/ { infunc = 0 }
        infunc && /^[[:space:]]*[-A-Za-z*|_][-A-Za-z*|_]*\)/ {
            line = $0
            sub(/\).*/, "", line)
            gsub(/[[:space:]]/, "", line)
            n = split(line, parts, "|")
            for (i = 1; i <= n; i++)
                if (parts[i] != "*" && parts[i] != "") print parts[i]
        }
    ' "$file" 2>/dev/null | sort -u
}

# Emit "word1 word2" (word2 may be empty) for each lore invocation found
# in inline code spans and fenced code blocks
_extract_lore_invocations() {
    local file="$1"
    {
        grep -oE '`lore [^`]+`' "$file" 2>/dev/null | sed 's/^`//; s/`$//' || true
        awk '/^[[:space:]]*```/ { infence = !infence; next } infence' "$file" 2>/dev/null \
            | grep -E '^[[:space:]]*(\$[[:space:]]*)?lore [a-z]' 2>/dev/null \
            | sed -E 's/^[[:space:]]*\$?[[:space:]]*//' || true
    } | awk '$1 == "lore" { print $2, $3 }'
}

# ── Check 10: markdown path references resolve ───────────────────────────
check_doc_paths() {
    local md_files
    md_files=$(_tracked_md_files)
    [[ -z "$md_files" ]] && { _pass "markdown path references resolve (no files)"; return 0; }

    local ok=true
    local md_file abs_md basedir rel_dir refs kind ref base
    while IFS= read -r md_file; do
        [[ -z "$md_file" ]] && continue
        case "$md_file" in
            # Plans and archives describe past or hypothetical states
            plans/*|docs/archive/*|_archive/*|.research/*) continue ;;
        esac
        abs_md="$LORE_DIR/$md_file"
        [[ -f "$abs_md" ]] || continue
        basedir=$(dirname "$abs_md")
        rel_dir=$(dirname "$md_file")
        refs=$(_extract_path_refs "$abs_md" | sort -u)
        while read -r kind ref; do
            [[ -z "$ref" ]] && continue
            # Backtick relative refs: skip when the leading dir is unknown
            if [[ "$kind" == "tick" ]]; then
                case "$ref" in
                    "~"*|/*) ;;
                    *) _leading_dir_known "$ref" "$basedir" "$rel_dir" || continue ;;
                esac
            fi
            if ! _path_ref_resolves "$ref" "$basedir" "$rel_dir"; then
                base="${ref##*/}"
                if [[ -n "$base" && -f "$LORE_DIR/plans/archive/$base" ]]; then
                    _warn "$md_file: dead reference '$ref' (moved to plans/archive/$base)"
                else
                    _warn "$md_file: dead reference '$ref'"
                fi
                ok=false
            fi
        done <<< "$refs"
    done <<< "$md_files"
    if [[ "$ok" == true ]]; then _pass "markdown path references resolve"; fi
}

# ── Check 11: lore commands in docs exist in the dispatch table ──────────
check_doc_commands() {
    local lore_sh="$LORE_DIR/lore.sh"
    [[ -f "$lore_sh" ]] || { _warn "lore.sh not found; skipping command check"; return 0; }

    local known
    known=$(_case_labels "$lore_sh" "main")
    [[ -z "$known" ]] && { _warn "could not parse lore.sh dispatch table"; return 0; }

    # Sub-dispatchers with parseable case tables
    local index_known="" registry_known=""
    [[ -f "$LORE_DIR/lib/search-index.sh" ]] \
        && index_known=$(_case_labels "$LORE_DIR/lib/search-index.sh" "main")
    [[ -f "$LORE_DIR/registry/lib/registry.sh" ]] \
        && registry_known=$(_case_labels "$LORE_DIR/registry/lib/registry.sh" "registry_main")

    local md_files
    md_files=$(_tracked_md_files)
    [[ -z "$md_files" ]] && { _pass "lore commands in docs match the dispatch table (no files)"; return 0; }

    local ok=true
    local md_file invocations cmd sub
    while IFS= read -r md_file; do
        [[ -z "$md_file" ]] && continue
        case "$md_file" in
            # Plans and archives may describe proposed or retired commands
            plans/*|docs/archive/*|_archive/*|.research/*) continue ;;
        esac
        [[ -f "$LORE_DIR/$md_file" ]] || continue
        invocations=$(_extract_lore_invocations "$LORE_DIR/$md_file" | sort -u)
        while read -r cmd sub; do
            [[ -z "$cmd" ]] && continue
            echo "$cmd" | grep -qE '^[a-z][a-z-]*$' || continue
            if ! echo "$known" | grep -qFx "$cmd"; then
                _warn "$md_file: unknown command 'lore $cmd'"
                ok=false
                continue
            fi
            [[ -z "$sub" ]] && continue
            echo "$sub" | grep -qE '^[a-z][a-z-]*$' || continue
            case "$cmd" in
                index)
                    if [[ -n "$index_known" ]] && ! echo "$index_known" | grep -qFx "$sub"; then
                        _warn "$md_file: unknown subcommand 'lore index $sub'"
                        ok=false
                    fi ;;
                registry)
                    if [[ -n "$registry_known" ]] && ! echo "$registry_known" | grep -qFx "$sub"; then
                        _warn "$md_file: unknown subcommand 'lore registry $sub'"
                        ok=false
                    fi ;;
            esac
        done <<< "$invocations"
    done <<< "$md_files"
    if [[ "$ok" == true ]]; then _pass "lore commands in docs match the dispatch table"; fi
}

# ── Deep prose check: claim manifest for judged review ───────────────────
_run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout &>/dev/null; then
        timeout "$secs" "$@"
    elif command -v gtimeout &>/dev/null; then
        gtimeout "$secs" "$@"
    else
        "$@"
    fi
}

check_prose_deep() {
    command -v jq &>/dev/null || { echo -e "${RED}Error: jq is required for --prose-deep${NC}" >&2; return 1; }

    local marker_re='Not bridged|never|always|only|does not'
    local keywords="registry transfer journal patterns failures inbox intent graph evidence bridge validate conflict paths"

    local claims="" f matches line line_no claim likely kw
    for f in SYSTEM.md CLAUDE.md; do
        [[ -f "$LORE_DIR/$f" ]] || continue
        matches=$(grep -nE "$marker_re" "$LORE_DIR/$f" 2>/dev/null) || true
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            line_no="${line%%:*}"
            claim="${line#*:}"
            # Best-effort keyword match: which component/lib file the claim concerns
            likely=""
            for kw in $keywords; do
                echo "$claim" | grep -qiw "$kw" || continue
                [[ -f "$LORE_DIR/lib/${kw}.sh" ]] && likely="$likely lib/${kw}.sh"
                [[ -d "$LORE_DIR/${kw}" ]] && likely="$likely ${kw}/"
            done
            if echo "$claim" | grep -qiwE 'search|index'; then
                [[ -f "$LORE_DIR/lib/search-index.sh" ]] && likely="$likely lib/search-index.sh"
            fi
            claims+=$(jq -n --arg file "$f" --arg line "$line_no" --arg claim "$claim" --arg likely "$likely" \
                '{file: $file, line: ($line | tonumber), claim: $claim,
                  likely_files: ($likely | split(" ") | map(select(length > 0)))}')$'\n'
        done <<< "$matches"
    done

    local manifest
    manifest=$(printf '%s' "$claims" | jq -s \
        '{source: "lore validate --prose-deep", claims: .}')

    # Judged review: only when explicitly enabled and claude CLI exists.
    # Fail-silent -- any failure falls through to printing the manifest.
    if [[ "${LORE_VALIDATE_DEEP:-0}" == "1" ]] && command -v claude &>/dev/null; then
        local headers="" lf target judged=""
        for lf in $(printf '%s' "$manifest" | jq -r '.claims[].likely_files[]' 2>/dev/null | sort -u); do
            target="$LORE_DIR/$lf"
            [[ -d "$target" ]] && target="$target/README.md"
            [[ -f "$target" ]] || continue
            headers+="--- ${lf} ---"$'\n'"$(head -40 "$target")"$'\n\n'
        done
        judged=$(printf '%s\n\n%s' "$manifest" "$headers" | _run_with_timeout 60 \
            claude -p "Review these architectural claims from documentation against the source file headers that follow. List any claim the source contradicts, citing file and line. If none, say: No contradictions found." \
            --model claude-haiku-4-5-20251001 2>/dev/null) || judged=""
        if [[ -n "$judged" ]]; then
            echo "$judged"
            return 0
        fi
    fi

    printf '%s\n' "$manifest"
}

# ── Main ─────────────────────────────────────────────────────────────────
cmd_validate() {
    _check_deps || return 1

    if [[ "${1:-}" == "--prose-deep" ]]; then
        check_prose_deep
        return 0
    fi

    if [[ ! -f "$MANI_FILE" ]]; then
        echo -e "${RED}Error: mani.yaml not found at ${MANI_FILE}${NC}" >&2
        return 1
    fi

    echo -e "${BOLD}Validating lore registry...${NC}"
    echo ""

    check_metadata_vs_mani
    check_clusters_vs_mani
    check_relationships_vs_mani
    check_contract_paths
    check_stale_names
    check_tag_cluster_consistency
    check_archived_no_cluster
    check_required_tags
    check_active_initiatives
    check_doc_paths
    check_doc_commands

    echo ""
    if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
        echo -e "${GREEN}All 11 checks passed${NC}"
    else
        echo -e "${DIM}Results: ${ERRORS} error(s), ${WARNINGS} warning(s)${NC}"
    fi

    return "$ERRORS"
}
