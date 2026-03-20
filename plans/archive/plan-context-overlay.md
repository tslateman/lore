Status: Draft

# Plan: Context Overlay Generator

## Context

Spec-trace needs a lightweight way to prime agent tasks with relevant Lore
context. Overstory uses dynamic overlays. We can add a small, safe variant:
generate a compact, ranked context bundle from Lore search results, with clear
IDs and guidance to fetch full details when needed.

## What to Do

### 1. Add a `lore overlay` command

Create a new `cmd_overlay()` in `lore.sh` that assembles a compact context
bundle from FTS5 search results. It should:

- Accept `--query`, `--project`, `--limit` (default 10)
- Call `_search_fts5` with `--compact`
- Emit a short header and the compact index lines
- Include a footer telling the reader to use `lore context <id>` for details

### 2. Add JSON output for automation

Add `--json` to emit a structured payload:

```json
{
  "query": "...",
  "project": "...",
  "items": [
    {"type": "decision", "id": "dec-...", "title": "...", "score": 2.41}
  ]
}
```

This supports downstream tooling that wants to render overlays itself.

### 3. Wire help text

Add the command to `lore help` output so it is discoverable.

## What NOT to Do

- Do not add new storage or a new index.
- Do not change FTS5 scoring.
- Do not change existing `lore search` output.
- Do not add a new MCP tool. This is a CLI only change.

## Files to Modify

- `lore.sh` -- add `cmd_overlay()` and CLI parsing
- `docs/` (optional) -- add a short note in the CLI help docs

## Acceptance Criteria

- [ ] `lore overlay --query "auth" --project lore` prints a compact list
- [ ] `lore overlay --query "auth" --json` returns structured items
- [ ] `lore search` output is unchanged

## Testing

```bash
lore index
lore overlay --query "architecture" --project lore
lore overlay --query "architecture" --json
```
