#!/usr/bin/env bash
# Validation tests for lib/validate.sh
#
# Tests all 9 registry validation checks with both pass and fail cases.
# Uses a temporary directory so production data is untouched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Test harness ---

PASS=0
FAIL=0
TMPDIR=""

# Minimal mani.yaml for tests
MINI_MANI='
projects:
  alpha:
    path: alpha
    desc: Test project alpha
    tags: [type:application, lang:shell, status:active, cluster:core]
  beta:
    path: beta
    desc: Test project beta
    tags: [type:library, lang:shell, status:active, cluster:core]
  archived-proj:
    path: archived-proj
    desc: Archived project
    tags: [type:tool, lang:shell, status:archived]
'

setup() {
    TMPDIR=$(mktemp -d)

    # Create workspace with mani.yaml
    mkdir -p "$TMPDIR/workspace"
    echo "$MINI_MANI" > "$TMPDIR/workspace/mani.yaml"

    # Create a lore directory inside workspace
    mkdir -p "$TMPDIR/workspace/lore/lib"
    mkdir -p "$TMPDIR/workspace/lore/registry/data"

    # Copy validate.sh and paths.sh
    cp "$SCRIPT_DIR/../lib/validate.sh" "$TMPDIR/workspace/lore/lib/"
    cp "$SCRIPT_DIR/../lib/paths.sh" "$TMPDIR/workspace/lore/lib/"

    # Set environment
    unset _LORE_PATHS_LOADED
    export LORE_DIR="$TMPDIR/workspace/lore"
    export LORE_DATA_DIR="$TMPDIR/workspace/lore"
    export WORKSPACE_ROOT="$TMPDIR/workspace"
    export MANI_FILE="$TMPDIR/workspace/mani.yaml"

    # Source validate.sh (sets up paths and functions)
    source "$TMPDIR/workspace/lore/lib/validate.sh"

    # Reset counters (validate.sh uses global ERRORS/WARNINGS)
    ERRORS=0
    WARNINGS=0
}

teardown() {
    [[ -n "$TMPDIR" && -d "$TMPDIR" ]] && rm -rf "$TMPDIR"
    TMPDIR=""
    ERRORS=0
    WARNINGS=0
    return 0
}

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1"
    local pattern="$2"
    local text="$3"
    if echo "$text" | grep -q "$pattern"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (pattern '$pattern' not found)"
        FAIL=$((FAIL + 1))
    fi
}

# Run a check function, capture output to file so ERRORS/WARNINGS propagate.
# Sets CHECK_OUTPUT for assertions. Must NOT be called inside $(...).
CHECK_OUTPUT=""
run_check() {
    local outfile="$TMPDIR/check_output"
    "$@" > "$outfile" 2>&1 || true
    CHECK_OUTPUT=$(cat "$outfile")
}

run_test() {
    local name="$1"
    echo ""
    echo "--- $name ---"
    setup
    "$name"
    teardown
}


# ── Check 1: metadata.yaml vs mani ─────────────────────────────────────

test_metadata_pass() {
    cat > "$LORE_DIR/registry/data/metadata.yaml" <<'YAML'
metadata:
  alpha:
    summary: Alpha project
  beta:
    summary: Beta project
YAML
    run_check check_metadata_vs_mani
    assert_eq "valid metadata produces 0 errors" 0 "$ERRORS"
    assert_contains "valid metadata shows PASS" "PASS" "$CHECK_OUTPUT"
}

test_metadata_unknown_project() {
    cat > "$LORE_DIR/registry/data/metadata.yaml" <<'YAML'
metadata:
  alpha:
    summary: Alpha
  nonexistent:
    summary: Ghost project
YAML
    run_check check_metadata_vs_mani
    assert_eq "unknown project produces 1 error" 1 "$ERRORS"
    assert_contains "error names the project" "nonexistent" "$CHECK_OUTPUT"
}

test_metadata_missing_file() {
    # No metadata.yaml at all -- should warn, not error
    run_check check_metadata_vs_mani
    assert_eq "missing metadata.yaml produces 0 errors" 0 "$ERRORS"
    assert_eq "missing metadata.yaml produces 1 warning" 1 "$WARNINGS"
}


# ── Check 2: clusters.yaml vs mani ─────────────────────────────────────

test_clusters_pass() {
    cat > "$LORE_DIR/registry/data/clusters.yaml" <<'YAML'
clusters:
  core:
    purpose: Core projects
    components:
      alpha:
        role: primary
      beta:
        role: secondary
YAML
    run_check check_clusters_vs_mani
    assert_eq "valid clusters produces 0 errors" 0 "$ERRORS"
    assert_contains "valid clusters shows PASS" "PASS" "$CHECK_OUTPUT"
}

test_clusters_unknown_component() {
    cat > "$LORE_DIR/registry/data/clusters.yaml" <<'YAML'
clusters:
  core:
    purpose: Core projects
    components:
      alpha:
        role: primary
      phantom:
        role: ghost
YAML
    run_check check_clusters_vs_mani
    assert_eq "unknown component produces 1 error" 1 "$ERRORS"
    assert_contains "error names the component" "phantom" "$CHECK_OUTPUT"
}

test_clusters_missing_file() {
    run_check check_clusters_vs_mani
    assert_eq "missing clusters.yaml produces 0 errors" 0 "$ERRORS"
    assert_eq "missing clusters.yaml produces 1 warning" 1 "$WARNINGS"
}


# ── Check 3: relationships.yaml vs mani ─────────────────────────────────

test_relationships_pass() {
    cat > "$LORE_DIR/registry/data/relationships.yaml" <<'YAML'
dependencies:
  alpha:
    depends_on:
      - project: beta
        type: runtime
YAML
    run_check check_relationships_vs_mani
    assert_eq "valid relationships produces 0 errors" 0 "$ERRORS"
    assert_contains "valid relationships shows PASS" "PASS" "$CHECK_OUTPUT"
}

test_relationships_unknown_source() {
    cat > "$LORE_DIR/registry/data/relationships.yaml" <<'YAML'
dependencies:
  ghost:
    depends_on:
      - project: alpha
        type: runtime
YAML
    run_check check_relationships_vs_mani
    assert_eq "unknown source project produces 1 error" 1 "$ERRORS"
    assert_contains "error names the project" "ghost" "$CHECK_OUTPUT"
}

test_relationships_unknown_target() {
    cat > "$LORE_DIR/registry/data/relationships.yaml" <<'YAML'
dependencies:
  alpha:
    depends_on:
      - project: missing-dep
        type: runtime
YAML
    run_check check_relationships_vs_mani
    assert_eq "unknown target produces 1 error" 1 "$ERRORS"
    assert_contains "error names the target" "missing-dep" "$CHECK_OUTPUT"
}

test_relationships_missing_file() {
    run_check check_relationships_vs_mani
    assert_eq "missing relationships.yaml produces 0 errors" 0 "$ERRORS"
    assert_eq "missing relationships.yaml produces 1 warning" 1 "$WARNINGS"
}


# ── Check 4: contracts.yaml paths ───────────────────────────────────────

test_contracts_pass() {
    # Create a file the contract points to
    mkdir -p "$TMPDIR/workspace/alpha"
    echo "# Contract" > "$TMPDIR/workspace/alpha/CONTRACT.md"

    cat > "$LORE_DIR/registry/data/contracts.yaml" <<YAML
contracts:
  alpha-contract:
    location: alpha/CONTRACT.md
    owner: alpha
YAML
    run_check check_contract_paths
    assert_eq "valid contract path produces 0 errors" 0 "$ERRORS"
    assert_contains "valid contracts shows PASS" "PASS" "$CHECK_OUTPUT"
}

test_contracts_missing_path() {
    cat > "$LORE_DIR/registry/data/contracts.yaml" <<YAML
contracts:
  phantom-contract:
    location: phantom/DOES_NOT_EXIST.md
    owner: alpha
YAML
    run_check check_contract_paths
    assert_eq "missing contract file produces 1 error" 1 "$ERRORS"
    assert_contains "error names the contract" "phantom-contract" "$CHECK_OUTPUT"
}

test_contracts_missing_file() {
    run_check check_contract_paths
    assert_eq "missing contracts.yaml produces 0 errors" 0 "$ERRORS"
    assert_eq "missing contracts.yaml produces 1 warning" 1 "$WARNINGS"
}


# ── Check 5: stale names ───────────────────────────────────────────────

test_stale_names_clean() {
    # LORE_DIR has only lib/ and registry/ -- no stale names
    run_check check_stale_names
    assert_eq "clean directory produces 0 errors" 0 "$ERRORS"
    assert_contains "clean directory shows PASS" "PASS" "$CHECK_OUTPUT"
}

test_stale_names_detected() {
    # Create a shell script with a stale name
    echo '# This references monarch for legacy reasons' > "$LORE_DIR/stale-ref.sh"

    run_check check_stale_names
    assert_eq "stale name produces 0 errors (warns only)" 0 "$ERRORS"
    assert_contains "stale name warns" "WARN" "$CHECK_OUTPUT"
    assert_contains "stale name mentions monarch" "monarch" "$CHECK_OUTPUT"
}


# ── Check 6: tag-cluster consistency ────────────────────────────────────

test_tag_cluster_pass() {
    cat > "$LORE_DIR/registry/data/clusters.yaml" <<'YAML'
clusters:
  core:
    purpose: Core projects
    components:
      alpha:
        role: primary
      beta:
        role: secondary
YAML
    run_check check_tag_cluster_consistency
    assert_eq "consistent tags+clusters produces 0 errors" 0 "$ERRORS"
    assert_contains "consistent tags shows PASS" "PASS" "$CHECK_OUTPUT"
}

test_tag_cluster_missing_cluster() {
    # Projects have cluster:core tag but clusters.yaml has no "core" cluster
    cat > "$LORE_DIR/registry/data/clusters.yaml" <<'YAML'
clusters:
  other:
    purpose: Different cluster
    components: {}
YAML
    run_check check_tag_cluster_consistency
    assert_eq "missing cluster definition produces errors" 2 "$ERRORS"
}

test_tag_cluster_not_in_components() {
    # Cluster exists but alpha is not listed as a component
    cat > "$LORE_DIR/registry/data/clusters.yaml" <<'YAML'
clusters:
  core:
    purpose: Core
    components:
      beta:
        role: secondary
YAML
    run_check check_tag_cluster_consistency
    # alpha has cluster:core tag but is not in the components list
    assert_eq "missing from components produces warnings" 1 "$WARNINGS"
}


# ── Check 7: archived projects no cluster tags ──────────────────────────

test_archived_no_cluster_pass() {
    # archived-proj has no cluster tag -- should pass
    run_check check_archived_no_cluster
    assert_eq "archived without cluster produces 0 errors" 0 "$ERRORS"
    assert_contains "archived check shows PASS" "PASS" "$CHECK_OUTPUT"
}

test_archived_with_cluster() {
    # Add cluster tag to the archived project
    cat > "$MANI_FILE" <<'YAML'
projects:
  alpha:
    path: alpha
    desc: Alpha
    tags: [type:application, lang:shell, status:active]
  bad-archive:
    path: bad-archive
    desc: Should not have cluster
    tags: [type:tool, lang:shell, status:archived, cluster:leftovers]
YAML

    run_check check_archived_no_cluster
    assert_eq "archived with cluster produces 1 error" 1 "$ERRORS"
    assert_contains "error names the project" "bad-archive" "$CHECK_OUTPUT"
}


# ── Check 8: required tags ─────────────────────────────────────────────

test_required_tags_pass() {
    # All projects in MINI_MANI have type: and status: tags
    run_check check_required_tags
    assert_eq "all required tags produces 0 errors" 0 "$ERRORS"
    assert_contains "required tags shows PASS" "PASS" "$CHECK_OUTPUT"
}

test_required_tags_missing() {
    cat > "$MANI_FILE" <<'YAML'
projects:
  bare-proj:
    path: bare
    desc: No tags at all
    tags: [lang:shell]
YAML

    run_check check_required_tags
    # Missing both type: and status:
    assert_eq "missing type+status produces 2 errors" 2 "$ERRORS"
}


# ── Check 9: active initiative staleness ────────────────────────────────

test_initiatives_no_council() {
    # No council/initiatives directory -- should warn
    run_check check_active_initiatives
    assert_eq "missing council dir produces 0 errors" 0 "$ERRORS"
    assert_eq "missing council dir warns" 1 "$WARNINGS"
}

test_initiatives_pass() {
    # Create matching initiative and CLAUDE.md
    mkdir -p "$TMPDIR/workspace/council/initiatives"
    cat > "$TMPDIR/workspace/council/initiatives/test-init.md" <<'MD'
# Test Initiative

**Status:** Active

Work in progress.
MD

    mkdir -p "$TMPDIR/workspace/alpha"
    cat > "$TMPDIR/workspace/alpha/CLAUDE.md" <<'MD'
# Alpha

## Active Initiatives

- **Test Initiative** — doing things
MD

    run_check check_active_initiatives
    assert_eq "matching active initiative produces 0 errors" 0 "$ERRORS"
    assert_contains "initiative check shows PASS" "PASS" "$CHECK_OUTPUT"
}

test_initiatives_stale_reference() {
    # Initiative is Completed but CLAUDE.md still lists it as active
    mkdir -p "$TMPDIR/workspace/council/initiatives"
    cat > "$TMPDIR/workspace/council/initiatives/old-init.md" <<'MD'
# Old Initiative

**Status:** Completed

Done.
MD

    mkdir -p "$TMPDIR/workspace/alpha"
    cat > "$TMPDIR/workspace/alpha/CLAUDE.md" <<'MD'
# Alpha

## Active Initiatives

- **Old Initiative** — should have been removed
MD

    run_check check_active_initiatives
    assert_eq "stale initiative reference warns" 1 "$WARNINGS"
    assert_contains "warning mentions status" "Completed" "$CHECK_OUTPUT"
}


# ── Integration: cmd_validate ───────────────────────────────────────────

test_cmd_validate_all_pass() {
    # Set up all registry files with valid data
    cat > "$LORE_DIR/registry/data/metadata.yaml" <<'YAML'
metadata:
  alpha:
    summary: Alpha project
YAML

    cat > "$LORE_DIR/registry/data/clusters.yaml" <<'YAML'
clusters:
  core:
    purpose: Core
    components:
      alpha:
        role: primary
      beta:
        role: secondary
YAML

    cat > "$LORE_DIR/registry/data/relationships.yaml" <<'YAML'
dependencies:
  alpha:
    depends_on:
      - project: beta
        type: runtime
YAML

    mkdir -p "$TMPDIR/workspace/alpha"
    echo "# Contract" > "$TMPDIR/workspace/alpha/CONTRACT.md"
    cat > "$LORE_DIR/registry/data/contracts.yaml" <<YAML
contracts:
  alpha-contract:
    location: alpha/CONTRACT.md
    owner: alpha
YAML

    # No council dir = skip initiative check (warn only)
    local exit_code=0
    cmd_validate > /dev/null 2>&1 || exit_code=$?
    assert_eq "full validation exits 0" 0 "$exit_code"
}

test_cmd_validate_counts_errors() {
    # metadata references nonexistent project
    cat > "$LORE_DIR/registry/data/metadata.yaml" <<'YAML'
metadata:
  ghost:
    summary: Does not exist
YAML

    # No other files -- warns for missing but doesn't error
    # cmd_validate returns ERRORS as exit code, so capture it
    local exit_code=0
    cmd_validate > "$TMPDIR/check_output" 2>&1 || exit_code=$?
    CHECK_OUTPUT=$(cat "$TMPDIR/check_output")
    assert_eq "validation with errors exits non-zero" 1 "$exit_code"
    assert_contains "reports error count" "1 error" "$CHECK_OUTPUT"
}


# ── Run all tests ───────────────────────────────────────────────────────

echo "=== Validation Tests ==="

# Check 1
run_test test_metadata_pass
run_test test_metadata_unknown_project
run_test test_metadata_missing_file

# Check 2
run_test test_clusters_pass
run_test test_clusters_unknown_component
run_test test_clusters_missing_file

# Check 3
run_test test_relationships_pass
run_test test_relationships_unknown_source
run_test test_relationships_unknown_target
run_test test_relationships_missing_file

# Check 4
run_test test_contracts_pass
run_test test_contracts_missing_path
run_test test_contracts_missing_file

# Check 5
run_test test_stale_names_clean
run_test test_stale_names_detected

# Check 6
run_test test_tag_cluster_pass
run_test test_tag_cluster_missing_cluster
run_test test_tag_cluster_not_in_components

# Check 7
run_test test_archived_no_cluster_pass
run_test test_archived_with_cluster

# Check 8
run_test test_required_tags_pass
run_test test_required_tags_missing

# Check 9
run_test test_initiatives_no_council
run_test test_initiatives_pass
run_test test_initiatives_stale_reference

# Integration
run_test test_cmd_validate_all_pass
run_test test_cmd_validate_counts_errors

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
