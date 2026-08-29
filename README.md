# lore

Lore is a working model for collaborating with coding agents, packaged as
persistent memory and a protocol layer for agent harnesses —
[Claude Code](https://claude.ai/claude-code) (reference baseline),
[OpenCode](https://opencode.ai), and [Codex CLI](https://developers.openai.com/codex/).

Each session starts from what previous sessions recorded — conventions,
gotchas, architecture notes, in-flight work.

## Install

Requires bash, Python 3, and Go (builds the TUI). Go can be skipped for
knowledge and memory use alone, but the TUI is required for `/coordinate` —
it allows coordinator agents to manage worker sessions.

```bash
git clone git@github.com:anticorrelator/lore.git && cd lore
bash install.sh                # --framework claude-code (default) | opencode | codex
```

Then, in a project you work on:

```bash
cd your-project
lore init      # create the knowledge store — or run /bootstrap in an agent session to seed it
```

`--dry-run` previews, `--uninstall` removes (data preserved). Re-run with a
different `--framework` to switch harnesses.

## Use

Most of lore is automatic. Hooks load relevant knowledge, active work, and
conversation threads at session start, and queue new insights for capture at
session end. Normal coding sessions need no lore-specific commands.

**TUI** — `lore` with no arguments. Work items, live agent sessions in
embedded terminals (spawn, drive, triage), knowledge browsing, review-finding
follow-ups, and the settlement view.

**Driving work** — slash commands in an agent session:

| | |
|---|---|
| `/coordinate` | drive a feature end-to-end across protocol sessions |
| `/spec` → `/implement` | plan a work item, then execute the plan with worker agents |
| `/work` | create, resume, and check status of work items |
| `/remember` | capture insights from the current conversation |
| `/pr-review` | multi-lens PR review (`--self` for your own branch) |

**Ceremonies** — periodic maintenance:

| | |
|---|---|
| `/bootstrap` | seed a new project's store by exploring the codebase |
| `/retro` | score how well the system supported a finished work cycle |
| `/evolve` | review and apply protocol suggestions accumulated by retro |
| `/renormalize` | prune and rebalance the knowledge store |

**Configuration** — the installer persists framework and role→model settings
to `~/.lore/config/`. `lore config show` prints them; `lore harness
enable|disable` toggles integration per harness.

The wider CLI (`lore search`, `lore work`, …) is used by agents and scripts.

## Data

Everything lore keeps lives per-project under
`~/.lore/repos/<host>/<org>/<repo>/`: knowledge entries (with provenance),
work items and plans, conversational threads, and scorecard telemetry. Logic
lives in this repo; data lives in `~/.lore/` and survives reinstalls.
