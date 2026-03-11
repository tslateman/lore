#!/usr/bin/env bash
# cmux-sidebar.sh — push Lore session context and fleet health to cmux sidebar.
# Triggered by: lore resume, lore snapshot, lore handoff.
[ -z "$CMUX_WORKSPACE_ID" ] && exit 0
CMUX=/Applications/cmux.app/Contents/Resources/bin/cmux
[ ! -x "$CMUX" ] && exit 0

source "$(dirname "$0")/../lib/paths.sh"

# --- Lore session context ---
session=$(cat "${LORE_TRANSFER_DATA}/.current_session" 2>/dev/null) || exit 0
data="${LORE_TRANSFER_DATA}/sessions/${session}.json"
[ ! -f "$data" ] && exit 0

goal=$(jq -r '.context.project // .summary // empty' "$data" 2>/dev/null)
blockers=$(jq '.handoff.blockers | length' "$data" 2>/dev/null)
next=$(jq -r '.handoff.next_steps[0] // empty' "$data" 2>/dev/null)

[ -n "$goal" ] && "$CMUX" set-status goal "$goal" --icon target --color "#4C8DFF" 2>/dev/null
if [ "${blockers:-0}" -gt 0 ]; then
    "$CMUX" set-status blockers "${blockers} blockers" --icon exclamationmark.triangle.fill --color "#FF6B6B" 2>/dev/null
else
    "$CMUX" clear-status blockers 2>/dev/null
fi
[ -n "$next" ] && "$CMUX" set-status next "$next" --icon arrow.right.circle --color "#A3E635" 2>/dev/null

# --- Shipyard fleet health ---
if command -v fl &>/dev/null && [ -f "${FLEET_DB:-}" ]; then
    health=$(fl health --json 2>/dev/null) || true
    if [ -n "$health" ]; then
        grade=$(echo "$health" | jq -r '.grade')
        active=$(echo "$health" | jq -r '.metrics.active_count // 0')
        violations=$(echo "$health" | jq -r '.violations')

        grade_color() {
            case "$1" in
                A) echo "#50c878" ;; B) echo "#A3E635" ;;
                C) echo "#f0a500" ;; D) echo "#FF6B6B" ;;
                *) echo "#FF3333" ;;
            esac
        }

        "$CMUX" set-status fleet_grade "$grade" --icon shield.checkered --color "$(grade_color "$grade")" 2>/dev/null
        [ "$active" -gt 0 ] && "$CMUX" set-status fleet_active "${active} active" --icon person.3.fill --color "#4C8DFF" 2>/dev/null
        [ "$violations" -gt 0 ] && "$CMUX" set-status fleet_inv "${violations} violations" --icon exclamationmark.circle --color "#FF6B6B" 2>/dev/null
    fi
fi
