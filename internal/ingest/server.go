package ingest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync/atomic"
	"time"

	"hooks-store/internal/hookevt"
	"hooks-store/internal/store"
)

const (
	maxBodyLen   = 1 << 20 // 1 MiB — matches the monitor's limit.
	maxJSONDepth = 100
)

// IngestEvent is a lightweight value type carrying only the fields the TUI needs.
// It decouples the TUI from the full hookevt.HookEvent / store.Document types.
type IngestEvent struct {
	HookType  string
	ToolName  string
	SessionID string
	BodySize  int
	Timestamp time.Time
}

// Server is the HTTP ingest server for receiving hook events from the monitor.
type Server struct {
	store     store.EventStore
	mux       *http.ServeMux
	ingested  atomic.Int64
	errors    atomic.Int64
	lastEvent atomic.Value // stores time.Time
	onIngest  func(IngestEvent)
}

// SetOnIngest registers a callback invoked after each successful ingest.
// The callback must be non-blocking (e.g. a non-blocking channel send).
func (s *Server) SetOnIngest(fn func(IngestEvent)) {
	s.onIngest = fn
}

// ErrCount returns the atomic error counter for direct reads by the TUI.
func (s *Server) ErrCount() *atomic.Int64 {
	return &s.errors
}

// New creates a new ingest Server wired to the given EventStore.
func New(s store.EventStore) *Server {
	srv := &Server{store: s}
	mux := http.NewServeMux()
	mux.HandleFunc("/ingest", srv.handleIngest)
	mux.HandleFunc("/health", srv.handleHealth)
	mux.HandleFunc("/stats", srv.handleStats)
	srv.mux = mux
	return srv
}

// Handler returns the HTTP handler for use with http.Server.
func (s *Server) Handler() http.Handler {
	return s.mux
}

func (s *Server) handleIngest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, maxBodyLen+1))
	if err != nil {
		s.errors.Add(1)
		jsonError(w, "failed to read body", http.StatusBadRequest)
		return
	}
	if len(body) > maxBodyLen {
		s.errors.Add(1)
		jsonError(w, "body too large", http.StatusRequestEntityTooLarge)
		return
	}
	if len(body) == 0 {
		s.errors.Add(1)
		jsonError(w, "empty body", http.StatusBadRequest)
		return
	}

	if err := checkJSONDepth(body, maxJSONDepth); err != nil {
		s.errors.Add(1)
		jsonError(w, err.Error(), http.StatusBadRequest)
		return
	}

	var evt hookevt.HookEvent
	if err := json.Unmarshal(body, &evt); err != nil {
		s.errors.Add(1)
		jsonError(w, "invalid JSON", http.StatusBadRequest)
		return
	}

	if evt.HookType == "" {
		s.errors.Add(1)
		jsonError(w, "missing hook_type", http.StatusBadRequest)
		return
	}

	doc := store.HookEventToDocument(evt)

	if err := s.store.Index(r.Context(), doc); err != nil {
		s.errors.Add(1)
		jsonError(w, "indexing failed", http.StatusServiceUnavailable)
		return
	}

	s.ingested.Add(1)
	s.lastEvent.Store(time.Now())

	if s.onIngest != nil {
		toolName, _ := evt.Data["tool_name"].(string)
		sessionID, _ := evt.Data["session_id"].(string)
		s.onIngest(IngestEvent{
			HookType:  evt.HookType,
			ToolName:  toolName,
			SessionID: sessionID,
			BodySize:  len(body),
			Timestamp: evt.Timestamp,
		})
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status": "accepted",
		"id":     doc.ID,
	})
}

// jsonError writes a JSON error response with the correct Content-Type.
func jsonError(w http.ResponseWriter, msg string, code int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"status": "healthy",
		"time":   time.Now().Format(time.RFC3339),
	})
}

func (s *Server) handleStats(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		jsonError(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	resp := map[string]interface{}{
		"ingested": s.ingested.Load(),
		"errors":   s.errors.Load(),
	}

	if last := s.lastEvent.Load(); last != nil {
		if t, ok := last.(time.Time); ok {
			resp["last_event"] = t.Format(time.RFC3339)
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

// checkJSONDepth scans raw JSON tokens to reject payloads that exceed maxDepth
// nesting levels.
func checkJSONDepth(data []byte, maxDepth int) error {
	dec := json.NewDecoder(bytes.NewReader(data))
	depth := 0
	for {
		t, err := dec.Token()
		if err != nil {
			return nil // io.EOF or parse error — let Unmarshal handle it
		}
		switch t {
		case json.Delim('{'), json.Delim('['):
			depth++
			if depth > maxDepth {
				return fmt.Errorf("JSON nesting exceeds maximum depth of %d", maxDepth)
			}
		case json.Delim('}'), json.Delim(']'):
			depth--
		}
	}
}
