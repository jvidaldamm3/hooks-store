package store

import "context"

// Document is the MeiliSearch-ready representation of a hook event.
// Fields are chosen for optimal search, filter, and sort operations.
type Document struct {
	ID            string                 `json:"id"`
	HookType      string                 `json:"hook_type"`
	Timestamp     string                 `json:"timestamp"`
	TimestampUnix int64                  `json:"timestamp_unix"`
	SessionID     string                 `json:"session_id,omitempty"`
	ToolName          string                 `json:"tool_name,omitempty"`
	HasClaudeMD       bool                   `json:"has_claude_md"`
	InputTokens       int64                  `json:"input_tokens,omitempty"`
	OutputTokens      int64                  `json:"output_tokens,omitempty"`
	CacheReadTokens   int64                  `json:"cache_read_tokens,omitempty"`
	CacheCreateTokens int64                  `json:"cache_create_tokens,omitempty"`
	CostUSD           float64                `json:"cost_usd,omitempty"`
	DataFlat          string                 `json:"data_flat"`
	Data          map[string]interface{} `json:"data"`
}

// EventStore is the storage port for persisting hook event documents.
// Implementations must be safe for concurrent use.
type EventStore interface {
	// Index persists a single document. Returns an error if the store
	// is unreachable or the operation fails.
	Index(ctx context.Context, doc Document) error

	// Close releases any resources held by the store.
	Close() error
}
