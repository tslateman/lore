.PHONY: install sync-entire sync-graph sync-all check-mcp build-mcp check test

# Install lore CLI
install:
	@./scripts/install.sh $(ARGS)

# Sync Entire CLI checkpoints to Lore journal
sync-entire:
	@./scripts/entire-yeoman.sh

# Sync journal decisions to knowledge graph
sync-graph:
	@./graph/sync.sh

# Sync all external sources
sync-all: sync-entire sync-graph

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

# Run all tests
test:
	@echo "Running tests..."
	@bash tests/test-capture-api.sh
	@bash tests/test-goals.sh
	@bash tests/verify-retrieval.sh
	@bash tests/test_inversion.sh
	@bash tests/test-cognitive-features.sh
	@bash tests/test-spec-layer.sh

# Check all build freshness
check: check-mcp
