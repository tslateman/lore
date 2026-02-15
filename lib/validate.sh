#!/usr/bin/env bash
# validate.sh - Comprehensive registry validation
#
# Checks consistency across mani.yaml, metadata.yaml, clusters.yaml,
# relationships.yaml, and contracts.yaml. Sourced by lore.sh.

set -euo pipefail

LORE_DIR="${LORE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$LORE_DIR/.." && pwd)}"
MANI_FILE="${MANI_FILE:-$WORKSPACE_ROOT/mani.yaml}"

DATA_DIR="$LORE_DIR/registry/data"
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
    local stale_names=("monarch" "lineage" "lens")

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
                */MEMORY.md|*/memory/*|*/plans/*|*archived*|*/RENAME*|*/validate.sh|*/CHANGELOG*)
                    continue ;;
            esac
            local rel="${hit#"$LORE_DIR"/}"
            _warn "stale name '$name' in $rel"
            ok=false
        done <<< "$hits"
    done
    if [[ "$ok" == true ]]; then _pass "no stale names (monarch, lineage, lens) in active files"; fi
}

# ── Check 6: cluster tag consistency ─────────────────────────────────────
check_tag_cluster_consistency() {
    [[ -f "$CLUSTERS_FILE" ]] || { _warn "clusters.yaml not found"; return 0; }

    local projects
    projects=$(yqj '.projects | keys[]' "$MANI_FILE") || true
    local ok=true
    while IFS= read -r project; do
        [[ -z "$project" ]] && continue
        local cluster_tag
        cluster_tag=$(_get_tag "$project" "cluster:")

        if [[ -n "$cluster_tag" ]]; then
            # Verify cluster exists in clusters.yaml
            local cluster_exists
            cluster_exists=$(yqj ".clusters | has(\"${cluster_tag}\")" "$CLUSTERS_FILE")
            if [[ "$cluster_exists" != "true" ]]; then
                _fail "'$project' has cluster:$cluster_tag tag but cluster '$cluster_tag' missing from clusters.yaml"
                ok=false
            fi

            # Verify project appears as a component in that cluster
            local in_cluster
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
    while IFS= read -r project; do
        [[ -z "$project" ]] && continue
        local status cluster_tag
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
    while IFS= read -r project; do
        [[ -z "$project" ]] && continue
        local proj_type status
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

# ── Main ─────────────────────────────────────────────────────────────────
cmd_validate() {
    _check_deps || return 1

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

    echo ""
    if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
        echo -e "${GREEN}All 8 checks passed${NC}"
    else
        echo -e "${DIM}Results: ${ERRORS} error(s), ${WARNINGS} warning(s)${NC}"
    fi

    return "$ERRORS"
}
