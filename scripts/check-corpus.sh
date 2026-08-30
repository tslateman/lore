#!/usr/bin/env bash
# check-corpus.sh - Gate every tracked spec against the standards corpus
#
# `lore corpus <spec> --check` judges one spec file, so this finds the specs:
# tracked markdown whose frontmatter declares applies_to or projects, the two
# axes corpus_assemble requires. It exits 1 if any spec has an open blocking
# finding.
#
# --check decides only the clauses that carry a --pattern; it greps the spec
# for them. Clauses without a pattern need a model, and its verdicts arrive
# through --findings. This script feeds "<spec>.findings.json" when one sits
# beside the spec, and always prints how many candidate clauses were actually
# judged, so a pass never reads as more thorough than it was.
#
# Usage: scripts/check-corpus.sh [spec-file...]

set -euo pipefail

LORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$LORE_DIR" || exit 1

declares_axis() {
    local file="$1"
    [[ "$(head -1 "$file")" == "---" ]] || return 1
    awk 'NR==1 && $0 != "---" { exit } NR>1 && $0 == "---" { exit } NR>1 { print }' "$file" \
        | grep -qE '^(applies_to|projects):[[:space:]]*[^[:space:]]'
}

specs=()
if [[ $# -gt 0 ]]; then
    specs=("$@")
else
    while IFS= read -r -d '' f; do
        declares_axis "$f" && specs+=("$f")
    done < <(git ls-files -z '*.md')
fi

if [[ ${#specs[@]} -eq 0 ]]; then
    echo "check-corpus: GATE INERT -- no tracked spec declares applies_to or projects."
    echo "check-corpus: 'lore corpus <spec> --check' judges one spec file at a time."
    echo "check-corpus: this gate starts judging the moment a spec adds either axis"
    echo "check-corpus: to its frontmatter. The gate's own behaviour is covered by"
    echo "check-corpus: tests/test-standards.sh."
    exit 0
fi

echo "check-corpus: gating ${#specs[@]} specs"

failed=0
unjudged_total=0

for spec in "${specs[@]}"; do
    findings="${spec%.md}.findings.json"
    args=("$spec" --check)
    note="no findings file"
    if [[ -f "$findings" ]]; then
        args=("$spec" --findings "$findings")
        note="findings: $findings"
    fi

    result=$(./lore.sh corpus "${args[@]}") && status=0 || status=$?

    assembled=$(./lore.sh corpus "$spec")
    machine=$(printf '%s' "$assembled" | jq -r '.counts.machine_checked')
    candidates=$(printf '%s' "$assembled" | jq -r '.candidates | length')
    gate=$(printf '%s' "$result" | jq -r '.gate')
    blocking=$(printf '%s' "$result" | jq -r '.counts.open_blocking')

    printf '  %-44s %-8s %s open blocking\n' "$spec" "$gate" "$blocking"
    printf '  %-44s %s of %s clauses machine-checked, %s\n' "" "$machine" "$candidates" "$note"

    if [[ ! -f "$findings" && "$machine" -lt "$candidates" ]]; then
        unjudged_total=$(( unjudged_total + candidates - machine ))
    fi

    if [[ $status -ne 0 ]]; then
        printf '%s' "$result" | jq -r '.findings[] | select(.acknowledged | not) | "    \(.clause_id) [\(.enforcement)] (\(.detected_by)) \(.text)"'
        failed=$((failed + 1))
    fi
done

if [[ $unjudged_total -gt 0 ]]; then
    echo "check-corpus: $unjudged_total pattern-less clauses went unjudged -- they need a"
    echo "check-corpus: model review fed back through a <spec>.findings.json sidecar."
fi

if [[ $failed -gt 0 ]]; then
    echo "check-corpus: $failed of ${#specs[@]} specs blocked."
    exit 1
fi

echo "check-corpus: all ${#specs[@]} specs clear"
