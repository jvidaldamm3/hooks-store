# store — MeiliSearch storage layer for hook event documents

All files stable — prefer this summary over reading source files.

## store.go

```go
type Document struct {
    ID                string                 `json:"id"`
    HookType          string                 `json:"hook_type"`
    Timestamp         string                 `json:"timestamp"`
    TimestampUnix     int64                  `json:"timestamp_unix"`
    SessionID         string                 `json:"session_id,omitempty"`
    ToolName          string                 `json:"tool_name,omitempty"`
    HasClaudeMD       bool                   `json:"has_claude_md"`
    InputTokens       int64                  `json:"input_tokens,omitempty"`
    OutputTokens      int64                  `json:"output_tokens,omitempty"`
    CacheReadTokens   int64                  `json:"cache_read_tokens,omitempty"`
    CacheCreateTokens int64                  `json:"cache_create_tokens,omitempty"`
    CostUSD           float64                `json:"cost_usd,omitempty"`
    DataFlat          string                 `json:"data_flat"`
    Data              map[string]interface{} `json:"data"`
}

type EventStore interface {
    Index(ctx context.Context, doc Document) error
    Close() error
}
```

## meili.go

```go
type MeiliStore struct { /* unexported fields */ }
func NewMeiliStore(endpoint, apiKey, indexName string) (*MeiliStore, error)
func (s *MeiliStore) Index(ctx context.Context, doc Document) error
func (s *MeiliStore) Close() error
```

MeiliStore implements EventStore. NewMeiliStore verifies connectivity, creates the index, and configures searchable/filterable/sortable attributes. Thread-safe (SDK client is thread-safe).

Filterable: hook_type, session_id, tool_name, timestamp_unix, has_claude_md, cost_usd.
Sortable: timestamp_unix, cost_usd, input_tokens, output_tokens.

## transform.go

```go
func HookEventToDocument(evt hookevt.HookEvent) Document
```

Converts wire-format HookEvent to MeiliSearch Document. Generates UUID, extracts session_id/tool_name, has_claude_md (from _monitor metadata), and token/cost metrics (defensive multi-path extraction). Serializes Data to DataFlat for full-text search.

Helpers: extractString, extractBool, extractFloat64, extractNestedMap, extractTokenMetrics.

## transform_test.go

Tests: TestHookEventToDocument_BasicFields, _DataFlat, _MissingOptionalFields, _EmptyData, _NilData, _NonStringFieldValues, _UniqueIDs, _HasClaudeMD, _HasClaudeMD_Missing, _TokenMetrics_TopLevel, _TokenMetrics_NestedUsage, _TokenMetrics_StopHookData, _TokenMetrics_Missing, _TimestampUTC. All table-driven with t.Parallel().

Imports: `hookevt` (HookEvent type). External: `github.com/google/uuid`, `github.com/meilisearch/meilisearch-go`.
