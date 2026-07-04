#!/usr/bin/env bash
#
# install-handoff-hook.sh - Register the auto-handoff hook with Claude Code
#
# Idempotently adds scripts/hooks/session-handoff.sh to SessionEnd and
# PreCompact in ~/.claude/settings.json. Backs up settings.json first.
# Safe to re-run: existing registrations are left untouched.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_PATH="${SCRIPT_DIR}/hooks/session-handoff.sh"
SETTINGS="${HOME}/.claude/settings.json"

command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }
[[ -f "${HOOK_PATH}" ]] || { echo "Hook not found: ${HOOK_PATH}" >&2; exit 1; }
chmod +x "${HOOK_PATH}"

mkdir -p "${HOME}/.claude"
if [[ -f "${SETTINGS}" ]]; then
    backup="${SETTINGS}.bak-$(date +%Y%m%d-%H%M%S)"
    cp "${SETTINGS}" "${backup}"
    echo "Backup: ${backup}"
else
    echo '{}' > "${SETTINGS}"
fi

python3 - "${SETTINGS}" "${HOOK_PATH}" << 'PYEOF'
import json, sys

settings_path, hook_path = sys.argv[1], sys.argv[2]
with open(settings_path) as fh:
    settings = json.load(fh)

hooks = settings.setdefault("hooks", {})
changed = []
for event in ("SessionEnd", "PreCompact"):
    entries = hooks.setdefault(event, [])
    present = any(
        h.get("command") == hook_path
        for entry in entries
        for h in entry.get("hooks", [])
    )
    if not present:
        entries.append({"hooks": [{"type": "command", "command": hook_path}]})
        changed.append(event)

if changed:
    with open(settings_path, "w") as fh:
        json.dump(settings, fh, indent=2)
        fh.write("\n")
    print("Registered session-handoff hook: " + ", ".join(changed))
else:
    print("Hook already registered; settings unchanged.")
PYEOF
