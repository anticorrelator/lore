package knowledge

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode"
)

// CategoryInfo represents a knowledge category from _manifest.json.
type CategoryInfo struct {
	Name          string
	EntryCount    int     `json:"entry_count"`
	PriorityScore float64 `json:"priority_score"`
}

// KnowledgeEntry represents a single knowledge entry from _manifest.json.
type KnowledgeEntry struct {
	Path          string   `json:"path"`
	Category      string   `json:"category"`
	Keywords      []string `json:"keywords"`
	Backlinks     []string `json:"backlinks"`
	Learned       string   `json:"learned"`
	Confidence    string   `json:"confidence"`
	RelatedFiles  []string `json:"related_files"`
	SeeAlso       []string `json:"see_also"`
	PriorityScore float64  `json:"priority_score"`
	Title         string   `json:"-"` // inferred from path
}

// manifestFile is the top-level shape of _manifest.json.
type manifestFile struct {
	FormatVersion int                        `json:"format_version"`
	Repo          string                     `json:"repo"`
	LastUpdated   string                     `json:"last_updated"`
	Categories    map[string]categoryRawInfo `json:"categories"`
	Entries       []KnowledgeEntry           `json:"entries"`
}

type categoryRawInfo struct {
	EntryCount    int     `json:"entry_count"`
	PriorityScore float64 `json:"priority_score"`
}

// Manifest holds the parsed manifest data.
type Manifest struct {
	Categories []CategoryInfo
	Entries    []KnowledgeEntry
}

// LoadManifest reads _manifest.json from the knowledge directory.
func LoadManifest(knowledgeDir string) (*Manifest, error) {
	path := filepath.Join(knowledgeDir, "_manifest.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}

	var mf manifestFile
	if err := json.Unmarshal(data, &mf); err != nil {
		return nil, err
	}

	// Build sorted categories list
	categories := make([]CategoryInfo, 0, len(mf.Categories))
	for name, info := range mf.Categories {
		categories = append(categories, CategoryInfo{
			Name:          name,
			EntryCount:    info.EntryCount,
			PriorityScore: info.PriorityScore,
		})
	}
	sort.Slice(categories, func(i, j int) bool {
		return categories[i].PriorityScore > categories[j].PriorityScore
	})

	// Infer titles from paths
	for i := range mf.Entries {
		mf.Entries[i].Title = titleFromPath(mf.Entries[i].Path)
	}

	return &Manifest{
		Categories: categories,
		Entries:    mf.Entries,
	}, nil
}

// EntriesByCategory returns entries filtered by category name.
func (m *Manifest) EntriesByCategory(category string) []KnowledgeEntry {
	var filtered []KnowledgeEntry
	for _, e := range m.Entries {
		if e.Category == category {
			filtered = append(filtered, e)
		}
	}
	return filtered
}

// titleFromPath infers a human-readable title from a knowledge entry path.
// e.g., "conventions/skills/script-first-skill-design.md" → "Script First Skill Design"
func titleFromPath(path string) string {
	base := filepath.Base(path)
	name := strings.TrimSuffix(base, ".md")
	name = strings.ReplaceAll(name, "-", " ")
	return titleCase(name)
}

// titleCase capitalizes the first letter of each word.
func titleCase(s string) string {
	prev := ' '
	return strings.Map(func(r rune) rune {
		if unicode.IsSpace(rune(prev)) || prev == ' ' {
			prev = r
			return unicode.ToUpper(r)
		}
		prev = r
		return r
	}, s)
}
