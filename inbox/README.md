# Inbox

A staging area for raw signals that haven't yet been classified as decisions, patterns, or failures.

## Overview

The inbox captures unstructured signals during work sessions. Signals enter as "raw" and are later promoted to formal entries (via `lore remember` or `lore learn`) or discarded. This lets agents record things they notice without stopping to classify them.

## Quick Start

```bash
# Capture a signal
lore observe "Config reload takes 3s on large files" --source "council" --tags "performance,config"

# List raw signals
lore inbox

# Filter by status
lore inbox --status promoted
```

## CLI Commands

| Command                                          | Description         |
| ------------------------------------------------ | ------------------- |
| `lore observe <text> [--source S] [--tags]`      | Append a raw signal |
| `lore inbox [--status raw\|promoted\|discarded]` | List signals        |

## Data Format

Signals are stored in `data/signals.jsonl` (append-only JSONL):

```json
{
  "id": "sig-a1b2c3d4",
  "timestamp": "2026-01-15T10:30:00Z",
  "source": "manual",
  "content": "Config reload takes 3s on large files",
  "status": "raw",
  "tags": ["performance", "config"]
}
```

Status transitions: `raw` -> `promoted` or `discarded`. Promoted records gain `promoted_to` and `promoted_at` fields; discarded records gain `discard_reason` and `discarded_at`.

Updates append a new version of the record. On read, the latest version for each ID wins.

Older records with `obs-` ids live in `data/observations.jsonl`, kept for backward compatibility; `lore curate` and `lore inbox` still read both files.

## Key Functions (`lib/inbox.sh`)

| Function         | Description                              |
| ---------------- | ---------------------------------------- |
| `signal_append`  | Add a raw signal (content, source, tags) |
| `signal_list`    | List signals, optionally by status       |
| `signal_promote` | Mark signal as promoted                  |
| `signal_discard` | Mark signal as discarded                 |
| `signal_get`     | Retrieve single signal by ID             |
| `signal_stats`   | Count signals by status                  |

## Dependencies

`bash`, `jq`
