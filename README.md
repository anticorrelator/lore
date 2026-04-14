# lore

A per-project knowledge store for [Claude Code](https://claude.ai/claude-code). Captures, organizes, and retrieves reusable insights across sessions.

## What it does

- **Captures** non-obvious, reusable insights during coding sessions — automatically via hooks and manually via skills
- **Organizes** them into searchable categories (principles, architecture, conventions, workflows, gotchas, abstractions)
- **Retrieves** relevant context at session start via hooks, and on-demand via skills and search
- **Tracks** work items, specs, and conversational threads across sessions
- **Reviews** PRs with knowledge-enriched analysis across multiple review lenses
- **Coordinates** multi-agent teams for spec creation and implementation

## Architecture

Lore separates **logic** (this repo) from **data** (`~/.lore/`):

```
<this repo>/                    # Logic (shareable, installable)
├── cli/lore                    # CLI dispatcher
├── scripts/                    # Hooks, search, indexing, utilities (~68 scripts)
├── skills/                     # Claude Code skill definitions (19 skills)
├── agents/                     # Agent definitions for team workflows (6 agents)
├── claude-md/                  # CLAUDE.md protocol fragments (9 numbered files)
├── tui/                        # Terminal UI (Go) — interactive dashboard
├── tests/                      # pytest + bash test suite
├── install.sh                  # Setup script
└── SELF_TEST.md                # System evaluation protocol reference

~/.lore/                        # Data (per-user, persists independently)
├── scripts -> <this repo>/scripts/   # Stable symlink
├── claude-md -> <this repo>/claude-md/  # Protocol fragment symlink
└── repos/                      # Per-project knowledge stores
    └── github.com/<org>/<repo>/
        ├── _manifest.json      # Entry metadata, keywords, backlinks
        ├── _index.md           # Dynamic knowledge index
        ├── _inbox.md, _inbox/  # Capture inbox
        ├── principles/         # Core design principles
        ├── architecture/       # System structure and patterns
        ├── conventions/        # Cross-cutting conventions
        ├── workflows/          # Operational procedures
        ├── gotchas/            # Pitfalls and non-obvious behaviors
        ├── abstractions/       # Key abstractions and models
        ├── domains/            # Domain-specific knowledge (lazy-loaded)
        ├── _threads/           # Conversational threads (pinned/active/dormant)
        ├── _work/              # Work items, specs, and plans
        ├── _meta/              # Analysis reports (staleness, usage)
        ├── _pending_captures/  # Novel insights from previous session (auto-populated)
        └── _capture_log.csv    # Capture activity log
```

The `~/.lore/scripts/` symlink is the portability layer — hooks reference it directly, while skills and agents use the `lore` CLI. If the logic repo moves, re-run `install.sh` to update the symlink and CLI.

## Prerequisites

- **Python 3** — required for search, indexing, analysis, and hooks
- **Bash** — scripts and CLI
- **Claude Code** — the host environment (skills, hooks, agents)
- **Go** (optional) — for building the TUI dashboard. Install skipped if `go` is not on PATH.

## Install

```bash
git clone git@github.com:anticorrelator/lore.git
cd lore
bash install.sh
```

This will:
1. Create `~/.lore/` data directory
2. Symlink `scripts/` and `claude-md/` into `~/.lore/`
3. Install the `lore` CLI to `~/.local/bin/`
4. Build and install the TUI (`lore-tui`) if Go is available
5. Symlink skills into `~/.claude/skills/`
6. Symlink agents into `~/.claude/agents/`
7. Configure hooks in `~/.claude/settings.json`
8. Assemble `~/.claude/CLAUDE.md` from protocol fragments

If `~/.local/bin` is not on your PATH, the installer will print instructions to add it.

### Dry run

Preview what the installer would do without making changes:

```bash
bash install.sh --dry-run
```

### Configuration

Set `LORE_DATA_DIR` to use a custom data directory (default: `~/.lore`):

```bash
export LORE_DATA_DIR=/path/to/data
bash install.sh
```

### Uninstall

```bash
bash install.sh --uninstall
```

Removes symlinks, hooks, CLI, and TUI binary. Data at `~/.lore/` is preserved.

## TUI

Running `lore` with no arguments launches an interactive terminal dashboard:

```bash
lore                             # Opens the TUI
```

The TUI provides an overview of active work items, knowledge store status, and quick access to common operations. Requires Go to build (handled automatically by `install.sh`). Rebuild manually with `lore rebuild`.

## CLI

The `lore` command is the primary interface for scripts and skills:

```bash
# Knowledge
lore search "query"              # Search knowledge and work items
lore search "query" --type work  # Search work items only
lore capture --insight "..."     # Capture insight to knowledge store
lore resolve                     # Print knowledge directory path
lore resolve "[[backlink]]"      # Resolve backlink references
lore prefetch "topic"            # Prefetch knowledge for agent prompts
lore read file.py --query "..."  # Read a file with optional query filtering
lore index                       # Show dynamic knowledge index
lore init                        # Initialize a knowledge store for current repo
lore heal                        # Detect and repair structural issues
lore stats                       # Show index statistics
lore status                      # Knowledge store health summary
lore check-links                 # Scan for broken backlink references
lore annotate                    # Record a retrieval friction annotation

# Work items
lore work list                   # List active work items
lore work create --title "name"  # Create a work item
lore work show "slug"            # Show work item details
lore work set "slug" --pr 123    # Set metadata (issue, pr) on a work item
lore work archive "slug"         # Archive completed work item
lore work unarchive "slug"       # Restore an archived work item
lore work search "query"         # Search across work items
lore work tasks "slug"           # Generate tasks from plan.md
lore work load-tasks "slug"      # Validate and output tasks (for /implement)
lore work regen-tasks "slug"     # Regenerate tasks.json from plan.md
lore work check "slug" "task"    # Check off a plan task
lore work heal                   # Repair work structure
lore work ai "description"       # Create work items from natural language

# Analysis
lore analyze staleness           # Scan entries for staleness
lore analyze usage               # Analyze entry access patterns
lore analyze concordance         # TF-IDF similarity computation
lore analyze merge-candidates    # Find entries worth merging

# Threads
lore thread list                 # List conversational threads
lore thread init                 # Initialize _threads/ directory
lore thread reindex              # Regenerate thread index

# Maintenance
lore curate                      # Pre-scan for curation issues
lore assemble                    # Reassemble CLAUDE.md from fragments
lore bootstrap scope             # Analyze codebase structure
lore manifest update             # Regenerate _manifest.json
lore backlinks generate          # Generate see-also backlinks from concordance
lore journal                     # Effectiveness journal
lore migrate knowledge           # Migrate to file-per-entry format
lore migrate threads             # Migrate to directory-per-entry threads
lore rebuild                     # Rebuild and reinstall the TUI binary

# Batch operations
lore batch-spec                  # Batch-run /spec short on eligible work items
lore batch-implement             # Batch-run /implement on ready work items

# Agent toggle
lore agent status                # Show enabled/disabled state and last-changed time
lore agent enable                # Enable lore agent integration (default)
lore agent disable               # Disable lore agent integration across all surfaces
```

Run `lore --help` or `lore <command> --help` for full details.

## Agent toggle (opencode coexistence)

`lore agent enable/disable` gives you a first-class way to turn lore's agent-facing activation on and off without uninstalling. This is especially useful when running opencode alongside Claude Code — lore's hooks are invisible to opencode, but skill symlinks and `CLAUDE.md` content are shared.

### What `lore agent disable` does

- Clears the lore region in `~/.claude/CLAUDE.md` (preserves any surrounding user content via `<!-- LORE:BEGIN -->`/`<!-- LORE:END -->` sentinels)
- Removes lore-owned skill symlinks from `~/.claude/skills/` and agent symlinks from `~/.claude/agents/` (saves a manifest for clean restore)
- Adds an early-exit gate in runtime hooks so lore no-ops in Claude Code sessions
- State is persisted in `~/.lore/config/agent.json`

### What `lore agent enable` does

The symmetric inverse: restores symlinks from the saved manifest, re-assembles `CLAUDE.md` with lore content, and removes the runtime gate.

### Per-session override

For a single shell session without changing global state:

```bash
LORE_AGENT_DISABLED=1 lore agent status   # shows "disabled (env override)"
```

This is useful for running opencode in a terminal while keeping lore active for Claude Code in another session.

### Worked example: opencode coexistence

```bash
# Disable lore for all frameworks (opencode sessions will no longer see lore)
lore agent disable

# Verify
lore agent status    # → disabled (config)
lore doctor          # → agent: disabled (config), all checks healthy

# Use opencode — no lore content in CLAUDE.md, no lore skills visible

# Re-enable for Claude Code
lore agent enable
lore agent status    # → enabled
```

> **Note:** The `lore` CLI itself is always available after disabling — you can always run `lore agent enable` to restore.

## Skills

### Core workflow

| Skill | Description |
|-------|-------------|
| `/work` | Create, resume, update, archive, search work items |
| `/spec` | Technical specifications — full team investigation or `/spec short` single-pass |
| `/implement` | Execute a spec's plan with a knowledge-aware agent team |
| `/remember` | Capture insights to knowledge store, update threads |
| `/memory` | Organize, search, view, curate, heal knowledge store |

### Code review

| Skill | Description |
|-------|-------------|
| `/pr-review` | Holistic multi-lens PR review with adaptive lens selection |
| `/pr-self-review` | Author-calibrated self-review before submitting |
| `/pr-pair-review` | Interactive pair-review with turn-based protocol |
| `/pr-revise` | Read PR feedback and create a work item to address it |
| `/pr-correctness` | Focused lens: trace logic paths for correctness bugs |
| `/pr-security` | Focused lens: evaluate security vulnerabilities and edge cases |
| `/pr-blast-radius` | Focused lens: trace impact of changes on code outside the diff |
| `/pr-regressions` | Focused lens: detect capability loss from deletions/modifications |
| `/pr-test-quality` | Focused lens: evaluate test coverage and assertion rigor |
| `/pr-thematic` | Focused lens: evaluate thematic coherence and scope |

### System health

| Skill | Description |
|-------|-------------|
| `/self-test` | Evaluate system health across 8 dimensions with scored results |
| `/retro` | Post-work-cycle retrospective — scores 5 dimensions, writes journal entry |
| `/renormalize` | Full knowledge store normalization — prune, merge, rebalance |
| `/bootstrap` | Explore a new codebase and seed initial knowledge |

## Agents

Agent definitions in `agents/` are symlinked to `~/.claude/agents/` during install. They power the multi-agent workflows used by `/spec` and `/implement`:

| Agent | Role |
|-------|------|
| `worker` | Executes implementation tasks with knowledge-aware context |
| `advisor` | Provides architectural guidance to workers |
| `researcher` | Investigates codebase areas during spec creation |
| `classifier` | Categorizes and routes knowledge entries |
| `crossref-scout` | Finds cross-references and related patterns |
| `structure-analyst` | Analyzes codebase structure for bootstrapping |

## Hooks

Lore installs Claude Code hooks that run automatically:

**SessionStart** — load context for each new session:
- `auto-reindex.sh` — regenerate index if stale
- `load-knowledge.sh` — load priority knowledge entries within token budget
- `load-work.sh` — surface active work items and branch-matched context
- `load-threads.sh` — load pinned/active thread summaries
- `extract-session-digest.py` — extract highlights from previous session for thread updates

**Stop** — capture and persist at session end:
- `stop-novelty-check.py` — detect novel insights, populate `_pending_captures/`
- `check-plan-persistence.py` — warn if ephemeral plans weren't persisted to `_work/`

**PreCompact / SessionEnd** — prepare for context compression:
- `pre-compact.sh` — save state before compaction

**TaskCompleted** — react to completed agent tasks:
- `task-completed-capture-check.sh` — check if task output contains capturable insights

## Protocol fragments

The `claude-md/` directory contains numbered protocol fragments that assemble into `~/.claude/CLAUDE.md`:

| Fragment | Purpose |
|----------|---------|
| `00-header.md` | Knowledge store protocol header |
| `10-capture-protocol.md` | Capture rules, triggers, and 4-condition gate |
| `15-agent-knowledge.md` | Agent knowledge guidance (spawning and running as agent) |
| `20-retrieval-protocol.md` | Knowledge and work retrieval patterns |
| `30-organization-protocol.md` | Organization, curation triggers |
| `40-self-healing.md` | Self-healing mechanisms |
| `50-work-protocol.md` | Work item lifecycle and persistence |
| `60-thread-protocol.md` | Conversational thread management (pinned/active/dormant tiers) |
| `70-review-protocol.md` | Shared review protocol for all PR review skills |

Run `lore assemble` to rebuild `CLAUDE.md` after editing fragments.

## Tests

```bash
python3 -m pytest tests/          # Python tests (search, concordance, tasks, staleness, etc.)
bash tests/test_capture.sh        # Bash integration tests (run individually)
```

## Typical workflow

### Starting a new feature

```
> /work create "add rate limiting to API"
```

This creates a work item in `_work/add-rate-limiting-to-api/` with metadata and a notes file. From here you can go straight to implementation or create a spec first.

### Creating a spec

```
> /spec short add-rate-limiting-to-api
```

Generates a single-pass technical plan with implementation steps, written to `plan.md` in the work item directory. For larger features, use `/spec` (without `short`) to run a full team-based investigation with researcher agents.

### Implementing from a spec

```
> /implement add-rate-limiting-to-api
```

Reads the plan, generates phased tasks, and spawns a team of worker agents to execute them in parallel. Workers have access to the knowledge store and coordinate through an advisor agent. Progress is tracked automatically.

### Capturing knowledge

Knowledge capture happens automatically — hooks detect novel insights at session end and queue them for review at the next session start. You can also capture manually at any time:

```
> /remember
```

This reviews the current conversation for uncaptured insights and persists them. Individual captures can also be done via CLI:

```bash
lore capture --insight "Rate limiter uses sliding window, not fixed window — \
  fixed window causes burst spikes at boundaries" \
  --category "gotchas" --confidence "high"
```

### Searching knowledge

Before exploring the codebase, check the knowledge store first:

```bash
lore search "rate limiting"
```

Within Claude Code, the knowledge store is searched automatically before grep/glob exploration. You can also use the skill:

```
> /memory search rate limiting
```

### Reviewing a PR

```
> /pr-review 142
```

Runs a multi-lens review (correctness, security, blast radius, test quality, regressions, thematic coherence) on the PR, enriched with knowledge store context. For focused analysis, use an individual lens like `/pr-security 142`.

After receiving review feedback on your own PR:

```
> /pr-revise 142
```

Reads all comments and creates a categorized work item to address them.

### Session continuity

Lore maintains context across sessions automatically:

1. **Knowledge** — insights captured in one session are available in all future sessions
2. **Work items** — `/work` tracks status, plans, and progress across sessions
3. **Threads** — conversational topics (design discussions, preferences) persist and evolve
4. **Hooks** — session start hooks load relevant context; session end hooks capture new insights

When you return to a project, run `/work` to see where things stand.

### System maintenance

```
> /self-test              # Score system health across 8 dimensions
> /retro                  # Post-work retrospective with journal entry
> /memory curate          # Deduplicate, prune stale entries, fix backlinks
> /renormalize            # Full knowledge store normalization
```

```bash
lore status               # Quick health summary
lore analyze staleness    # Find entries that may need updating
lore analyze usage        # See which entries are actually being retrieved
```
