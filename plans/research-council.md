# Council Research Document

Comprehensive analysis of ~/dev/council for unified API design across Lineage, Lore, and Council.

## 1. Project Identity

Council is the advisory layer for cross-project decisions across the agent stack. It does NOT execute work. It advises, tracks initiatives, and maintains advisory frameworks. Six seats, each with a domain, a core question, and a directive.

**Key files**: `charter.md` (oaths and mandates), `CLAUDE.md` (agent entry point), `README.md` (index)

## 2. Seat Structure

### Six Seats

| Seat           | Directive            | Core Question                                             | Directory     |
| -------------- | -------------------- | --------------------------------------------------------- | ------------- |
| **Critic**     | Discipline of Doubt  | "What are we refusing to see?"                            | `critic/`     |
| **Mentor**     | Continuity of Wisdom | "Who will carry this forward?"                            | `mentor/`     |
| **Wayfinder**  | Logic of Discovery   | "What's the elegant path through?"                        | `wayfinder/`  |
| **Marshal**    | Security of Action   | "What's the risk, and am I ready?"                        | `marshal/`    |
| **Mainstay**   | Structural Anchor    | "What holds this together?"                               | `mainstay/`   |
| **Ambassador** | Voice Beyond         | "How does the world see us, and what do we need from it?" | `ambassador/` |

### When to Invoke

| Situation                              | Seat       |
| -------------------------------------- | ---------- |
| Choosing between approaches            | Critic     |
| New or unfamiliar territory            | Wayfinder  |
| Destructive or irreversible action     | Marshal    |
| Creating or modifying contracts        | Mainstay   |
| Writing docs or transferring knowledge | Mentor     |
| External-facing work (PRs, APIs)       | Ambassador |

### Productive Tensions

| Tension               | Dynamic                                                |
| --------------------- | ------------------------------------------------------ |
| Critic <-> Wayfinder  | Why vs. How -- doubt challenges momentum               |
| Marshal <-> Mainstay  | Advance vs. Hold -- expansion against stability        |
| Ambassador <-> Critic | External vs. Internal -- perception against truth      |
| Mentor <-> All        | Past to Future -- ensures the council outlasts members |

### Seat Content Inventory

#### Critic (4 files)

- `critique.md` -- Rapoport's Rules, Sagan's Baloney Detection Kit, Feynman's First Principle, cognitive bias field guide, debiasing techniques (pre-mortem, red team, devil's advocate), logical fallacies, Socratic toolkit, accountability (Taleb skin-in-the-game)
- `decisions.md` -- Decision spectrum (one-way/two-way/sliding doors), trade-off analysis, technical judgment development stages, delegation framework, lightweight ADR template, sunk cost/quitting, calibration
- `disagreement.md` -- Graham's Hierarchy (DH0-DH6), steel-manning, disagree-and-commit, disagreeing up/down/across, structural disagreement techniques, emotional de-escalation
- `career.md` -- IC career advancement, eight value concepts, senior vs staff comparison, visibility gap, brag document, sponsorship, promotion timing

#### Mentor (1 file)

- `lineage.md` -- Inverted career concepts for growing others, successor identification, knowledge transfer modes, sponsorship guidance, measuring mentorship success

#### Wayfinder (3 files)

- `exploration.md` -- Exploration mindset, spike development, constraint mapping, navigating ambiguity (Cynefin levels), learning new domains
- `adr-dev-directory-tooling.md` -- ADR: Adopted zoxide, rejected ghq/gita/mani, deferred fzf. Council input from all 6 seats.
- `adr-flow-sdk-migration.md` -- ADR: Hold SDK migration, build markdown first, add post-hoc validation. Kill criteria defined. Pre-mortem included.

#### Marshal (1 file + 3 subsystems)

- `risk.md` -- Risk vs. uncertainty, risk matrix, OODA loop, blast radius reduction, decision-making under pressure, team protection
- Plus `cred-broker/`, `git-proxy/`, `container-auth/` (see section 7)

#### Mainstay (5 files)

- `architecture.md` -- Architecture thinking, structural integrity signals, technical debt management, preventing drift, documentation guidance
- `loop.md` -- Loop pattern: stateless process reading shared state, exit conditions (completion/max-iterations/quit-file/stuck-detection), signal contract, layer separation (Ralph=loop, Flow=state, Bach=workers)
- `state.md` -- State file anatomy (`.flow/state.json`), schema (goal/scope/constraints/milestones/signal), milestone->phase->task hierarchy, signal lifecycle, dual representation (JSON + PLAN.md), delegation to workers
- `worker.md` -- Manager/worker split, task envelope schema, result envelope schema, worker specializations (researcher/coder/reviewer/tester), incapability signaling, layer visibility
- `pipeline.md` -- Linear stage topology, adjacent-only coupling, contracts as boundaries (SIGNAL_CONTRACT, TASK_CONTRACT), pipeline composition (Council pipeline nests inside orchestration pipeline)

#### Ambassador (2 files)

- `visibility.md` -- Making invisible work visible, glue work trap, brag document, framing language, 1:1->1:many->systemic scaling, gender dynamics
- `influence.md` -- Influence without authority, expertise/relationships/coalition-building/framing, political awareness, sponsor relationships, air cover

## 3. ADR Format and Lifecycle

### ADR Template

ADRs follow a lightweight format defined in `critic/decisions.md`:

```markdown
# [Decision Title]

## Status

Accepted | Superseded | Deprecated

## Context

What's the situation? What forces are at play?

## Decision

What are we doing?

## Consequences

What trade-offs are we accepting?
```

### Extended ADR Format (Wayfinder)

Wayfinder's ADRs add:

- **Options Evaluated** -- table with tool/approach, verdict (Adopted/Rejected/Deferred), rationale
- **Council Input** -- table with each seat's position
- **Kill Criteria** -- conditions for revisiting the decision
- **Pre-Mortem** -- imagined failure causes (Klein's protocol)
- **Trade-offs Named** -- explicit "We Chose X / Over Y / Because Z" table

### ADR Storage

ADRs live as markdown files in the relevant seat's directory:

- `wayfinder/adr-dev-directory-tooling.md` (status: Accepted)
- `wayfinder/adr-flow-sdk-migration.md` (status: Accepted, Hold)

No centralized ADR registry or numbering system. ADRs are indexed via the README.md table.

### ADR Lifecycle

1. **Proposed** -- draft written in seat directory
2. **Council Input** -- relevant seats provide positions
3. **Accepted/Rejected** -- status field updated
4. **Superseded/Deprecated** -- later decision replaces it

The pre-commit hook detects seat-level changes and records them to Lineage via `lineage_record_adr()`.

## 4. Initiative Tracking

Initiatives track cross-project work with an accountable seat.

### Active Initiatives

| Initiative         | Owner     | Status            | File                                |
| ------------------ | --------- | ----------------- | ----------------------------------- |
| Orchestration      | Mainstay  | Contracts defined | `initiatives/orchestration.md`      |
| Container Capture  | Mainstay  | Backlog           | `initiatives/container-capture.md`  |
| Morpheus Proposal  | Wayfinder | Proposal          | `initiatives/morpheus-proposal.md`  |
| Agent Optimization | Mainstay  | Proposal          | `initiatives/agent-optimization.md` |
| Feedback Loop      | Mentor    | Planning          | `initiatives/feedback-loop.md`      |

### Resolved Initiatives

| Initiative             | Owner    | Outcome          | File                                    |
| ---------------------- | -------- | ---------------- | --------------------------------------- |
| Agent Credentials      | Marshal  | Complete         | `initiatives/agent-credentials.md`      |
| Ecosystem Architecture | Mainstay | Migrated to Lore | `initiatives/ecosystem-architecture.md` |

### Initiative Format

Each initiative follows a standard structure:

- **Title and description**
- **Accountable seat**
- **Status** (with phase details)
- **Problem statement**
- **Architecture/design** (diagrams, schemas)
- **Implementation plan** (phased)
- **Acceptance criteria** (checkboxes)
- **Open questions**
- **Related initiatives** (cross-references)
- **History table** (date + action)

### Key Initiative Details

#### Orchestration (`initiatives/orchestration.md`)

Architecture: `Oracle -> Lore -> Neo -> aoe`, with `Ralph -> Flow -> Bach` underneath.
Contracts: Signal (Ralph<->Flow), Task (Flow->Bach), Container (Neo->aoe).
Superseded by `lore/SYSTEM.md` for the full ecosystem map.

#### Feedback Loop (`initiatives/feedback-loop.md`)

Closes the gap between Mirror (judgment capture) and Lineage (storage) and agent sessions (use).
Introduces the **Yeoman pattern**: a thin script reading from a known path, writing to a known path, manual invocation, idempotent, fail-silent.
Phase 1: Mirror->Lineage yeoman. Phase 2: Pattern injection into `lineage resume`.

#### Agent Optimization (`initiatives/agent-optimization.md`)

Findings from 4 parallel research streams: CLAUDE.md audit, contract analysis, council seat advisory, industry best practices.
Three-tier context injection model: Static (CLAUDE.md), Triggered (hooks), Phase-routed (Flow integration).
Quick wins already implemented: Council CLAUDE.md, fixed Oracle stale references, council core questions in shared prompt, reconciled commit conventions.

#### Agent Credentials (`initiatives/agent-credentials.md`)

Complete. Three subsystems built: cred-broker, git-proxy, container-auth.

## 5. Hooks System

### Pre-commit Hook (`hooks/pre-commit`)

Pipeline:

1. `prettier --write '**/*.md'` -- format all markdown
2. Re-stage formatted files
3. `markdownlint '**/*.md'` -- lint check (fail on error)
4. `vale *.md */*.md` -- prose check (fail on error)
5. `lychee --offline '**/*.md'` -- link check (fail on error)
6. **Lineage integration**: Sources `lib/lineage-client.sh`, scans staged files matching seat/initiative patterns, records to Lineage

Lineage recording logic:

```bash
git diff --cached --name-only | grep -E '^(critic|marshal|mainstay|ambassador|wayfinder|mentor|initiatives)/.+\.md$'
```

For each matched file:

- Initiative directory files -> `lineage_record_initiative()`
- Seat directory files -> `lineage_record_adr()` with status "accepted"

### Marshal PreToolUse Hook (`.claude/settings.local.json`)

A Claude Code PreToolUse hook that intercepts Bash commands:

```json
{
  "type": "command",
  "command": "jq -r '.tool_input.command // empty' | grep -qEf .claude/marshal-blocks && echo 'Marshal: destructive command blocked' >&2 && exit 2 || exit 0"
}
```

The `.claude/marshal-blocks` file contains regex patterns for destructive commands:

- `git push --force` / `git push -f`
- `git reset --hard`
- `rm -rf` (at line start, after `;`, `&&`, `|`)
- `git branch -D`
- `git clean -f`
- `git checkout .`

This is the Marshal seat's operational implementation -- blocking destructive commands before execution.

## 6. Decision Workflow and Governance

### Decision Types

| Type         | Reversibility | Response                           |
| ------------ | ------------- | ---------------------------------- |
| One-way door | Hard/costly   | Invoke Critic + Marshal, take time |
| Two-way door | Easy/cheap    | Decide fast, document rationale    |
| Sliding door | Window closes | Decide or lose opportunity         |

### Governance Process

1. **Identify the decision type** (one-way/two-way door)
2. **Invoke relevant seat(s)** based on situation
3. **Apply frameworks** from seat content (Rapoport's Rules, pre-mortem, etc.)
4. **Document as ADR** if one-way door or will be questioned later
5. **Record to Lineage** via pre-commit hook or manual `lineage_record_adr()`
6. **Track as initiative** if cross-project scope

### Council's Role

Council does NOT execute work. Its governance model:

- Seats provide advisory frameworks (cheat sheets, question lists)
- Initiatives track cross-project coordination
- Pre-commit hooks automate recording
- Marshal hooks enforce safety at runtime
- ADRs capture reasoning for future reference

## 7. Container Auth and Cred-Broker Subsystems

Three subsystems implement the Marshal seat's credential security initiative.

### Cred-Broker (`cred-broker/`)

**Purpose**: Manage scoped, time-limited tokens for repository access.

**CLI** (`broker.sh`):

- `issue <repo> <scope> [ttl] [--branch <branch>]` -- issue scoped token
- `validate <token>` -- check validity
- `revoke <token>` -- immediately revoke
- `list [--filter active|revoked|expired]` -- list tokens
- `audit [--limit N] [--action ACTION]` -- view audit log
- `cleanup` -- remove expired tokens

**Scopes**: read, read-only, write, read-write, admin

**Data storage**: `data/tokens.json` (token database), `data/audit.log` (JSONL audit trail)

**Policy**: `config/policy.yaml` -- max TTL per scope, allowed repos, branch restrictions

**Libraries**:

- `lib/tokens.sh` -- token CRUD operations
- `lib/audit.sh` -- JSONL audit logging
- `lib/policy.sh` -- policy enforcement (issue policy checks)

**Lineage integration**: Sources `lineage-client.sh`, records token issue/deny events as security decisions.

### Git Proxy (`git-proxy/`)

**Purpose**: Intercept git commands, validate tokens, enforce policy, inject credentials.

**CLI** (`proxy.sh`):

```bash
./proxy.sh [--token TOKEN] git <command> [args...]
```

**Pipeline**: Validate token -> Parse command -> Check policy -> Inject credentials -> Execute -> Log

**Libraries**:

- `lib/intercept.sh` -- parse git command, extract repo/operation/branch, determine required scope
- `lib/policy.sh` -- branch protection, repo allowlist, token scope validation, rate limiting
- `lib/inject.sh` -- credential injection (env vars, credential store, git helper, system keychain), temporary GIT_ASKPASS

**Config**: `config/branches.yaml` -- protected branches (main, master, release/\*, production), per-repo overrides, agent-specific overrides

**Exit codes**: 0=success, 1=error, 2=policy violation, 3=auth failure, 4=credential lookup failure

**Lineage integration**: Records auth failures, policy violations, and successes as security decisions.

### Container Auth (`container-auth/`)

**Purpose**: Bridge credential broker to Neo/aoe agent containers.

**Bootstrap** (`bootstrap.sh`):

1. Validate environment (AGENT_ID, MISSION_ID required)
2. Request scoped token from broker (Unix socket or HTTP)
3. Configure git to use proxy
4. Apply network policies (if CAP_NET_ADMIN)
5. Execute agent's main process

**Contract** (`contracts/CONTAINER_AUTH_CONTRACT.md` v1.0.0):

- Token request format: `POST /v1/token/request` with agent_id, mission_id, scope
- Token response: token, expires_at, scope, proxy_url, restrictions
- Error codes: invalid_agent, scope_denied, rate_limited, token_expired, token_revoked
- Security: tokens in `/run/secrets/agent-token` mode 0600, network isolation via iptables

**Neo Integration** (`contracts/neo-integration.yaml`):

- Credential scope definitions by role: reader, contributor, lead, admin
- Mission-based access: development, review, hotfix, documentation
- Role mappings: oracle=reader, developer=contributor, reviewer=reader, deployer=lead
- Container environment template with AGENT_ID, MISSION_ID, CREDENTIAL_SCOPE
- Network config: proxy_only egress

**Libraries**:

- `lib/git-config.sh` -- configure_git_proxy, configure_git_safe_directories, block_direct_git_auth
- `lib/network.sh` -- apply_network_policy, apply_strict_policy, apply_permissive_policy

## 8. Testing Structure

### Test Suites (`tests/`)

Three test files, all bash-based with shared assertion helpers.

#### test-marshal-hook.sh

Tests the Marshal PreToolUse hook by piping synthetic JSON through the grep pipeline.

- Force push patterns (4 blocked, 2 allowed)
- Hard reset (2 blocked, 2 allowed)
- rm -rf (5 blocked, 1 allowed)
- Branch delete (2 blocked, 2 allowed)
- git clean (3 blocked, 1 allowed)
- git checkout . (1 blocked, 2 allowed)
- Safe commands / false positives (9 allowed)
- Commit message prose (1 known false positive documented)

#### test-orchestration.sh

Cross-repo contract conformance tests. Validates schema alignment across Ralph, Flow, and Bach without invoking Claude.

- Signal contract: exists, 8 actions, state.json validity, 5 statuses
- Flow commands: existence, signal documentation
- Task contract: exists with envelope fields, 4 worker templates, 4 result statuses
- Ralph dispatch: FLOW_PROMPT.md maps all actions, exit conditions implemented
- Cross-repo alignment: signal actions across contract/prompt/integration, worker names in contract match templates
- Repos: `~/dev/cli/ralph`, `~/dev/cli/flow`, `~/dev/cli/bach` (skips gracefully when missing)

#### test-integration.sh

End-to-end broker->proxy flow without real git remotes.

- Issue read token, validate, attempt write (denied), issue write token, push (allowed), revoke, verify revoked fails, audit log populated
- Sources cred-broker and git-proxy libraries directly
- Uses temp directory for isolated test data

### Additional Test Scripts

- `cred-broker/test-broker.sh`
- `git-proxy/test-proxy.sh`
- `container-auth/test-container.sh` (supports `--mock` mode)

### Makefile Test Target

```
make test  # runs all 6 test suites in sequence
make check # format + lint + prose + links
```

## 9. lib/ Directory

### lineage-client.sh

Council's Lineage integration. Sources `lineage-client-base.sh` from `$LINEAGE_DIR/lib/`.

Three domain-specific functions:

```bash
lineage_record_adr(title, status, rationale)
  # -> lineage_record_decision "ADR: $title" --tags "council,adr,$status" --type "architecture"

lineage_record_principle(name, description)
  # -> lineage_learn_pattern "$name" --context "$description" --category "architecture"

lineage_record_initiative(name, description)
  # -> lineage_add_node concept "$name" --data '{"kind":"initiative","source":"council",...}'
```

All functions fail silently if Lineage is unavailable (returns 0).

**Used by**: pre-commit hook, broker.sh, proxy.sh, bootstrap.sh

## 10. Charter (`charter.md`)

Full governance charter defining:

- Six seat table (seat, directive, domain)
- Individual seat sections with:
  - Directive name
  - Mandate (behavioral description)
  - Oath (first-person commitment)
- Productive tensions table (4 tension pairs)
- When to invoke table (6 situations)
- Core questions (6 questions, one per seat)

The charter is the constitutional document. Seat content files operationalize the oaths into frameworks and cheat sheets.

## 11. Data Shapes for API Design

### Data Council Produces

| Data Type        | Shape                  | Storage        | Write Method             |
| ---------------- | ---------------------- | -------------- | ------------------------ |
| ADR              | Markdown file          | Seat dirs      | Manual + pre-commit hook |
| Initiative       | Markdown file          | initiatives/   | Manual + pre-commit hook |
| Seat advisory    | Markdown file          | Seat dirs      | Manual                   |
| Security events  | Lineage decisions      | Via lineage    | broker.sh, proxy.sh      |
| Blocked commands | Marshal regex patterns | marshal-blocks | Manual                   |

### Data Council Reads

| Source  | What                | How                        |
| ------- | ------------------- | -------------------------- |
| Lineage | Decisions, patterns | Via lineage-client-base.sh |
| Git     | Staged file changes | git diff --cached          |
| Broker  | Token state         | broker.sh validate/list    |

### Entities for Unified API

1. **Seats** -- 6 fixed seats with name, directive, core question, mandate, oath, content files
2. **ADRs** -- title, status (proposed/accepted/superseded/deprecated), context, decision, consequences, council input, options evaluated
3. **Initiatives** -- name, accountable seat, status, problem, design, acceptance criteria, history
4. **Security tokens** -- id, repo, scope, branch, issued_at, expires_at, revoked
5. **Audit events** -- timestamp, action, token_id, repo, actor, result, details
6. **Marshal blocks** -- regex patterns for destructive command detection

## 12. Conventions and Configuration

### Tooling

- **Formatter**: prettier (markdown)
- **Linter**: markdownlint
- **Prose checker**: vale (Google, write-good, proselint styles)
- **Link checker**: lychee (offline mode)
- **Config**: `.vale.ini`, `.prettierrc`, `.markdownlint.json`

### Cross-Project Conventions

- CLAUDE.md is the agent entry point in each project
- No emdashes in documentation
- TOML for config, YAML for registries
- Conventional commits with Strunk's body
- `set -euo pipefail` in shell scripts

### Git Hooks Setup

```bash
make setup  # symlinks hooks/pre-commit to .git/hooks/pre-commit, runs vale sync
```

## 13. Integration Points with Other Projects

| Project  | Integration                                                                                                                           |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| Lineage  | lineage-client.sh (record ADRs, principles, initiatives). Pre-commit hook writes seat changes. Broker/proxy write security decisions. |
| Lore     | Ecosystem architecture migrated to lore/SYSTEM.md. Lore owns project registry.                                                        |
| Neo      | Container auth contract. Neo integration YAML (role->scope mappings). Container watcher design.                                       |
| aoe      | Container bootstrap. Network isolation. Proxy credential injection.                                                                   |
| Oracle   | Orchestration pipeline entry. Agent optimization references.                                                                          |
| Ralph    | Orchestration tests validate contract alignment. Loop pattern documented.                                                             |
| Flow     | State pattern documented. Signal contract tested.                                                                                     |
| Bach     | Worker pattern documented. Task contract tested.                                                                                      |
| Mirror   | Feedback loop initiative bridges Mirror judgments to Lineage.                                                                         |
| Coalesce | Critic-owned prototype analysis tool (referenced in decisions.md).                                                                    |

## 14. API Design Implications

### What a Unified API Must Expose from Council

1. **Seat metadata** -- names, directives, core questions, content index
2. **ADR CRUD** -- list, read, create (with council input), update status
3. **Initiative CRUD** -- list, read, create, update status/history
4. **Security token management** -- issue, validate, revoke, list, audit
5. **Marshal block patterns** -- read, update
6. **Advisory query** -- "given this situation, which seat applies?"
7. **Governance state** -- which initiatives are active, who owns what

### Council Has No Structured Data Store

Unlike Lineage (JSONL, JSON) and Lore (YAML registry), Council stores everything as markdown files and shell scripts. A unified API would need to:

- Parse markdown frontmatter or headers for ADR metadata
- Index initiative status from markdown content
- Expose seat content as structured advisory
- Wrap cred-broker CLI as a proper API

### Key Architectural Consideration

Council's advisory content is large (critique.md alone is 221 lines). The agent-optimization initiative already identified the three-tier injection model: load seat metadata statically, inject seat frameworks via hooks, and route by phase. A unified API should respect this principle -- serve metadata by default, full content on request.
