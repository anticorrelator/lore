package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/anticorrelator/lore/tui/internal/followup"
	"github.com/anticorrelator/lore/tui/internal/gh"
	"github.com/anticorrelator/lore/tui/internal/search"
	"github.com/anticorrelator/lore/tui/internal/settlement"
	"github.com/anticorrelator/lore/tui/internal/work"
)

// initFinishedMsg is sent after the onboarding init scripts complete.
type initFinishedMsg struct {
	Err error
}

// doctorResultMsg carries the outcome of an async `lore doctor --quiet` run
// kicked off at TUI startup. Banner is the one-line drift summary from
// doctor's stdout when drift was detected; empty when clean, throttled, or
// the script could not be invoked. The TUI never blocks on this message —
// it merely surfaces the banner in the status bar.
type doctorResultMsg struct {
	banner string
}

// runDoctor invokes `bash ~/.lore/scripts/doctor.sh --quiet` and returns a
// doctorResultMsg. Throttling lives inside doctor.sh (24h marker file), so
// the TUI can call this on every Init without worry. When doctor exits
// non-zero it writes a one-line summary to stdout — we forward that string
// (trimmed) as the banner. When doctor exits zero or the script is missing,
// we return an empty banner and the status bar shows its normal hints.
func runDoctor() tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "bash", filepath.Join(os.Getenv("HOME"), ".lore/scripts/doctor.sh"), "--quiet")
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		out, err := cmd.Output()
		if err == nil {
			// Exit 0 — clean or throttled. Nothing to surface.
			return doctorResultMsg{}
		}
		// Exit non-zero. doctor.sh --quiet prints a one-line summary to
		// stdout in this branch. If stdout is empty (e.g. script missing,
		// permission error, timeout), leave banner empty rather than
		// surface a misleading message.
		banner := strings.TrimSpace(string(out))
		// Keep only the first line — defensive against future doctor.sh
		// changes that may add follow-up lines like "agent: enabled".
		if i := strings.IndexByte(banner, '\n'); i >= 0 {
			banner = banner[:i]
		}
		return doctorResultMsg{banner: banner}
	}
}

// runInit runs init-repo.sh then init-work.sh sequentially, returning initFinishedMsg.
// Both scripts are idempotent; if init-repo fails, init-work is skipped.
func runInit(projectDir string) tea.Cmd {
	return func() tea.Msg {
		repoCmd := exec.Command("lore", "init")
		repoCmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		repoCmd.Dir = projectDir
		if err := repoCmd.Run(); err != nil {
			return initFinishedMsg{Err: err}
		}

		workCmd := exec.Command("lore", "init-work")
		workCmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		workCmd.Dir = projectDir
		if err := workCmd.Run(); err != nil {
			return initFinishedMsg{Err: err}
		}

		return initFinishedMsg{}
	}
}

// workAIFinishedMsg is sent after lore work ai returns.
type workAIFinishedMsg struct {
	Err    error
	Output string
}

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

type settlementStatusLoadedMsg struct {
	status settlement.Status
	err    error
	output string
}

type settlementActionCompleteMsg struct {
	action    string
	automatic bool
	result    settlement.ActionResult
	err       error
	output    string
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

func loadSettlementStatus() tea.Cmd {
	return func() tea.Msg {
		// Trigger pump: the event-driven enqueue surface (dispute detector,
		// spot-sample budget, rollup steady-state) runs on this status tick —
		// enqueue-only, self-throttled processor-side, best-effort here. This
		// replaces the retired census drivers as the thing that keeps the
		// queue fed; dispatch still goes through shouldAutoProcessSettlement
		// or manual process/drain.
		pumpCtx, pumpCancel := context.WithTimeout(context.Background(), 30*time.Second)
		pump := exec.CommandContext(pumpCtx, "lore", "settlement", "triggers", "--json")
		pump.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		_ = pump.Run()
		pumpCancel()

		cmd := exec.Command("lore", "settlement", "status", "--json")
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		out, err := cmd.CombinedOutput()
		if err != nil {
			return settlementStatusLoadedMsg{err: fmt.Errorf("%w: %s", err, strings.TrimSpace(string(out))), output: string(out)}
		}
		status, err := settlement.ParseStatus(out)
		return settlementStatusLoadedMsg{status: status, err: err, output: string(out)}
	}
}

func runSettlementAction(action string) tea.Cmd {
	return runSettlementActionWithMode(action, false)
}

func runAutomaticSettlementProcess() tea.Cmd {
	return runSettlementActionWithMode("process", true)
}

// settlementSubprocessTimeout caps how long the TUI will wait for a
// `lore settlement <action>` subprocess to return. It must comfortably
// exceed the executor budget (default executor_timeout_seconds=300 inside
// settlement-audit-executor.sh) plus typical setup/teardown overhead.
// If the subprocess hangs past this ceiling — e.g. a wedged `claude -p`
// invocation or a held flock — CommandContext cancels and kills it so
// the TUI's settlementProcessInFlight flag can be cleared and auto-process
// can resume. A separate model-level failsafe (settlementInFlightFailsafe
// in update.go) catches the rarer case where even the cancel can't free
// the goroutine.
const settlementSubprocessTimeout = 10 * time.Minute

func runSettlementActionWithMode(action string, automatic bool) tea.Cmd {
	return func() tea.Msg {
		args := []string{"settlement", action, "--json"}
		if action == "process" {
			args = []string{"settlement", "process", "--once", "--json"}
		}
		ctx, cancel := context.WithTimeout(context.Background(), settlementSubprocessTimeout)
		defer cancel()
		cmd := exec.CommandContext(ctx, "lore", args...)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		out, err := cmd.CombinedOutput()
		if ctx.Err() == context.DeadlineExceeded {
			return settlementActionCompleteMsg{
				action:    action,
				automatic: automatic,
				err:       fmt.Errorf("subprocess exceeded %s ceiling and was killed (output: %s)", settlementSubprocessTimeout, strings.TrimSpace(string(out))),
				output:    string(out),
			}
		}
		if err != nil {
			return settlementActionCompleteMsg{action: action, automatic: automatic, err: fmt.Errorf("%w: %s", err, strings.TrimSpace(string(out))), output: string(out)}
		}
		result, parseErr := settlement.ParseActionResult(action, out)
		return settlementActionCompleteMsg{action: action, automatic: automatic, result: result, err: parseErr, output: string(out)}
	}
}

// runWorkAI runs lore work ai headlessly and returns workAIFinishedMsg when done.
func runWorkAI(ctx context.Context, prompt string) tea.Cmd {
	return func() tea.Msg {
		cmd := exec.CommandContext(ctx, "lore", "work", "ai", prompt)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		out, err := cmd.CombinedOutput()
		return workAIFinishedMsg{Err: err, Output: string(out)}
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
// When findingsJSON is non-empty it is passed as --findings-json so the script
// can embed selected lens findings in the promoted work item's notes.md.
func runPromoteFollowUp(id, findingsJSON string) tea.Cmd {
	return func() tea.Msg {
		args := []string{"followup", "promote", "--followup-id", id}
		if findingsJSON != "" {
			args = append(args, "--findings-json", findingsJSON)
		}
		cmd := exec.Command("lore", args...)
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

// runMarkFollowUpReviewed sets a followup's status to "reviewed" and returns ActionCompleteMsg when done.
func runMarkFollowUpReviewed(id string) tea.Cmd {
	return func() tea.Msg {
		cmd := exec.Command("lore", "followup", "update", id, "--status", "reviewed")
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		err := cmd.Run()
		return followup.ActionCompleteMsg{ID: id, Action: "mark-reviewed", Err: err}
	}
}

// runDeleteFollowUp runs lore followup delete and returns ActionCompleteMsg when done.
func runDeleteFollowUp(id string) tea.Cmd {
	return func() tea.Msg {
		cmd := exec.Command("lore", "followup", "delete", "--followup-id", id)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		err := cmd.Run()
		return followup.ActionCompleteMsg{ID: id, Action: "delete", Err: err}
	}
}

// runPostReview runs post-proposed-review.sh and returns PostReviewCompleteMsg when done.
// Counts are read from the sidecar's last_post after a successful run — never trusted
// from the caller — because Phase 2 always writes last_post on successful POST.
func runPostReview(knowledgeDir, followupID string) tea.Cmd {
	return func() tea.Msg {
		cmd := exec.Command("lore", "followup", "post-review", followupID)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		var stderr strings.Builder
		cmd.Stderr = &stderr
		if err := cmd.Run(); err != nil {
			msg := strings.TrimSpace(stderr.String())
			if msg == "" {
				msg = err.Error()
			}
			return followup.PostReviewCompleteMsg{ID: followupID, Err: fmt.Errorf("%s", msg)}
		}
		itemDir, err := followup.ResolveDir(knowledgeDir, followupID)
		if err != nil {
			return followup.PostReviewCompleteMsg{ID: followupID, Err: fmt.Errorf("review posted, but failed to persist outcomes locally: %w", err)}
		}
		sidecarPath := filepath.Join(itemDir, "proposed-comments.json")
		data, err := os.ReadFile(sidecarPath)
		if err != nil {
			return followup.PostReviewCompleteMsg{ID: followupID, Err: fmt.Errorf("review posted, but failed to persist outcomes locally: %w", err)}
		}
		var review followup.ProposedReview
		if err := json.Unmarshal(data, &review); err != nil {
			return followup.PostReviewCompleteMsg{ID: followupID, Err: fmt.Errorf("review posted, but failed to persist outcomes locally: %w", err)}
		}
		if review.LastPost == nil {
			return followup.PostReviewCompleteMsg{ID: followupID, Err: fmt.Errorf("review posted, but last_post missing from sidecar — re-review to confirm counts")}
		}
		return followup.PostReviewCompleteMsg{
			ID:          followupID,
			PostedCount: review.LastPost.Posted,
			Dropped:     review.LastPost.Dropped,
			Shifted:     review.LastPost.Shifted,
			Renamed:     review.LastPost.Renamed,
			Appended:    review.LastPost.Appended,
		}
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
		result[i] = search.PopupItem{
			ID:       item.ID,
			Label:    item.ID,
			Subtitle: item.Source,
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
