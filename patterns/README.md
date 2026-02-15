# Pattern Learner

A memory system for AI agents that captures lessons learned, anti-patterns discovered, and reusable solutions.

Part of the **Lore** memory system.

## Overview

Pattern Learner helps AI agents:

- **Remember** lessons from past sessions
- **Avoid** repeating mistakes (anti-patterns)
- **Apply** proven solutions to new situations
- **Build** institutional knowledge over time

## Quick Start

```bash
# Initialize the patterns database
./patterns.sh init

# Capture a pattern you learned
./patterns.sh capture "Safe bash arithmetic" \
  --context "Incrementing variables in bash with set -e" \
  --solution "Use x=\$((x + 1)) instead of ((x++))" \
  --category bash \
  --example-bad "((count++))" \
  --example-good "count=\$((count + 1))"

# Record an anti-pattern to avoid
./patterns.sh warn "Baked-in credentials" \
  --symptom "Credentials stored in container image or code" \
  --risk "Credential exfiltration by compromised agent" \
  --fix "Use credential broker with scoped tokens" \
  --category security \
  --severity critical

# Check code for known patterns/anti-patterns
./patterns.sh check src/deploy.sh

# Get suggestions for a context
./patterns.sh suggest "writing bash script with counters"

# List all patterns
./patterns.sh list --type all
```

## Commands

### `capture <pattern>` - Record a Pattern

Record something you learned that should be repeated.

```bash
./patterns.sh capture "Pattern name" \
  --context "When this pattern applies" \
  --solution "How to implement it" \
  --problem "What problem it solves" \
  --category <category> \
  --origin "session-YYYY-MM-DD" \
  --example-bad "code to avoid" \
  --example-good "code to use"
```

**Categories**: bash, git, testing, architecture, naming, security, docker, api, performance, general

### `warn <anti-pattern>` - Record an Anti-Pattern

Record something to avoid.

```bash
./patterns.sh warn "Anti-pattern name" \
  --symptom "How to recognize it" \
  --risk "Why it's dangerous" \
  --fix "How to fix it" \
  --category <category> \
  --severity <low|medium|high|critical>
```

### `check <file|code>` - Check for Patterns

Analyze code or a file for known patterns and anti-patterns.

```bash
# Check a file
./patterns.sh check script.sh

# Check inline code
./patterns.sh check '((count++))'

# Verbose output with line numbers
./patterns.sh check script.sh --verbose
```

### `suggest <context>` - Get Suggestions

Get pattern suggestions relevant to your current work.

```bash
./patterns.sh suggest "writing bash script with counters"
./patterns.sh suggest "designing multi-agent system" --limit 3
```

### `list` - List Patterns

List all known patterns and anti-patterns.

```bash
./patterns.sh list                      # All patterns
./patterns.sh list --type patterns      # Only patterns
./patterns.sh list --type anti-patterns # Only anti-patterns
./patterns.sh list --category bash      # Filter by category
./patterns.sh list --format yaml        # Output as YAML
```

### `show <id>` - Show Pattern Details

Display full details for a specific pattern.

```bash
./patterns.sh show pat-000001-seed
```

### `validate <id>` - Validate a Pattern

Mark a pattern as validated (increases confidence score).

```bash
./patterns.sh validate pat-000001-seed
```

## File Structure

```
patterns/
├── patterns.sh          # Main CLI
├── lib/
│   ├── capture.sh       # Pattern capture and storage
│   ├── match.sh         # Pattern matching logic
│   └── suggest.sh       # Proactive suggestions
├── data/
│   └── patterns.yaml    # Pattern database
├── templates/
│   └── pattern.yaml     # Template for new patterns
└── README.md            # This file
```

## Pattern Database Schema

Patterns and anti-patterns are stored in `data/patterns.yaml`:

```yaml
patterns:
  - id: pat-xxx
    name: "Pattern name"
    context: "When this applies"
    problem: "What goes wrong without it"
    solution: "How to do it right"
    category: bash
    origin: "session-2026-02-09"
    confidence: 0.9 # 0.0 to 1.0
    validations: 5 # Times validated
    created_at: "2026-02-09T12:00:00Z"
    examples:
      - bad: "problematic code"
      - good: "correct code"

anti_patterns:
  - id: anti-xxx
    name: "Anti-pattern name"
    symptom: "How to recognize it"
    risk: "Why it's dangerous"
    fix: "How to fix it"
    category: security
    severity: critical # low, medium, high, critical
    created_at: "2026-02-09T12:00:00Z"
```

## Confidence Scoring

Patterns have a confidence score (0.0 to 1.0) that represents how well-validated they are:

- **0.5** - Newly captured pattern
- **0.7-0.8** - Validated a few times
- **0.9+** - Well-established pattern

Confidence increases each time you run `validate` on a pattern.

## Built-in Checks

The `check` command includes built-in detection for common issues:

1. **Unsafe bash arithmetic** - `((x++))` with `set -e`
2. **Hardcoded credentials** - Passwords/secrets in code
3. **Missing error traps** - `set -e` without cleanup traps
4. **Dangerous rm commands** - Unvalidated path deletion

## Integration with Lore

Pattern Learner is designed to work with other Lore components:

- **Sessions** - Patterns link back to originating sessions
- **Decisions** - Patterns can reference decision outcomes
- **Context** - Patterns can be shared across agent teams

## Examples

### The Bash Arithmetic Pattern

This is a real pattern learned during development:

```bash
# Problem: With set -e, this exits when count is 0
((count++))  # Returns exit code 1 when count is 0!

# Solution: Use arithmetic expansion
count=$((count + 1))  # Always returns exit code 0
```

### Security Anti-Pattern

```bash
# Anti-pattern: Baked-in credentials
docker build --build-arg API_KEY=secret123 .

# Fix: Use credential broker or runtime injection
docker build .
docker run -e API_KEY="$API_KEY" myimage
```

## Contributing

When you learn something new:

1. **Capture it** - Use `patterns.sh capture` or `warn`
2. **Categorize it** - Choose the right category
3. **Link origin** - Reference the session where you learned it
4. **Add examples** - Include bad and good code examples
5. **Validate over time** - Run `validate` when patterns prove useful
