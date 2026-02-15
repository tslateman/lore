# Failures

Structured failure reports for tracking what went wrong across agent sessions.

## Overview

The failure journal captures tool errors, permission denials, timeouts, and logic errors in a structured, append-only format. It supports the "Rule of Three" -- when the same error type recurs three or more times, `triggers` surfaces it as a recurring pattern worth addressing.

## Quick Start

```bash
# Log a failure
lore fail NonZeroExit "prettier crashed on large table" --tool Bash --mission mission-abc

# List failures
lore failures --type ToolError
lore failures --mission mission-abc

# Show recurring failure types
lore triggers
```

## CLI Commands

| Command                                                          | Description                                                |
| ---------------------------------------------------------------- | ---------------------------------------------------------- |
| `lore fail <type> <message> [--tool T] [--mission M] [--step S]` | Log a failure report                                       |
| `lore failures [--type T] [--mission M]`                         | List failures with optional filters                        |
| `lore triggers [threshold]`                                      | Show error types recurring >= threshold times (default: 3) |

## Error Types

`UserDeny`, `HardDeny`, `NonZeroExit`, `Timeout`, `ToolError`, `LogicError`

## Data Format

Failures are stored in `data/failures.jsonl` (append-only JSONL):

```json
{
  "id": "fail-a1b2c3d4",
  "timestamp": "2026-01-15T10:30:00Z",
  "error_type": "NonZeroExit",
  "error_message": "prettier crashed on large table",
  "tool": "Bash",
  "mission": "mission-abc",
  "step": 3
}
```

Optional fields (`tool`, `mission`, `step`) are omitted when empty.

## Key Functions (`lib/failures.sh`)

| Function            | Description                                        |
| ------------------- | -------------------------------------------------- |
| `failures_append`   | Log a failure (type, message, tool, mission, step) |
| `failures_list`     | List failures, filterable by type/mission          |
| `failures_triggers` | Error types recurring >= threshold times           |
| `failures_timeline` | Chronological failures for a mission               |
| `failures_stats`    | Count failures by error type                       |

## Dependencies

`bash`, `jq`
