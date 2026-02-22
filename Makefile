.PHONY: install sync-memory sync-entire sync-graph sync-all check-mcp build-mcp run-mcp check test

# Install lore CLI
install:
	@./scripts/install.sh $(ARGS)

# Sync Entire CLI checkpoints to Lore journal
sync-entire:
	@./scripts/entire-yeoman.sh

# Sync journal decisions to knowledge graph
sync-graph:
	@./graph/sync.sh

# Sync Lore shadows into Engram
sync-memory:
	@./lib/bridge.sh $(ARGS)

# Sync all sources
sync-all: sync-entire sync-graph sync-memory

# Check MCP server build freshness
check-mcp:
	@if [ mcp/src/index.ts -nt mcp/build/index.js ]; then \
		echo "MCP build is stale (src newer than build). Run: make build-mcp"; \
		exit 1; \
	else \
		echo "MCP build is up to date"; \
	fi

# Build MCP server
build-mcp:
	cd mcp && npm run build

# Run MCP server (stdio, for Claude Code plugin use)
run-mcp: build-mcp
	LORE_DIR=$(CURDIR) node mcp/build/index.js

# Run all tests
test:
	@echo "Running tests..."
	@bash tests/test-capture-api.sh
	@bash tests/test-goals.sh
	@bash tests/test-recall.sh
	@bash tests/test-concepts.sh
	@bash tests/verify-retrieval.sh
	@bash tests/test_inversion.sh
	@bash tests/test-cognitive-features.sh
	@bash tests/test-spec-layer.sh
	@bash tests/test-curated-resume.sh
	@bash tests/test-recall-router.sh
	@bash tests/test-promote.sh
	@bash tests/test-graph-edge-projection.sh

# Check all build freshness
check: check-mcp
