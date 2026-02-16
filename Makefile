.PHONY: sync-entire sync-all

# Sync Entire CLI checkpoints to Lore journal
sync-entire:
	@./scripts/entire-yeoman.sh

# Sync all external sources
sync-all: sync-entire
