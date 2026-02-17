.PHONY: sync-entire sync-graph sync-all

# Sync Entire CLI checkpoints to Lore journal
sync-entire:
	@./scripts/entire-yeoman.sh

# Sync journal decisions to knowledge graph
sync-graph:
	@./graph/sync.sh

# Sync all external sources
sync-all: sync-entire sync-graph
