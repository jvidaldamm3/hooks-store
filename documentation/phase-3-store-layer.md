# Phase 3: EventStore + MeiliStore

## Overview

This phase builds the storage layer for the hooks-store companion — the
`EventStore` interface, the `MeiliStore` implementation using the official
MeiliSearch Go SDK, and the `HookEvent → Document` transformation.

## Design Decisions

### Interface-based storage

The `EventStore` interface (`internal/store/store.go`) defines two methods:

```go
type EventStore interface {
    Index(ctx context.Context, doc Document) error
    Close() error
}
```

This mirrors the `EventSink` pattern from Phase 2 — the ingest server
(Phase 4) depends on the interface, not on MeiliSearch directly.

### Document schema

```go
type Document struct {
    ID            string                 `json:"id"`
    HookType      string                 `json:"hook_type"`
    Timestamp     string                 `json:"timestamp"`
    TimestampUnix int64                  `json:"timestamp_unix"`
    SessionID     string                 `json:"session_id,omitempty"`
    ToolName      string                 `json:"tool_name,omitempty"`
    DataFlat      string                 `json:"data_flat"`
    Data          map[string]interface{} `json:"data"`
}
```

**Why these fields:**

| Field | Purpose |
|-------|---------|
| `id` | UUID v4 — MeiliSearch primary key for deduplication |
| `hook_type` | Searchable + filterable (e.g., `hook_type = PreToolUse`) |
| `timestamp` | ISO 8601 string for human-readable display |
| `timestamp_unix` | Unix epoch for sortable chronological ordering |
| `session_id` | Extracted from `Data` for direct filtering without nested search |
| `tool_name` | Extracted from `Data` for direct filtering without nested search |
| `data_flat` | Entire `Data` map serialized as JSON string — full-text searchable |
| `data` | Original nested map preserved for structured access |

### HookEvent → Document transformation

`HookEventToDocument()` in `internal/store/transform.go`:

- **UUID v4** for `id` via `github.com/google/uuid`
- **UTC normalization**: timestamps are always stored in UTC regardless of source timezone
- **Millisecond precision**: `2006-01-02T15:04:05.000Z` format
- **Field extraction**: `session_id` and `tool_name` are pulled from the `Data` map
  only if present and of type `string` — non-string values are silently skipped
- **`data_flat`**: `json.Marshal(Data)` — gives MeiliSearch a flat string to index
  for full-text search of nested fields

### MeiliStore specifics

`internal/store/meili.go`:

- Uses `meilisearch.New()` which returns `ServiceManager` interface
- Health check on startup via `IsHealthy()` — fails fast if MeiliSearch is down
- Creates index idempotently with `CreateIndex()`
- Configures searchable, filterable, and sortable attributes on startup
- `Index()` uses `AddDocuments()` which is asynchronous — MeiliSearch enqueues
  the document and indexes it in the background
- `Close()` is a no-op — the SDK's HTTP client needs no explicit cleanup

### FilterableAttributes type quirk

The MeiliSearch Go SDK v0.36.1 has an inconsistency:
- `UpdateSearchableAttributes` takes `*[]string`
- `UpdateFilterableAttributes` takes `*[]interface{}`
- `UpdateSortableAttributes` takes `*[]string`

The code constructs `[]interface{}` for filterable attributes accordingly.

## Files Created

| File | Purpose |
|------|---------|
| `internal/store/store.go` | `EventStore` interface + `Document` struct |
| `internal/store/meili.go` | `MeiliStore` implementation using meilisearch-go SDK |
| `internal/store/transform.go` | `HookEventToDocument()` transformation |
| `internal/store/transform_test.go` | 8 tests covering all transformation paths |

## Dependencies Added

| Package | Version | Purpose |
|---------|---------|---------|
| `github.com/meilisearch/meilisearch-go` | v0.36.1 | Official MeiliSearch Go SDK |
| `github.com/google/uuid` | v1.6.0 | UUID v4 generation for document IDs |

## Test Results

- `internal/store`: 8/8 pass
  - `TestHookEventToDocument_BasicFields` — verifies all document fields
  - `TestHookEventToDocument_DataFlat` — verifies JSON serialization and nested content
  - `TestHookEventToDocument_MissingOptionalFields` — empty when keys absent
  - `TestHookEventToDocument_EmptyData` — handles `{}`
  - `TestHookEventToDocument_NilData` — handles nil map
  - `TestHookEventToDocument_NonStringFieldValues` — skips non-string extraction
  - `TestHookEventToDocument_UniqueIDs` — 100 events produce 100 unique UUIDs
  - `TestHookEventToDocument_TimestampUTC` — non-UTC timezone converted correctly

## Phase 2 Review Fixes Applied

During the Phase 2 review before starting Phase 3, three issues were found and fixed:

1. **Critical**: `WriteConfig()` destroyed `[sink]` section — added `extractNonHooksContent()`
   to preserve non-`[hooks]` sections when the TUI toggles a hook
2. **Minor**: `HTTPSink` response body not drained — added `io.Copy(io.Discard, resp.Body)`
   for keep-alive connection reuse
3. **Tests**: Added 7 new tests for `ReadSinkConfig` (5) and `WriteConfig` section preservation (2)
