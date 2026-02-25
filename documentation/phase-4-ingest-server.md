# Phase 4: HTTP Ingest Server + Main Entry Point

## Overview

This phase builds the companion's HTTP server (`POST /ingest`) and wires
everything into a runnable binary with flags, environment variable support,
and graceful shutdown.

## HTTP API

### POST /ingest

Receives a hook event from the monitor's HTTPSink and persists it to MeiliSearch.

**Request:**
```json
{
  "hook_type": "PreToolUse",
  "timestamp": "2026-02-25T14:30:00Z",
  "data": {
    "tool_name": "Write",
    "session_id": "sess-abc-123"
  }
}
```

**Response (202 Accepted):**
```json
{
  "status": "accepted",
  "id": "550e8400-e29b-41d4-a716-446655440000"
}
```

**Error responses:**

| Status | Condition |
|--------|-----------|
| 400 | Empty body, invalid JSON, missing `hook_type`, excessive nesting |
| 405 | Non-POST method |
| 413 | Body exceeds 1 MiB |
| 503 | MeiliSearch indexing failed |

### GET /health

```json
{"status": "healthy", "time": "2026-02-25T14:30:00Z"}
```

### GET /stats

```json
{
  "ingested": 42,
  "errors": 2,
  "last_event": "2026-02-25T14:30:00Z"
}
```

## Design Decisions

### 202 Accepted (not 200 OK)

MeiliSearch indexes documents asynchronously — `AddDocuments` returns a task ID
and the actual indexing happens in the background. The 202 status accurately
communicates "accepted for processing" rather than "already stored".

### Body size limit

1 MiB (`maxBodyLen`), matching the monitor's `MaxBodyLen` constant. Both sides
enforce the same limit for consistency.

### JSON depth check

Same `checkJSONDepth` pattern used in the monitor's `HandleHook`. Prevents stack
exhaustion during `json.Unmarshal` on deeply nested payloads (limit: 100 levels).

### Validation

- `hook_type` must be non-empty — without it, the document is meaningless
- `timestamp` can be zero (the transformation still works, producing epoch 0)
- `data` can be null/empty (common for `SessionStart`, `Stop` events)

### Atomic counters for stats

`sync/atomic.Int64` for `ingested` and `errors` — lock-free, same pattern as
the monitor's `Dropped` counter. `sync/atomic.Value` for `lastEvent` timestamp.

### Configuration priority

Flags > environment variables > defaults:

| Flag | Env var | Default |
|------|---------|---------|
| `--port` | `HOOKS_STORE_PORT` | `9800` |
| `--meili-url` | `MEILI_URL` | `http://localhost:7700` |
| `--meili-key` | `MEILI_KEY` | (empty) |
| `--meili-index` | `MEILI_INDEX` | `hook-events` |

### Graceful shutdown

Same `sync.Once` + `context.WithCancel` pattern as the monitor:
- SIGINT/SIGTERM triggers graceful HTTP shutdown (5s drain timeout)
- `MeiliStore.Close()` called via deferred cleanup

### Localhost-only binding

`net.Listen("tcp", "127.0.0.1:"+port)` — the companion only accepts connections
from localhost, same as the monitor. No external exposure.

## Files Created/Modified

| File | Change |
|------|--------|
| `internal/ingest/server.go` | NEW — HTTP handlers: /ingest, /health, /stats |
| `internal/ingest/server_test.go` | NEW — 13 tests |
| `cmd/hooks-store/main.go` | REPLACED — full binary with flags, shutdown, banner |
| `hooks-store.conf` | NEW — default configuration file |

## Test Results

- `internal/ingest`: 13/13 pass
  - Success path, method not allowed, empty body, invalid JSON
  - Missing hook_type, body too large, store error, deep JSON
  - Health endpoint, stats (empty + after ingest)
  - Concurrent ingestion (50 goroutines)
  - Response body validity

- `internal/store`: 8/8 pass (unchanged)

## Phase 3 Review Fixes Applied

1. **Medium**: `MeiliStore.Index()` now uses `AddDocumentsWithContext(ctx, ...)`
   instead of `AddDocuments(...)` — respects context cancellation/timeouts
2. **Cosmetic**: Removed redundant `202` check in `setup-meili-index.sh`
