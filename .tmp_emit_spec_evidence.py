import json
import pathlib
import subprocess

ROOT = pathlib.Path("/Users/dustinqngo/work/lore")
KDIR = pathlib.Path(subprocess.check_output(["lore", "resolve"], text=True).strip())
GOMOD = pathlib.Path(subprocess.check_output(["go", "env", "GOMODCACHE"], text=True).strip())
SHA = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
SLUG = "restore-embedded-terminal-visual-fidelity"

def p(rel):
    return ROOT / rel

def k(rel):
    return KDIR / rel

defs = [
    # External-skill applicability assertions.
    ("ext-browser", pathlib.Path("/Users/dustinqngo/.codex/plugins/cache/openai-bundled/browser/26.707.30751/skills/control-in-app-browser/SKILL.md"), 2, 3, "The Browser skill targets browser-page interaction rather than native terminal cell rendering.", "The embedded session becomes a browser-rendered target with faithful terminal cell metadata.", "Excludes a wrong-surface external advisor."),
    ("ext-visualize", pathlib.Path("/Users/dustinqngo/.codex/plugins/cache/openai-bundled/visualize/1.0.11/skills/visualize/SKILL.md"), 8, 11, "The Visualize skill creates explanatory conversation artifacts rather than native terminal fixtures.", "The implementation deliverable becomes an explanatory interactive visualization.", "Excludes a wrong-surface external advisor."),
    ("ext-system-design", pathlib.Path("/Users/dustinqngo/.codex/plugins/cache/openai-curated-remote/openai-templates/0.1.0/skills/artifact-template-system-design/agents/openai.yaml"), 6, 7, "The System Design artifact template disallows implicit invocation.", "The user explicitly invokes the retained system-design artifact template.", "Prevents repurposing an artifact template for the repository plan."),
    ("ext-openai-docs", pathlib.Path("/Users/dustinqngo/.codex/skills/.system/openai-docs/SKILL.md"), 41, 43, "OpenAI Docs directs generic software work to be handled directly.", "The design turns on current OpenAI product behavior rather than repository code.", "Excludes documentation lookup solely because the hosted harness is Codex."),
    ("ext-imagegen", pathlib.Path("/Users/dustinqngo/.codex/skills/.system/imagegen/SKILL.md"), 2, 3, "Imagegen is for bitmap assets rather than repo-native terminal code.", "The requested implementation expands to a generated bitmap asset.", "Excludes an irrelevant visual-content skill."),

    # Preference/convention assertions.
    ("pref-file-ownership", k("principles/lore-coordination-system-is-four-layers.md"), 2, 2, "Coordination is constrained by sole-writer file ownership and source sequencing.", "The current coordination contract authorizes concurrent writers to one source file.", "Makes the collision declaration operational."),
    ("pref-faint-classification", k("gotchas/screen-scrape-observability-must-classify-harness.md"), 2, 2, "Faint styling participates in shared harness-screen classification.", "Current classifiers no longer inspect faint or share the classification seam.", "Requires visual styling changes to preserve observer inputs."),
    ("pref-backend-seam", k("architecture/tui-terminal-backend-seam-specpanelmodel-owns-pty.md"), 2, 2, "Emulator-shaped behavior belongs behind the Ghostty backend seam.", "Current architecture moves emulator translation into the root view.", "Locates cell and cursor extraction in the backend."),
    ("pref-lipgloss-reset", k("conventions/in-lipgloss-v2-rendering-background-styled-row-aro.md"), 2, 2, "Nested styled spans can clear an outer Lipgloss background at an inner reset.", "A current Lipgloss reproduction preserves the outer background without reapplication.", "Keeps outer composition as a localization checkpoint."),
    ("pref-visual-stack", k("conventions/tui-s-visual-verification-stack-is-two-tier-headle.md"), 2, 2, "TUI visual verification uses deterministic headless rendering plus live tmux capture.", "The current stack no longer emits ANSI headlessly or has an authoritative replacement.", "Defines deterministic and live acceptance responsibilities."),
    ("pref-headless-parity", k("conventions/headless-view-viewcontent-tier-renders-per-cell-co.md"), 2, 2, "Headless and live rendering have demonstrated per-cell attribute parity for identical model state.", "A current identical-state cell differs between the two paths.", "Supports headless parsed-cell assertions."),
    ("pref-stable-probe", k("conventions/contract-tests-converted-pty-probe-recordings-fail.md"), 2, 2, "Live PTY assertions require precise structural locators and explicit state preconditions.", "Broad viewport grep remains stable across repeated current harness runs.", "Shapes the live composer parity witness."),
    ("pref-task-path-ownership", k("conventions/in-plan-md-task-lines-name-non-edited-files-in.md"), 2, 2, "Backticked path mentions in task lines become generated ownership dependencies.", "Task generation now distinguishes read-only backticked paths.", "Requires an exact task edit set."),
    ("pref-live-steering", k("preferences/operator-s-mid-coordination-questions-are-live-coo.md"), 2, 2, "Operator steering during coordination immediately changes queued and running contracts.", "The operator preference is superseded by advisory-only treatment.", "Makes the July sequencing guidance binding."),
    ("pref-fixture-survives", k("conventions/design-exploration-probe-test-suites-that-pin-brok.md"), 2, 2, "State-construction fixtures should survive after the failing expectation turns green.", "The repair necessarily replaces the fixture's state model.", "Keeps the localization fixture as durable acceptance coverage."),

    # Background localization assertions.
    ("bg-styled-trailing-blanks", p("tui/internal/work/backend_ghostty.go"), 370, 383, "The adapter trims only zero-style trailing blanks and retains styled trailing cells.", "A later unconditional trim removes a non-zero-style blank.", "Composer backgrounds commonly extend across blank cells."),
    ("bg-attribute-sgr", p("tui/internal/work/backend_ghostty.go"), 404, 432, "The cell emitter maps faint, inverse, and RGB background to SGR.", "Fixture source cells contain the attributes but reparsed backend cells do not.", "Rules out a generic absence of attribute-emission code."),
    ("bg-styleinto", p("tui/internal/work/backend_ghostty.go"), 335, 366, "Each iterated Ghostty cell is observed through StyleInto before grapheme handling.", "Target composer cells are skipped before style observation.", "Provides the direct pre-emission localization checkpoint."),
    ("bg-composition-clamp", p("tui/view.go"), 411, 433, "Outer composition conditionally truncates already-styled terminal rows and otherwise pads them.", "In-width rows are transformed by another unobserved composition layer.", "Provides the final-frame loss checkpoint."),
    ("bg-pty-sizing", p("tui/update.go"), 1602, 1613, "PTY width reserves the two terminal inset cells used by outer composition.", "Another sizing path leaves the backend at a different width.", "Explains why normal rows should avoid the overflow clamp."),
    ("bg-plain-rows", p("tui/internal/work/backend_ghostty.go"), 220, 249, "Plain readiness rows are rendered independently and trim trailing blanks.", "ScreenSnapshot rows become derived from styled ANSI output.", "Pins the byte-stability scope guard."),

    # Cursor integration assertions.
    ("cursor-readiness-contract", p("tui/internal/work/backend_ghostty.go"), 175, 194, "Readiness uses active-area cursor facts and independently produced plain rows and ANSI.", "Readiness already consumes render-state viewport cursor style or color.", "Supports a separate presentation cursor channel."),
    ("cursor-render-rows-only", p("tui/internal/work/backend_ghostty.go"), 144, 161, "The live backend render currently returns rows without cursor metadata.", "Another render path already returns frame cursor metadata.", "Localizes the missing cursor transport at the backend frame boundary."),
    ("cursor-update-cache", p("tui/internal/work/sessionpanel.go"), 687, 700, "SessionPanel refreshes backend-derived presentation during Update.", "View already mutates and retains backend state safely.", "Supports caching cursor metadata with rendered rows."),
    ("cursor-viewport-contract", GOMOD / "go.mitchellh.com/libghostty@v0.0.0-20260528200934-790a3ff6e9f6/render_state_data.go", 242, 300, "Libghostty distinguishes cursor visibility from viewport coordinate availability.", "Upstream guarantees viewport coordinates without CursorViewportHasValue.", "Defines the required visibility conjunction and coordinate source."),
    ("cursor-bubbletea-contract", GOMOD / "charm.land/bubbletea/v2@v2.0.7/tea.go", 356, 380, "Bubble Tea cursor metadata is frame-relative position plus color, shape, and blink.", "Bubble Tea changes Cursor to content-relative coordinates.", "Establishes root View as the attachment point."),
    ("cursor-shape-fallback", GOMOD / "charm.land/bubbletea/v2@v2.0.7/cursor.go", 11, 19, "Bubble Tea exposes block, underline, and bar cursor shapes but no hollow-block shape.", "The pinned version gains a hollow-block enum.", "Requires an explicit hollow-block fallback."),
    ("cursor-root-gap", p("tui/view.go"), 61, 65, "The root View currently never publishes Bubble Tea cursor metadata.", "A wrapper outside model.View mutates the returned View cursor.", "Confirms the frame-level cursor gap."),
    ("cursor-frame-origin", p("tui/view.go"), 406, 440, "The side-by-side compositor adds the terminal inset used in cursor coordinate translation.", "Framing uses a different terminal origin at implementation time.", "Grounds named and fixture-tested frame transforms."),

    # Fixture/collision assertions, retained with their producer identity even where they reinforce prior claims.
    ("fixture-plain-ansi-split", p("tui/internal/work/backend_ghostty.go"), 185, 194, "ScreenSnapshot plain rows and styled ANSI are independently produced.", "Rows are derived by stripping ANSI or mutate after rendering.", "Lets one fixture pin visual fidelity and unchanged readiness bytes."),
    ("fixture-direct-style", p("tui/internal/work/backend_ghostty.go"), 338, 346, "StyleInto provides a direct pre-emission cell-state checkpoint.", "StyleInto is unavailable per cell.", "Makes the localization fixture possible without production instrumentation."),
    ("fixture-emitter", p("tui/internal/work/backend_ghostty.go"), 370, 432, "The current adapter retains styled trailing cells and emits faint, inverse, and background attributes.", "The fixture disproves retention or emission despite source cell state.", "Requires evidence-led repair selection."),
    ("fixture-root-cursor-gap", p("tui/view.go"), 61, 65, "Root View does not assign cursor metadata.", "Current code assigns View.Cursor elsewhere.", "Confirms the cursor acceptance gap."),
    ("fixture-outer-checkpoint", p("tui/view.go"), 411, 433, "Terminal buffering, truncation, and padding form an outer-composition checkpoint.", "Composed cells cannot be observed after this layer.", "Pins the third localization boundary."),
    ("fixture-ghostty-cursor-api", GOMOD / "go.mitchellh.com/libghostty@v0.0.0-20260528200934-790a3ff6e9f6/render_state_data.go", 224, 300, "Libghostty exposes viewport cursor visibility, position, blink, style, and color inputs.", "The getters fail or never reflect terminal cursor state.", "Avoids raw cursor escape reconstruction."),
    ("fixture-bubbletea-cursor-api", GOMOD / "charm.land/bubbletea/v2@v2.0.7/tea.go", 356, 369, "Bubble Tea Cursor carries position, color, shape, and blink.", "The renderer ignores these fields in the pinned version.", "Provides matching frame-level output metadata."),
    ("fixture-sibling-collision", k("_work/prevent-tui-stderr-screen-corruption/plan.md"), 20, 31, "The sibling stderr-sweep plan owns root rendering and session-panel surfaces.", "The sibling plan changes its declared edit set before dispatch.", "Requires coordinator sequencing and motivates the minimized fidelity edit set."),
]

for claim_id, path, start, end, claim, falsifier, significance in defs:
    lines = path.read_text().splitlines()
    snippet = "\n".join(lines[start - 1:end])
    digest = subprocess.check_output(
        ["python3", str(pathlib.Path.home() / ".lore/scripts/snippet_normalize.py"), "--hash"],
        input=snippet + "\n", text=True,
    ).strip()
    row = {
        "claim_id": claim_id,
        "tier": "task-evidence",
        "claim": claim,
        "producer_role": "researcher",
        "protocol_slot": "Synthesis",
        "task_id": claim_id.split("-", 1)[0],
        "phase_id": "spec-investigation",
        "scale": "subsystem",
        "file": str(path),
        "line_range": f"{start}-{end}",
        "exact_snippet": snippet,
        "normalized_snippet_hash": digest,
        "falsifier": falsifier,
        "why_this_work_needs_it": significance,
        "captured_at_sha": SHA,
        "change_context": {
            "diff_ref": SHA,
            "changed_files": [str(path)],
            "summary": f"/spec investigation grounded {claim_id} for embedded terminal visual fidelity.",
        },
    }
    proc = subprocess.run(
        ["bash", str(ROOT / "scripts/evidence-append.sh"), "--work-item", SLUG],
        input=json.dumps(row), text=True, cwd=ROOT, capture_output=True,
    )
    if proc.returncode:
        raise SystemExit(f"{claim_id}: {proc.stderr or proc.stdout}")
    print(f"- **{claim_id}:** {claim} Source: `{path}:{start}-{end}`")
