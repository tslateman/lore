# Inbox

A staging area for raw observations that haven't yet been classified as decisions, patterns, or failures.

## Overview

The inbox captures unstructured observations during work sessions. Observations enter as "raw" and are later promoted to formal entries (via `lore remember` or `lore learn`) or discarded. This lets agents record things they notice without stopping to classify them.

## Quick Start

```bash
# Capture an observation
lore observe "Config reload takes 3s on large files" --source "neo" --tags "performance,config"

# List raw observations
lore inbox

# Filter by status
lore inbox --status promoted
```

## CLI Commands

| Command                                          | Description              |
| ------------------------------------------------ | ------------------------ |
| `lore observe <text> [--source S] [--tags]`      | Append a raw observation |
| `lore inbox [--status raw\|promoted\|discarded]` | List observations        |

## Data Format

Observations are stored in `data/observations.jsonl` (append-only JSONL):

```json
{
  "id": "obs-a1b2c3d4",
  "timestamp": "2026-01-15T10:30:00Z",
  "source": "manual",
  "content": "Config reload takes 3s on large files",
  "status": "raw",
  "tags": ["performance", "config"]
}
```

Status transitions: `raw` -> `promoted` or `discarded`. Promoted records gain `promoted_to` and `promoted_at` fields; discarded records gain `discard_reason` and `discarded_at`.

Updates append a new version of the record. On read, the latest version for each ID wins.

## Key Functions (`lib/inbox.sh`)

| Function        | Description                                   |
| --------------- | --------------------------------------------- |
| `inbox_append`  | Add a raw observation (content, source, tags) |
| `inbox_list`    | List observations, optionally by status       |
| `inbox_promote` | Mark observation as promoted                  |
| `inbox_discard` | Mark observation as discarded                 |
| `inbox_get`     | Retrieve single observation by ID             |
| `inbox_stats`   | Count observations by status                  |

## Dependencies

`bash`, `jq`
