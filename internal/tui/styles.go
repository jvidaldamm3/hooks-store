package tui

import "github.com/charmbracelet/lipgloss"

// hookTypeStyles mirrors the claude-hooks-monitor palette for visual consistency.
var hookTypeStyles = map[string]lipgloss.Style{
	"SessionStart":       lipgloss.NewStyle().Foreground(lipgloss.Color("42")).Bold(true),
	"SessionEnd":         lipgloss.NewStyle().Foreground(lipgloss.Color("196")).Bold(true),
	"PreToolUse":         lipgloss.NewStyle().Foreground(lipgloss.Color("226")).Bold(true),
	"PostToolUse":        lipgloss.NewStyle().Foreground(lipgloss.Color("51")).Bold(true),
	"PostToolUseFailure": lipgloss.NewStyle().Foreground(lipgloss.Color("196")).Bold(true),
	"UserPromptSubmit":   lipgloss.NewStyle().Foreground(lipgloss.Color("201")).Bold(true),
	"Notification":       lipgloss.NewStyle().Foreground(lipgloss.Color("39")).Bold(true),
	"PermissionRequest":  lipgloss.NewStyle().Foreground(lipgloss.Color("255")).Bold(true),
	"Stop":               lipgloss.NewStyle().Foreground(lipgloss.Color("196")),
	"SubagentStart":      lipgloss.NewStyle().Foreground(lipgloss.Color("87")),
	"SubagentStop":       lipgloss.NewStyle().Foreground(lipgloss.Color("87")).Bold(true),
	"TeammateIdle":       lipgloss.NewStyle().Foreground(lipgloss.Color("75")),
	"TaskCompleted":      lipgloss.NewStyle().Foreground(lipgloss.Color("46")),
	"ConfigChange":       lipgloss.NewStyle().Foreground(lipgloss.Color("227")),
	"PreCompact":         lipgloss.NewStyle().Foreground(lipgloss.Color("207")),
}

var (
	defaultHookStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("252"))

	titleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("42"))

	sepStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("237"))

	labelStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("244"))

	valueStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("252"))

	errorStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("196")).
			Bold(true)

	dimStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("241"))

	footerStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("241"))
)

func hookStyle(hookType string) lipgloss.Style {
	if s, ok := hookTypeStyles[hookType]; ok {
		return s
	}
	return defaultHookStyle
}
