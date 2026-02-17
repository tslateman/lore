# Intent

Goals -- what we are trying to achieve.

## Overview

Intent defines strategic goals with success criteria. Goals are stored as
individual YAML files, making them easy to edit directly.

Absorbed from Oracle's Telos layer into Lore.

## Quick Start

```bash
# Create a goal
lore goal create "Reduce API latency" --priority high --deadline 2026-03-01

# Edit the YAML to add success criteria
vi intent/data/goals/goal-1234567890-abcd1234.yaml

# List goals
lore goal list --status active
```

## CLI Commands

| Command                                               | Description                      |
| ----------------------------------------------------- | -------------------------------- |
| `lore goal create <name> [--priority P] [--deadline]` | Create a new goal                |
| `lore goal list [--status S] [--priority P]`          | List goals with optional filters |
| `lore goal show <goal-id>`                            | Show goal details and criteria   |

## Data Format

### Goals (`data/goals/<goal-id>.yaml`)

```yaml
id: goal-1234567890-abcd1234
name: "Reduce API latency"
status: draft # draft | active | blocked | completed | cancelled
priority: high # critical | high | medium | low
deadline: "2026-03-01"
success_criteria:
  - id: sc-1
    description: "p95 latency under 200ms"
    type: manual
    met: false
depends_on: []
projects: []
tags: []
```

## Key Functions (`lib/intent.sh`)

| Function      | Description                                    |
| ------------- | ---------------------------------------------- |
| `create_goal` | Create goal YAML with name, priority, deadline |
| `list_goals`  | List goals, filterable by status/priority      |
| `get_goal`    | Display goal details and success criteria      |

## Dependencies

`bash`, `yq`, `jq`
