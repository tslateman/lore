.PHONY: install sync-memory sync-entire sync-graph sync-all check test

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
	@bash tests/test-cross-system-traversal.sh
	@bash tests/test-storage-tiers.sh
	@bash tests/test-validate.sh

# Check all build freshness
check:
