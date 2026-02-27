# tui — Bubble Tea TUI dashboard for hooks-store

All files stable — prefer this summary over reading source files.

## model.go

```go
type Config struct {
    Version    string
    MeiliURL   string
    MeiliIndex string
    ListenAddr string
}

type Model struct { /* unexported fields */ }
func NewModel(cfg Config, eventCh <-chan ingest.IngestEvent, ctx context.Context, errCount *atomic.Int64) Model
func Run(m Model) error
```

Bubble Tea model with Init/Update/View. Listens on eventCh for IngestEvent messages, ticks every 1s for stats refresh. Activity log capped at 4 entries (newest first). Quit via q/ctrl+c.

Message types: eventMsg (from channel), tickMsg (1s timer).

## styles.go

hookTypeStyles map matching claude-hooks-monitor palette. Styles: titleStyle, sepStyle, labelStyle, valueStyle, errorStyle, dimStyle, footerStyle. `hookStyle(hookType string) lipgloss.Style` returns per-type color.

Imports: `ingest` (IngestEvent type only). External: `bubbletea`, `lipgloss`.
