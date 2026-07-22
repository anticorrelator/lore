package work

import (
	"math/rand"
	"regexp"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

var digestANSIRe = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func digestStrip(s string) string {
	return digestANSIRe.ReplaceAllString(s, "")
}

func sectionLabels(sections []digestSection) []string {
	labels := make([]string, len(sections))
	for i, s := range sections {
		labels[i] = s.label
	}
	return labels
}

func TestExtractDigestSectionsFixedOrder(t *testing.T) {
	// Sections appear scrambled in the document; extraction is canonical order.
	plan := `# Token refresh

## Architecture

Transport owns detection.

## Intent

Fix double-refresh.

## Story narrative

Two clients raced.
`
	sections := extractDigestSections(plan)
	want := []string{"Intent", "Narrative", "Architecture"}
	if got := sectionLabels(sections); strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("labels = %v, want %v", got, want)
	}
	if sections[0].body != "Fix double-refresh." {
		t.Errorf("Intent body = %q", sections[0].body)
	}
	if sections[2].body != "Transport owns detection." {
		t.Errorf("Architecture body = %q", sections[2].body)
	}
}

func TestExtractDigestSectionsSubsetAndAbsence(t *testing.T) {
	sections := extractDigestSections("# Plan\n\n## Narrative\n\nJust a story.\n")
	if got := sectionLabels(sections); len(got) != 1 || got[0] != "Narrative" {
		t.Fatalf("labels = %v, want [Narrative]", got)
	}

	if got := extractDigestSections("# Plan\n\nFreeform notes, no digest headings.\n"); len(got) != 0 {
		t.Fatalf("expected no sections, got %v", sectionLabels(got))
	}
}

func TestExtractDigestSectionsMatchingRules(t *testing.T) {
	// Case-insensitive substring match at any level; "diagram" maps to
	// Architecture; the first occurrence of a slot wins.
	plan := "#### DESIGN INTENT\n\nfirst intent\n\n## Intent\n\nsecond intent\n\n## Flow diagram\n\nboxes\n"
	sections := extractDigestSections(plan)
	if got := sectionLabels(sections); strings.Join(got, ",") != "Intent,Architecture" {
		t.Fatalf("labels = %v, want [Intent Architecture]", got)
	}
	if sections[0].body != "first intent" {
		t.Errorf("first occurrence should win: body = %q", sections[0].body)
	}
	if sections[1].body != "boxes" {
		t.Errorf("diagram body = %q", sections[1].body)
	}
}

func TestExtractDigestSectionsBodyExtent(t *testing.T) {
	// A section runs to the next heading at the same or higher level;
	// deeper headings stay inside the body.
	plan := "## Intent\n\ngoal\n\n### Sub-point\n\ndetail\n\n## Other\n\nnot digest\n"
	sections := extractDigestSections(plan)
	if len(sections) != 1 {
		t.Fatalf("sections = %v", sectionLabels(sections))
	}
	if !strings.Contains(sections[0].body, "### Sub-point") || !strings.Contains(sections[0].body, "detail") {
		t.Errorf("deeper heading not kept in body: %q", sections[0].body)
	}
	if strings.Contains(sections[0].body, "not digest") {
		t.Errorf("body ran past the terminating heading: %q", sections[0].body)
	}
}

func TestExtractDigestSectionsFencedHeadingsIgnored(t *testing.T) {
	plan := "```\n## Intent\nfenced, not a heading\n```\n\nprose\n"
	if got := extractDigestSections(plan); len(got) != 0 {
		t.Fatalf("fenced heading classified: %v", sectionLabels(got))
	}

	// Fences inside a section body do not terminate it early.
	plan = "## Intent\n\n```\n## Narrative\n```\n\nafter fence\n"
	sections := extractDigestSections(plan)
	if len(sections) != 1 || sections[0].label != "Intent" {
		t.Fatalf("sections = %v, want [Intent]", sectionLabels(sections))
	}
	if !strings.Contains(sections[0].body, "after fence") {
		t.Errorf("fenced pseudo-heading terminated the body: %q", sections[0].body)
	}
}

// digestVocab builds pseudo-random markdown documents for the property
// tests: plain prose, digest and non-digest headings, and fence delimiters.
func digestRandomDoc(r *rand.Rand, fenceAllKeywords bool) string {
	keywords := []string{"Intent", "narrative", "ARCHITECTURE", "Flow Diagram"}
	var lines []string
	for i, n := 0, 3+r.Intn(25); i < n; i++ {
		switch r.Intn(5) {
		case 0: // digest-keyword heading
			h := strings.Repeat("#", 1+r.Intn(4)) + " " + keywords[r.Intn(len(keywords))]
			if fenceAllKeywords {
				lines = append(lines, "```", h, "```")
			} else {
				lines = append(lines, h)
			}
		case 1: // non-digest heading
			lines = append(lines, "## Rollout plan")
		case 2:
			if !fenceAllKeywords {
				lines = append(lines, "```", "code line", "```")
			} else {
				lines = append(lines, "code line")
			}
		default:
			lines = append(lines, "prose line about the token refresh flow")
		}
	}
	return strings.Join(lines, "\n")
}

func TestExtractDigestPropertyNeverSynthesizes(t *testing.T) {
	r := rand.New(rand.NewSource(7))
	canonical := map[string]int{"Intent": 0, "Narrative": 1, "Architecture": 2}
	for trial := 0; trial < 500; trial++ {
		plan := digestRandomDoc(r, false)
		sections := extractDigestSections(plan)
		prev := -1
		for _, s := range sections {
			// Bodies are verbatim slices of the input — never synthesized.
			if s.body != "" && !strings.Contains(plan, s.body) {
				t.Fatalf("trial %d: body not a substring of the plan: %q", trial, s.body)
			}
			ord, ok := canonical[s.label]
			if !ok {
				t.Fatalf("trial %d: unknown label %q", trial, s.label)
			}
			// Canonical order, at most one section per slot.
			if ord <= prev {
				t.Fatalf("trial %d: labels out of order: %v", trial, sectionLabels(sections))
			}
			prev = ord
		}
		// Deterministic for identical input.
		again := extractDigestSections(plan)
		if len(again) != len(sections) {
			t.Fatalf("trial %d: non-deterministic extraction", trial)
		}
	}
}

func TestExtractDigestPropertyFencedNeverClassifies(t *testing.T) {
	r := rand.New(rand.NewSource(11))
	for trial := 0; trial < 500; trial++ {
		plan := digestRandomDoc(r, true)
		if got := extractDigestSections(plan); len(got) != 0 {
			t.Fatalf("trial %d: fenced keyword heading classified: %v\ndoc:\n%s",
				trial, sectionLabels(got), plan)
		}
	}
}

func TestRenderDigestDegradationLadder(t *testing.T) {
	plan := "## Intent\n\nFix the refresh flow.\n\n## Architecture\n\nBoxes and arrows.\n"
	d := &WorkItemDetail{
		Slug:        "token-refresh-hardening",
		Status:      "active",
		Updated:     "2026-07-01T10:00:00Z",
		PlanContent: &plan,
	}

	out := digestStrip(renderDigest(d, 60))
	firstLine := strings.SplitN(out, "\n", 2)[0]
	if !strings.Contains(firstLine, "token-refresh-hardening") {
		t.Errorf("first line must carry the full slug: %q", firstLine)
	}
	if !strings.Contains(firstLine, "● active") {
		t.Errorf("first line missing status badge: %q", firstLine)
	}
	iIdx, aIdx := strings.Index(out, " Intent "), strings.Index(out, " Architecture ")
	if iIdx < 0 || aIdx < 0 || iIdx > aIdx {
		t.Errorf("section rules missing or misordered: intent=%d architecture=%d\n%s", iIdx, aIdx, out)
	}
	if strings.Contains(out, "Narrative") {
		t.Errorf("absent section was synthesized:\n%s", out)
	}

	// Zero digest sections: dim notice plus the full rendered plan.
	loose := "# Loose notes\n\nNo digest headings here.\n"
	d.PlanContent = &loose
	out = digestStrip(renderDigest(d, 60))
	if !strings.Contains(out, "showing the full plan") {
		t.Errorf("degraded notice missing:\n%s", out)
	}
	if !strings.Contains(out, "No digest headings here.") {
		t.Errorf("full plan not shown in degraded mode:\n%s", out)
	}

	// No plan document at all.
	d.PlanContent = nil
	out = digestStrip(renderDigest(d, 60))
	if !strings.Contains(out, "No plan document — nothing to digest.") {
		t.Errorf("no-plan notice missing:\n%s", out)
	}
	if !strings.Contains(out, "token-refresh-hardening") {
		t.Errorf("identity line must render even without a plan:\n%s", out)
	}
}

// TestDetailModelLandsOnDigestTab replays loadDetail's message sequence
// headlessly: NewDetailModel, WindowSizeMsg, then a constructed
// DetailLoadedMsg — no I/O, since detail I/O lives only in Cmds.
func TestDetailModelLandsOnDigestTab(t *testing.T) {
	plan := "## Intent\n\nFix the refresh flow.\n\n## Narrative\n\nTwo clients raced.\n\n## Architecture\n\nTransport owns detection.\n"
	m := NewDetailModel("", "token-refresh-hardening")
	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 50})
	m, _ = m.Update(DetailLoadedMsg{
		Slug: "token-refresh-hardening",
		Detail: &WorkItemDetail{
			Slug:        "token-refresh-hardening",
			Title:       "Token refresh hardening",
			Status:      "active",
			Updated:     "2026-07-01T10:00:00Z",
			PlanContent: &plan,
		},
	})

	if m.ActiveTab() != TabDigest {
		t.Fatalf("landing tab = %v, want TabDigest", m.ActiveTab())
	}
	view := digestStrip(m.renderTabContent(m.contentWidth(), m.contentHeight()))
	firstLine := strings.SplitN(view, "\n", 2)[0]
	if !strings.Contains(firstLine, "token-refresh-hardening") {
		t.Errorf("digest first line missing full slug: %q", firstLine)
	}
	iIdx := strings.Index(view, " Intent ")
	nIdx := strings.Index(view, " Narrative ")
	aIdx := strings.Index(view, " Architecture ")
	if iIdx < 0 || nIdx < 0 || aIdx < 0 || !(iIdx < nIdx && nIdx < aIdx) {
		t.Errorf("sections missing or out of order: %d %d %d\n%s", iIdx, nIdx, aIdx, view)
	}

	// The digest tab is viewport-backed: scroll keys are consumed by it.
	if !m.digestTab.ready {
		t.Fatal("digest tab not viewport-backed after load")
	}
}

func TestDetailModelDigestFollowsPlanRefresh(t *testing.T) {
	plan := "## Intent\n\nOld intent.\n"
	m := NewDetailModel("", "slug-a")
	m, _ = m.Update(tea.WindowSizeMsg{Width: 100, Height: 50})
	m, _ = m.Update(DetailLoadedMsg{
		Slug:   "slug-a",
		Detail: &WorkItemDetail{Slug: "slug-a", Status: "active", PlanContent: &plan},
	})

	m, _ = m.Update(DetailPlanRefreshedMsg{Slug: "slug-a", Content: "## Intent\n\nNew intent.\n"})
	view := digestStrip(m.renderTabContent(m.contentWidth(), m.contentHeight()))
	if !strings.Contains(view, "New intent.") || strings.Contains(view, "Old intent.") {
		t.Errorf("digest did not follow plan refresh:\n%s", view)
	}
}

// TestDetailModelNarrowBarCollapsesExtraFiles pins the phase acceptance:
// with 5+ extra files at narrow width the bar collapses into "+N more"
// while tab-key cycling still reaches every tab.
func TestDetailModelNarrowBarCollapsesExtraFiles(t *testing.T) {
	plan := "## Intent\n\ngoal\n"
	m := NewDetailModel("", "slug-a")
	m, _ = m.Update(tea.WindowSizeMsg{Width: 50, Height: 40})
	m, _ = m.Update(DetailLoadedMsg{
		Slug: "slug-a",
		Detail: &WorkItemDetail{
			Slug: "slug-a", Status: "active", PlanContent: &plan,
			HasTasks: true, HasExecutionLog: true,
			ExtraFiles: []ExtraFile{
				{Name: "design", Content: "d"},
				{Name: "evidence", Content: "e"},
				{Name: "capture-notes", Content: "c"},
				{Name: "review-findings", Content: "r"},
				{Name: "spike-log", Content: "s"},
			},
		},
	})

	bar := digestStrip(m.renderTabBar())
	if !strings.Contains(bar, "more") {
		t.Fatalf("narrow bar did not collapse: %q", bar)
	}
	if w := len(bar); w > 50 {
		t.Errorf("bar width %d exceeds panel width 50: %q", w, bar)
	}

	total := len(m.tabHost.Tabs())
	seen := map[string]bool{}
	for i := 0; i < total; i++ {
		seen[m.tabHost.ActiveID()] = true
		if b := digestStrip(m.renderTabBar()); !strings.Contains(b, m.tabHost.Tabs()[m.tabHost.ActiveIndex()].Label) {
			t.Errorf("active tab %q not visible in bar: %q", m.tabHost.ActiveID(), b)
		}
		m, _ = m.Update(tea.KeyPressMsg{Code: tea.KeyTab})
	}
	if len(seen) != total {
		t.Fatalf("cycling reached %d of %d tabs", len(seen), total)
	}
}

// --- ExtractSection (generalized fence-aware section boundary) ---

func TestExtractSectionBasic(t *testing.T) {
	md := "# Ledger\n\n## Brief\n\nlanded: the thing\nsurprises: none\n\n## Rows\n\nrow one\n"
	body, found := ExtractSection(md, "Brief")
	if !found {
		t.Fatal("Brief section should be found")
	}
	if body != "landed: the thing\nsurprises: none" {
		t.Errorf("unexpected body: %q", body)
	}
}

func TestExtractSectionMissingIsNotAnError(t *testing.T) {
	if _, found := ExtractSection("# Ledger\n\n## Rows\n", "Brief"); found {
		t.Error("absent section must report found=false")
	}
}

func TestExtractSectionIgnoresHeadingsInsideFences(t *testing.T) {
	md := "```\n## Brief\nfake\n```\n\n## Brief\n\nreal body\n\n## Next\n"
	body, found := ExtractSection(md, "Brief")
	if !found || body != "real body" {
		t.Fatalf("fence-aware match failed: found=%v body=%q", found, body)
	}
	// A fenced heading inside the body must not terminate the section.
	md2 := "## Brief\n\nbefore\n```\n## Not A Boundary\n```\nafter\n\n## Next\n"
	body2, found2 := ExtractSection(md2, "Brief")
	if !found2 || !strings.Contains(body2, "after") {
		t.Fatalf("fenced heading terminated the section: %q", body2)
	}
}

func TestExtractSectionBoundaryIsEqualOrHigherLevel(t *testing.T) {
	md := "## Brief\n\nintro\n\n### Sub Facet\n\ndetail\n\n## Rows\n\nrow\n"
	body, found := ExtractSection(md, "Brief")
	if !found {
		t.Fatal("Brief section should be found")
	}
	if !strings.Contains(body, "Sub Facet") || strings.Contains(body, "Rows") {
		t.Errorf("lower-level headings belong to the section, equal-level ends it: %q", body)
	}
}
