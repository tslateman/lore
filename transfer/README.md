# Context Transfer

Enable succession between sessions - another agent can pick up exactly where the previous left off.

## Overview

Context Transfer is the key to "memory that compounds." It captures session state, creates explicit handoff notes, and enables seamless succession between agent sessions. No more starting from scratch.

## Quick Start

```bash
# Initialize a new session
./transfer.sh init

# Work on your task...

# Capture current state
./transfer.sh snapshot

# Add context as you work
./transfer.sh handoff "Finished API implementation, tests passing"

# When done, your successor can resume
./transfer.sh resume session-20240115-143022-a1b2c3d4
```

## Commands

### `init`

Start a new session. Creates a session file with a unique ID.

```bash
./transfer.sh init
# Output: Initialized new session: session-20240115-143022-a1b2c3d4
```

### `snapshot`

Capture current session state including:

- Git state (branch, uncommitted changes, recent commits)
- Active files (recently modified)
- Environment context
- Links to related journal entries and patterns

```bash
./transfer.sh snapshot
./transfer.sh snapshot "Completed authentication module"
```

### `resume <session-id>`

Load context from a previous session. Displays:

- What was accomplished (goals, decisions)
- Patterns learned (important lessons)
- Open threads needing attention
- Handoff notes with prioritized next steps
- Blockers and open questions

```bash
./transfer.sh resume session-20240115-143022-a1b2c3d4
./transfer.sh resume session-20240115-143022-a1b2c3d4 --json
```

### `handoff <message>`

Create explicit handoff notes for your successor.

```bash
./transfer.sh handoff "Finished API, need to add integration tests"
```

### `status`

Show what context is currently loaded.

```bash
./transfer.sh status
./transfer.sh status --json
```

### `diff <session1> <session2>`

Compare what changed between sessions.

```bash
./transfer.sh diff session-abc123 session-def456
```

### `list`

List all saved sessions.

```bash
./transfer.sh list
./transfer.sh list --json
```

### `compress <session-id>`

Compress a session to its essential elements while preserving:

- All goals addressed
- All decisions made
- All patterns learned (never compressed)
- All open threads
- Full handoff notes

```bash
./transfer.sh compress session-abc123
```

## Session Structure

Sessions are stored as JSON in `data/sessions/`:

```json
{
  "id": "session-20240115-143022-a1b2c3d4",
  "started_at": "2024-01-15T14:30:22Z",
  "ended_at": "2024-01-15T18:45:00Z",
  "summary": "Implemented user authentication with OAuth2",

  "goals_addressed": ["Add OAuth2 login flow", "Secure API endpoints"],

  "decisions_made": [
    "Use JWT for session tokens",
    "Store refresh tokens in httpOnly cookies"
  ],

  "patterns_learned": [
    "Always validate redirect URIs server-side",
    "Token refresh should happen before expiry, not after"
  ],

  "open_threads": [
    "Need to add rate limiting to auth endpoints",
    "Should implement token revocation"
  ],

  "handoff": {
    "next_steps": [
      "Add integration tests for OAuth flow",
      "Implement rate limiting",
      "Add token revocation endpoint"
    ],
    "blockers": ["Waiting on OAuth provider API key for staging"],
    "questions": [
      "Should we support multiple OAuth providers?",
      "What's the token expiry policy?"
    ]
  },

  "git_state": {
    "branch": "feature/oauth2-auth",
    "commits": [
      "abc1234 Add OAuth2 callback handler",
      "def5678 Implement JWT token generation"
    ],
    "uncommitted": ["src/auth/rate_limit.rs"]
  }
}
```

## Library Functions

### snapshot.sh

- `snapshot_session` - Capture current session state
- `capture_git_state` - Get git branch, commits, uncommitted files
- `capture_active_files` - Find recently modified files
- `add_goal`, `add_decision`, `add_thread`, `add_pattern` - Add items to session

### resume.sh

- `resume_session` - Load and display previous session context
- `get_session_brief` - Quick summary for fast loading
- `find_latest_session` - Find most recent session
- `resume_latest` - Resume the most recent session

### handoff.sh

- `create_handoff` - Create structured handoff notes
- `add_next_step`, `add_blocker`, `add_question` - Add handoff items
- `interactive_handoff` - Guided handoff creation
- `format_handoff` - Display formatted handoff notes

### compress.sh

- `compress_session` - Smart compression preserving essentials
- `extract_critical` - Extract only most critical information
- `one_line_summary` - Generate log-friendly summary
- `merge_sessions` - Consolidate multiple sessions
- `prune_old_sessions` - Archive old sessions while preserving patterns

## Philosophy

### What Gets Preserved

- **Goals** - What was attempted, even if incomplete
- **Decisions** - The choices made and why
- **Patterns** - Lessons learned (NEVER compressed or deleted)
- **Open Threads** - Unfinished work that needs attention
- **Handoff Notes** - Explicit succession guidance

### What Gets Compressed

- Detailed git history (kept: branch, recent commits)
- Full file lists (kept: most active files)
- Environment details (kept: working directory)

### The Golden Rule

**Patterns learned are never lost.** Even when pruning old sessions, patterns are extracted and archived. These represent hard-won lessons that compound over time.

## Integration with Lore

Context Transfer integrates with other Lore components:

- Links to relevant **Journal** entries from the session timeframe
- References **Patterns** that were active or learned
- Connects to **Goals** that were addressed

## Environment Variables

- `LORE_TRANSFER_ROOT` - Override the transfer component root directory
- `LORE_ROOT` - Root directory for all Lore components (for cross-linking)

## Examples

### Complete Workflow

```bash
# Start your session
./transfer.sh init

# Work on your task, periodically capturing state
./transfer.sh snapshot "Finished database migrations"

# Add learnings as you go
# (Or use the snapshot.sh library functions directly)

# When ready to hand off
./transfer.sh handoff "Database schema complete, API endpoints next"

# Your successor picks up seamlessly
./transfer.sh resume session-20240115-143022-a1b2c3d4
```

### Quick Context Check

```bash
# See what sessions exist
./transfer.sh list

# Check current session status
./transfer.sh status

# Compare progress between sessions
./transfer.sh diff session-old session-new
```

### Session Management

```bash
# Compress old sessions to save space
./transfer.sh compress session-abc123

# List all sessions as JSON for tooling
./transfer.sh list --json
```
