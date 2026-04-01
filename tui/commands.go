package main

import (
	"context"
	"encoding/json"
	"os/exec"
	"strings"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/gh"
	"github.com/anticorrelator/lore/tui/internal/search"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// workAIFinishedMsg is sent after lore work ai returns.
type workAIFinishedMsg struct{}

// aiTickMsg drives the loading-dots animation while aiLoading is true.
type aiTickMsg struct{}

func aiTick() tea.Cmd {
	return tea.Tick(400*time.Millisecond, func(time.Time) tea.Msg { return aiTickMsg{} })
}

// popupSearchResultMsg carries results from a debounced popup search subprocess.
type popupSearchResultMsg struct {
	items []search.PopupItem
	query string
}

type workItemsLoadedMsg struct {
	items []work.WorkItem
	err   error
}

type prStatusLoadedMsg struct {
	statuses map[string]gh.PRStatus
	err      error
}

// activeSessionsCheckedMsg carries all non-stale sessions discovered on disk.
type activeSessionsCheckedMsg struct {
	sessions map[string]work.SessionInfo
}

// listActiveSessions returns a Cmd that reads all session lock files and sends activeSessionsCheckedMsg.
func listActiveSessions(workDir string) tea.Cmd {
	return func() tea.Msg {
		return activeSessionsCheckedMsg{sessions: work.ListActiveSessions(workDir)}
	}
}

func loadWorkItems(workDir string) tea.Cmd {
	return func() tea.Msg {
		items, err := work.LoadIndex(workDir)
		return workItemsLoadedMsg{items: items, err: err}
	}
}

func loadPRStatus() tea.Cmd {
	return func() tea.Msg {
		statuses, err := gh.LoadPRStatus(context.Background())
		return prStatusLoadedMsg{statuses: statuses, err: err}
	}
}

// runWorkAI runs lore work ai headlessly and returns workAIFinishedMsg when done.
func runWorkAI(ctx context.Context, prompt string) tea.Cmd {
	return func() tea.Msg {
		cmd := exec.CommandContext(ctx, "lore", "work", "ai", prompt)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		cmd.Run()
		return workAIFinishedMsg{}
	}
}

// runArchive runs lore work archive (or unarchive) and returns ArchiveFinishedMsg when done.
func runArchive(slug string, unarchive bool) tea.Cmd {
	return func() tea.Msg {
		subcmd := "archive"
		if unarchive {
			subcmd = "unarchive"
		}
		cmd := exec.Command("lore", "work", subcmd, slug)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		err := cmd.Run()
		return work.ArchiveFinishedMsg{Err: err}
	}
}

// runPromoteFollowUp runs lore followup promote and returns ActionCompleteMsg when done.
func runPromoteFollowUp(id string) tea.Cmd {
	return func() tea.Msg {
		cmd := exec.Command("lore", "followup", "promote", "--followup-id", id)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		err := cmd.Run()
		return followup.ActionCompleteMsg{ID: id, Action: "promote", Err: err}
	}
}

// runDismissFollowUp runs lore followup dismiss and returns ActionCompleteMsg when done.
func runDismissFollowUp(id string) tea.Cmd {
	return func() tea.Msg {
		cmd := exec.Command("lore", "followup", "dismiss", "--followup-id", id)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		err := cmd.Run()
		return followup.ActionCompleteMsg{ID: id, Action: "dismiss", Err: err}
	}
}

// runDelete runs lore work delete and returns DeleteFinishedMsg when done.
func runDelete(slug string) tea.Cmd {
	return func() tea.Msg {
		cmd := exec.Command("lore", "work", "delete", slug)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		err := cmd.Run()
		return work.DeleteFinishedMsg{Err: err}
	}
}

// buildWorkItemPopupItems converts work items into popup items for the search overlay.
func buildWorkItemPopupItems(items []work.WorkItem) []search.PopupItem {
	result := make([]search.PopupItem, len(items))
	for i, item := range items {
		result[i] = search.PopupItem{
			ID:       item.Slug,
			Label:    item.Title,
			Subtitle: item.Slug,
		}
	}
	return result
}

// buildFollowupPopupItems converts follow-up items into popup items for the search overlay.
func buildFollowupPopupItems(items []followup.FollowUpItem) []search.PopupItem {
	result := make([]search.PopupItem, len(items))
	for i, item := range items {
		label := item.Title
		if label == "" {
			label = item.ID
		}
		result[i] = search.PopupItem{
			ID:       item.ID,
			Label:    label,
			Subtitle: item.Severity + " · " + item.Source,
		}
	}
	return result
}

// runPopupSearch executes `lore work search <query> --json` and converts results to PopupItems.
func runPopupSearch(query string) tea.Msg {
	cmd := exec.Command("lore", "work", "search", query, "--json")
	out, err := cmd.Output()
	if err != nil {
		return popupSearchResultMsg{query: query}
	}
	var results []search.SearchResult
	if err := json.Unmarshal(out, &results); err != nil {
		return popupSearchResultMsg{query: query}
	}
	items := make([]search.PopupItem, len(results))
	for i, r := range results {
		slug := r.Slug
		if slug == "" {
			// Extract from path as fallback.
			parts := strings.Split(r.Path, "/")
			for j, p := range parts {
				if p == "_work" && j+1 < len(parts) {
					slug = parts[j+1]
					break
				}
			}
		}
		label := r.Heading
		if label == "" {
			label = slug
		}
		items[i] = search.PopupItem{
			ID:       slug,
			Label:    label,
			Subtitle: r.Category,
		}
	}
	return popupSearchResultMsg{items: items, query: query}
}
