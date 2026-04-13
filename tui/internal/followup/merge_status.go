package followup

import (
	"context"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/anticorrelator/lore/tui/internal/gh"
)

// FetchMergeStatusCmd returns a tea.Cmd that fetches the merge status for a
// specific PR via gh.LoadMergeStatus and emits a MergeStatusLoadedMsg.
// A 5-second timeout guards against gh calls that hang on network.
func FetchMergeStatusCmd(followupID string, requestSeq uint64, owner, repo string, pr int) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		status, err := gh.LoadMergeStatus(ctx, owner, repo, pr)
		return MergeStatusLoadedMsg{
			FollowupID: followupID,
			RequestSeq: requestSeq,
			Status:     status,
			Err:        err,
		}
	}
}
