package store

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"hooks-store/internal/hookevt"
)

func TestHookEventToDocument_BasicFields(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "PreToolUse",
		Timestamp: time.Date(2026, 2, 25, 14, 30, 0, 0, time.UTC),
		Data: map[string]interface{}{
			"tool_name":  "Write",
			"session_id": "sess-abc-123",
		},
	}

	doc := HookEventToDocument(evt)

	if doc.ID == "" {
		t.Error("ID should not be empty")
	}
	// UUID v4 format: 8-4-4-4-12
	if len(doc.ID) != 36 {
		t.Errorf("ID length = %d, want 36 (UUID v4)", len(doc.ID))
	}
	if doc.HookType != "PreToolUse" {
		t.Errorf("HookType = %q, want PreToolUse", doc.HookType)
	}
	if doc.Timestamp != "2026-02-25T14:30:00.000Z" {
		t.Errorf("Timestamp = %q, want 2026-02-25T14:30:00.000Z", doc.Timestamp)
	}
	if doc.TimestampUnix != 1772029800 {
		t.Errorf("TimestampUnix = %d, want 1772029800", doc.TimestampUnix)
	}
	if doc.SessionID != "sess-abc-123" {
		t.Errorf("SessionID = %q, want sess-abc-123", doc.SessionID)
	}
	if doc.ToolName != "Write" {
		t.Errorf("ToolName = %q, want Write", doc.ToolName)
	}
}

func TestHookEventToDocument_DataFlat(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "PostToolUse",
		Timestamp: time.Now(),
		Data: map[string]interface{}{
			"tool_name": "Bash",
			"output":    "hello world",
			"nested": map[string]interface{}{
				"deep": "value",
			},
		},
	}

	doc := HookEventToDocument(evt)

	// DataFlat should be valid JSON.
	var parsed map[string]interface{}
	if err := json.Unmarshal([]byte(doc.DataFlat), &parsed); err != nil {
		t.Fatalf("DataFlat is not valid JSON: %v", err)
	}

	// Should contain nested values as searchable text.
	if !strings.Contains(doc.DataFlat, "hello world") {
		t.Error("DataFlat should contain 'hello world'")
	}
	if !strings.Contains(doc.DataFlat, "deep") {
		t.Error("DataFlat should contain nested key 'deep'")
	}
}

func TestHookEventToDocument_MissingOptionalFields(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "SessionStart",
		Timestamp: time.Now(),
		Data:      map[string]interface{}{"some_key": "some_value"},
	}

	doc := HookEventToDocument(evt)

	if doc.SessionID != "" {
		t.Errorf("SessionID should be empty when missing, got %q", doc.SessionID)
	}
	if doc.ToolName != "" {
		t.Errorf("ToolName should be empty when missing, got %q", doc.ToolName)
	}
}

func TestHookEventToDocument_EmptyData(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "Stop",
		Timestamp: time.Now(),
		Data:      map[string]interface{}{},
	}

	doc := HookEventToDocument(evt)

	if doc.DataFlat != "{}" {
		t.Errorf("DataFlat = %q, want {}", doc.DataFlat)
	}
	if doc.Data == nil {
		t.Error("Data should not be nil")
	}
}

func TestHookEventToDocument_NilData(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "Stop",
		Timestamp: time.Now(),
		Data:      nil,
	}

	doc := HookEventToDocument(evt)

	// json.Marshal(nil map) produces "null"
	if doc.DataFlat != "null" {
		t.Errorf("DataFlat = %q, want null", doc.DataFlat)
	}
}

func TestHookEventToDocument_NonStringFieldValues(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "PreToolUse",
		Timestamp: time.Now(),
		Data: map[string]interface{}{
			"tool_name":  42,       // not a string
			"session_id": true,     // not a string
		},
	}

	doc := HookEventToDocument(evt)

	// Non-string values should not be extracted.
	if doc.ToolName != "" {
		t.Errorf("ToolName should be empty for non-string value, got %q", doc.ToolName)
	}
	if doc.SessionID != "" {
		t.Errorf("SessionID should be empty for non-string value, got %q", doc.SessionID)
	}
}

func TestHookEventToDocument_UniqueIDs(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "PreToolUse",
		Timestamp: time.Now(),
		Data:      map[string]interface{}{},
	}

	ids := make(map[string]struct{}, 100)
	for i := 0; i < 100; i++ {
		doc := HookEventToDocument(evt)
		if _, exists := ids[doc.ID]; exists {
			t.Fatalf("duplicate ID generated: %s", doc.ID)
		}
		ids[doc.ID] = struct{}{}
	}
}

func TestHookEventToDocument_HasClaudeMD(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "SessionStart",
		Timestamp: time.Now(),
		Data: map[string]interface{}{
			"session_id": "sess-123",
			"_monitor": map[string]interface{}{
				"has_claude_md": true,
				"project_dir":  "/tmp/myproject",
			},
		},
	}
	doc := HookEventToDocument(evt)
	if !doc.HasClaudeMD {
		t.Error("HasClaudeMD should be true when _monitor.has_claude_md is true")
	}
}

func TestHookEventToDocument_HasClaudeMD_Missing(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "PreToolUse",
		Timestamp: time.Now(),
		Data:      map[string]interface{}{"tool_name": "Write"},
	}
	doc := HookEventToDocument(evt)
	if doc.HasClaudeMD {
		t.Error("HasClaudeMD should default to false when _monitor is absent")
	}
}

func TestHookEventToDocument_TokenMetrics_TopLevel(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "Stop",
		Timestamp: time.Now(),
		Data: map[string]interface{}{
			"input_tokens":                 float64(1500),
			"output_tokens":                float64(500),
			"cache_read_input_tokens":      float64(200),
			"cache_creation_input_tokens":  float64(100),
			"total_cost_usd":              0.0042,
		},
	}
	doc := HookEventToDocument(evt)

	if doc.InputTokens != 1500 {
		t.Errorf("InputTokens = %d, want 1500", doc.InputTokens)
	}
	if doc.OutputTokens != 500 {
		t.Errorf("OutputTokens = %d, want 500", doc.OutputTokens)
	}
	if doc.CacheReadTokens != 200 {
		t.Errorf("CacheReadTokens = %d, want 200", doc.CacheReadTokens)
	}
	if doc.CacheCreateTokens != 100 {
		t.Errorf("CacheCreateTokens = %d, want 100", doc.CacheCreateTokens)
	}
	if doc.CostUSD != 0.0042 {
		t.Errorf("CostUSD = %f, want 0.0042", doc.CostUSD)
	}
}

func TestHookEventToDocument_TokenMetrics_NestedUsage(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "Stop",
		Timestamp: time.Now(),
		Data: map[string]interface{}{
			"usage": map[string]interface{}{
				"input_tokens":  float64(2000),
				"output_tokens": float64(800),
			},
			"total_cost_usd": 0.01,
		},
	}
	doc := HookEventToDocument(evt)

	if doc.InputTokens != 2000 {
		t.Errorf("InputTokens = %d, want 2000", doc.InputTokens)
	}
	if doc.OutputTokens != 800 {
		t.Errorf("OutputTokens = %d, want 800", doc.OutputTokens)
	}
	if doc.CostUSD != 0.01 {
		t.Errorf("CostUSD = %f, want 0.01", doc.CostUSD)
	}
}

func TestHookEventToDocument_TokenMetrics_StopHookData(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "Stop",
		Timestamp: time.Now(),
		Data: map[string]interface{}{
			"stop_hook_data": map[string]interface{}{
				"total_cost_usd": 0.05,
				"usage": map[string]interface{}{
					"input_tokens":  float64(3000),
					"output_tokens": float64(1200),
				},
			},
		},
	}
	doc := HookEventToDocument(evt)

	if doc.InputTokens != 3000 {
		t.Errorf("InputTokens = %d, want 3000", doc.InputTokens)
	}
	if doc.OutputTokens != 1200 {
		t.Errorf("OutputTokens = %d, want 1200", doc.OutputTokens)
	}
	if doc.CostUSD != 0.05 {
		t.Errorf("CostUSD = %f, want 0.05", doc.CostUSD)
	}
}

func TestHookEventToDocument_TokenMetrics_Missing(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "PreToolUse",
		Timestamp: time.Now(),
		Data:      map[string]interface{}{"tool_name": "Write"},
	}
	doc := HookEventToDocument(evt)

	if doc.InputTokens != 0 || doc.OutputTokens != 0 || doc.CostUSD != 0 {
		t.Error("Token metrics should be zero when not present in data")
	}
}

func TestHookEventToDocument_TimestampUTC(t *testing.T) {
	t.Parallel()

	// Event with non-UTC timezone.
	loc := time.FixedZone("EST", -5*3600)
	evt := hookevt.HookEvent{
		HookType:  "SessionEnd",
		Timestamp: time.Date(2026, 2, 25, 10, 0, 0, 0, loc), // 10:00 EST = 15:00 UTC
		Data:      map[string]interface{}{},
	}

	doc := HookEventToDocument(evt)

	if doc.Timestamp != "2026-02-25T15:00:00.000Z" {
		t.Errorf("Timestamp = %q, want UTC conversion 2026-02-25T15:00:00.000Z", doc.Timestamp)
	}
}
