# hooks-store — MeiliSearch companion for Claude Hooks Monitor

**Requires: MeiliSearch running on :7700** (default; configurable via --meili-url / MEILI_URL).

Go module: `hooks-store`. Receives hook events via HTTP POST /ingest, transforms and indexes them into MeiliSearch for search and filtering.

## Build & Test

```bash
make build          # → bin/hooks-store
make test           # go test ./...
make run            # build + run
make send-test-hook # curl a test event
```

## Key Files
- cmd/hooks-store/main.go — Entry point, flag parsing, wiring
- internal/ingest/server.go — HTTP server, IngestEvent callback, validation
- internal/store/meili.go — MeiliSearch client, index setup
- internal/store/transform.go — HookEvent → Document conversion
- internal/tui/model.go — Bubble Tea dashboard (alt screen, live event stats)

## Configuration
- Flags: --port, --meili-url, --meili-key, --meili-index
- Env: HOOKS_STORE_PORT, MEILI_URL, MEILI_KEY, MEILI_INDEX
- Config file: hooks-store.conf (lowest priority)

## Architecture
```
POST /ingest → ingest.Server → store.HookEventToDocument → MeiliStore.Index
                    ↓ (callback)
              eventCh → tui.Model (alt screen dashboard with live counters)
```
