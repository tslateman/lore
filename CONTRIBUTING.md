# Contributing to Lore

Explicit context management for multi-agent systems.

## Setup

```bash
# Requirements: bash 4.0+, jq, yq, sqlite3
brew install jq yq  # macOS

# Verify
lore --help
```

## Code Style

| Convention          | Rule                                            |
| ------------------- | ----------------------------------------------- |
| Shell safety        | `set -euo pipefail` in every script             |
| Variable expansions | Always quote (`"$var"`, not `$var`)             |
| Cleanup             | Use `trap` for temporary files and state        |
| Data format         | JSONL for append-only logs, YAML for registries |
| Configuration       | TOML for config, YAML for registries            |
| Prose               | Strunk's Elements of Style -- active, concrete  |
| Emdashes            | Never. Use double hyphens (`--`) instead        |

## Commits

Use conventional prefixes with Strunk's-style body:

```text
feat: Add semantic search to lore search
fix: Fix duplicate session ID on rapid handoff
docs: Document graph traversal depth parameter
```

Active voice. Omit needless words. No `Co-Authored-By` signatures.

## Data Conventions

- **Append-only**: Decisions and patterns are never deleted, only marked revised
  or abandoned
- **Tags**: Always include the source project name
- **Schemas**: Follow existing schemas in `journal/data/schema.json`
- **Paths**: Component data lives in `<component>/data/`

## Testing

```bash
make check       # format + lint + prose + links
make sync-all    # sync external sources
```

## Pull Requests

1. Branch from `main` with a descriptive name
2. Keep changes focused -- one concern per PR
3. Read CLAUDE.md and `LORE_CONTRACT.md` before modifying interfaces
4. Run `make check` before submitting
5. Integration via `lib/lore-client-base.sh` must remain fail-silent

## What Not to Do

- Don't duplicate data across components -- cross-link instead
- Don't break the append-only contract on JSONL files
- Don't add runtime dependencies beyond bash, jq, yq, sqlite3
