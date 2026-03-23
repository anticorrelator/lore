package work

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// TasksFile is the top-level shape of tasks.json.
type TasksFile struct {
	PlanChecksum string  `json:"plan_checksum"`
	GeneratedAt  string  `json:"generated_at"`
	Phases       []Phase `json:"phases"`
}

// Phase represents a plan phase containing tasks.
type Phase struct {
	PhaseNumber int    `json:"phase_number"`
	PhaseName   string `json:"phase_name"`
	Objective   string `json:"objective"`
	Tasks       []Task `json:"tasks"`
}

// Task represents a single task within a phase.
type Task struct {
	ID          string   `json:"id"`
	Subject     string   `json:"subject"`
	Description string   `json:"description"`
	ActiveForm  string   `json:"activeForm"`
	BlockedBy   []string `json:"blockedBy"`
	FileTargets []string `json:"file_targets"`
}

// tasksRow is a display row — either a phase header or a task.
type tasksRow struct {
	isPhase bool
	phase   *Phase
	task    *Task
}

// TasksModel is the Bubble Tea model for the Tasks tab.
type TasksModel struct {
	rows      []tasksRow
	collapsed map[int]bool // phase index → collapsed
	cursor    int
	expanded  int // task index with expanded description, -1 if none
	width     int
	height    int
	empty     bool
}

// NewTasksModel creates a tasks model by reading tasks.json from the work dir.
// Falls back to _archive/<slug>/ if the active path does not exist.
func NewTasksModel(workDir, slug string) TasksModel {
	path := filepath.Join(workDir, slug, "tasks.json")
	if _, err := os.Stat(path); os.IsNotExist(err) {
		if archivePath := filepath.Join(workDir, "_archive", slug, "tasks.json"); func() bool {
			_, e := os.Stat(archivePath); return e == nil
		}() {
			path = archivePath
		}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return TasksModel{empty: true, expanded: -1}
	}

	var tf TasksFile
	if err := json.Unmarshal(data, &tf); err != nil {
		return TasksModel{empty: true, expanded: -1}
	}

	return newTasksModelFromFile(tf)
}

func newTasksModelFromFile(tf TasksFile) TasksModel {
	var rows []tasksRow
	collapsed := make(map[int]bool)

	for i := range tf.Phases {
		rows = append(rows, tasksRow{isPhase: true, phase: &tf.Phases[i]})
		for j := range tf.Phases[i].Tasks {
			rows = append(rows, tasksRow{isPhase: false, task: &tf.Phases[i].Tasks[j]})
		}
	}

	if len(rows) == 0 {
		return TasksModel{empty: true, expanded: -1}
	}

	return TasksModel{
		rows:      rows,
		collapsed: collapsed,
		cursor:    0,
		expanded:  -1,
	}
}

func (m TasksModel) Init() tea.Cmd {
	return nil
}

func (m TasksModel) Update(msg tea.Msg) (TasksModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height

	case tea.MouseMsg:
		visible := m.visibleRows()
		switch msg.Button {
		case tea.MouseButtonWheelDown:
			m.cursor = m.nextVisible(m.cursor, 1, visible)
		case tea.MouseButtonWheelUp:
			m.cursor = m.nextVisible(m.cursor, -1, visible)
		}

	case tea.KeyMsg:
		visible := m.visibleRows()
		switch msg.String() {
		case "j", "down":
			m.cursor = m.nextVisible(m.cursor, 1, visible)
		case "k", "up":
			m.cursor = m.nextVisible(m.cursor, -1, visible)
		case "g", "home":
			if len(visible) > 0 {
				m.cursor = visible[0]
			}
		case "G", "end":
			if len(visible) > 0 {
				m.cursor = visible[len(visible)-1]
			}
		case "enter":
			if m.cursor >= 0 && m.cursor < len(m.rows) {
				row := m.rows[m.cursor]
				if row.isPhase {
					// Toggle collapse
					phaseIdx := m.phaseIndexAt(m.cursor)
					m.collapsed[phaseIdx] = !m.collapsed[phaseIdx]
				} else {
					// Toggle expanded description
					if m.expanded == m.cursor {
						m.expanded = -1
					} else {
						m.expanded = m.cursor
					}
				}
			}
		}
	}
	return m, nil
}

// IsEmpty returns whether there are no tasks.
func (m TasksModel) IsEmpty() bool {
	return m.empty
}

func (m TasksModel) View() string {
	if m.empty {
		return "  No tasks defined."
	}

	var b strings.Builder

	phaseStyle := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("4"))
	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	selectedBg := lipgloss.NewStyle().Background(lipgloss.Color("237")).Bold(true)
	blockedStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8")).Italic(true)

	visible := m.visibleRows()
	if len(visible) == 0 {
		return b.String()
	}

	// Line-count-based windowing: m.height is in terminal lines, not logical rows.
	// Pre-compute per-row heights, then walk outward from the cursor to find the
	// visible window where total rendered lines fit within m.height.
	budget := m.height
	if budget < 1 {
		budget = 1<<31 - 1 // unbounded when height not set
	}

	// Pre-compute heights for all visible rows.
	heights := make([]int, len(visible))
	for i, idx := range visible {
		heights[i] = m.rowHeight(idx)
	}

	// Find cursor position in the visible list.
	cursorPos := 0
	for i, idx := range visible {
		if idx == m.cursor {
			cursorPos = i
			break
		}
	}

	// Walk outward from cursor, consuming the line budget.
	// Always include the cursor row first.
	offset := cursorPos
	end := cursorPos + 1
	used := heights[cursorPos]

	// Expand window forward and backward greedily.
	lo, hi := cursorPos-1, cursorPos+1
	for used < budget {
		addedAny := false
		if hi < len(visible) && used+heights[hi] <= budget {
			used += heights[hi]
			end = hi + 1
			hi++
			addedAny = true
		}
		if lo >= 0 && used+heights[lo] <= budget {
			used += heights[lo]
			offset = lo
			lo--
			addedAny = true
		}
		if !addedAny {
			break
		}
	}

	for vi := offset; vi < end; vi++ {
		idx := visible[vi]
		row := m.rows[idx]

		var line string
		if row.isPhase {
			phaseIdx := m.phaseIndexAt(idx)
			arrow := "▼"
			if m.collapsed[phaseIdx] {
				arrow = "▶"
			}
			line = phaseStyle.Render(fmt.Sprintf("  %s Phase %d: %s",
				arrow, row.phase.PhaseNumber, row.phase.PhaseName))
		} else {
			subject := row.task.Subject
			maxW := m.width - 8
			if maxW > 0 && lipgloss.Width(subject) > maxW {
				subject = truncate(subject, maxW)
			}
			line = fmt.Sprintf("    [ ] %s", subject)

			if idx == m.cursor {
				line = selectedBg.Render(line)
			}

			b.WriteString(line)
			b.WriteString("\n")

			// Show blockedBy if present
			if len(row.task.BlockedBy) > 0 {
				blocked := blockedStyle.Render(fmt.Sprintf("        <- blocked by: %s",
					strings.Join(row.task.BlockedBy, ", ")))
				b.WriteString(blocked)
				b.WriteString("\n")
			}

			// Show expanded description
			if m.expanded == idx && row.task.Description != "" {
				descLines := wrapText(row.task.Description, m.width-10)
				for _, dl := range descLines {
					b.WriteString(dimStyle.Render("        "+dl) + "\n")
				}
			}
			continue
		}

		if idx == m.cursor {
			line = selectedBg.Render(line)
		}

		b.WriteString(line)
		b.WriteString("\n")

		// Show objective for expanded phase headers (word-wrapped)
		if row.isPhase && !m.collapsed[m.phaseIndexAt(idx)] && row.phase.Objective != "" {
			for _, wl := range wrapText(row.phase.Objective, m.width-6) {
				b.WriteString(dimStyle.Render("    "+wl) + "\n")
			}
		}
	}

	return b.String()
}

// rowHeight returns the number of terminal lines a visible row renders.
// Phase headers: 1 line for the header + wrapped objective lines if not collapsed.
// Task rows: 1 line for the subject + 1 if blockedBy is non-empty + wrapped
// description lines if expanded.
func (m TasksModel) rowHeight(idx int) int {
	row := m.rows[idx]
	if row.isPhase {
		h := 1
		phaseIdx := m.phaseIndexAt(idx)
		if !m.collapsed[phaseIdx] && row.phase.Objective != "" {
			h += len(wrapText(row.phase.Objective, m.width-6))
		}
		return h
	}
	// Task row
	h := 1
	if len(row.task.BlockedBy) > 0 {
		h++
	}
	if m.expanded == idx && row.task.Description != "" {
		h += len(wrapText(row.task.Description, m.width-10))
	}
	return h
}

// visibleRows returns indices of rows that are not hidden by collapsed phases.
func (m TasksModel) visibleRows() []int {
	var visible []int
	currentPhase := -1
	for i, row := range m.rows {
		if row.isPhase {
			currentPhase = m.phaseIndexAt(i)
			visible = append(visible, i)
		} else {
			if currentPhase >= 0 && !m.collapsed[currentPhase] {
				visible = append(visible, i)
			}
		}
	}
	return visible
}

// nextVisible returns the next visible row index from current, in the given direction.
func (m TasksModel) nextVisible(current, dir int, visible []int) int {
	if len(visible) == 0 {
		return current
	}

	// Find current position in visible
	pos := -1
	for i, idx := range visible {
		if idx == current {
			pos = i
			break
		}
	}

	if pos < 0 {
		// Current row not visible; jump to nearest
		if dir > 0 && len(visible) > 0 {
			return visible[0]
		}
		return visible[len(visible)-1]
	}

	next := pos + dir
	if next < 0 {
		next = 0
	}
	if next >= len(visible) {
		next = len(visible) - 1
	}
	return visible[next]
}

// phaseIndexAt returns which phase number (0-based) the row at index belongs to.
func (m TasksModel) phaseIndexAt(idx int) int {
	count := -1
	for i := 0; i <= idx; i++ {
		if m.rows[i].isPhase {
			count++
		}
	}
	return count
}

func (m TasksModel) countPhases() int {
	count := 0
	for _, row := range m.rows {
		if row.isPhase {
			count++
		}
	}
	return count
}

// wrapText breaks text into lines of at most maxWidth characters.
func wrapText(text string, maxWidth int) []string {
	if maxWidth <= 0 {
		maxWidth = 80
	}

	var lines []string
	for _, paragraph := range strings.Split(text, "\n") {
		if paragraph == "" {
			lines = append(lines, "")
			continue
		}
		words := strings.Fields(paragraph)
		if len(words) == 0 {
			lines = append(lines, "")
			continue
		}
		current := words[0]
		for _, w := range words[1:] {
			if len(current)+1+len(w) > maxWidth {
				lines = append(lines, current)
				current = w
			} else {
				current += " " + w
			}
		}
		lines = append(lines, current)
	}
	return lines
}
