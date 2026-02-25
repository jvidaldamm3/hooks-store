package ingest

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"hooks-store/internal/hookevt"
	"hooks-store/internal/store"
)

// Compile-time check that mockStore implements store.EventStore.
var _ store.EventStore = (*mockStore)(nil)

// TestEndToEnd_WireFormat simulates the full pipeline: the monitor's HTTPSink
// marshals a HookEvent and POSTs it to the companion's /ingest endpoint.
// This verifies JSON wire format compatibility between the two programs.
func TestEndToEnd_WireFormat(t *testing.T) {
	t.Parallel()

	// Set up companion ingest server with a capturing store.
	ms := &mockStore{}
	srv := New(ms)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	// Simulate what the monitor's HTTPSink.Send() does:
	// json.Marshal(hookevt.HookEvent) → POST to endpoint.
	evt := hookevt.HookEvent{
		HookType:  "PreToolUse",
		Timestamp: time.Date(2026, 2, 25, 14, 30, 0, 0, time.UTC),
		Data: map[string]interface{}{
			"tool_name":  "Write",
			"session_id": "sess-abc-123",
			"input": map[string]interface{}{
				"file_path": "/home/user/test.go",
				"content":   "package main",
			},
		},
	}

	body, err := json.Marshal(evt)
	if err != nil {
		t.Fatalf("marshal event: %v", err)
	}

	resp, err := http.Post(ts.URL+"/ingest", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("POST /ingest: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("status = %d, want 202", resp.StatusCode)
	}

	// Verify the document was correctly transformed and indexed.
	ms.mu.Lock()
	defer ms.mu.Unlock()

	if len(ms.docs) != 1 {
		t.Fatalf("expected 1 doc, got %d", len(ms.docs))
	}

	doc := ms.docs[0]
	if doc.HookType != "PreToolUse" {
		t.Errorf("HookType = %q, want PreToolUse", doc.HookType)
	}
	if doc.ToolName != "Write" {
		t.Errorf("ToolName = %q, want Write", doc.ToolName)
	}
	if doc.SessionID != "sess-abc-123" {
		t.Errorf("SessionID = %q, want sess-abc-123", doc.SessionID)
	}
	if doc.Timestamp != "2026-02-25T14:30:00.000Z" {
		t.Errorf("Timestamp = %q, want 2026-02-25T14:30:00.000Z", doc.Timestamp)
	}
	if doc.TimestampUnix != 1772029800 {
		t.Errorf("TimestampUnix = %d, want 1772029800", doc.TimestampUnix)
	}
	if doc.ID == "" {
		t.Error("ID should not be empty")
	}
	// DataFlat should contain nested field values for full-text search.
	if doc.DataFlat == "" {
		t.Error("DataFlat should not be empty")
	}
	// Verify nested data survived the marshal→unmarshal→transform pipeline.
	input, ok := doc.Data["input"].(map[string]interface{})
	if !ok {
		t.Fatal("Data.input should be a nested map")
	}
	if input["file_path"] != "/home/user/test.go" {
		t.Errorf("Data.input.file_path = %v, want /home/user/test.go", input["file_path"])
	}
}

// TestEndToEnd_AllHookTypes sends all 15 canonical hook types through the
// pipeline and verifies each is accepted and transformed correctly.
func TestEndToEnd_AllHookTypes(t *testing.T) {
	t.Parallel()

	allTypes := []string{
		"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
		"PostToolUseFailure", "PermissionRequest", "Notification",
		"SubagentStart", "SubagentStop", "Stop", "TeammateIdle",
		"TaskCompleted", "ConfigChange", "PreCompact", "SessionEnd",
	}

	ms := &mockStore{}
	srv := New(ms)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	for _, ht := range allTypes {
		evt := hookevt.HookEvent{
			HookType:  ht,
			Timestamp: time.Now(),
			Data:      map[string]interface{}{"type": ht},
		}
		body, _ := json.Marshal(evt)

		resp, err := http.Post(ts.URL+"/ingest", "application/json", bytes.NewReader(body))
		if err != nil {
			t.Fatalf("POST for %s: %v", ht, err)
		}
		resp.Body.Close()

		if resp.StatusCode != http.StatusAccepted {
			t.Errorf("%s: status = %d, want 202", ht, resp.StatusCode)
		}
	}

	ms.mu.Lock()
	defer ms.mu.Unlock()

	if len(ms.docs) != len(allTypes) {
		t.Fatalf("expected %d docs, got %d", len(allTypes), len(ms.docs))
	}

	// Verify each doc has a unique ID and correct hook type.
	seen := make(map[string]struct{})
	for i, doc := range ms.docs {
		if doc.HookType != allTypes[i] {
			t.Errorf("doc[%d].HookType = %q, want %q", i, doc.HookType, allTypes[i])
		}
		if _, exists := seen[doc.ID]; exists {
			t.Errorf("duplicate ID: %s", doc.ID)
		}
		seen[doc.ID] = struct{}{}
	}
}

// TestEndToEnd_CompanionDown verifies the HTTPSink behavior when the companion
// is unreachable — the error is returned but the monitor (caller) discards it.
func TestEndToEnd_CompanionDown(t *testing.T) {
	t.Parallel()

	// Start and immediately close the server to get an unreachable URL.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	url := srv.URL
	srv.Close()

	evt := hookevt.HookEvent{
		HookType:  "PreToolUse",
		Timestamp: time.Now(),
		Data:      map[string]interface{}{},
	}
	body, _ := json.Marshal(evt)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, url+"/ingest", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")

	_, err := http.DefaultClient.Do(req)
	if err == nil {
		t.Error("expected connection error when companion is down")
	}
	// This is the behavior the monitor relies on: error returned, silently discarded.
}

// TestEndToEnd_ConcurrentBurst sends a burst of events concurrently,
// simulating multiple monitor goroutines firing simultaneously.
func TestEndToEnd_ConcurrentBurst(t *testing.T) {
	t.Parallel()

	ms := &mockStore{}
	srv := New(ms)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	const n = 100
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			evt := hookevt.HookEvent{
				HookType:  "PreToolUse",
				Timestamp: time.Now(),
				Data:      map[string]interface{}{"i": float64(i)},
			}
			body, _ := json.Marshal(evt)
			resp, err := http.Post(ts.URL+"/ingest", "application/json", bytes.NewReader(body))
			if err != nil {
				t.Errorf("POST[%d]: %v", i, err)
				return
			}
			resp.Body.Close()
			if resp.StatusCode != http.StatusAccepted {
				t.Errorf("POST[%d]: status = %d, want 202", i, resp.StatusCode)
			}
		}(i)
	}
	wg.Wait()

	ms.mu.Lock()
	defer ms.mu.Unlock()
	if len(ms.docs) != n {
		t.Errorf("expected %d docs, got %d", n, len(ms.docs))
	}
}

