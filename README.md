# lore

A per-project knowledge store for [Claude Code](https://claude.ai/claude-code). Captures, organizes, and retrieves reusable insights across sessions.

## What it does

- **Captures** non-obvious, reusable insights during coding sessions
- **Organizes** them into searchable category files (architecture, conventions, workflows, gotchas, etc.)
- **Retrieves** relevant context at session start via hooks, and on-demand via skills and search
- **Tracks** work items and conversational threads across sessions

## Architecture

Lore separates **logic** (this repo) from **data** (`~/.lore/`):

```
<this repo>/                    # Logic (shareable, installable)
├── scripts/                    # Hooks, search, indexing, utilities
├── skills/                     # Claude Code skill definitions
├── claude-md/                  # CLAUDE.md protocol fragments
├── tests/                      # pytest suite
├── install.sh                  # Setup script
└── SELF_TEST.md                # System evaluation protocol

~/.lore/                        # Data (per-user, persists independently)
├── scripts -> <this repo>/scripts/   # Stable symlink
└── repos/                      # Per-project knowledge stores
    └── github.com/<org>/<repo>/
        ├── _index.md, _inbox.md, _manifest.json
        ├── architecture.md, conventions.md, workflows.md, ...
        ├── _threads/           # Conversational threads
        └── _work/              # Work items and specs
```

The `~/.lore/scripts/` symlink is the portability layer — all hooks and skills reference it. If the logic repo moves, re-run `install.sh` to update the symlink.

## Install

```bash
git clone git@github.com:anticorrelator/lore.git
cd lore
bash install.sh
```

This creates `~/.lore/`, symlinks skills into `~/.claude/skills/`, configures hooks in `~/.claude/settings.json`, and assembles `~/.claude/CLAUDE.md`.

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

## Skills

| Skill | Description |
|-------|-------------|
| `/memory` | Organize inbox, search, view, heal knowledge store |
| `/remember` | Capture insights to inbox, update threads |
| `/work` | Create, resume, update, archive work items |
| `/spec` | Technical specifications via divide-and-conquer investigation |
| `/self-test` | Evaluate system health across 8 dimensions |

## Tests

```bash
python3 -m pytest tests/
```
