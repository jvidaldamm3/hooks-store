package tui

import (
	"context"
	"fmt"
	"strings"
	"sync/atomic"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"hooks-store/internal/ingest"
)

const maxRecentEvents = 20

// Config holds the static information displayed in the TUI header.
type Config struct {
	Version    string
	MeiliURL   string
	MeiliIndex string
	ListenAddr string
}

// Model is the Bubble Tea model for the hooks-store dashboard.
type Model struct {
	cfg          Config
	eventCh      <-chan ingest.IngestEvent
	ctx          context.Context
	errCount     *atomic.Int64
	ingested     int
	errors       int64
	lastEvent    time.Time
	recentEvents []ingest.IngestEvent
}

// NewModel creates a new TUI model.
func NewModel(cfg Config, eventCh <-chan ingest.IngestEvent, ctx context.Context, errCount *atomic.Int64) Model {
	return Model{
		cfg:      cfg,
		eventCh:  eventCh,
		ctx:      ctx,
		errCount: errCount,
	}
}

// Run starts the Bubble Tea program and blocks until it exits.
func Run(m Model) error {
	p := tea.NewProgram(m, tea.WithAltScreen())
	_, err := p.Run()
	return err
}

// --- Messages ---

type eventMsg ingest.IngestEvent
type tickMsg time.Time

// --- Bubble Tea interface ---

func (m Model) Init() tea.Cmd {
	return tea.Batch(waitForEvent(m.eventCh, m.ctx), tickEvery(time.Second))
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		}

	case eventMsg:
		evt := ingest.IngestEvent(msg)
		m.ingested++
		m.lastEvent = time.Now()
		m.recentEvents = append([]ingest.IngestEvent{evt}, m.recentEvents...)
		if len(m.recentEvents) > maxRecentEvents {
			m.recentEvents = m.recentEvents[:maxRecentEvents]
		}
		return m, waitForEvent(m.eventCh, m.ctx)

	case tickMsg:
		m.errors = m.errCount.Load()
		return m, tickEvery(time.Second)
	}

	return m, nil
}

func (m Model) View() string {
	var b strings.Builder

	sep := sepStyle.Render(strings.Repeat("─", 50))

	// Header
	b.WriteString(sep + "\n")
	b.WriteString("  " + titleStyle.Render(fmt.Sprintf("hooks-store %s", m.cfg.Version)) + "\n")
	b.WriteString(sep + "\n")

	// Config block
	b.WriteString("  " + labelStyle.Render("MeiliSearch:") + "  " + valueStyle.Render(fmt.Sprintf("%s (index: %s)", m.cfg.MeiliURL, m.cfg.MeiliIndex)) + "\n")
	b.WriteString("  " + labelStyle.Render("Listening:") + "    " + valueStyle.Render(m.cfg.ListenAddr) + "\n")
	b.WriteString("  " + labelStyle.Render("Endpoints:") + "    " + valueStyle.Render("POST /ingest  GET /health  GET /stats") + "\n")
	b.WriteString(sep + "\n")

	// Stats line
	errLabel := fmt.Sprintf("Errors: %d", m.errors)
	if m.errors > 0 {
		errLabel = errorStyle.Render(errLabel)
	} else {
		errLabel = valueStyle.Render(errLabel)
	}

	lastStr := "never"
	if !m.lastEvent.IsZero() {
		ago := time.Since(m.lastEvent).Truncate(time.Second)
		lastStr = fmt.Sprintf("%s ago", ago)
	}

	b.WriteString(fmt.Sprintf("  %s     %s     %s\n",
		valueStyle.Render(fmt.Sprintf("Ingested: %d", m.ingested)),
		errLabel,
		valueStyle.Render(fmt.Sprintf("Last: %s", lastStr)),
	))
	b.WriteString(sep + "\n")

	// Activity log
	b.WriteString("  " + titleStyle.Render("Recent Activity") + "\n")
	if len(m.recentEvents) == 0 {
		b.WriteString("  " + dimStyle.Render("Waiting for events...") + "\n")
	} else {
		for _, evt := range m.recentEvents {
			hookType := hookStyle(evt.HookType).Render(fmt.Sprintf("%-20s", evt.HookType))

			toolName := "---"
			if evt.ToolName != "" {
				toolName = evt.ToolName
			}
			toolCol := dimStyle.Render(fmt.Sprintf("%-14s", toolName))

			sizeCol := dimStyle.Render(fmt.Sprintf("%8s", formatBytes(evt.BodySize)))

			timeCol := dimStyle.Render(evt.Timestamp.Local().Format("15:04:05"))

			b.WriteString(fmt.Sprintf("  %s %s %s   %s\n", hookType, toolCol, sizeCol, timeCol))
		}
	}
	b.WriteString(sep + "\n")

	// Footer
	b.WriteString("  " + footerStyle.Render("q: quit") + "\n")

	return b.String()
}

// --- Commands ---

func waitForEvent(ch <-chan ingest.IngestEvent, ctx context.Context) tea.Cmd {
	return func() tea.Msg {
		select {
		case evt, ok := <-ch:
			if !ok {
				return tea.Quit()
			}
			return eventMsg(evt)
		case <-ctx.Done():
			return tea.Quit()
		}
	}
}

func tickEvery(d time.Duration) tea.Cmd {
	return tea.Tick(d, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}

func formatBytes(b int) string {
	switch {
	case b >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(b)/float64(1<<20))
	case b >= 1<<10:
		return fmt.Sprintf("%.1f KB", float64(b)/float64(1<<10))
	default:
		return fmt.Sprintf("%d B", b)
	}
}
