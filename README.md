# lore

A per-project knowledge store for [Claude Code](https://claude.ai/claude-code). Captures, organizes, and retrieves reusable insights across sessions.

## What it does

- **Captures** non-obvious, reusable insights during coding sessions — automatically via hooks and manually via skills
- **Organizes** them into searchable categories (principles, architecture, conventions, workflows, gotchas, abstractions)
- **Retrieves** relevant context at session start via hooks, and on-demand via skills and search
- **Tracks** work items, specs, and conversational threads across sessions
- **Reviews** PRs with knowledge-enriched analysis across multiple review modes

## Architecture

Lore separates **logic** (this repo) from **data** (`~/.lore/`):

```
<this repo>/                    # Logic (shareable, installable)
├── cli/lore                    # CLI dispatcher
├── scripts/                    # Hooks, search, indexing, utilities (~58 scripts)
├── skills/                     # Claude Code skill definitions (13 skills)
├── claude-md/                  # CLAUDE.md protocol fragments (9 numbered files)
├── tests/                      # pytest + bash test suite
├── install.sh                  # Setup script
└── SELF_TEST.md                # System evaluation protocol reference

~/.lore/                        # Data (per-user, persists independently)
├── scripts -> <this repo>/scripts/   # Stable symlink
└── repos/                      # Per-project knowledge stores
    └── github.com/<org>/<repo>/
        ├── _manifest.json      # Entry metadata, keywords, backlinks
        ├── _index.md            # Dynamic knowledge index
        ├── _inbox.md, _inbox/   # Capture inbox
        ├── principles/          # Core design principles
        ├── architecture/        # System structure and patterns
        ├── conventions/         # Cross-cutting conventions
        ├── workflows/           # Operational procedures
        ├── gotchas/             # Pitfalls and non-obvious behaviors
        ├── abstractions/        # Key abstractions and models
        ├── domains/             # Domain-specific knowledge (lazy-loaded)
        ├── _threads/            # Conversational threads (pinned/active/dormant)
        ├── _work/               # Work items, specs, and plans
        ├── _meta/               # Analysis reports (staleness, usage)
        ├── _pending_captures/   # Novel insights from previous session (auto-populated)
        └── _capture_log.csv     # Capture activity log
```

The `~/.lore/scripts/` symlink is the portability layer — hooks reference it directly, while skills and agents use the `lore` CLI. If the logic repo moves, re-run `install.sh` to update the symlink and CLI.

## Install

```bash
git clone git@github.com:anticorrelator/lore.git
cd lore
bash install.sh
```

This creates `~/.lore/`, symlinks skills into `~/.claude/skills/`, configures hooks in `~/.claude/settings.json`, and assembles `~/.claude/CLAUDE.md` from protocol fragments.

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

Removes symlinks and hooks. Data at `~/.lore/` is preserved.

## CLI

The `lore` command is the primary interface for scripts and skills:

```bash
# Knowledge
lore search "query"              # Search knowledge and work items
lore capture --insight "..."     # Capture insight to knowledge store
lore resolve                     # Print knowledge directory path
lore resolve "[[backlink]]"      # Resolve backlink references
lore prefetch "topic"            # Prefetch knowledge for agent prompts
lore index                       # Show dynamic knowledge index
lore heal                        # Detect and repair structural issues
lore stats                       # Show index statistics
lore status                      # Knowledge store health summary
lore check-links                 # Scan for broken backlink references

# Work items
lore work list                   # List active work items
lore work create "name"          # Create a work item
lore work show "slug"            # Show work item details
lore work archive "slug"         # Archive completed work item
lore work search "query"         # Search across work items
lore work tasks "slug"           # Generate tasks from plan.md
lore work heal                   # Repair work structure

# Analysis
lore analyze staleness           # Scan entries for staleness
lore analyze usage               # Analyze entry access patterns
lore analyze concordance         # TF-IDF similarity computation
lore analyze merge-candidates    # Find entries worth merging

# Other
lore thread list                 # List conversational threads
lore curate                      # Pre-scan for curation issues
lore assemble                    # Reassemble CLAUDE.md from fragments
lore bootstrap scope             # Analyze codebase structure
```

Run `lore --help` or `lore <command> --help` for full details.

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
| `/pr-review` | Review someone else's PR with knowledge-enriched analysis |
| `/pr-self-review` | Reflective review of your own PR before submitting |
| `/pr-pair-review` | Interactive pair-review with turn-based protocol |
| `/pr-revise` | Read PR feedback and create a work item to address it |

### System health

| Skill | Description |
|-------|-------------|
| `/self-test` | Evaluate system health across 8 dimensions with scored results |
| `/retro` | Post-work-cycle retrospective — scores 5 dimensions, writes journal entry |
| `/renormalize` | Full knowledge store normalization — prune, merge, rebalance |
| `/bootstrap` | Explore a new codebase and seed initial knowledge |

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
