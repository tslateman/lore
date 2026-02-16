Status: Complete (consumed by api-architecture.md)

# Lore Research Document

Deep research for unified API design covering Lineage, Lore, and Council.

## 1. CLI Surface Area

### lore-cli.sh (v0.2.0)

Four commands, all in `scripts/lore-cli.sh` (983 lines):

| Command    | Signature                     | Description                                         |
| ---------- | ----------------------------- | --------------------------------------------------- |
| `show`     | `lore show <project> [-h]`    | Enriched project details from all registry files    |
| `context`  | `lore context <project> [-h]` | Markdown context bundle for agent onboarding        |
| `validate` | `lore validate [-h]`          | Delegates to `validate-registry.sh`                 |
| `sync`     | `lore sync [-h]`              | Warns if metadata.yaml references missing from mani |

**Deprecated commands** (redirected to mani): `list`, `add`, `query`, `status`.

**Global options**: `-h/--help`, `-v/--version`.

**Environment variables**:

| Variable      | Default               | Purpose                         |
| ------------- | --------------------- | ------------------------------- |
| `DEV_PATH`    | `~/dev`               | Root directory for all projects |
| `MANI_FILE`   | `$DEV_PATH/mani.yaml` | Override mani.yaml location     |
| `LINEAGE_DIR` | `$DEV_PATH/lineage`   | Lineage installation path       |

**Dependencies**: Go yq v4.52+, jq v1.7+, mani (optional, for `mani list` equivalents).

### validate-registry.sh (497 lines)

Seven validations, invoked standalone or via `lore validate`:

| #   | Validation              | Behavior on failure                                      |
| --- | ----------------------- | -------------------------------------------------------- |
| 1   | File existence          | FAIL (blocks remaining validations if mani.yaml missing) |
| 2   | Path validation         | WARN per inaccessible path                               |
| 3   | Metadata references     | FAIL per orphan in metadata.yaml                         |
| 4   | Cluster consistency     | FAIL per missing component or mismatched tag             |
| 5   | Relationship validation | FAIL per unknown dependency target                       |
| 6   | Tag schema              | FAIL per project missing type:/lang:/status:             |
| 7   | Contract locations      | FAIL per missing contract file                           |

**Exit codes**: 0 = all pass (warnings allowed), 1 = any failure.

**Side effect**: On successful validation, syncs relationships to Lineage graph via `lineage_sync_relationships()`.

### migrate-to-mani.sh (238 lines)

One-time migration script (historical). Converts old `registry/projects.yaml` to `mani.yaml` + `metadata.yaml`. Supports `--dry-run`.

### Helper pattern: yqj()

All scripts share the same bridge function:

```bash
yqj() {
    yq -o=json '.' "$2" 2>/dev/null | jq -r "$1"
}
```

Converts YAML to JSON via Go yq, then queries with jq. This is the only YAML access pattern in the codebase.

## 2. Registry Format and Schema

### Source of truth split

**mani.yaml** (at `$DEV_PATH/mani.yaml`, outside lore repo):

- Project existence, path, description, tags
- Tags encode type, language, status, cluster, and free-form metadata
- Managed by mani CLI

**metadata.yaml** (in `registry/`):

- Role, contracts (exposes/consumes), components, links
- Projects without metadata can be omitted
- Version: "1.0"

**clusters.yaml** (in `registry/`):

- Cluster definitions with components (path, role, order, description)
- Data flow declarations (from, to, type, contract)
- Principles per cluster
- Entry points
- Version: "1.0"

**relationships.yaml** (in `registry/`):

- `dependencies` -- direct project-to-project with type and reason
- `shared` -- what a project provides to others (type, reason)
- `integrations` -- optional connections with status (active/proposed)
- `pattern_sharing` -- patterns borrowed across projects
- Version: "1.0"

**contracts.yaml** (in `registry/`):

- Maps contract names to interface, location, and status
- Paths relative to `~/dev/`
- Version: "1.0"

### mani.yaml tag encoding

| Prefix     | Values                                                                     |
| ---------- | -------------------------------------------------------------------------- |
| `type:`    | orchestrator, library, application, service, tool, infrastructure, cluster |
| `lang:`    | rust, shell, go, typescript, python, markdown                              |
| `status:`  | active, wip, archived, deprecated, external                                |
| `cluster:` | orchestration, council, forge, cli                                         |
| (none)     | Free-form: agents, memory, cli, tui, etc.                                  |

### metadata.yaml schema

```yaml
version: "1.0"
metadata:
  <project-name>:
    role: <string> # Function within cluster
    contracts:
      exposes:
        - <contract-file> # Files this project provides
      consumes:
        - <contract-file> # Files this project depends on
    components:
      - <sub-project> # For clusters/orchestrators
    links:
      <key>: <url> # External URLs (docs, upstream)
```

Currently 15 projects have metadata entries: agent-of-empires, bach, cli, council, duet, entire, flow, forge, lineage, mirror, lore, neo, oracle, ralph (archived).

### clusters.yaml schema

```yaml
version: "1.0"
clusters:
  <cluster-name>:
    root: <path>
    description: <string>
    status: active
    components:
      <project>:
        path: <path>
        role: <string>
        order: <int> # Pipeline position
        description: <string>
    data_flow:
      - from: <project>
        to: <project>
        type: <string> # decisions, tasks, results, context, etc.
        contract: <file>
    principles:
      - <string>
    entry_points:
      primary: <path>
      components:
        - <path>
```

Four clusters defined: orchestration (7 components), council (2), cli (3), forge (3).

### relationships.yaml schema

```yaml
version: "1.0"
dependencies:
  <project>:
    depends_on:
      - project: <name>
        type: runtime | workflow
        reason: <string>

shared:
  <project>:
    provides_to:
      - project: <name>
        type: optional
        reason: <string>

integrations:
  <project>:
    integrates_with:
      - project: <name>
        type: optional
        reason: <string>
        status: active | proposed
        contract: <file> # Optional

pattern_sharing:
  - pattern: <name>
    source: <project>
    adopted_by:
      - <project>
    description: <string>
```

### contracts.yaml schema

```yaml
version: "1.0"
contracts:
  <contract-name>:
    interface: <string> # "Harness to Flow", "All to Lineage"
    location: <path> # Relative to ~/dev/
    status: defined | proposed | draft
```

Five contracts tracked: signal, task, container, lineage, entire_bridge.

## 3. Context System

### `lore context <project>` output structure

Produces plain markdown (no ANSI), suitable for agents and humans. Sections are skipped if empty:

1. **Header** -- Project name + description
2. **Basics** -- Path, type, language, status (from mani.yaml tags)
3. **Dependencies** -- Table: dependency, type, reason (from relationships.yaml)
4. **Depended On By** -- Reverse dependency table (computed from relationships.yaml)
5. **Cluster** -- Role, pipeline visualization, adjacent contracts, data flow, principles (from clusters.yaml + metadata.yaml)
6. **Contracts** -- Exposes/consumes (from metadata.yaml)
7. **Flow State** -- Goal, status, signal, milestone, phase progress, blockers (from `.flow/state.json` in project dir)
8. **Recent Handoffs** -- Extracted from `context/HANDOFF.md` by project name matching
9. **Recent Judgments** -- From `mirror list --project <name> --format json --limit 3` (if mirror CLI available)
10. **Lineage Context** -- Related decisions and relevant patterns (via lineage-client.sh)
11. **Entry Point** -- `~/dev/<path>/CLAUDE.md`

### Data sources per section

| Section        | Source file(s)                      | Read method                                  |
| -------------- | ----------------------------------- | -------------------------------------------- |
| Basics         | mani.yaml                           | yqj tag extraction                           |
| Dependencies   | relationships.yaml                  | yqj `.dependencies.<project>.depends_on[]`   |
| Depended On By | relationships.yaml                  | yqj reverse scan of all dependencies         |
| Cluster        | clusters.yaml + metadata.yaml       | yqj component sort + data flow filter        |
| Contracts      | metadata.yaml                       | yqj `.metadata.<project>.contracts`          |
| Flow State     | `$DEV_PATH/<path>/.flow/state.json` | jq direct read                               |
| Handoffs       | context/HANDOFF.md                  | awk section extraction by project name       |
| Judgments      | mirror CLI                          | `mirror list --project <name> --format json` |
| Lineage        | lineage-client.sh                   | `journal.sh list`, `patterns.sh suggest`     |
| Entry Point    | mani.yaml                           | Path construction                            |

### Context assembly flow

```
mani.yaml (basics, path) ─────────────┐
metadata.yaml (role, contracts) ──────┤
clusters.yaml (pipeline, data flow) ──┼── lore context <project> ── markdown
relationships.yaml (deps, reverse) ───┤
.flow/state.json (if exists) ─────────┤
context/HANDOFF.md (if matches) ──────┤
mirror CLI (if available) ────────────┤
lineage-client.sh (if available) ─────┘
```

## 4. Validation Pipeline

### Invocation paths

1. `./scripts/validate-registry.sh` -- direct
2. `./scripts/lore-cli.sh validate` -- delegates to above

### Validation sequence

```
check_dependencies (yq, jq)
    |
validate_files (5 files: mani, metadata, clusters, relationships, contracts)
    |  [FAIL blocks remaining if mani.yaml missing]
    |
validate_paths (every project path exists on filesystem)
    |
validate_metadata_refs (metadata.yaml projects exist in mani.yaml)
    |
validate_clusters (bidirectional: components exist in mani + tagged projects appear in clusters)
    |
validate_relationships (dependency targets exist; integration targets exist)
    |
validate_tag_schema (every project has type:, lang:, status: tags)
    |
validate_contracts (contract files exist at declared paths)
    |
[On 0 failures]: lineage_sync_relationships(relationships.yaml)
```

### Lineage sync on validation success

After all validations pass, `validate-registry.sh` sources `lib/lineage-client.sh` and calls `lineage_sync_relationships()`, which runs:

```bash
"$LINEAGE_DIR/lineage.sh" ingest lore relationships "$relationships_file"
```

This bulk-imports relationship data into Lineage's graph.

## 5. Relationship/Dependency Model

### Three relationship types

1. **Dependencies** (`dependencies`): Hard project-to-project. Types: `runtime`, `workflow`. Example: bach depends on flow (runtime, receives tasks via TASK_CONTRACT).

2. **Shared resources** (`shared`): What a project provides to others. Always type `optional`. Example: lineage provides to neo, oracle, council, lore, mirror.

3. **Integrations** (`integrations`): Optional connections with implementation status. Types: `optional`. Status: `active` or `proposed`. May reference a contract file.

### Dependency graph (from relationships.yaml)

```
oracle --> lore (runtime: reads registry)
oracle --> neo (runtime: delegates teams)
oracle --> lineage (runtime: records decisions)
neo --> agent-of-empires (runtime: tmux sessions)
neo --> lineage (runtime: team lifecycle)
lore --> lineage (runtime: syncs relationships)
council --> lineage (runtime: ADR decisions)
bach --> flow (runtime: receives tasks)
get-shit-done --> spec-trace (workflow: specs define prototypes)
coalesce --> get-shit-done (workflow: prototypes feed synthesis)
duet --> (none)
entire --> (none)
```

### Pattern sharing model

Six named patterns tracked:

| Pattern             | Source  | Adopted by                                      |
| ------------------- | ------- | ----------------------------------------------- |
| contract-interfaces | flow    | bach                                            |
| narrow-interfaces   | council | flow, bach, get-shit-done, coalesce             |
| claude-md-entry     | lore    | council, flow, bach, neo, duet, lineage, mirror |
| structured-memory   | lineage | mirror                                          |
| unified-memory      | lineage | oracle, neo, lore, council                      |
| spec-driven         | forge   | get-shit-done, spec-trace, coalesce             |

## 6. Contract Files

### Tracked contracts

| Name          | Interface         | Location                                   | Status   |
| ------------- | ----------------- | ------------------------------------------ | -------- |
| signal        | Harness to Flow   | `cli/flow/SIGNAL_CONTRACT.md`              | defined  |
| task          | Flow to Bach      | `cli/bach/TASK_CONTRACT.md`                | defined  |
| container     | Neo to aoe        | `neo/CONTAINER_CONTRACT.md`                | defined  |
| lineage       | All to Lineage    | `lineage/LINEAGE_CONTRACT.md`              | defined  |
| entire_bridge | Entire to Lineage | `lore/contracts/ENTIRE_BRIDGE_CONTRACT.md` | proposed |

### Entire Bridge Contract (proposed)

Defines how Entire session transcripts feed Lineage:

- Extract decisions from transcripts -> `journal/data/decisions.jsonl`
- Extract anti-patterns from repeated failures -> `patterns/data/patterns.yaml`
- Link decisions to commits -> `graph/data/graph.json`
- Create handoff snapshots -> `transfer/data/sessions/`

Trigger: PostCommit (async, non-blocking). Opt-in via `.entire/settings.local.json`. Fails silently.

### Contract pattern (from `patterns/conventions/contracts.md`)

- Markdown-based interface files at project boundaries
- Components declare exposes/consumes in metadata.yaml
- Components only know adjacent interfaces
- Human-readable, versioned

## 7. Pattern Sharing Mechanism

### How it works

`relationships.yaml` has a `pattern_sharing` section listing named patterns with source project and adopters. This is purely declarative metadata -- no runtime mechanism enforces or syncs patterns.

### Pattern library (in `patterns/`)

Two directories:

- `patterns/conventions/` -- documented patterns (currently: contracts.md)
- `patterns/templates/` -- reusable templates (currently: claude-md.md)

Cross-project patterns reference their source locations:

| Pattern          | Location                       | Description                         |
| ---------------- | ------------------------------ | ----------------------------------- |
| Loop pattern     | `council/mainstay/loop.md`     | Stateless loop, external state      |
| State pattern    | `council/mainstay/state.md`    | Centralized state, signal lifecycle |
| Worker pattern   | `council/mainstay/worker.md`   | Task envelopes, incapability        |
| Pipeline pattern | `council/mainstay/pipeline.md` | Adjacent-only coupling              |

### Planned but undocumented patterns

- Documentation conventions (CLAUDE.md anatomy)
- Config conventions (TOML for config, YAML for registries)

## 8. Lineage Integration

### lineage-client.sh (Lore's client)

Sources `lineage-client-base.sh` from Lineage, adds four Lore-specific functions:

| Function                         | When called                                | What it does                                       |
| -------------------------------- | ------------------------------------------ | -------------------------------------------------- |
| `lineage_sync_relationships()`   | After successful `lore validate`           | Runs `lineage.sh ingest lore relationships <file>` |
| `lineage_sync_pattern_sharing()` | (Available but not called in current code) | Runs `lineage.sh ingest lore patterns <file>`      |
| `lineage_record_project_added()` | (Available but not called in current code) | Records decision + adds project node to graph      |
| `lineage_enrich_context()`       | During `lore context <project>`            | Prints related decisions (journal) and patterns    |

### Integration hooks

1. **validate-registry.sh** (lines 481-487): After successful validation, syncs relationships to Lineage graph.

2. **lore-cli.sh context** (lines 766-774): `context_lineage()` sources lineage-client and calls `lineage_enrich_context()`, which outputs related decisions and relevant patterns.

### Base library functions used

From `lineage-client-base.sh`:

- `check_lineage()` -- verifies Lineage is available
- `lineage_record_decision()` -- writes to journal
- `lineage_add_node()` -- adds graph node

### Fail-silent principle

All lineage-client functions return 0 on failure. The `|| true` pattern is used throughout. If Lineage is unavailable, Lore operates normally without enrichment.

## 9. mani.yaml and Multi-Project Orchestration

### mani.yaml location and ownership

Lives at `$DEV_PATH/mani.yaml` (typically `~/dev/mani.yaml`). Outside the lore repo. This is the source of truth for project existence. Lore reads it but never writes to it.

### mani.yaml structure

```yaml
projects:
  <project-name>:
    path: <relative-to-DEV_PATH>
    desc: <one-line description>
    tags: [type:<t>, lang:<l>, status:<s>, cluster:<c>, <free-tags>...]
    url: <git-url> # Optional, for mani sync
```

24 projects registered. No tasks, no commands section (mani supports these but Lore doesn't use them).

### mani CLI usage (from CLAUDE.md)

```bash
mani list projects                          # all
mani list projects --tags type:orchestrator  # filter
mani list projects --tags cluster:council    # cluster
mani list projects --tags "lang:rust"        # language
mani exec --all git status -s               # cross-repo
```

### How Lore relates to mani

- **mani** handles: project listing, filtering, cross-repo commands, TUI
- **Lore** handles: context assembly, contract tracking, cluster choreography, relationship tracking, validation

The two tools share `mani.yaml` as the project existence layer. Lore's `sync` command checks if metadata.yaml references match mani.yaml. The `validate` command cross-references all registry files against mani.yaml.

## 10. Data Shapes Summary

### For unified API design, these are the queryable entities:

| Entity             | Source             | Primary key    | Query patterns              |
| ------------------ | ------------------ | -------------- | --------------------------- |
| Project            | mani.yaml          | project name   | By name, by tag, by cluster |
| Metadata           | metadata.yaml      | project name   | By project name             |
| Cluster            | clusters.yaml      | cluster name   | By name, list components    |
| Dependency         | relationships.yaml | source project | Forward deps, reverse deps  |
| Integration        | relationships.yaml | source project | By project, by status       |
| Pattern (shared)   | relationships.yaml | pattern name   | By source, by adopter       |
| Contract           | contracts.yaml     | contract name  | By name, by status          |
| Handoff            | context/HANDOFF.md | (unstructured) | By project name (awk grep)  |
| Flow state         | .flow/state.json   | (per project)  | By project path             |
| Judgment           | mirror CLI         | (external)     | By project name             |
| Decision (Lineage) | journal.sh         | (external)     | By project name             |
| Pattern (Lineage)  | patterns.sh        | (external)     | By project name             |

### Key observations for API design

1. **Five YAML files** form the core registry: mani.yaml, metadata.yaml, clusters.yaml, relationships.yaml, contracts.yaml. All queried via the `yqj()` pattern.

2. **Three external integrations**: Flow state (reads .flow/state.json), Mirror judgments (mirror CLI), Lineage decisions/patterns (lineage-client.sh). All optional, fail-silent.

3. **No write path in CLI** beyond sync/validate side effects. The `add` command was deprecated in favor of manual YAML editing + `mani sync`.

4. **Context assembly is the crown jewel** -- it aggregates 8 data sources into a single markdown document. A unified API should preserve this aggregation capability.

5. **Validation is the enforcement layer** -- the only place that asserts cross-file consistency. A unified API should expose validation as a first-class operation.

6. **Pattern sharing is metadata-only** -- no runtime mechanism. Worth considering whether a unified API should make pattern sharing queryable/actionable.

7. **Handoffs are unstructured markdown** -- parsed by awk with project-name matching. Converting to structured data would improve queryability.

8. **The `yqj()` helper is the universal data access pattern** -- YAML -> JSON -> jq. A unified API could internalize this as a proper query engine.

## 11. Architectural Principles

From SYSTEM.md and cluster definitions:

- **mani knows what exists; Lore knows why it matters**
- **Memory flows to Lineage; context flows from Lineage**
- **Operational state stays in each project** (Neo's agent JSON, Oracle's goal YAML)
- **Patterns learned are never lost**
- **Client libraries fail silently** if Lineage unavailable
- **Components only know adjacent interfaces** (narrow-interfaces pattern)
- **CLAUDE.md is the agent entry point** for each project
- **Lineage is the dynasty; everything else is the current reign**
- **Lore does NOT execute work** -- it provides context and metadata

## 12. Known Gaps and Open Questions

From CHECKLIST.md, SYSTEM.md, and considerations:

1. **Neo mission discovery** -- Oracle writes missions to `/neo/missions/active/` but Neo has no watch mechanism
2. **Mirror -> Lineage bridge** -- judgments never reach Lineage; both work independently
3. **Pattern suggestion loops** -- nothing feeds patterns back into active work automatically
4. **Forge integration** -- no contract connects Forge to orchestration pipeline
5. **Documentation conventions pattern** -- source material ready, not written
6. **Config conventions pattern** -- source material ready, not written
7. **Phase 5: Grow the Graph** -- hook graph writes into decisions, populate from registry, activate suggestion in oracle/neo
