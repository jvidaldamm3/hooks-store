package store

import (
	"sort"
	"strings"

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

	// Extract prompt text (UserPromptSubmit events).
	if p, ok := extractString(evt.Data, "prompt"); ok {
		doc.Prompt = p
	}

	// Extract file_path from tool_input (Read/Edit/Write/Glob events).
	if ti, ok := extractNestedMap(evt.Data, "tool_input"); ok {
		if fp, ok := extractString(ti, "file_path"); ok {
			doc.FilePath = fp
		}
	}

	// Extract error message (PostToolUseFailure events).
	if em, ok := extractString(evt.Data, "error"); ok {
		doc.ErrorMessage = em
	}

	// Extract permission_mode.
	if pm, ok := extractString(evt.Data, "permission_mode"); ok {
		doc.PermissionMode = pm
	}

	// Extract working directory (present on all events).
	if cwd, ok := extractString(evt.Data, "cwd"); ok {
		doc.Cwd = cwd
	}

	// Extract CLAUDE.md flag from _monitor metadata (set by hook-client).
	if monitor, ok := extractNestedMap(evt.Data, "_monitor"); ok {
		if hasMD, ok := extractBool(monitor, "has_claude_md"); ok {
			doc.HasClaudeMD = hasMD
		}
		if pd, ok := extractString(monitor, "project_dir"); ok {
			doc.ProjectDir = pd
		}
	}

	// Extract token/cost metrics from the event data.
	extractTokenMetrics(&doc, evt.Data)

	// Extract leaf string values for full-text search.
	// MeiliSearch indexes string fields for search — nested maps are not traversed.
	// Using values-only extraction eliminates JSON key noise from search tokens.
	doc.DataFlat = extractStringValues(evt.Data)

	return doc
}

// DocumentToPromptDocument converts a Document to a PromptDocument for the
// dedicated prompts index. Only meaningful for UserPromptSubmit events.
func DocumentToPromptDocument(doc Document) PromptDocument {
	return PromptDocument{
		ID:             doc.ID,
		HookType:       doc.HookType,
		Timestamp:      doc.Timestamp,
		TimestampUnix:  doc.TimestampUnix,
		SessionID:      doc.SessionID,
		Prompt:         doc.Prompt,
		PromptLength:   len(doc.Prompt),
		Cwd:            doc.Cwd,
		ProjectDir:     doc.ProjectDir,
		PermissionMode: doc.PermissionMode,
		HasClaudeMD:    doc.HasClaudeMD,
	}
}

// extractStringValues recursively extracts string leaf values from a data map,
// skipping all keys and non-string values (numbers, bools, null).
// Returns a space-separated string suitable for full-text search indexing.
func extractStringValues(data map[string]interface{}) string {
	if data == nil {
		return ""
	}
	var values []string
	collectStringValues(data, &values)
	return strings.Join(values, " ")
}

// collectStringValues is the recursive helper for extractStringValues.
func collectStringValues(v interface{}, values *[]string) {
	switch val := v.(type) {
	case string:
		if val != "" {
			*values = append(*values, val)
		}
	case map[string]interface{}:
		keys := make([]string, 0, len(val))
		for k := range val {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			collectStringValues(val[k], values)
		}
	case []interface{}:
		for _, elem := range val {
			collectStringValues(elem, values)
		}
	// float64, bool, nil — skip (not useful for text search)
	}
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

// extractBool retrieves a boolean value from a JSON-unmarshaled map.
func extractBool(data map[string]interface{}, key string) (bool, bool) {
	v, ok := data[key]
	if !ok {
		return false, false
	}
	b, ok := v.(bool)
	return b, ok
}

// extractFloat64 retrieves a float64 value from a JSON-unmarshaled map.
// JSON numbers unmarshal to float64 by default in Go.
func extractFloat64(data map[string]interface{}, key string) (float64, bool) {
	v, ok := data[key]
	if !ok {
		return 0, false
	}
	f, ok := v.(float64)
	return f, ok
}

// extractNestedMap retrieves a nested map from a JSON-unmarshaled map.
func extractNestedMap(data map[string]interface{}, key string) (map[string]interface{}, bool) {
	v, ok := data[key]
	if !ok {
		return nil, false
	}
	m, ok := v.(map[string]interface{})
	return m, ok
}

// extractTokenMetrics populates token and cost fields from the event data.
// Claude Code places these at different nesting levels depending on hook type,
// so we check multiple known paths defensively. First non-zero value wins.
func extractTokenMetrics(doc *Document, data map[string]interface{}) {
	// Path 1: Top-level fields.
	if v, ok := extractFloat64(data, "input_tokens"); ok {
		doc.InputTokens = int64(v)
	}
	if v, ok := extractFloat64(data, "output_tokens"); ok {
		doc.OutputTokens = int64(v)
	}
	if v, ok := extractFloat64(data, "cache_read_input_tokens"); ok {
		doc.CacheReadTokens = int64(v)
	}
	if v, ok := extractFloat64(data, "cache_creation_input_tokens"); ok {
		doc.CacheCreateTokens = int64(v)
	}
	if v, ok := extractFloat64(data, "total_cost_usd"); ok {
		doc.CostUSD = v
	}

	// Path 2: Nested under "usage" map.
	if usage, ok := extractNestedMap(data, "usage"); ok {
		if doc.InputTokens == 0 {
			if v, ok := extractFloat64(usage, "input_tokens"); ok {
				doc.InputTokens = int64(v)
			}
		}
		if doc.OutputTokens == 0 {
			if v, ok := extractFloat64(usage, "output_tokens"); ok {
				doc.OutputTokens = int64(v)
			}
		}
		if doc.CacheReadTokens == 0 {
			if v, ok := extractFloat64(usage, "cache_read_input_tokens"); ok {
				doc.CacheReadTokens = int64(v)
			}
		}
		if doc.CacheCreateTokens == 0 {
			if v, ok := extractFloat64(usage, "cache_creation_input_tokens"); ok {
				doc.CacheCreateTokens = int64(v)
			}
		}
	}

	// Path 3: Nested under "stop_hook_data".
	if stopData, ok := extractNestedMap(data, "stop_hook_data"); ok {
		if doc.CostUSD == 0 {
			if v, ok := extractFloat64(stopData, "total_cost_usd"); ok {
				doc.CostUSD = v
			}
		}
		if usage, ok := extractNestedMap(stopData, "usage"); ok {
			if doc.InputTokens == 0 {
				if v, ok := extractFloat64(usage, "input_tokens"); ok {
					doc.InputTokens = int64(v)
				}
			}
			if doc.OutputTokens == 0 {
				if v, ok := extractFloat64(usage, "output_tokens"); ok {
					doc.OutputTokens = int64(v)
				}
			}
		}
	}
}
