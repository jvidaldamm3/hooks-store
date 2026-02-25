package ingest

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"hooks-store/internal/store"
)

// mockStore is a test double for store.EventStore.
type mockStore struct {
	docs    []store.Document
	mu      sync.Mutex
	indexFn func(ctx context.Context, doc store.Document) error
}

func (m *mockStore) Index(ctx context.Context, doc store.Document) error {
	if m.indexFn != nil {
		return m.indexFn(ctx, doc)
	}
	m.mu.Lock()
	m.docs = append(m.docs, doc)
	m.mu.Unlock()
	return nil
}

func (m *mockStore) Close() error { return nil }

func TestHandleIngest_Success(t *testing.T) {
	t.Parallel()
	ms := &mockStore{}
	srv := New(ms)

	body := `{"hook_type":"PreToolUse","timestamp":"2026-02-25T14:30:00Z","data":{"tool_name":"Write"}}`
	req := httptest.NewRequest(http.MethodPost, "/ingest", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusAccepted {
		t.Fatalf("status = %d, want 202", w.Code)
	}

	var resp map[string]interface{}
	json.NewDecoder(w.Body).Decode(&resp)
	if resp["status"] != "accepted" {
		t.Errorf("response status = %v, want accepted", resp["status"])
	}
	if resp["id"] == nil || resp["id"] == "" {
		t.Error("response should contain a non-empty id")
	}

	ms.mu.Lock()
	defer ms.mu.Unlock()
	if len(ms.docs) != 1 {
		t.Fatalf("expected 1 indexed doc, got %d", len(ms.docs))
	}
	if ms.docs[0].HookType != "PreToolUse" {
		t.Errorf("doc HookType = %q, want PreToolUse", ms.docs[0].HookType)
	}
	if ms.docs[0].ToolName != "Write" {
		t.Errorf("doc ToolName = %q, want Write", ms.docs[0].ToolName)
	}
}

func TestHandleIngest_MethodNotAllowed(t *testing.T) {
	t.Parallel()
	srv := New(&mockStore{})

	req := httptest.NewRequest(http.MethodGet, "/ingest", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Errorf("status = %d, want 405", w.Code)
	}
}

func TestHandleIngest_EmptyBody(t *testing.T) {
	t.Parallel()
	srv := New(&mockStore{})

	req := httptest.NewRequest(http.MethodPost, "/ingest", strings.NewReader(""))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", w.Code)
	}
}

func TestHandleIngest_InvalidJSON(t *testing.T) {
	t.Parallel()
	srv := New(&mockStore{})

	req := httptest.NewRequest(http.MethodPost, "/ingest", strings.NewReader("{not json"))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", w.Code)
	}
}

func TestHandleIngest_MissingHookType(t *testing.T) {
	t.Parallel()
	srv := New(&mockStore{})

	body := `{"timestamp":"2026-02-25T14:30:00Z","data":{}}`
	req := httptest.NewRequest(http.MethodPost, "/ingest", strings.NewReader(body))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400", w.Code)
	}
}

func TestHandleIngest_BodyTooLarge(t *testing.T) {
	t.Parallel()
	srv := New(&mockStore{})

	// Create a body larger than 1 MiB.
	big := `{"hook_type":"Test","data":{"x":"` + strings.Repeat("A", maxBodyLen) + `"}}`
	req := httptest.NewRequest(http.MethodPost, "/ingest", strings.NewReader(big))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("status = %d, want 413", w.Code)
	}
}

func TestHandleIngest_StoreError(t *testing.T) {
	t.Parallel()
	ms := &mockStore{
		indexFn: func(ctx context.Context, doc store.Document) error {
			return fmt.Errorf("meili down")
		},
	}
	srv := New(ms)

	body := `{"hook_type":"PreToolUse","timestamp":"2026-02-25T14:30:00Z","data":{}}`
	req := httptest.NewRequest(http.MethodPost, "/ingest", strings.NewReader(body))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want 503", w.Code)
	}
}

func TestHandleIngest_DeepJSON(t *testing.T) {
	t.Parallel()
	srv := New(&mockStore{})

	// Build deeply nested JSON: {"a":{"a":{"a":... 150 levels deep.
	var b strings.Builder
	for i := 0; i < 150; i++ {
		b.WriteString(`{"a":`)
	}
	b.WriteString(`1`)
	for i := 0; i < 150; i++ {
		b.WriteString(`}`)
	}

	req := httptest.NewRequest(http.MethodPost, "/ingest", strings.NewReader(b.String()))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("status = %d, want 400 for deep JSON", w.Code)
	}
}

func TestHandleHealth(t *testing.T) {
	t.Parallel()
	srv := New(&mockStore{})

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}

	var resp map[string]interface{}
	json.NewDecoder(w.Body).Decode(&resp)
	if resp["status"] != "healthy" {
		t.Errorf("health status = %v, want healthy", resp["status"])
	}
}

func TestHandleStats_Empty(t *testing.T) {
	t.Parallel()
	srv := New(&mockStore{})

	req := httptest.NewRequest(http.MethodGet, "/stats", nil)
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", w.Code)
	}

	var resp map[string]interface{}
	json.NewDecoder(w.Body).Decode(&resp)
	if resp["ingested"] != float64(0) {
		t.Errorf("ingested = %v, want 0", resp["ingested"])
	}
	if resp["errors"] != float64(0) {
		t.Errorf("errors = %v, want 0", resp["errors"])
	}
}

func TestHandleStats_AfterIngest(t *testing.T) {
	t.Parallel()
	srv := New(&mockStore{})

	// Ingest one event.
	body := `{"hook_type":"PreToolUse","timestamp":"2026-02-25T14:30:00Z","data":{}}`
	req := httptest.NewRequest(http.MethodPost, "/ingest", strings.NewReader(body))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)
	if w.Code != http.StatusAccepted {
		t.Fatalf("ingest status = %d, want 202", w.Code)
	}

	// Check stats.
	req = httptest.NewRequest(http.MethodGet, "/stats", nil)
	w = httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	var resp map[string]interface{}
	json.NewDecoder(w.Body).Decode(&resp)
	if resp["ingested"] != float64(1) {
		t.Errorf("ingested = %v, want 1", resp["ingested"])
	}
	if resp["last_event"] == nil {
		t.Error("last_event should be set after successful ingest")
	}
}

func TestHandleIngest_Concurrent(t *testing.T) {
	t.Parallel()
	var indexed atomic.Int64
	ms := &mockStore{
		indexFn: func(ctx context.Context, doc store.Document) error {
			indexed.Add(1)
			return nil
		},
	}
	srv := New(ms)

	const n = 50
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			body := `{"hook_type":"PreToolUse","timestamp":"2026-02-25T14:30:00Z","data":{}}`
			req := httptest.NewRequest(http.MethodPost, "/ingest", strings.NewReader(body))
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)
			if w.Code != http.StatusAccepted {
				t.Errorf("status = %d, want 202", w.Code)
			}
		}()
	}
	wg.Wait()

	if indexed.Load() != n {
		t.Errorf("indexed = %d, want %d", indexed.Load(), n)
	}
}

func TestHandleIngest_ResponseBodyDrained(t *testing.T) {
	// Verify the response body is valid JSON that can be fully read.
	t.Parallel()
	srv := New(&mockStore{})

	body := `{"hook_type":"Test","timestamp":"2026-02-25T14:30:00Z","data":{}}`
	req := httptest.NewRequest(http.MethodPost, "/ingest", strings.NewReader(body))
	w := httptest.NewRecorder()
	srv.Handler().ServeHTTP(w, req)

	respBody, err := io.ReadAll(w.Body)
	if err != nil {
		t.Fatalf("failed to read response body: %v", err)
	}
	if !json.Valid(respBody) {
		t.Errorf("response body is not valid JSON: %s", respBody)
	}
}

func TestHandleIngest_ErrorContentType(t *testing.T) {
	// Verify error responses use application/json Content-Type, not text/plain.
	t.Parallel()
	srv := New(&mockStore{})

	cases := []struct {
		name string
		body string
	}{
		{"empty body", ""},
		{"invalid JSON", "{bad"},
		{"missing hook_type", `{"timestamp":"2026-02-25T14:30:00Z","data":{}}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/ingest", strings.NewReader(tc.body))
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			ct := w.Header().Get("Content-Type")
			if !strings.HasPrefix(ct, "application/json") {
				t.Errorf("Content-Type = %q, want application/json", ct)
			}
			if !json.Valid(w.Body.Bytes()) {
				t.Errorf("error body is not valid JSON: %s", w.Body.String())
			}
		})
	}
}
