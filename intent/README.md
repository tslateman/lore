# Intent

Goals and missions -- what we are trying to achieve and the steps to get there.

## Overview

Intent decomposes strategic goals into executable missions. Each goal defines success criteria; `mission generate` creates one mission per criterion. Goals are stored as individual YAML files, making them easy to edit directly.

Absorbed from Oracle's Telos layer into Lore.

## Quick Start

```bash
# Create a goal
lore goal create "Reduce API latency" --priority high --deadline 2026-03-01

# Edit the YAML to add success criteria, then generate missions
lore mission generate goal-1234567890-abcd1234

# List goals and missions
lore goal list --status active
lore mission list --goal goal-1234567890-abcd1234
```

## CLI Commands

| Command                                               | Description                           |
| ----------------------------------------------------- | ------------------------------------- |
| `lore goal create <name> [--priority P] [--deadline]` | Create a new goal                     |
| `lore goal list [--status S] [--priority P]`          | List goals with optional filters      |
| `lore goal show <goal-id>`                            | Show goal details and criteria        |
| `lore mission generate <goal-id>`                     | Create missions from success criteria |
| `lore mission list [--goal ID] [--status S]`          | List missions with optional filters   |

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

### Missions (`data/missions/<mission-id>.yaml`)

```yaml
id: mission-1234567890-abcd1234
name: "Reduce API latency - p95 latency under 200ms"
goal_id: goal-1234567890-abcd1234
status: pending # pending | assigned | in_progress | blocked | completed | failed
priority: high
work_items:
  - id: wi-1
    description: "p95 latency under 200ms"
    completed: false
addresses_criteria:
  - sc-1
```

## Key Functions (`lib/intent.sh`)

| Function         | Description                                    |
| ---------------- | ---------------------------------------------- |
| `create_goal`    | Create goal YAML with name, priority, deadline |
| `list_goals`     | List goals, filterable by status/priority      |
| `get_goal`       | Display goal details and success criteria      |
| `create_mission` | Generate missions from goal criteria           |
| `list_missions`  | List missions, filterable by goal/status       |

## Dependencies

`bash`, `yq`, `jq`
