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
