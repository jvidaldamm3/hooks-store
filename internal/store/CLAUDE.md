# store — MeiliSearch storage layer for hook event documents

All files stable — prefer this summary over reading source files.

## store.go

```go
type PromptDocument struct {
    ID             string `json:"id"`
    HookType       string `json:"hook_type"`
    Timestamp      string `json:"timestamp"`
    TimestampUnix  int64  `json:"timestamp_unix"`
    SessionID      string `json:"session_id,omitempty"`
    Prompt         string `json:"prompt"`
    PromptLength   int    `json:"prompt_length"`
    Cwd            string `json:"cwd,omitempty"`
    ProjectDir     string `json:"project_dir,omitempty"`
    PermissionMode string `json:"permission_mode,omitempty"`
    HasClaudeMD    bool   `json:"has_claude_md"`
}

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
    Prompt            string                 `json:"prompt,omitempty"`
    FilePath          string                 `json:"file_path,omitempty"`
    ErrorMessage      string                 `json:"error_message,omitempty"`
    ProjectDir        string                 `json:"project_dir,omitempty"`
    PermissionMode    string                 `json:"permission_mode,omitempty"`
    Cwd               string                 `json:"cwd,omitempty"`
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
type MeiliStore struct { /* unexported fields: client, index, indexPrompts */ }
func NewMeiliStore(endpoint, apiKey, indexName, promptsIndexName string) (*MeiliStore, error)
func (s *MeiliStore) Index(ctx context.Context, doc Document) error
func (s *MeiliStore) MigrateDocuments(ctx context.Context, batchSize int) (int, error)
func (s *MeiliStore) MigrateDataFlat(ctx context.Context, batchSize int) (int, error)
func (s *MeiliStore) MigratePrompts(ctx context.Context, batchSize int) (int, error)
func (s *MeiliStore) Close() error
```

MeiliStore implements EventStore. NewMeiliStore verifies connectivity, creates the main index and optionally a dedicated prompts index (if `promptsIndexName` is non-empty), configures searchable/filterable/sortable attributes, and waits for each settings task to complete. Thread-safe (SDK client is thread-safe).

**Main index (hook-events):**
Searchable: hook_type, tool_name, session_id, prompt, error_message, data_flat.
Filterable: hook_type, session_id, tool_name, timestamp_unix, has_claude_md, cost_usd, project_dir, permission_mode, file_path, cwd.
Sortable: timestamp_unix, cost_usd, input_tokens, output_tokens.

**Prompts index (hook-prompts):**
Searchable: prompt, session_id.
Filterable: session_id, timestamp_unix, project_dir, permission_mode, has_claude_md, cwd, prompt_length.
Sortable: timestamp_unix, prompt_length.

Both indexes: pagination maxTotalHits 10000, faceting maxValuesPerFacet 500.

Index() dual-writes UserPromptSubmit events to both indexes. Prompts write is fail-soft (logs to stderr).

MigrateDocuments backfills top-level fields on existing documents. MigrateDataFlat rewrites data_flat from JSON serialization to values-only format using extractStringValues. MigratePrompts scans the main index, filters UserPromptSubmit events client-side, and indexes PromptDocuments into the prompts index. Must run after MigrateDocuments.

Helpers: waitForSettingsTask, setupPromptsIndex, extractMigrationFields, extractPromptMigrationFields. MigrateDataFlat uses extractStringValues from transform.go.

## transform.go

```go
func HookEventToDocument(evt hookevt.HookEvent) Document
func DocumentToPromptDocument(doc Document) PromptDocument
```

HookEventToDocument converts wire-format HookEvent to MeiliSearch Document. Generates UUID, extracts session_id/tool_name, prompt, file_path (from tool_input), error_message, permission_mode, cwd, project_dir (from _monitor), has_claude_md (from _monitor metadata), and token/cost metrics (defensive multi-path extraction). Generates DataFlat via `extractStringValues()` — space-separated string of leaf values from the data map (values only, no JSON keys).

`extractStringValues(data)` recursively walks the data map and collects only string leaf values, skipping keys, numbers, booleans, and nulls. `collectStringValues(v, *values)` is its recursive helper.

DocumentToPromptDocument converts a Document to a lean PromptDocument for the prompts index. Computes PromptLength = len(Prompt) (byte count).

Helpers: extractString, extractBool, extractFloat64, extractNestedMap, extractTokenMetrics, extractStringValues, collectStringValues.

## transform_test.go

Tests: TestHookEventToDocument_BasicFields, _DataFlat, _MissingOptionalFields, _EmptyData, _NilData, _NonStringFieldValues, _UniqueIDs, _Prompt, _Prompt_Missing, _FilePath, _FilePath_NoToolInput, _ErrorMessage, _ProjectDir, _PermissionMode, _HasClaudeMD, _HasClaudeMD_Missing, _Cwd, _Cwd_Missing, _TokenMetrics_TopLevel, _TokenMetrics_NestedUsage, _TokenMetrics_StopHookData, _TokenMetrics_Missing, TestDocumentToPromptDocument, TestDocumentToPromptDocument_EmptyPrompt, _TimestampUTC. All with t.Parallel().

Imports: `hookevt` (HookEvent type). External: `github.com/google/uuid`, `github.com/meilisearch/meilisearch-go`.
