package followup

import (
	"encoding/json"
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"
)

// Attachment is a reference to an artifact associated with a follow-up
// (e.g. a PR, work item, or knowledge entry).
type Attachment struct {
	Type string `json:"type"`
	Ref  string `json:"ref"`
}

// SuggestedAction represents a recommended action for a follow-up
// (e.g. create_work_item, comment_on_pr, approve, dismiss).
type SuggestedAction struct {
	Type string `json:"type"`
	// Additional fields are action-type specific; captured as raw JSON for
	// forward-compatibility.
	Raw json.RawMessage `json:"-"`
}

// FollowUpItem represents a single follow-up from _followup_index.json.
type FollowUpItem struct {
	ID               string           `json:"id"`
	Title            string           `json:"title"`
	Status           string           `json:"status"`
	Source           string           `json:"source"`
	Attachments      []Attachment     `json:"attachments"`
	SuggestedActions []SuggestedAction `json:"suggested_actions"`
	Created          string           `json:"created"`
	Updated          string           `json:"updated"`
	PromotedTo       string           `json:"promoted_to"`
	HasFinding       bool             `json:"has_finding"`
}

// PRRef returns the Ref of the first attachment with type "pr", or "" if none.
func (f *FollowUpItem) PRRef() string {
	for _, a := range f.Attachments {
		if a.Type == "pr" {
			return a.Ref
		}
	}
	return ""
}

// WorkItemRef returns the work item reference for this follow-up.
// It returns PromotedTo if set; otherwise scans Attachments for type "work_item".
func (f *FollowUpItem) WorkItemRef() string {
	if f.PromotedTo != "" {
		return f.PromotedTo
	}
	for _, a := range f.Attachments {
		if a.Type == "work_item" {
			return a.Ref
		}
	}
	return ""
}

// followUpIndex is the top-level shape of _followup_index.json.
type followUpIndex struct {
	Version     int            `json:"version"`
	LastUpdated string         `json:"last_updated"`
	Pending     []FollowUpItem `json:"pending"`
	Reviewed    []FollowUpItem `json:"reviewed"`
	Promoted    []FollowUpItem `json:"promoted"`
	Dismissed   []FollowUpItem `json:"dismissed"`
}

// StatusFilter controls which follow-up statuses are returned by LoadIndex.
type StatusFilter int

const (
	// StatusPending returns only pending follow-ups (default).
	StatusPending StatusFilter = iota
	// StatusAll returns follow-ups in all statuses.
	StatusAll
	// StatusReviewed returns only reviewed follow-ups.
	StatusReviewed
	// StatusPromoted returns only promoted follow-ups.
	StatusPromoted
	// StatusDismissed returns only dismissed follow-ups.
	StatusDismissed
)

// LoadIndex reads _followup_index.json from the knowledge directory and
// returns follow-up items matching the given status filter.
// knowledgeDir is the root of the knowledge store (parent of _followups/).
func LoadIndex(knowledgeDir string, filter StatusFilter) ([]FollowUpItem, error) {
	indexPath := filepath.Join(knowledgeDir, "_followup_index.json")
	data, err := os.ReadFile(indexPath)
	if err != nil {
		return nil, err
	}

	var idx followUpIndex
	if err := json.Unmarshal(data, &idx); err != nil {
		return nil, err
	}

	switch filter {
	case StatusAll:
		result := make([]FollowUpItem, 0,
			len(idx.Pending)+len(idx.Reviewed)+len(idx.Promoted)+len(idx.Dismissed))
		result = append(result, idx.Pending...)
		result = append(result, idx.Reviewed...)
		result = append(result, idx.Promoted...)
		result = append(result, idx.Dismissed...)
		return result, nil
	case StatusReviewed:
		return idx.Reviewed, nil
	case StatusPromoted:
		return idx.Promoted, nil
	case StatusDismissed:
		return idx.Dismissed, nil
	default: // StatusPending
		return idx.Pending, nil
	}
}

// IndexMtime returns the modification time (Unix epoch nanoseconds) of
// _followup_index.json, or 0 if the file does not exist.
// Used by the TUI for mtime-based live-reload polling.
func IndexMtime(knowledgeDir string) int64 {
	indexPath := filepath.Join(knowledgeDir, "_followup_index.json")
	info, err := os.Stat(indexPath)
	if err != nil {
		return 0
	}
	return info.ModTime().UnixNano()
}

// IndexLoadedMsg carries a freshly-loaded slice of follow-up items.
// Sent by LoadIndexCmd and handled by the parent model to update ListModel.
type IndexLoadedMsg struct {
	Items []FollowUpItem
	Err   error
}

// ListDismissedMsg is sent by ListModel when the user presses Esc.
// The parent model (main.go) handles it to return to stateWork.
type ListDismissedMsg struct{}

// PromoteRequestMsg is sent when the user requests promoting a follow-up to a work item.
type PromoteRequestMsg struct {
	ID string
}

// DismissRequestMsg is sent when the user requests dismissing a follow-up.
type DismissRequestMsg struct {
	ID string
}

// ActionCompleteMsg is sent after promote-followup.sh or dismiss-followup.sh finishes.
type ActionCompleteMsg struct {
	// ID is the follow-up that was acted on.
	ID string
	// Action is "promote" or "dismiss".
	Action string
	// Err is non-nil if the subprocess failed.
	Err error
}

// FollowupChatRequestMsg is sent when the user presses c on a follow-up in the right panel.
// The handler in main.go uses these fields to build the specConfirm modal and seed the chat.
type FollowupChatRequestMsg struct {
	ID             string
	Title          string
	Source         string
	FindingExcerpt string
}

// LoadIndexCmd returns a Cmd that reads _followup_index.json and sends IndexLoadedMsg.
// Loads all statuses so that client-side filter cycling (open/reviewed/all) works
// without re-fetching.
func LoadIndexCmd(knowledgeDir string) tea.Cmd {
	return func() tea.Msg {
		items, err := LoadIndex(knowledgeDir, StatusAll)
		return IndexLoadedMsg{Items: items, Err: err}
	}
}
