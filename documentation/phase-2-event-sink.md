# Phase 2: EventSink in Monitor

## Overview

This phase adds an optional event forwarding mechanism to the Claude Hooks Monitor.
When enabled, every hook event is also sent via HTTP POST to an external companion
program — without affecting the monitor's existing behavior.

## Design Decisions

### Interface-based decoupling

The `EventSink` interface (`internal/sink/sink.go`) defines two methods:

```go
type EventSink interface {
    Send(ctx context.Context, event hookevt.HookEvent) error
    Close() error
}
```

This allows swapping the transport mechanism (HTTP, pipe, message bus) by
implementing a different sink — without changing the monitor core.

### SetSink() instead of constructor change

The monitor has 30+ call sites for `NewHookMonitor(eventCh)` across tests and
production code. Rather than changing the constructor signature (which would
require updating every call site), we use `SetSink()`:

```go
mon := monitor.NewHookMonitor(eventCh)
mon.SetSink(httpSink)  // optional — nil by default
```

This preserves full backward compatibility. All existing tests pass unchanged.

### Fire-and-forget pattern

The sink is called in a background goroutine, outside the monitor's lock:

```go
if m.eventSink != nil {
    evt := event
    go func() {
        ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
        defer cancel()
        _ = m.eventSink.Send(ctx, evt) // error intentionally discarded
    }()
}
```

**Why fire-and-forget:**
- The monitor must never block on an external service
- If the companion is down, events are silently dropped — the monitor continues
- The 5s timeout ensures goroutines don't leak if the companion hangs
- Error discarding is intentional: the monitor's job is monitoring, not delivery guarantees

**Why a goroutine per event (not a buffered channel):**
- Simpler — no background consumer goroutine to manage
- The HTTP client handles connection pooling internally
- Event rate is low enough (dozens per session) that goroutine overhead is negligible
- The 5s timeout ensures bounded goroutine count

### HTTPSink specifics

`internal/sink/http.go`:
- 3s client timeout (separate from the 5s context timeout in AddEvent)
- Connection pooling: `MaxIdleConnsPerHost: 5` for keep-alive reuse
- Accepts any 2xx response as success
- Returns errors on non-2xx, connection refused, or timeout

## Configuration

Added `[sink]` section to `hook_monitor.conf`:

```ini
[sink]
forward = no
endpoint = http://localhost:9800/ingest
```

- `forward`: `yes`/`no` — disabled by default
- `endpoint`: companion URL — defaults to localhost:9800

Parsed by `config.ReadSinkConfig()` using the same INI parsing pattern as
the existing `[hooks]` section.

## Files Changed

| File | Change |
|------|--------|
| `internal/sink/sink.go` | NEW — `EventSink` interface |
| `internal/sink/http.go` | NEW — `HTTPSink` implementation |
| `internal/sink/http_test.go` | NEW — 6 tests (success, 500, conn refused, context cancel, concurrent, close) |
| `internal/monitor/monitor.go` | Added `eventSink` field, `SetSink()`, `CloseSink()`, goroutine in `AddEvent()` |
| `internal/config/config.go` | Added `SinkConfig`, `ReadSinkConfig()`, `parseINISection()` |
| `hooks/hook_monitor.conf` | Added `[sink]` section |
| `cmd/monitor/main.go` | Wire sink from config, added `CloseSink()` to cleanup |

## Test Results

- `internal/sink`: 6/6 pass
- `internal/monitor`: 27/27 pass (all existing tests unchanged)
- `internal/server`: all pass
- `internal/config`: all pass
