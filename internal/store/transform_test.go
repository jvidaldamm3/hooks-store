package store

import (
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

	// Should contain leaf string values.
	if !strings.Contains(doc.DataFlat, "hello world") {
		t.Error("DataFlat should contain 'hello world'")
	}
	if !strings.Contains(doc.DataFlat, "value") {
		t.Error("DataFlat should contain nested value 'value'")
	}
	// Should NOT contain JSON keys.
	if strings.Contains(doc.DataFlat, "tool_name") {
		t.Error("DataFlat should not contain JSON key 'tool_name'")
	}
	if strings.Contains(doc.DataFlat, "nested") {
		t.Error("DataFlat should not contain JSON key 'nested'")
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

	if doc.DataFlat != "" {
		t.Errorf("DataFlat = %q, want empty string", doc.DataFlat)
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

	if doc.DataFlat != "" {
		t.Errorf("DataFlat = %q, want empty string", doc.DataFlat)
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

func TestHookEventToDocument_Prompt(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "UserPromptSubmit",
		Timestamp: time.Now(),
		Data: map[string]interface{}{
			"session_id": "sess-123",
			"prompt":     "explain the architecture",
		},
	}
	doc := HookEventToDocument(evt)
	if doc.Prompt != "explain the architecture" {
		t.Errorf("Prompt = %q, want %q", doc.Prompt, "explain the architecture")
	}
}

func TestHookEventToDocument_Prompt_Missing(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "PreToolUse",
		Timestamp: time.Now(),
		Data:      map[string]interface{}{"tool_name": "Read"},
	}
	doc := HookEventToDocument(evt)
	if doc.Prompt != "" {
		t.Errorf("Prompt should be empty when missing, got %q", doc.Prompt)
	}
}

func TestHookEventToDocument_FilePath(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "PreToolUse",
		Timestamp: time.Now(),
		Data: map[string]interface{}{
			"tool_name": "Read",
			"tool_input": map[string]interface{}{
				"file_path": "/home/user/project/main.go",
			},
		},
	}
	doc := HookEventToDocument(evt)
	if doc.FilePath != "/home/user/project/main.go" {
		t.Errorf("FilePath = %q, want %q", doc.FilePath, "/home/user/project/main.go")
	}
}

func TestHookEventToDocument_FilePath_NoToolInput(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "PreToolUse",
		Timestamp: time.Now(),
		Data: map[string]interface{}{
			"tool_name": "Bash",
		},
	}
	doc := HookEventToDocument(evt)
	if doc.FilePath != "" {
		t.Errorf("FilePath should be empty when tool_input is absent, got %q", doc.FilePath)
	}
}

func TestHookEventToDocument_ErrorMessage(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "PostToolUseFailure",
		Timestamp: time.Now(),
		Data: map[string]interface{}{
			"tool_name": "Write",
			"error":     "permission denied: /etc/passwd",
		},
	}
	doc := HookEventToDocument(evt)
	if doc.ErrorMessage != "permission denied: /etc/passwd" {
		t.Errorf("ErrorMessage = %q, want %q", doc.ErrorMessage, "permission denied: /etc/passwd")
	}
}

func TestHookEventToDocument_ProjectDir(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "SessionStart",
		Timestamp: time.Now(),
		Data: map[string]interface{}{
			"_monitor": map[string]interface{}{
				"has_claude_md": true,
				"project_dir":  "/home/user/my-project",
			},
		},
	}
	doc := HookEventToDocument(evt)
	if doc.ProjectDir != "/home/user/my-project" {
		t.Errorf("ProjectDir = %q, want %q", doc.ProjectDir, "/home/user/my-project")
	}
}

func TestHookEventToDocument_PermissionMode(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "PreToolUse",
		Timestamp: time.Now(),
		Data: map[string]interface{}{
			"tool_name":       "Write",
			"permission_mode": "bypassPermissions",
		},
	}
	doc := HookEventToDocument(evt)
	if doc.PermissionMode != "bypassPermissions" {
		t.Errorf("PermissionMode = %q, want %q", doc.PermissionMode, "bypassPermissions")
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
	if doc.ProjectDir != "/tmp/myproject" {
		t.Errorf("ProjectDir = %q, want /tmp/myproject", doc.ProjectDir)
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

func TestHookEventToDocument_Cwd(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "PreToolUse",
		Timestamp: time.Now(),
		Data: map[string]interface{}{
			"tool_name": "Read",
			"cwd":       "/home/user/project",
		},
	}
	doc := HookEventToDocument(evt)
	if doc.Cwd != "/home/user/project" {
		t.Errorf("Cwd = %q, want %q", doc.Cwd, "/home/user/project")
	}
}

func TestHookEventToDocument_Cwd_Missing(t *testing.T) {
	t.Parallel()

	evt := hookevt.HookEvent{
		HookType:  "PreToolUse",
		Timestamp: time.Now(),
		Data:      map[string]interface{}{"tool_name": "Read"},
	}
	doc := HookEventToDocument(evt)
	if doc.Cwd != "" {
		t.Errorf("Cwd should be empty when missing, got %q", doc.Cwd)
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

func TestDocumentToPromptDocument(t *testing.T) {
	t.Parallel()

	doc := Document{
		ID:             "test-uuid-123",
		HookType:       "UserPromptSubmit",
		Timestamp:      "2026-02-25T14:30:00.000Z",
		TimestampUnix:  1772029800,
		SessionID:      "sess-abc-123",
		Prompt:         "explain the architecture",
		Cwd:            "/home/user/project",
		ProjectDir:     "/home/user/project",
		PermissionMode: "default",
		HasClaudeMD:    true,
	}

	pdoc := DocumentToPromptDocument(doc)

	if pdoc.ID != doc.ID {
		t.Errorf("ID = %q, want %q", pdoc.ID, doc.ID)
	}
	if pdoc.HookType != doc.HookType {
		t.Errorf("HookType = %q, want %q", pdoc.HookType, doc.HookType)
	}
	if pdoc.Timestamp != doc.Timestamp {
		t.Errorf("Timestamp = %q, want %q", pdoc.Timestamp, doc.Timestamp)
	}
	if pdoc.TimestampUnix != doc.TimestampUnix {
		t.Errorf("TimestampUnix = %d, want %d", pdoc.TimestampUnix, doc.TimestampUnix)
	}
	if pdoc.SessionID != doc.SessionID {
		t.Errorf("SessionID = %q, want %q", pdoc.SessionID, doc.SessionID)
	}
	if pdoc.Prompt != doc.Prompt {
		t.Errorf("Prompt = %q, want %q", pdoc.Prompt, doc.Prompt)
	}
	if pdoc.PromptLength != len(doc.Prompt) {
		t.Errorf("PromptLength = %d, want %d", pdoc.PromptLength, len(doc.Prompt))
	}
	if pdoc.Cwd != doc.Cwd {
		t.Errorf("Cwd = %q, want %q", pdoc.Cwd, doc.Cwd)
	}
	if pdoc.ProjectDir != doc.ProjectDir {
		t.Errorf("ProjectDir = %q, want %q", pdoc.ProjectDir, doc.ProjectDir)
	}
	if pdoc.PermissionMode != doc.PermissionMode {
		t.Errorf("PermissionMode = %q, want %q", pdoc.PermissionMode, doc.PermissionMode)
	}
	if pdoc.HasClaudeMD != doc.HasClaudeMD {
		t.Errorf("HasClaudeMD = %v, want %v", pdoc.HasClaudeMD, doc.HasClaudeMD)
	}
}

func TestDocumentToPromptDocument_EmptyPrompt(t *testing.T) {
	t.Parallel()

	doc := Document{
		ID:       "test-uuid-456",
		HookType: "UserPromptSubmit",
		Prompt:   "",
	}

	pdoc := DocumentToPromptDocument(doc)

	if pdoc.PromptLength != 0 {
		t.Errorf("PromptLength = %d, want 0 for empty prompt", pdoc.PromptLength)
	}
	if pdoc.Prompt != "" {
		t.Errorf("Prompt = %q, want empty string", pdoc.Prompt)
	}
}

func TestExtractStringValues(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name     string
		data     map[string]interface{}
		contains []string // values that should be present
		excludes []string // values that should NOT be present
	}{
		{
			name:     "flat map",
			data:     map[string]interface{}{"a": "hello", "b": "world"},
			contains: []string{"hello", "world"},
			excludes: []string{"a", "b"},
		},
		{
			name:     "nested map",
			data:     map[string]interface{}{"outer": map[string]interface{}{"inner": "deep"}},
			contains: []string{"deep"},
			excludes: []string{"outer", "inner"},
		},
		{
			name:     "mixed types",
			data:     map[string]interface{}{"s": "text", "n": 42.0, "b": true},
			contains: []string{"text"},
			excludes: []string{"42", "true", "s", "n", "b"},
		},
		{
			name:     "array values",
			data:     map[string]interface{}{"list": []interface{}{"one", "two"}},
			contains: []string{"one", "two"},
			excludes: []string{"list"},
		},
		{
			name: "empty strings skipped",
			data: map[string]interface{}{"a": "", "b": "kept"},
			contains: []string{"kept"},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			result := extractStringValues(tc.data)
			for _, want := range tc.contains {
				if !strings.Contains(result, want) {
					t.Errorf("result %q should contain %q", result, want)
				}
			}
			for _, exclude := range tc.excludes {
				if strings.Contains(result, exclude) {
					t.Errorf("result %q should not contain %q", result, exclude)
				}
			}
		})
	}
}

func TestExtractStringValues_EmptyMap(t *testing.T) {
	t.Parallel()
	if got := extractStringValues(map[string]interface{}{}); got != "" {
		t.Errorf("extractStringValues(empty) = %q, want empty string", got)
	}
}

func TestExtractStringValues_NilMap(t *testing.T) {
	t.Parallel()
	if got := extractStringValues(nil); got != "" {
		t.Errorf("extractStringValues(nil) = %q, want empty string", got)
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
