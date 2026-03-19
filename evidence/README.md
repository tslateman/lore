# Evidence

Factual evidence with confidence tracking, grounding decisions and patterns in verifiable observations.

## Overview

The evidence store captures facts that support (or contest) decisions and patterns. Each record carries a confidence level that evolves over time: new evidence enters as "preliminary" and advances to "confirmed," or falls to "contested" or "superseded" as understanding changes. This gives agents a way to answer "What supports this?" before acting on a belief.

## Quick Start

```bash
# Capture evidence
lore capture "API latency p99 dropped from 800ms to 200ms after connection pooling" --evidence --source "council" --tags "performance,api" --provenance "grafana dashboard 2026-03-10"

# List all evidence
lore evidence list

# Filter by confidence
lore evidence list --confidence confirmed

# Get a single record
lore evidence get evi-a1b2c3d4

# View counts by confidence level
lore evidence stats
```

## CLI Commands

| Command                                                                                    | Description                      |
| ------------------------------------------------------------------------------------------ | -------------------------------- |
| `lore capture <text> --evidence [--confidence C] [--source S] [--tags T] [--provenance P]` | Append evidence                  |
| `lore evidence list [--confidence C]`                                                      | List evidence, optionally filter |
| `lore evidence get <id>`                                                                   | Retrieve single record by ID     |
| `lore evidence stats`                                                                      | Count by confidence level        |

## Data Format

Evidence is stored in `data/evidence.jsonl` (append-only JSONL):

```json
{
  "id": "evi-a1b2c3d4",
  "timestamp": "2026-03-10T14:20:00Z",
  "source": "council",
  "content": "API latency p99 dropped from 800ms to 200ms after connection pooling",
  "confidence": "preliminary",
  "tags": ["performance", "api"],
  "cited_by": [],
  "provenance": "grafana dashboard 2026-03-10"
}
```

Confidence transitions: `preliminary` -> `confirmed`, `contested`, or `superseded`. Updated records gain an `updated_at` field.

Updates append a new version of the record. On read, the latest version for each ID wins.

## Key Functions (`lib/evidence.sh`)

| Function                     | Description                                                  |
| ---------------------------- | ------------------------------------------------------------ |
| `evidence_append`            | Add evidence (content, source, tags, confidence, provenance) |
| `evidence_list`              | List evidence, optionally by confidence                      |
| `evidence_get`               | Retrieve single record by ID                                 |
| `evidence_update_confidence` | Append new version with updated confidence                   |
| `evidence_stats`             | Count evidence by confidence level                           |

## Dependencies

`bash`, `jq`
