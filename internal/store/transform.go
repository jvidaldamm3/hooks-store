package store

import (
	"encoding/json"

	"hooks-store/internal/hookevt"

	"github.com/google/uuid"
)

// HookEventToDocument transforms a wire-format HookEvent into a
// MeiliSearch-ready Document with derived fields for search and filtering.
func HookEventToDocument(evt hookevt.HookEvent) Document {
	doc := Document{
		ID:            uuid.New().String(),
		HookType:      evt.HookType,
		Timestamp:     evt.Timestamp.UTC().Format("2006-01-02T15:04:05.000Z"),
		TimestampUnix: evt.Timestamp.Unix(),
		Data:          evt.Data,
	}

	// Extract top-level fields commonly used for filtering.
	if sid, ok := extractString(evt.Data, "session_id"); ok {
		doc.SessionID = sid
	}
	if tn, ok := extractString(evt.Data, "tool_name"); ok {
		doc.ToolName = tn
	}

	// Serialize the entire Data map to a flat JSON string for full-text search.
	// MeiliSearch indexes string fields for search — nested maps are not traversed.
	if b, err := json.Marshal(evt.Data); err == nil {
		doc.DataFlat = string(b)
	}

	return doc
}

// extractString retrieves a string value from a JSON-unmarshaled map.
// Returns ("", false) if the key is missing or the value is not a string.
func extractString(data map[string]interface{}, key string) (string, bool) {
	v, ok := data[key]
	if !ok {
		return "", false
	}
	s, ok := v.(string)
	return s, ok
}
