# Lore Documentation

Lore is the knowledge layer for the stack. It records decisions, patterns, and
failures so work compounds instead of repeating. See
[SYSTEM.md](https://github.com/tslateman/lore/blob/main/SYSTEM.md) for the
architecture.

## Guides

- [Tutorial](tutorial.md) - one complete session cycle: resume, capture, hand off
- [Engram integration](engram-integration.md) - how the durable record and working memory bridge
- [Troubleshooting](TROUBLE.md) - common issues and fixes

## Diagrams

- [Delegated Task Loop](delegated-task-loop.html) - how a lead seeds context, an
  agent returns an artifact, and corrections reach the written record

Diagram pages render from the `.workflow.json` beside them. Regenerate one with
`archify deliver workflow docs/<name>.workflow.json docs/<name>.html`.

Superseded notes live in [archive/](archive/).
