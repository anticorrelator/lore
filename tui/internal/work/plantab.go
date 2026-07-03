package work

import (
	"strings"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"github.com/anticorrelator/lore/tui/internal/render"
)

// PlanTabModel is the scrollable renderer for the Plan tab.
type PlanTabModel struct {
	viewport viewport.Model
	ready    bool
	empty    bool
}

// NewPlanTabModel constructs a PlanTabModel from optional content.
// Content is treated as empty when nil, blank, or whitespace-only.
func NewPlanTabModel(content *string, width, height int) PlanTabModel {
	if content == nil || strings.TrimSpace(*content) == "" {
		return PlanTabModel{empty: true}
	}
	rendered := renderMarkdown(*content, width)
	vp := viewport.New(viewport.WithWidth(width), viewport.WithHeight(height))
	vp.SetContent(rendered)
	return PlanTabModel{viewport: vp, ready: true}
}

func (m PlanTabModel) Update(msg tea.Msg) (PlanTabModel, tea.Cmd) {
	if m.empty {
		return m, nil
	}

	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		// Dimensions arrive already-inner: DetailModel.Update forwards
		// contentWidth/contentHeight, so use them verbatim (same convention
		// as the notes tab). Do not subtract chrome again here.
		m.viewport.SetWidth(msg.Width)
		m.viewport.SetHeight(msg.Height)
	default:
		var cmd tea.Cmd
		m.viewport, cmd = m.viewport.Update(msg)
		return m, cmd
	}

	return m, nil
}

// IsEmpty returns whether there is no plan content.
func (m PlanTabModel) IsEmpty() bool {
	return m.empty
}

func (m PlanTabModel) View() string {
	if m.empty {
		dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
		return "  " + dimStyle.Render("No plan document.")
	}
	return m.viewport.View()
}

// wordWrapRaw delegates to the shared render package.
func wordWrapRaw(text string, width int) []string {
	return render.WordWrapRaw(text, width)
}

// renderMarkdown delegates to the shared render package.
func renderMarkdown(content string, width int) string {
	return render.Markdown(content, width)
}
