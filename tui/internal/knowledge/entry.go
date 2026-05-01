package knowledge

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// EntryMeta holds metadata parsed from the HTML comment at the bottom of a knowledge entry.
// The schema is open-ended: known fields are surfaced as named members; the full key/value
// map is preserved on Fields so callers can render new fields without parser changes.
type EntryMeta struct {
	Learned      string
	Confidence   string
	Source       string
	Scale        string
	WorkItem     string
	RelatedFiles []string
	Fields       map[string]string
}

// EntryLoadedMsg is sent when a knowledge entry finishes loading.
type EntryLoadedMsg struct {
	Content  string
	Meta     EntryMeta
	Err      error
	FilePath string
}

// EntryModel is the Bubble Tea model for viewing a single knowledge entry.
type EntryModel struct {
	viewport viewport.Model
	meta     EntryMeta
	title    string
	ready    bool
	loading  bool
	err      error
	width    int
	height   int
}

// NewEntryModel creates an entry model for the given path.
func NewEntryModel(title string) EntryModel {
	return EntryModel{
		title:   title,
		loading: true,
	}
}

// LoadEntryCmd returns a command that reads a knowledge entry from disk.
func LoadEntryCmd(knowledgeDir, entryPath string) tea.Cmd {
	return func() tea.Msg {
		fullPath := filepath.Join(knowledgeDir, entryPath)
		data, err := os.ReadFile(fullPath)
		if err != nil {
			return EntryLoadedMsg{Err: err, FilePath: entryPath}
		}

		content := string(data)
		meta := parseEntryMeta(content)
		// Strip the metadata comment and first heading from display content
		content = stripMetaComment(content)
		content = stripFirstHeading(content)

		return EntryLoadedMsg{
			Content:  content,
			Meta:     meta,
			FilePath: entryPath,
		}
	}
}

// metaCommentRegex matches an HTML comment whose body is a pipe-separated list of
// "key: value" pairs. This is the structural shape of capture metadata
// (regular entries, edge synopses, future schemas) and won't match free-text
// HTML comments like the inbox header.
//
// The capture group holds the inner pipe-delimited body; ordering and field set
// are open — parseEntryMeta inspects each pair individually.
var metaCommentRegex = regexp.MustCompile(`(?s)<!--\s*([a-z_][a-z0-9_]*:\s*[^|>]*(?:\|\s*[a-z_][a-z0-9_]*:\s*[^|>]*)+)\s*-->`)

func parseEntryMeta(content string) EntryMeta {
	match := metaCommentRegex.FindStringSubmatch(content)
	if match == nil {
		return EntryMeta{Fields: map[string]string{}}
	}

	meta := EntryMeta{Fields: map[string]string{}}
	for _, pair := range strings.Split(match[1], "|") {
		colon := strings.IndexByte(pair, ':')
		if colon < 0 {
			continue
		}
		key := strings.TrimSpace(pair[:colon])
		val := strings.TrimSpace(pair[colon+1:])
		if key == "" {
			continue
		}
		meta.Fields[key] = val

		switch key {
		case "learned":
			meta.Learned = val
		case "confidence":
			meta.Confidence = val
		case "source":
			meta.Source = val
		case "scale":
			meta.Scale = val
		case "work_item":
			meta.WorkItem = val
		case "related_files":
			if val != "" {
				parts := strings.Split(val, ",")
				for i := range parts {
					parts[i] = strings.TrimSpace(parts[i])
				}
				meta.RelatedFiles = parts
			}
		}
	}

	return meta
}

func stripMetaComment(content string) string {
	return metaCommentRegex.ReplaceAllString(content, "")
}

// stripFirstHeading removes the first "# ..." heading line from content.
// The title is already shown in the split-pane border, so displaying it
// again inside the entry body would be redundant.
func stripFirstHeading(content string) string {
	lines := strings.Split(content, "\n")
	for i, l := range lines {
		if strings.HasPrefix(l, "# ") {
			return strings.Join(append(lines[:i], lines[i+1:]...), "\n")
		}
	}
	return content
}

func (m EntryModel) Init() tea.Cmd {
	return nil
}

func (m EntryModel) Update(msg tea.Msg) (EntryModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		if m.ready {
			m.viewport.Width = msg.Width
			m.viewport.Height = m.contentHeight()
		}

	case EntryLoadedMsg:
		m.loading = false
		if msg.Err != nil {
			m.err = msg.Err
			return m, nil
		}
		m.meta = msg.Meta

		rendered := renderEntryMarkdown(msg.Content, m.contentWidth())

		vp := viewport.New(m.contentWidth(), m.contentHeight())
		vp.SetContent(rendered)
		m.viewport = vp
		m.ready = true

	default:
		if m.ready {
			var cmd tea.Cmd
			m.viewport, cmd = m.viewport.Update(msg)
			return m, cmd
		}
	}

	return m, nil
}

func (m EntryModel) contentWidth() int {
	w := m.width - 4
	if w < 20 {
		w = 80
	}
	return w
}

func (m EntryModel) contentHeight() int {
	// Reserve space for metadata footer line, plus small margin
	h := m.height - 3
	if h < 5 {
		h = 5
	}
	return h
}

func (m EntryModel) View() string {
	if m.loading {
		return fmt.Sprintf("\n  Loading %s...\n", m.title)
	}

	if m.err != nil {
		dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
		return fmt.Sprintf("\n  Error: %v\n\n  %s\n", m.err,
			dimStyle.Render("Press Esc to go back."))
	}

	var b strings.Builder

	dimStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))

	if m.ready {
		b.WriteString(m.viewport.View())
	}

	b.WriteString("\n")

	// Metadata footer
	var metaParts []string
	if m.meta.Learned != "" {
		metaParts = append(metaParts, fmt.Sprintf("learned: %s", m.meta.Learned))
	}
	if m.meta.Confidence != "" {
		metaParts = append(metaParts, fmt.Sprintf("confidence: %s", m.meta.Confidence))
	}
	if m.meta.Source != "" {
		metaParts = append(metaParts, fmt.Sprintf("source: %s", m.meta.Source))
	}
	if m.meta.Scale != "" {
		metaParts = append(metaParts, fmt.Sprintf("scale: %s", m.meta.Scale))
	}

	if len(metaParts) > 0 {
		footer := dimStyle.Render("  " + strings.Join(metaParts, " | ") + "  |  Esc back")
		b.WriteString(footer)
	} else {
		b.WriteString(dimStyle.Render("  Esc back"))
	}

	return b.String()
}

// Package-level compiled regexps for inline markdown parsing.
var (
	entryBoldRe     = regexp.MustCompile(`\*\*([^*\n]+)\*\*`)
	entryCodeRe     = regexp.MustCompile("`([^`\n]+)`")
	entryWikiLinkRe = regexp.MustCompile(`\[\[([^\]]+)\]\]`)
)

// wordWrapRaw splits text into lines of at most width bytes (word-boundary).
func wordWrapRaw(text string, width int) []string {
	if width <= 0 || len(text) <= width {
		return []string{text}
	}
	words := strings.Fields(text)
	if len(words) == 0 {
		return []string{""}
	}
	var lines []string
	cur := words[0]
	for _, w := range words[1:] {
		if len(cur)+1+len(w) <= width {
			cur += " " + w
		} else {
			lines = append(lines, cur)
			cur = w
		}
	}
	return append(lines, cur)
}

// renderEntryMarkdown converts markdown to styled terminal output using a fast
// line-by-line approach. Safe to call synchronously on the event loop.
func renderEntryMarkdown(content string, width int) string {
	if width <= 0 {
		width = 80
	}

	h1Style   := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("12"))
	h2Style   := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("6"))
	h3Style   := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("7"))
	dimStyle  := lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	codeStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("11"))
	boldStyle := lipgloss.NewStyle().Bold(true)

	applyInline := func(s string) string {
		s = entryBoldRe.ReplaceAllStringFunc(s, func(m string) string {
			return boldStyle.Render(m[2 : len(m)-2])
		})
		s = entryCodeRe.ReplaceAllStringFunc(s, func(m string) string {
			return codeStyle.Render(m[1 : len(m)-1])
		})
		s = entryWikiLinkRe.ReplaceAllStringFunc(s, func(m string) string {
			return dimStyle.Render(m)
		})
		return s
	}

	lines := strings.Split(content, "\n")
	var out strings.Builder
	out.Grow(len(content) + 512)

	inCodeBlock := false
	justWroteHeading := false
	for _, line := range lines {
		if strings.HasPrefix(line, "```") {
			inCodeBlock = !inCodeBlock
			justWroteHeading = false
			out.WriteString(dimStyle.Render(line) + "\n")
			continue
		}
		if inCodeBlock {
			out.WriteString(dimStyle.Render(line) + "\n")
			continue
		}

		// Absorb the blank line that typically follows a heading in source —
		// the heading already emits its own trailing blank line.
		if justWroteHeading && strings.TrimSpace(line) == "" {
			continue
		}
		justWroteHeading = false

		switch {
		case strings.HasPrefix(line, "#### "):
			out.WriteString("  " + h3Style.Render(line[5:]) + "\n\n")
			justWroteHeading = true
		case strings.HasPrefix(line, "### "):
			out.WriteString(h3Style.Render(line[4:]) + "\n\n")
			justWroteHeading = true
		case strings.HasPrefix(line, "## "):
			out.WriteString(h2Style.Render(line[3:]) + "\n\n")
			justWroteHeading = true
		case strings.HasPrefix(line, "# "):
			out.WriteString(h1Style.Render(line[2:]) + "\n\n")
			justWroteHeading = true
		default:
			stripped := strings.TrimLeft(line, " ")
			indent := line[:len(line)-len(stripped)]
			avail := width - len(indent) - 2
			switch {
			case strings.HasPrefix(stripped, "- [x] "),
				strings.HasPrefix(stripped, "- [X] "):
				for i, wl := range wordWrapRaw(stripped[6:], avail) {
					pfx := indent + "  "
					if i == 0 {
						pfx = indent + "✓ "
					}
					out.WriteString(dimStyle.Render(pfx+wl) + "\n")
				}
			case strings.HasPrefix(stripped, "- [ ] "):
				for i, wl := range wordWrapRaw(stripped[6:], avail) {
					if i == 0 {
						out.WriteString(indent + "○ " + applyInline(wl) + "\n")
					} else {
						out.WriteString(indent + "  " + applyInline(wl) + "\n")
					}
				}
			case strings.HasPrefix(stripped, "- "):
				for i, wl := range wordWrapRaw(stripped[2:], avail) {
					if i == 0 {
						out.WriteString(indent + "• " + applyInline(wl) + "\n")
					} else {
						out.WriteString(indent + "  " + applyInline(wl) + "\n")
					}
				}
			case strings.TrimSpace(line) == "---":
				out.WriteString(dimStyle.Render(strings.Repeat("─", 60)) + "\n")
			default:
				if strings.TrimSpace(line) == "" {
					out.WriteByte('\n')
				} else {
					for _, wl := range wordWrapRaw(line, width) {
						out.WriteString(applyInline(wl) + "\n")
					}
				}
			}
		}
	}

	return out.String()
}
