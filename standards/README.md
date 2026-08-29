# Standards

Normative clauses, addressable one at a time.

`decisions/` records what we chose. `intent/` records what we are going for.
Standards record what a spec must do, in RFC 2119 terms, so a reviewer can
cite `STD-0001.3` instead of "the API standard".

## Storage

| File                   | Holds                                            |
| ---------------------- | ------------------------------------------------ |
| `data/standards.jsonl` | Standard headers: id, title, `applies_to`, owner |
| `data/clauses.jsonl`   | One record per clause, the unit a finding cites  |

Both are append-only. Reads dedup by id and take the latest record.

## Commands

```bash
lore standards new "API versioning" --applies-to api,http --owner platform
# → STD-0001

lore standards add STD-0001 MUST "Every public endpoint carries a version prefix."
# → STD-0001.1

lore standards list --applies-to api --level MUST
lore standards get STD-0001.1
lore standards stats
```

Levels are `MUST`, `MUST_NOT`, `SHOULD`, `SHOULD_NOT`, `MAY`. Lowercase and
spaces normalize, so `"must not"` becomes `MUST_NOT`.

A clause inherits its standard's `applies_to` unless given its own. A clause
with an empty `applies_to` matches every spec.

## Revision

Supersede in one step. The replacement records what it supersedes, and the old
clause is marked `superseded` with a pointer to its replacement:

```bash
lore standards add STD-0001 MUST "Every public endpoint carries a version prefix in the path." \
  --supersedes STD-0001.1
```

Retire a clause with no replacement:

```bash
lore standards retire STD-0001.2
```

Superseded and retired clauses drop out of `list` and out of the review corpus.
They stay in the file.

## Lint

`lore standards lint` prints structural problems as JSON and exits 1 when it
finds any:

- a clause that supersedes a target that does not exist
- a clause that supersedes a target still marked active
- a clause with `superseded_by` set but a status other than `superseded`
- a clause marked superseded with no replacement
- a clause belonging to an unknown standard

Run it in CI. The corpus is only worth reviewing against while it holds.

## Severity

The reviewer maps level to severity. Standards carry the RFC 2119 reading:

| Level                  | Unacknowledged conflict |
| ---------------------- | ----------------------- |
| `MUST`, `MUST_NOT`     | critical                |
| `SHOULD`, `SHOULD_NOT` | major                   |
| `MAY`                  | no finding              |

`MAY` clauses never produce a finding, so `lore corpus` leaves them out of the
candidate set entirely.
