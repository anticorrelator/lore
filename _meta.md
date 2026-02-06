# Project Knowledge Store — System Documentation

## Overview

A per-project hierarchical markdown knowledge store that Claude builds organically while working on codebases. Knowledge persists across sessions and is shared across clones of the same repository.

## Two-Pass Architecture

### Pass 1 — Capture (during coding)
Claude appends raw insights to `_inbox.md` in a single tool call. Minimal formatting, includes suggested category and context. Zero disruption to the coding task.

### Pass 2 — Organize (at session start or on-demand)
The SessionStart hook detects pending inbox items and prompts Claude to run `/knowledge organize`. Claude processes the inbox: files entries into correct category files, deduplicates, merges with existing entries, adds backlinks, and updates index/manifest.

## Directory Structure

```
~/.project-knowledge/
  _meta.md                    # This file — system documentation
  scripts/                    # Bash scripts for hooks and utilities
    resolve-repo.sh           # CWD -> knowledge path resolution
    init-repo.sh              # Initialize repo knowledge structure
    load-knowledge.sh         # SessionStart hook script
    pre-compact.sh            # PreCompact hook script
    search-knowledge.sh       # Keyword + full-text search
    update-manifest.sh        # Regenerate _manifest.json
  repos/
    <normalized-remote>/      # Per-repo knowledge (e.g., github.com/arize-ai/phoenix)
      _inbox.md               # Capture queue (append-only during coding)
      _index.md               # Navigation TOC with [[backlinks]]
      _manifest.json          # Machine-readable file list with keywords
      architecture.md         # System design, component boundaries
      conventions.md          # Standards beyond what linters enforce
      abstractions.md         # Core patterns, base classes, type hierarchies
      workflows.md            # Build/test/deploy commands & patterns
      gotchas.md              # Non-obvious pitfalls and debugging tips
      team.md                 # Inferred team conventions from PR feedback
      domains/                # Deep subsystem knowledge (on-demand)
        <topic>.md
    local/                    # Fallback for repos without git remotes
      <dirname>/
```

## File Categories

| Category | Purpose | Examples |
|----------|---------|----------|
| architecture | System design, boundaries, tech stack | Component diagrams, service boundaries, data flow |
| conventions | Standards beyond linters | Naming patterns, error handling style, API design |
| abstractions | Core patterns, hierarchies | Base classes, type systems, design patterns in use |
| workflows | Build, test, deploy | Commands, CI pipeline quirks, environment setup |
| gotchas | Non-obvious pitfalls | Edge cases, debugging tips, common mistakes |
| team | Team conventions | PR feedback patterns, review standards, preferences |
| domains/* | Deep subsystem knowledge | Created on-demand for specific subsystems |

## Inbox Entry Format

```markdown
## [YYYY-MM-DDTHH:MM:SS]
- **Insight:** The concrete finding
- **Context:** How/where it was discovered
- **Suggested category:** category-name
- **Related files:** paths to relevant source files
- **Confidence:** high|medium|low
```

## Organized Entry Format

```markdown
### Brief Descriptive Title
Concrete insight in 1-5 sentences. Cross-reference related topics with [[backlinks]].
See also: [[related-file]], [[domains/topic]].
<!-- learned: YYYY-MM-DD | confidence: high|medium|low | source: code-exploration -->
```

## Backlink Convention

- `[[filename]]` — link to knowledge file (e.g., `[[architecture]]`)
- `[[filename#heading]]` — link to section (e.g., `[[gotchas#Symlink Issue]]`)
- `[[filename|display text]]` — link with display text

## Capture Criteria (4-condition gate)

An insight should be captured only if ALL four conditions are met:
1. **Reusable** — applicable beyond the current task
2. **Non-obvious** — not already in README, CLAUDE.md, or docs
3. **Stable** — unlikely to change soon
4. **High confidence** — verified through code exploration, not speculative

Target: 1-3 captures per substantial session.

## Knowledge Decay

- Entries have timestamps and confidence levels
- Medium/low confidence entries >90 days old are flagged for re-verification
- Claude updates stale entries when encountering the relevant topic
- Contradicted entries are corrected during normal work

## Repo Identification

1. Try `git remote get-url origin`
2. Normalize: strip protocol/auth, SSH colon -> slash, strip `.git`, lowercase
3. Path: `~/.project-knowledge/repos/<normalized>`
4. Fallback (no remote): `repos/local/<repo-root-basename>`
5. Fallback (no git): `repos/local/<cwd-basename>`
