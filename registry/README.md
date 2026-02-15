# Registry

Project metadata and context assembly for agent onboarding.

## Overview

The registry enriches `mani.yaml` project entries with role, contract, dependency, and cluster information from four YAML data files. Its primary purpose is assembling context bundles that give agents everything they need to start working on a project.

## Quick Start

```bash
# Show enriched project details
lore registry show flow

# List all projects
lore registry list

# Assemble context for agent onboarding
lore registry context flow

# Check registry consistency
lore registry validate
```

## CLI Commands

| Command                           | Description                                        |
| --------------------------------- | -------------------------------------------------- |
| `lore registry show <project>`    | Enriched details (path, cluster, deps, contracts)  |
| `lore registry list`              | List all projects from mani.yaml                   |
| `lore registry context <project>` | Markdown context bundle for agents                 |
| `lore registry validate`          | Check metadata/clusters/relationships against mani |

## Data Files

| File                      | Contents                                       |
| ------------------------- | ---------------------------------------------- |
| `data/metadata.yaml`      | Role, contracts (exposes/consumes), components |
| `data/clusters.yaml`      | Cluster definitions, pipeline choreography     |
| `data/relationships.yaml` | Cross-project dependencies (sole source)       |
| `data/contracts.yaml`     | Contract location and status tracking          |

The registry reads from these files and from `mani.yaml` (at `~/dev/mani.yaml`). It does not own `mani.yaml` -- that file is the workspace-level source of truth for project existence, paths, and tags.

## Key Functions (`lib/registry.sh`)

| Function            | Description                                   |
| ------------------- | --------------------------------------------- |
| `show_project`      | Render enriched project details               |
| `list_projects`     | List all projects with description and status |
| `get_context`       | Assemble markdown context bundle              |
| `validate_registry` | Check metadata/clusters/relationships vs mani |
| `project_exists`    | Check if project exists in mani.yaml          |
| `get_tag_value`     | Extract prefixed tag value from mani tags     |
| `yqj`               | Helper: yq to JSON, then jq query             |

## Dependencies

`bash`, `yq`, `jq`, `mani.yaml`
