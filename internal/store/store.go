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
	ToolName      string                 `json:"tool_name,omitempty"`
	DataFlat      string                 `json:"data_flat"`
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
