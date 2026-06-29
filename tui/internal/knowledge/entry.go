package knowledge

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"charm.land/bubbles/v2/viewport"
	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/render"
	"github.com/anticorrelator/lore/tui/internal/style"
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

// Ready reports whether an entry has been loaded into the viewport.
// The detail pane should only take focus when this is true.
func (m EntryModel) Ready() bool { return m.ready }

func (m EntryModel) Update(msg tea.Msg) (EntryModel, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		if m.ready {
			m.viewport.SetWidth(msg.Width)
			m.viewport.SetHeight(m.contentHeight())
		}

	case EntryLoadedMsg:
		m.loading = false
		if msg.Err != nil {
			m.err = msg.Err
			return m, nil
		}
		m.meta = msg.Meta

		rendered := render.Markdown(msg.Content, m.contentWidth())

		vp := viewport.New(viewport.WithWidth(m.contentWidth()), viewport.WithHeight(m.contentHeight()))
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
		return fmt.Sprintf("\n  Error: %v\n\n  %s\n", m.err,
			style.Dim.Render("Press Esc to go back."))
	}

	if !m.ready {
		return "\n  " + style.Dim.Render("Select an entry to view it here.") + "\n"
	}

	var b strings.Builder
	b.WriteString(m.viewport.View())
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
		footer := style.Dim.Render("  " + strings.Join(metaParts, " | ") + "  |  Esc back")
		b.WriteString(footer)
	} else {
		b.WriteString(style.Dim.Render("  Esc back"))
	}

	return b.String()
}
