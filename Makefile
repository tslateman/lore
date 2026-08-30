CHECKS = check-format check-lint check-prose check-links check-corpus check-standards

.PHONY: install sync-memory sync-graph sync-all test check $(CHECKS)

# Install lore CLI
install:
	@./scripts/install.sh $(ARGS)

# Sync journal decisions to knowledge graph
sync-graph:
	@./graph/sync.sh

# Sync Lore shadows into Engram
sync-memory:
	@./lib/bridge.sh $(ARGS)

# Sync all sources
sync-all: sync-graph sync-memory

# Run every test suite, then report which failed
test:
	@./scripts/run-tests.sh $(ARGS)

# prettier over tracked markdown
check-format:
	@./scripts/check-format.sh

# shellcheck over tracked shell scripts
check-lint:
	@./scripts/check-shell.sh

# House prose rules: no emdashes
check-prose:
	@./scripts/check-prose.sh

# Markdown links resolve on disk
check-links:
	@./scripts/check-links.sh

# Specs judged against the standards corpus
check-corpus:
	@./scripts/check-corpus.sh

# Standards corpus internal consistency
check-standards:
	@echo "Linting the standards corpus..."
	@bash lore.sh standards lint

# Run every gate, then report which failed
check:
	@fail=""; \
	for gate in $(CHECKS); do \
		echo ""; \
		echo "=============================================================="; \
		echo "  $$gate"; \
		echo "=============================================================="; \
		$(MAKE) --no-print-directory $$gate || fail="$$fail $$gate"; \
	done; \
	echo ""; \
	echo "=============================================================="; \
	if [ -n "$$fail" ]; then \
		echo "  check: FAILED --$$fail"; \
		echo "=============================================================="; \
		exit 1; \
	fi; \
	echo "  check: all gates passed"; \
	echo "=============================================================="
