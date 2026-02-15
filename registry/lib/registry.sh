#!/usr/bin/env bash
# Registry - Project metadata and context assembly
# Registry - part of Lore

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/../data"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$HOME/dev}"
MANI_FILE="${MANI_FILE:-$WORKSPACE_ROOT/mani.yaml}"

METADATA_FILE="${DATA_DIR}/metadata.yaml"
CLUSTERS_FILE="${DATA_DIR}/clusters.yaml"
RELATIONSHIPS_FILE="${DATA_DIR}/relationships.yaml"
CONTRACTS_FILE="${DATA_DIR}/contracts.yaml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Check dependencies
check_deps() {
    if ! command -v yq &>/dev/null; then
        echo -e "${RED}Error: yq is required but not installed${NC}" >&2
        return 1
    fi
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}Error: jq is required but not installed${NC}" >&2
        return 1
    fi
}

# Helper: query YAML via yq -> JSON, then jq
yqj() {
    yq -o=json '.' "$2" 2>/dev/null | jq -r "$1"
}

# Check if mani.yaml exists
check_mani() {
    if [[ ! -f "$MANI_FILE" ]]; then
        echo -e "${RED}Error: mani.yaml not found at ${MANI_FILE}${NC}" >&2
        return 1
    fi
}

# Check if project exists in mani.yaml
project_exists() {
    local project="$1"
    local exists
    exists=$(yqj ".projects | has(\"${project}\")" "$MANI_FILE")
    [[ "$exists" == "true" ]]
}

# Extract a prefixed tag value from mani tags
get_tag_value() {
    local project="$1"
    local prefix="$2"
    yqj ".projects.\"${project}\".tags[]? // empty" "$MANI_FILE" | grep "^${prefix}" | head -1 | sed "s/^${prefix}//" || true
}

# Print horizontal separator
print_separator() {
    printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'
}

# ============================================
# show_project - Enriched project details
# ============================================

show_project() {
    local project_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                project_name="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$project_name" ]]; then
        echo -e "${RED}Error: Project name required${NC}" >&2
        echo "Usage: lore registry show <project>" >&2
        return 1
    fi

    check_deps
    check_mani

    if ! project_exists "$project_name"; then
        echo -e "${RED}Error: Project '${project_name}' not found in mani.yaml${NC}" >&2
        return 1
    fi

    local path description
    path=$(yqj ".projects.\"${project_name}\".path" "$MANI_FILE")
    description=$(yqj ".projects.\"${project_name}\".desc // \"No description\"" "$MANI_FILE")

    local proj_type language status cluster
    proj_type=$(get_tag_value "$project_name" "type:")
    language=$(get_tag_value "$project_name" "lang:")
    status=$(get_tag_value "$project_name" "status:")
    cluster=$(get_tag_value "$project_name" "cluster:")

    echo -e "${BOLD}${project_name}${NC}"
    print_separator
    echo -e "${DIM}${description}${NC}"
    echo ""

    echo -e "${BOLD}Basic Info${NC}"
    echo -e "  Path:     ~/dev/${path}"
    echo -e "  Type:     ${proj_type:-unknown}"
    echo -e "  Language: ${language:-unknown}"
    echo -e "  Status:   ${status:-unknown}"

    if [[ -n "$cluster" && -f "$METADATA_FILE" ]]; then
        local role=""
        role=$(yqj ".metadata.\"${project_name}\".role // empty" "$METADATA_FILE")
        echo ""
        echo -e "${BOLD}Cluster${NC}"
        echo -e "  Member of: ${CYAN}${cluster}${NC}"
        if [[ -n "$role" ]]; then
            echo -e "  Role:      ${role}"
        fi
    fi

    if [[ -f "$RELATIONSHIPS_FILE" ]]; then
        local deps
        deps=$(yqj ".dependencies.\"${project_name}\".depends_on[]? | \"\(.project)\"" "$RELATIONSHIPS_FILE" 2>/dev/null)
        if [[ -n "$deps" ]]; then
            echo ""
            echo -e "${BOLD}Dependencies${NC}"
            while IFS= read -r dep; do
                echo -e "  - ${dep}"
            done <<< "$deps"
        fi
    fi

    if [[ -f "$METADATA_FILE" ]]; then
        local contracts
        contracts=$(yqj ".metadata.\"${project_name}\".contracts // null" "$METADATA_FILE")
        if [[ "$contracts" != "null" ]]; then
            echo ""
            echo -e "${BOLD}Contracts${NC}"

            local exposes
            exposes=$(yqj ".metadata.\"${project_name}\".contracts.exposes // [] | length" "$METADATA_FILE")
            if [[ "$exposes" -gt 0 ]]; then
                echo -e "  ${GREEN}Exposes:${NC}"
                yqj ".metadata.\"${project_name}\".contracts.exposes[]" "$METADATA_FILE" | while read -r contract; do
                    echo -e "    - ${contract}"
                done
            fi

            local consumes
            consumes=$(yqj ".metadata.\"${project_name}\".contracts.consumes // [] | length" "$METADATA_FILE")
            if [[ "$consumes" -gt 0 ]]; then
                echo -e "  ${YELLOW}Consumes:${NC}"
                yqj ".metadata.\"${project_name}\".contracts.consumes[]" "$METADATA_FILE" | while read -r contract; do
                    echo -e "    - ${contract}"
                done
            fi
        fi
    fi

    print_separator
}

# ============================================
# list_projects - List all projects from mani
# ============================================

list_projects() {
    check_deps
    check_mani

    echo -e "${BOLD}Projects${NC}"
    print_separator
    printf "%-20s %-40s %-12s\n" "NAME" "DESCRIPTION" "STATUS"
    print_separator

    local projects
    projects=$(yqj '.projects | keys[]' "$MANI_FILE")

    local count=0
    while IFS= read -r project; do
        [[ -z "$project" ]] && continue

        local description status
        description=$(yqj ".projects.\"${project}\".desc // \"\"" "$MANI_FILE")
        status=$(get_tag_value "$project" "status:")

        if [[ ${#description} -gt 38 ]]; then
            description="${description:0:35}..."
        fi

        printf "%-20s %-40s %-12s\n" "$project" "$description" "${status:-unknown}"
        ((count++)) || true
    done <<< "$projects"

    print_separator
    echo -e "${DIM}Total: ${count} project(s)${NC}"
}

# ============================================
# get_context - Assemble context for a project
# ============================================

get_context() {
    local project_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -*)
                echo -e "${RED}Error: Unknown option: $1${NC}" >&2
                return 1
                ;;
            *)
                project_name="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$project_name" ]]; then
        echo -e "${RED}Error: Project name required${NC}" >&2
        echo "Usage: lore registry context <project>" >&2
        return 1
    fi

    check_deps
    check_mani

    if ! project_exists "$project_name"; then
        echo -e "${RED}Error: Project '${project_name}' not found in mani.yaml${NC}" >&2
        return 1
    fi

    local description
    description=$(yqj ".projects.\"${project_name}\".desc // \"\"" "$MANI_FILE")

    echo "# ${project_name}"
    if [[ -n "$description" ]]; then
        echo ""
        echo "> ${description}"
    fi

    # Basics
    local path proj_type language status
    path=$(yqj ".projects.\"${project_name}\".path" "$MANI_FILE")
    proj_type=$(get_tag_value "$project_name" "type:")
    language=$(get_tag_value "$project_name" "lang:")
    status=$(get_tag_value "$project_name" "status:")

    echo ""
    echo "## Basics"
    echo ""
    echo "- **Path**: ~/dev/${path}"
    echo "- **Type**: ${proj_type:-unknown}"
    echo "- **Language**: ${language:-unknown}"
    echo "- **Status**: ${status:-unknown}"

    # Dependencies
    if [[ -f "$RELATIONSHIPS_FILE" ]]; then
        local deps
        deps=$(yqj ".dependencies.\"${project_name}\".depends_on[]? | \"\(.project)\t\(.type)\t\(.reason)\"" "$RELATIONSHIPS_FILE" 2>/dev/null)

        if [[ -n "$deps" ]]; then
            echo ""
            echo "## Dependencies"
            echo ""
            echo "| Dependency | Type | Reason |"
            echo "| ---------- | ---- | ------ |"
            while IFS=$'\t' read -r dep_name dep_type dep_reason; do
                echo "| ${dep_name} | ${dep_type} | ${dep_reason} |"
            done <<< "$deps"
        fi
    fi

    # Cluster
    local cluster
    cluster=$(get_tag_value "$project_name" "cluster:")
    if [[ -n "$cluster" && -f "$CLUSTERS_FILE" ]]; then
        local role=""
        if [[ -f "$METADATA_FILE" ]]; then
            role=$(yqj ".metadata.\"${project_name}\".role // \"\"" "$METADATA_FILE")
        fi

        echo ""
        echo "## Cluster: ${cluster}"
        echo ""
        echo "**Role**: ${role:-unknown}"
    fi

    # Entry point
    echo ""
    echo "## Entry Point"
    echo ""
    echo "Read ~/dev/${path}/CLAUDE.md"
}

# ============================================
# validate - Check registry consistency
# ============================================

validate_registry() {
    check_deps
    check_mani

    local errors=0
    local warnings=0

    echo -e "${BOLD}Validating registry...${NC}"
    echo ""

    # Check metadata projects exist in mani
    if [[ -f "$METADATA_FILE" ]]; then
        local meta_projects
        meta_projects=$(yqj '.metadata | keys[]' "$METADATA_FILE" 2>/dev/null)
        while IFS= read -r project; do
            [[ -z "$project" ]] && continue
            if ! project_exists "$project"; then
                echo -e "${RED}  Error: '$project' in metadata.yaml but not in mani.yaml${NC}"
                ((errors++)) || true
            fi
        done <<< "$meta_projects"
    fi

    # Check cluster components exist in mani
    if [[ -f "$CLUSTERS_FILE" ]]; then
        local cluster_components
        cluster_components=$(yqj '.clusters | to_entries[] | .value.components | keys[]' "$CLUSTERS_FILE" 2>/dev/null)
        while IFS= read -r component; do
            [[ -z "$component" ]] && continue
            if ! project_exists "$component"; then
                echo -e "${YELLOW}  Warning: cluster component '$component' not in mani.yaml${NC}"
                ((warnings++)) || true
            fi
        done <<< "$cluster_components"
    fi

    # Check relationship targets exist in mani
    if [[ -f "$RELATIONSHIPS_FILE" ]]; then
        local dep_projects
        dep_projects=$(yqj '.dependencies | keys[]' "$RELATIONSHIPS_FILE" 2>/dev/null)
        while IFS= read -r project; do
            [[ -z "$project" ]] && continue
            if ! project_exists "$project"; then
                echo -e "${YELLOW}  Warning: '$project' in relationships.yaml but not in mani.yaml${NC}"
                ((warnings++)) || true
            fi
        done <<< "$dep_projects"
    fi

    echo ""
    if [[ $errors -eq 0 && $warnings -eq 0 ]]; then
        echo -e "${GREEN}Registry is consistent${NC}"
    else
        echo -e "Errors: $errors, Warnings: $warnings"
    fi

    return "$errors"
}

# ============================================
# Main dispatch
# ============================================

registry_help() {
    echo "Registry - Project metadata and context assembly"
    echo ""
    echo "Usage:"
    echo "  lore registry show <project>      Show enriched project details"
    echo "  lore registry list                 List all projects"
    echo "  lore registry context <project>    Assemble context for agent onboarding"
    echo "  lore registry validate             Check registry consistency"
}

registry_main() {
    if [[ $# -eq 0 ]]; then
        registry_help
        return 0
    fi

    local command="$1"
    shift

    case "$command" in
        show)     show_project "$@" ;;
        list)     list_projects "$@" ;;
        context)  get_context "$@" ;;
        validate) validate_registry "$@" ;;
        -h|--help|help) registry_help ;;
        *)
            echo -e "${RED}Unknown registry command: $command${NC}" >&2
            registry_help >&2
            return 1
            ;;
    esac
}
