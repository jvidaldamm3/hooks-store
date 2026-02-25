# hooks-store — MeiliSearch companion for Claude Hooks Monitor
# Usage: make help

ifeq ($(OS),Windows_NT)
  EXE := .exe
else
  EXE :=
endif

BINARY  := bin/hooks-store$(EXE)
GO      := $(shell which go 2>/dev/null || echo /usr/local/go/bin/go)
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -s -w -X main.version=$(VERSION)

.PHONY: help build run test clean \
        install-meili install-meili-service setup-meili-index \
        meili-search meili-stats meili-health \
        send-test-hook companion-health companion-stats

help: ## Show all targets with descriptions
	@echo ""
	@echo "  hooks-store — MeiliSearch Companion"
	@echo "  ────────────────────────────────────"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""

build: ## Build hooks-store binary
	@mkdir -p bin
	$(GO) build -ldflags="$(LDFLAGS)" -o $(BINARY) ./cmd/hooks-store
	@echo "Built $(BINARY)"

run: build ## Run companion (connects to MeiliSearch)
	./$(BINARY)

test: ## Run full test suite
	$(GO) test ./...

clean: ## Remove build artifacts
	rm -rf bin/
	@echo "Cleaned."

# ─── MeiliSearch management ───────────────────────────────────────────

install-meili: ## Install MeiliSearch binary to ~/.local/bin
	@./scripts/install-meili.sh

install-meili-service: ## Install MeiliSearch as user systemd service
	@./scripts/install-meili.sh --service

setup-meili-index: ## Configure MeiliSearch index for hook events (run once)
	@./scripts/setup-meili-index.sh

meili-health: ## Check MeiliSearch health
	@curl -sf http://localhost:7700/health | jq . 2>/dev/null || echo "MeiliSearch is not running"

meili-stats: ## Show MeiliSearch index statistics
	@curl -sf http://localhost:7700/indexes/hook-events/stats | jq .

meili-search: ## Search hook events (usage: make meili-search Q="Write")
	@curl -sf 'http://localhost:7700/indexes/hook-events/search' \
		-H 'Content-Type: application/json' \
		-d "{\"q\":\"$(Q)\",\"sort\":[\"timestamp_unix:desc\"],\"limit\":20}" | jq .

# ─── Companion management ────────────────────────────────────────────

COMPANION_URL ?= http://localhost:9800

send-test-hook: ## Send a test hook event to the companion
	@curl -s -X POST $(COMPANION_URL)/ingest \
		-H 'Content-Type: application/json' \
		-d '{"hook_type":"PreToolUse","timestamp":"'"$$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","data":{"tool_name":"TestTool","session_id":"test-session"}}' | jq .

companion-health: ## Check companion health
	@curl -sf $(COMPANION_URL)/health | jq . 2>/dev/null || echo "Companion is not running"

companion-stats: ## Show companion ingestion statistics
	@curl -sf $(COMPANION_URL)/stats | jq .
