# Contributing to Lore

Explicit context management for multi-agent systems.

## Setup

```bash
# Requirements: bash 4.0+, jq, yq, sqlite3, python3, perl
brew install jq yq  # macOS; python3 and perl ship with the system

# yq must be mikefarah's Go implementation, not the Python package.
# Both number themselves v4.x, so read the URL in the output.
yq --version   # yq (https://github.com/mikefarah/yq/) version v4.x.x

# Verify
lore --help
```

## Runtime Dependencies

`bash`, `jq`, `yq`, and `sqlite3` carry most of the CLI. Two more are load-bearing:

| Tool      | Used by                                                             | Required for                              |
| --------- | ------------------------------------------------------------------- | ----------------------------------------- |
| `python3` | `lib/search-index.sh`, `lib/recall-router.sh`, `scripts/hooks/*.sh` | Graph traversal, rerank, handoff hooks    |
| `perl`    | `lib/librarian.sh`, `lib/rerank.sh`                                 | `lore librarian`; rerank timeout fallback |

`yq` means mikefarah's Go implementation. Lore calls `yq -o=json`
(`lib/corpus.sh:85`), `yq -i` (`lore.sh:2077`), and `load()` (`lore.sh:2077`).
The Python package named `yq` is a jq wrapper and answers `yq -o=json` with
`jq: Unknown option -o`.

`perl` runs one expression, `alarm N; exec @ARGV`, to bound a `claude -p` call.
`lib/rerank.sh` already prefers `timeout(1)` and falls back to perl only when it
is absent; `lib/librarian.sh` calls perl unconditionally. Giving librarian the
same three-branch helper would drop perl to optional.

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
feat: Default bare capture to observation, unify CLI around single verb
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
- Don't add runtime dependencies beyond bash, jq, yq, sqlite3, python3, perl
