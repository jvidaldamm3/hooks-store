# Phase 6: Terminal User Interface

## Overview

Replace the static startup banner with a live Bubble Tea TUI dashboard.
The TUI shows connection info, ingestion statistics, and a scrolling
activity log of recent events. Matches the visual style of the sister
project (claude-hooks-monitor).

## Requirements

- Clean quit with `q` or `ctrl+c`
- Activity visualization: hook type, tool name, payload size, timestamp
- Preserve current banner info (ports, endpoints, MeiliSearch connection)
- Live stats: ingested count, error count, time since last event
- Minimal footprint — status dashboard, not an interactive explorer

## Architecture

### Event Flow

```
Claude Code CLI
     │
     ▼  (via monitor's EventSink)
POST /ingest
     │
     ▼
┌─────────────────────────────────────────────────┐
│  ingest.Server.handleIngest()                   │
│                                                 │
│  1. validate + unmarshal                        │
│  2. store.Index(doc)                            │
│  3. ingested.Add(1)                             │
│  4. onIngest(IngestEvent{...})  ◄── NEW         │
│         │                                       │
└─────────┼───────────────────────────────────────┘
          │  non-blocking send
          ▼
    ┌──────────┐
    │ eventCh  │  buffered channel (cap 256)
    │ (main)   │
    └────┬─────┘
         │
         ▼
┌─────────────────────────────────────────────────┐
│  tui.Model (Bubble Tea event loop)              │
│                                                 │
│  waitForEvent() ──► EventMsg ──► Update()       │
│  tickEvery(1s)  ──► tickMsg  ──► Update()       │
│                                                 │
│  View() renders:                                │
│    ├── header banner (static config)            │
│    ├── stats line (ingested / errors / last)    │
│    └── activity log (recent events, newest first│)
└─────────────────────────────────────────────────┘
```

### Goroutine Map

```
main goroutine ─────── tui.Run() [blocks until quit]
     │
     ├── go httpSrv.Serve(ln)
     │       └── per-request goroutines (net/http)
     │               └── handleIngest() calls onIngest()
     │
     └── go signal handler (SIGINT/SIGTERM)
              └── cancel(ctx) → triggers tea.Quit via waitForEvent
```

### Shutdown Sequence

```
User presses "q"               External SIGTERM
       │                              │
       ▼                              ▼
  tea.Quit returned            signal goroutine
       │                       cancel(ctx)
       ▼                              │
  tui.Run() returns                   ▼
       │                       waitForEvent sees ctx.Done()
       ▼                       returns tea.Quit
  shutdownOnce.Do()                   │
       │                              ▼
       ├── cancel(ctx)          tui.Run() returns
       ├── httpSrv.Shutdown()          │
       └── close(eventCh)             ... (same path)
```

Both paths converge through `sync.Once`, ensuring shutdown
runs exactly once regardless of trigger source.

## Module Boundaries

### Decoupling Strategy

The TUI is fully decoupled from the ingest server through two
narrow interfaces:

```
┌──────────────┐     callback fn      ┌──────────────┐
│ ingest.Server│ ──────────────────── │   main.go    │
│              │  SetOnIngest(fn)     │  (wiring)    │
│              │                      │              │
│  onIngest ●──┼── func(IngestEvent)  │  eventCh ●───┼──► tui.Model
│              │                      │              │
│  errors   ●──┼── ErrCount() ───────┼──► TUI reads │
│ (atomic)     │   *atomic.Int64      │   via Load() │
└──────────────┘                      └──────────────┘
```

**Key decisions:**

1. **Callback, not channel** on Server: The ingest package stays
   independent of Bubble Tea types. `SetOnIngest` accepts a plain
   `func(IngestEvent)` — the caller decides what to do with it.

2. **IngestEvent is a value type** in the `ingest` package: Contains
   only the fields the TUI needs (`HookType`, `BodySize`, `Timestamp`,
   `ToolName`, `SessionID`). No reference to `hookevt.HookEvent` or
   `store.Document` — the TUI never sees the full event payload.

3. **Error counter via atomic pointer**: Rather than a second channel
   or duplicating error tracking, the TUI reads `Server.errors` directly
   via `ErrCount() *atomic.Int64`. Atomics are safe for concurrent reads
   and this avoids coupling the TUI to error-path details.

4. **Channel ownership in main.go**: The channel is created and closed
   in `main()`, not inside any package. Both `ingest` and `tui` receive
   it as a dependency — neither owns it.

### Dependency Graph

```
cmd/hooks-store/main.go
     │
     ├── internal/ingest    (SetOnIngest, ErrCount)
     ├── internal/tui       (Run, Config)
     ├── internal/store     (NewMeiliStore)
     └── internal/hookevt   (not directly — used by ingest)

internal/tui
     └── internal/ingest    (IngestEvent type only)

internal/ingest
     ├── internal/hookevt
     └── internal/store
```

The `tui` package imports `ingest` only for the `IngestEvent` struct.
It has zero knowledge of MeiliSearch, HTTP handlers, or event
transformation.

## File Changes

### New files

| File | Purpose |
|------|---------|
| `internal/tui/model.go` | Model struct, Init/Update/View, Run(), waitForEvent, tickEvery, formatBytes |
| `internal/tui/styles.go` | lipgloss styles, hookTypeStyles map (copied from monitor for consistency) |

### Modified files

| File | Changes |
|------|---------|
| `internal/ingest/server.go` | Add `IngestEvent` struct, `onIngest` field, `SetOnIngest()`, `ErrCount()`, notification call in handleIngest |
| `cmd/hooks-store/main.go` | Replace printBanner + signal-wait with channel wiring + `tui.Run()` |
| `go.mod` / `go.sum` | Add `bubbletea v1.3.10`, `lipgloss v1.1.0` |

### Untouched files

| File | Why |
|------|-----|
| `internal/store/store.go` | No interface changes needed |
| `internal/store/meili.go` | Storage layer unaffected |
| `internal/store/transform.go` | Transform logic unchanged |
| `internal/hookevt/hookevt.go` | Wire format unchanged |
| All `_test.go` files | Existing tests pass — `onIngest` defaults to nil (no-op) |

## TUI Layout

```
──────────────────────────────────────────────────
  hooks-store dev
──────────────────────────────────────────────────
  MeiliSearch:  http://localhost:7700 (index: hook-events)
  Listening:    http://localhost:9800
  Endpoints:    POST /ingest  GET /health  GET /stats
──────────────────────────────────────────────────
  Ingested: 42     Errors: 0     Last: 3s ago
──────────────────────────────────────────────────
  Recent Activity
  PreToolUse       Write          1.2 KB   14:32:05
  PostToolUse      Write          0.8 KB   14:32:05
  SessionStart     ---            0.3 KB   14:31:58
  UserPromptSubmit ---            2.1 KB   14:31:57
  ...
──────────────────────────────────────────────────
  q: quit
```

### Layout Sections

1. **Header** (static): version, separator lines
2. **Config block** (static): MeiliSearch URL, listen port, endpoints
3. **Stats line** (live): ingested count, error count (red if >0), relative time since last event
4. **Activity log** (live, scrolling): most recent events first, fills available terminal height
5. **Footer** (static): keybinding hint

### Activity Log Columns

| Column | Width | Source |
|--------|-------|--------|
| Hook type | 20 chars | `IngestEvent.HookType`, colored per hookTypeStyles |
| Tool name | 14 chars | `IngestEvent.ToolName`, dim, `---` if empty |
| Body size | 8 chars | `IngestEvent.BodySize`, formatted as KB/MB |
| Time | 8 chars | `IngestEvent.Timestamp`, `HH:MM:SS` format |

### Bounded Memory

- `recentEvents` slice capped at 20 entries
- When full, oldest entry is dropped (slice shift)
- Activity log renders only what fits in terminal height
- No unbounded growth

## Concurrency Safety

| Concern | Mitigation |
|---------|------------|
| HTTP goroutines call `onIngest` concurrently | Callback performs non-blocking channel send — no shared state |
| Channel send when TUI is slow | `select { case ch<-evt: default: }` drops excess events |
| Channel close during in-flight send | Channel closed in main after `tui.Run()` returns — all senders have already been stopped by `httpSrv.Shutdown()` |
| TUI reads `Server.errors` from different goroutine | `atomic.Int64.Load()` is safe for concurrent reads |
| Multiple shutdown triggers | `sync.Once` ensures single execution |

## Verification

1. **Build**: `go build ./...`
2. **Unit tests**: `go test ./internal/ingest/...` — existing tests pass (nil callback is no-op)
3. **Manual smoke test**:
   ```bash
   # Terminal 1: start hooks-store
   ./bin/hooks-store

   # Terminal 2: send test events
   curl -s -X POST localhost:9800/ingest \
     -d '{"hook_type":"PreToolUse","timestamp":"2026-02-25T14:30:00Z","data":{"tool_name":"Write","session_id":"s1"}}'

   curl -s -X POST localhost:9800/ingest \
     -d '{"hook_type":"SessionStart","timestamp":"2026-02-25T14:30:01Z","data":{"session_id":"s1"}}'
   ```
4. **Verify**: Activity log updates, counters increment, "Last: Xs ago" ticks
5. **Quit**: Press `q` — clean exit, no panic, no goroutine leak
