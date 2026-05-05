# Framework Compatibility

Operator-facing reference for running Lore against multiple AI coding harnesses (Claude Code, OpenCode, Codex CLI). Every cell here is grounded in [`adapters/capabilities.json`](../adapters/capabilities.json) (the closed-set capability profile per harness) and the dated vendor evidence in [`adapters/capabilities-evidence.md`](../adapters/capabilities-evidence.md). Compatibility cells, degradation messages, and adapter contracts live closer to the code than to this doc — this page joins them for the operator's view.

> **Status:** May 2026. Hand-derived against the capability profile committed at SHA `cf908bb`. `lore framework status` and `lore framework doctor` (T20, T21) emit the same matrix at runtime against the live profile; the regen script for this doc lands later in the migration (T66). When `framework status` and this doc disagree, **trust `framework status`** — it joins against the live `capabilities.json`.

## Contents

- [Setup per harness](#setup-per-harness)
- [Support levels & degradation vocabulary](#support-levels--degradation-vocabulary)
- [Per-skill capability dependencies](#per-skill-capability-dependencies)
- [Compatibility matrix](#compatibility-matrix)
- [Per-harness capability profile](#per-harness-capability-profile)
- [Known degradation per harness](#known-degradation-per-harness)
- [Role registry & role→model configuration](#role-registry--rolemodel-configuration)
- [CLI surface](#cli-surface)
- [Evidence artifact pointers](#evidence-artifact-pointers)
- [Harness-specific scripts](#harness-specific-scripts)
- [Where to file follow-ups](#where-to-file-follow-ups)
- [Related documents](#related-documents)

## Setup per harness

```bash
bash install.sh --framework claude-code   # default; reference baseline
bash install.sh --framework opencode      # multi-provider; native plugin runtime
bash install.sh --framework codex         # native hooks since 0.124.0 (April 2026)
```

Selection persists to `$LORE_DATA_DIR/config/framework.json`. Re-running `install.sh --framework <name>` switches the active harness while preserving role bindings and capability overrides. Per-shell override: `LORE_FRAMEWORK=<id>` (validated against the closed framework set; an unknown id is an error, not a silent fall-back).

`install.sh` resolves install paths via `adapters/capabilities.json::frameworks.<id>.install_paths` — Lore never hardcodes per-harness paths. After install, `lore framework status` prints the resolved framework, capability levels, role bindings, and pointers to the evidence + compatibility artifacts.

| Harness     | Binary    | Instructions file        | Skills dir            | Settings/permissions               | MCP servers                         |
|-------------|-----------|--------------------------|-----------------------|-------------------------------------|--------------------------------------|
| claude-code | `claude`  | `~/.claude/CLAUDE.md`    | `~/.claude/skills`    | `~/.claude/settings.json`           | `~/.claude/settings.json`            |
| opencode    | `opencode`| `~/.claude/CLAUDE.md`    | `~/.claude/skills`    | `~/.config/opencode/config.json`    | `~/.config/opencode/opencode.json`   |
| codex       | `codex`   | `~/.codex/AGENTS.md`     | `~/.codex/skills`     | `~/.codex/config.toml`              | `~/.codex/config.toml`               |

OpenCode reads `~/.claude/CLAUDE.md` and `~/.claude/skills/` natively, so the assembled Claude file works for OpenCode without re-rendering. Codex reads AGENTS.md-style instructions from `~/.codex/AGENTS.md`; `assemble-instructions.sh --framework codex` emits AGENTS.md instead of CLAUDE.md.

## Support levels & degradation vocabulary

Cells in `capabilities.json` use the four-level scale defined in `support_levels`:

- **full** — native support that matches Lore's protocol semantics with no degradation.
- **partial** — native surface exists but does not cover every semantic Lore requires; the gap is documented in the cell `notes`.
- **fallback** — no native surface; Lore implements the capability through a wrapper, MCP shim, or lead-side post-hoc check. Behavior is best-effort and not equivalent to native.
- **none** — capability unavailable on this harness; callers must degrade explicitly and surface the unsupported state.

Adapter-emitted stderr notices use the closed degradation vocabulary defined in [`adapters/capabilities.json::skills._degradation_vocab`](../adapters/capabilities.json) (T41). Strings outside this set are a contract violation:

- `degraded:partial` — at least one requirement was below its `min_level` but at or above its `partial_below`. Skill ran in partial-mode; the adapter MUST emit a one-line notice naming the requirement and observed level.
- `degraded:fallback` — operation routed through a fallback path (e.g., lead-side validator instead of native blocking hook). Functionally same as `partial` from the user's view; the gap is named at the cell level rather than the skill level.
- `degraded:none` — skill is `unavailable` because at least one requirement was below `partial_below`. The skill MUST refuse to run; calling it is a no-op + stderr notice naming the missing requirement.
- `degraded:no-evidence` — capability cell has support `> none` but no `evidence` pointer. Skills SHOULD treat this as a soft block — proceed in partial-mode and surface the missing-evidence notice.
- `degraded:unverified-support(<level>)` — reserved scoped form for stderr notices when a capability cell has been overridden in `framework.json` (per-user override) without a refreshed evidence pointer.

## Per-skill capability dependencies

The matrix below classifies skills by their hardest required capability. Skills that use `TeamCreate` / `SendMessage` / `Task` spawn primitives depend on the team-orchestration capabilities; skills that drive a single-agent flow only depend on `instructions` and `skills` discovery (full on every harness).

| Skill                | Subagents required | Team messaging required | TaskCompleted blocking required | Multi-provider model routing required |
|----------------------|--------------------|-------------------------|---------------------------------|----------------------------------------|
| `/spec`              | yes                | yes                     | no (lead validates returned reports) | no (per-role bindings collapse on single) |
| `/implement`         | yes                | yes                     | yes (worker reports gated by hook) | no                                       |
| `/bootstrap`         | yes                | yes                     | no                                 | no                                       |
| `/renormalize`       | yes                | yes                     | no                                 | no                                       |
| `/retro`             | yes                | yes                     | no                                 | no                                       |
| `/work`              | no (single-agent)  | no                      | no                                 | no                                       |
| `/memory`            | no                 | no                      | no                                 | no                                       |
| `/remember`          | no                 | no                      | no                                 | no                                       |
| `/self-test`         | no                 | no                      | no                                 | no                                       |
| `/evolve`            | no                 | no                      | no                                 | no                                       |
| `/followup-discuss`  | no                 | no                      | no                                 | no                                       |
| `/pr-review`         | yes (lens fanout)  | no (lead-only aggregation) | no                              | no                                       |
| `/pr-self-review`    | yes                | no                      | no                                 | no                                       |
| `/pr-create`         | no                 | no                      | no                                 | no                                       |
| `/pr-revise`         | no                 | no                      | no                                 | no                                       |
| `/pr-pair-review`    | no                 | no                      | no                                 | no                                       |
| Single-lens reviews (`/pr-{correctness,security,blast-radius,test-quality,interface-clarity,regressions,thematic,user-impact}`) | no | no | no | no |
| `/codex-plan-review` | no (delegates to codex CLI) | no                | no                                 | no                                       |
| `/codex-pr-review`   | no (delegates to codex CLI) | no                | no                                 | no                                       |
| `/codex-design-review` | no (delegates)            | no                | no                                 | no                                       |

The full per-skill `requires` schema (with `min_level` and `partial_below` thresholds) lives in [`adapters/capabilities.json::skills`](../adapters/capabilities.json). T41 / T9 wired the team-heavy skills (`bootstrap`, `implement`, `spec`) to the partial-mode contract: a `partial_below` floor splits "downgrade to partial-mode" from "refuse outright".

## Compatibility matrix

The classification below applies the dependency table above against each harness's capability profile. Single-agent skills (the "no" rows above) are **full** on every harness; they are summarized in the "Single-agent skills" row at the bottom.

| Skill                | Claude Code | OpenCode  | Codex     |
|----------------------|-------------|-----------|-----------|
| `/spec`              | full        | partial   | partial   |
| `/implement`         | full        | partial   | partial   |
| `/bootstrap`         | full        | partial   | partial   |
| `/renormalize`       | full        | partial   | partial   |
| `/retro`             | full        | partial   | partial   |
| `/work`              | full        | full      | full      |
| `/pr-review`         | full        | full      | full      |
| `/pr-self-review`    | full        | full      | full      |
| `/codex-plan-review` | full        | full      | full      |
| `/codex-pr-review`   | full        | full      | full      |
| Single-agent skills  | full        | full      | full      |

The `/pr-review` family is `full` on every harness because its lens fanout uses lead-only aggregation today — no skill in that family relies on `team_messaging` or `task_completed_hook`. If a future revision adds inter-lens messaging, this matrix re-classifies them.

### Why no skill is `unavailable` today

Every Lore skill has a working fallback path on every supported harness. The candidates for `unavailable` would be:

- A skill that hard-required `task_completed_hook=full` with no fallback (would force `unavailable` on OpenCode/Codex). Today's `/implement` keeps protocol compliance via the lead-side validator — see [`adapters/agents/README.md`](../adapters/agents/README.md) §"Completion Enforcement Degradation Modes".
- A skill that hard-required `plugin_runtime=full` (would force `unavailable` on Claude Code and Codex). No such skill exists; the OpenCode plugin (`adapters/opencode/lore-hooks.ts`) is an adapter, not a skill.
- A skill that hard-required `mcp=full` for non-optional behavior (no such skill today).

If the skill-capability manifest reveals a hard requirement that breaks one of the supported harnesses, that skill flips to `unavailable` here and the `/<skill>` SKILL.md gains a "Harness compatibility" section listing supported harnesses.

## Per-harness capability profile

The full capability profile lives in [`adapters/capabilities.json`](../adapters/capabilities.json). Summary view (every non-`none` cell carries an evidence id pointing into [`adapters/capabilities-evidence.md`](../adapters/capabilities-evidence.md)):

| Capability             | Claude Code | OpenCode  | Codex     |
|------------------------|-------------|-----------|-----------|
| `instructions`         | full        | full      | full      |
| `skills`               | full        | full      | partial   |
| `mcp`                  | full        | partial   | full      |
| `session_start_hook`   | full        | partial   | full      |
| `stop_hook`            | full        | partial   | full      |
| `pre_compact_hook`     | full        | fallback  | fallback  |
| `tool_hooks`           | full        | partial   | full      |
| `permission_hooks`     | full        | partial   | full      |
| `task_completed_hook`  | full        | fallback  | fallback  |
| `subagents`            | full        | partial   | partial   |
| `team_messaging`       | full        | none      | none      |
| `transcript_provider`  | full        | partial   | partial   |
| `headless_runner`      | full        | partial   | full      |
| `plugin_runtime`       | none        | full      | none      |
| `model_routing.shape`  | single      | multi     | single    |

Capability cells in `adapters/capabilities.json` should always be a triple of (`support`, `evidence`, `notes`) — the canonical convention promoted from this work item is documented in `conventions/capability-cells-in-adapters-capabilities-json-sho.md`. Operators editing overrides via `framework.json::capability_overrides` should consult the evidence pointer first; promoting an override past the evidence-supported level is a D8 ceiling violation flagged by `lore framework capability-overrides`.

## Known degradation per harness

Each cell that is not `full` is degraded for a specific reason documented below. Adapters MUST surface a one-line stderr notice using the [degradation vocabulary](#support-levels--degradation-vocabulary).

### Claude Code

Reference baseline. The only `none` cell is `plugin_runtime` — Claude Code hooks are shell/python commands invoked by the harness; there is no in-process plugin runtime, so OpenCode-style TypeScript plugins are not portable. Scripts handle every extension need.

### OpenCode

| Skill           | Mode      | Why (capability gap)                                                                                                       | Fallback                                                                                                              | Degraded notice                                                                |
|-----------------|-----------|---------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------|
| `/spec`         | partial   | `team_messaging=none` — no native SendMessage equivalent.                                                                 | Lead-orchestrated fanout: workers run in parallel without inter-agent messaging; lead aggregates returned reports.    | `[lore] degraded: /spec via lead-orchestration (team_messaging=none)`           |
| `/implement`    | partial   | `team_messaging=none` AND `task_completed_hook=fallback` — no in-flight messaging, no native worker-completion blocking. | Lead-orchestrated fanout + lead-side validator (rejects worker reports missing required structure).                   | `[lore] degraded: /implement via lead-validator (task_completed_hook=fallback)` |
| `/bootstrap`    | partial   | `team_messaging=none`.                                                                                                     | Lead-orchestrated fanout.                                                                                             | `[lore] degraded: /bootstrap via lead-orchestration (team_messaging=none)`      |
| `/renormalize`  | partial   | `team_messaging=none`.                                                                                                     | Lead-orchestrated fanout.                                                                                             | `[lore] degraded: /renormalize via lead-orchestration (team_messaging=none)`    |
| `/retro`        | partial   | `team_messaging=none`.                                                                                                     | Lead-orchestrated fanout.                                                                                             | `[lore] degraded: /retro via lead-orchestration (team_messaging=none)`          |

Other OpenCode cells worth flagging:

- `mcp=partial` — MCP servers configured in `~/.config/opencode/opencode.json` instead of `~/.claude/settings.json`. The OpenCode surface itself is full; `partial` reflects that Lore's cross-harness MCP packaging writer is not yet wired.
- `pre_compact_hook=fallback` — no native PreCompact event semantics confirmed; fallback runs the persistence reminder on last-known signal rather than a true PreCompact event.
- `transcript_provider=partial` — session artifact format differs from Claude JSONL. Transcript provider stub at `adapters/transcripts/opencode.py` translates available fields and reports degraded for missing ones (T51 partial-provider pattern; see `conventions/t51-partial-provider-pattern-all-7-operations.md`).

### Codex

| Skill           | Mode      | Why (capability gap)                                                                                                       | Fallback                                                                                                              | Degraded notice                                                                |
|-----------------|-----------|---------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------|
| `/spec`         | partial   | `team_messaging=none` — no native SendMessage equivalent.                                                                 | Lead-orchestrated fanout.                                                                                             | `[lore] degraded: /spec via lead-orchestration (team_messaging=none)`           |
| `/implement`    | partial   | `team_messaging=none` AND `task_completed_hook=fallback`.                                                                 | Lead-orchestrated fanout + lead-side validator.                                                                       | `[lore] degraded: /implement via lead-validator (task_completed_hook=fallback)` |
| `/bootstrap`    | partial   | `team_messaging=none`.                                                                                                     | Lead-orchestrated fanout.                                                                                             | `[lore] degraded: /bootstrap via lead-orchestration (team_messaging=none)`      |
| `/renormalize`  | partial   | `team_messaging=none`.                                                                                                     | Lead-orchestrated fanout.                                                                                             | `[lore] degraded: /renormalize via lead-orchestration (team_messaging=none)`    |
| `/retro`        | partial   | `team_messaging=none`.                                                                                                     | Lead-orchestrated fanout.                                                                                             | `[lore] degraded: /retro via lead-orchestration (team_messaging=none)`          |

Other Codex cells worth flagging:

- `skills=partial` — Codex documents a native skills surface; per-skill discovery semantics may differ from Claude's eager session-start load.
- `pre_compact_hook=fallback` — no native PreCompact event documented. Lore uses Stop/SessionStart bookends to remind the user to persist plans.
- `transcript_provider=partial` — same shape as OpenCode: format differs from Claude JSONL, provider stub at `adapters/transcripts/codex.py` translates available fields and reports degraded for missing ones.

The Codex-specific migration note (April 2026 hooks introduction, supersedes the stale "notify-only" assumption) lives at [`docs/codex-migration.md`](codex-migration.md).

## Role registry & role→model configuration

Lore defines a closed agent-role registry and persists a `roles → model` map per user. Every spawn-site resolves its model from the active role rather than accepting a `--model` flag at invocation time. The flag is preserved as a per-invocation override but is no longer the primary surface (D10).

### Closed role set

Defined in [`adapters/roles.json`](../adapters/roles.json):

| Role         | Description                                                                                              | Call sites                                              |
|--------------|----------------------------------------------------------------------------------------------------------|---------------------------------------------------------|
| `lead`       | Coordinator agent that plans phases, spawns workers, and gates phase transitions on returned reports.    | `skills/spec/SKILL.md`, `skills/implement/SKILL.md`     |
| `worker`     | Task-iterating implementation agent emitting Tier 2 evidence anchored to file:line ranges.               | `agents/worker.md`, `skills/implement`, `batch-implement` |
| `researcher` | Task-iterating investigation agent that explores design space without modifying source files.            | `agents/researcher.md`, `skills/spec`, `batch-spec`     |
| `reviewer`   | Single-batch evaluator that consumes a finished artifact and returns a verdict against a rubric.         | `skills/pr-review`, `generate-review-summary.sh`        |
| `judge`      | Single-batch verdict agent that scores candidates against a closed rubric (correctness gate, batch suit.) | `judge-batch-candidates.sh`, `audit-artifact.sh`        |
| `summarizer` | Lightweight synthesis agent that compresses transcripts, capture queues, or review threads.              | `work-ai.sh`, `extract-session-digest.py`               |
| `default`    | Resolution fallback consulted when a role binding is unset; never named directly by a call site.         | (fallback only)                                         |

Adding a role requires updating `roles.json`, `scripts/lib.sh::resolve_model_for_role`, `tui/internal/config/config.go::ResolveModelForRole`, and `tests/frameworks/roles.bats` — the closed set keeps the schema verifiable and `lore framework status` output finite.

### Role binding precedence

`resolve_model_for_role <role>` walks this chain (env → per-repo → user → harness default):

1. **`LORE_MODEL_<ROLE>` env var** (uppercased role name; e.g. `LORE_MODEL_LEAD`). Per-shell override.
2. **`$KDIR/.lore.config` per-repo `[model.role]` table** (when present in the repo). Repo-scoped override.
3. **`$LORE_DATA_DIR/config/framework.json::role_bindings.<role>`** (user-level binding, written by `lore framework set-model` once T22 ships).
4. **Harness default** — for `model_routing=single` harnesses (claude-code, codex), the role map collapses to one binding without affecting call sites.
5. **`adapters/roles.json::default_role` fallback** (typically `"default"`).

### Multi-provider syntax (model_routing=multi)

Multi-provider harnesses (today: OpenCode) honor per-role bindings using the `<provider>/<model>` syntax:

```jsonc
// $LORE_DATA_DIR/config/framework.json
{
  "framework": "opencode",
  "role_bindings": {
    "lead":       "anthropic/opus",       // Opus for the coordinator
    "worker":     "anthropic/haiku",      // Haiku for fanout workers (cost-optimized)
    "researcher": "openai/gpt-4o",        // Cross-provider for design exploration
    "judge":      "anthropic/sonnet",     // Sonnet for verdict rubrics
    "default":    "anthropic/sonnet"
  }
}
```

The separator is `/` (slash), not `:` (colon). `lib.sh::validate_role_model_binding` and `tests/frameworks/roles.bats` pin this convention; adapters writing role bindings MUST use `/`.

Single-provider harnesses (claude-code, codex) reject `provider/model` syntax — `framework_model_routing_shape == "single"` plus a binding naming a provider the harness cannot serve returns non-zero with a remediation message naming the conflict. `lore framework doctor` flags these conflicts with set-model hints.

### Inspecting the resolved view

```bash
lore framework status                # Shows resolved bindings + source attribution
lore framework doctor                # Walks cwd resolution chain; surfaces conflicts
lore config role lead                # Print model bound to <role> from framework.json
lore config roles                    # Print full role->model map as JSON
```

## CLI surface

The `framework` and `config` subgroups expose the harness profile and persisted configuration:

```bash
# Diagnostic surface (joins live config against capabilities.json)
lore framework status [--json]
lore framework doctor [--json]
lore framework capability-overrides [--json]

# Read persisted configuration verbatim
lore config framework                # Active framework name
lore config role <role>              # Model bound to <role>
lore config roles                    # Full role->model map (JSON)
lore config capability-overrides     # Capability overrides (JSON)
lore config show                     # Entire framework.json (JSON)
lore config path                     # Absolute path to framework.json

# Future (lands with task-22): write-side role binding
lore framework set-model <role> <model>     # Persist a role binding
lore framework unset-model <role>           # Remove a binding
```

`lore framework status` prints the resolved framework name + binary, capability levels grouped by support level (`native | partial | fallback | unavailable`), the active role bindings (one collapsed line per role with source attribution), and pointers to the evidence + compatibility artifacts. `lore framework doctor` adds: cwd resolution chain walk (per-repo `.lore.config` diff), conflict diagnostics with set-model hints, and capability-override ceiling check.

`lore status` and `lore doctor` (general health checks) report against the active harness's install paths — they return `n/a` for paths the active harness does not use, rather than hardcoded `~/.claude/*` checks.

## Evidence artifact pointers

Every non-`none` capability cell in `capabilities.json` carries an `evidence` field pointing at an entry in `capabilities-evidence.md`. Each evidence entry has six required fields per the D8 evidence contract: source, URL/path, retrieved date, product/version, claim, and consumed-by list.

| Artifact                                                                       | Purpose                                                                                                |
|--------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------|
| [`adapters/capabilities.json`](../adapters/capabilities.json)                  | Closed-set capability profile per harness; the canonical source of truth for support levels.            |
| [`adapters/capabilities-evidence.md`](../adapters/capabilities-evidence.md)    | Dated vendor-doc evidence for every non-`none` cell. Cell with no evidence ≡ unverified-support.        |
| [`adapters/roles.json`](../adapters/roles.json)                                | Closed agent-role registry. Resolution fallback; never named by call sites except `default`.            |
| [`adapters/README.md`](../adapters/README.md)                                  | Dual-implementation contract (bash `lib.sh` ↔ Go `tui/internal/config/config.go`).                      |
| [`adapters/hooks/README.md`](../adapters/hooks/README.md)                      | Hook adapter contract: nine lifecycle events, dispatch shape, per-harness signaling protocols.          |
| [`adapters/agents/README.md`](../adapters/agents/README.md)                    | Orchestration adapter contract: seven operations, completion-enforcement degradation modes (D9).        |
| [`adapters/transcripts/README.md`](../adapters/transcripts/README.md)          | Transcript/session provider contract for digest, novelty, plan-persistence, ceremony detection (D5).    |
| [`docs/codex-migration.md`](codex-migration.md)                                | Operator note on the April 2026 Codex CLI hooks update (supersedes the stale "notify-only" assumption). |

When citing in code or other docs, prefer the file paths above over copying the matrix here.

## Harness-specific scripts

A small number of Lore scripts target a single harness rather than going through the adapter contract. These exist because the underlying surface is harness-specific (e.g., a billing/auth wrapper for one vendor's CLI).

| Script | Harness | Purpose | Why harness-specific |
|--------|---------|---------|----------------------|
| `scripts/claude-billing.sh` | Claude Code only | Anthropic API-key billing/usage wrapper | Wraps `anthropic` Python SDK with API key authentication; manages a lease file that switches Claude Code between Pro/Max subscription auth and Anthropic API-key billing. OpenCode and Codex use their own billing surfaces (vendor-managed) and do not use the `claude` binary or the `~/.claude/api-billing-lease` path this script requires. Invoking this script under a non-Claude-Code harness exits with an explanatory error. |

The general rule: a script that takes a `--framework` flag or routes through `resolve_active_framework` is a multi-harness script and does NOT belong in this table. A script that hardcodes a single binary or vendor-specific config path belongs here, with a documented reason.

## Where to file follow-ups

- **Vendor capability changes** (new hooks, dropped hooks, subagent semantics shift) → update [`adapters/capabilities-evidence.md`](../adapters/capabilities-evidence.md) with a fresh `Retrieved:` date, then flip the matching [`adapters/capabilities.json`](../adapters/capabilities.json) cell, then re-grade this matrix. The flow is intentional: the matrix must never be the canonical source for capability state — it is a view over `capabilities.json`, not a peer.
- **New skills added under `skills/`** — add a row to the per-skill `requires` map in `capabilities.json::skills.<name>`, then add a row to the [Per-skill capability dependencies](#per-skill-capability-dependencies) table. The framework status output updates automatically off the JSON.
- **A skill whose degradation note doesn't match this table** — the adapter is the bug. Fix the stderr notice to use the closed [degradation vocabulary](#support-levels--degradation-vocabulary), not the doc.
- **Per-harness install path changes** — update `capabilities.json::frameworks.<id>.install_paths`, then re-run `install.sh --framework <id>` to repackage. Do NOT add hardcoded paths to `install.sh` — `resolve_harness_install_path` is the gate.

## Related documents

- [`adapters/README.md`](../adapters/README.md) — dual-impl contract; helper inventory for `lib.sh` ↔ `config.go`.
- [`adapters/agents/README.md`](../adapters/agents/README.md) — orchestration adapter contract (spawn, wait, completion enforcement).
- [`adapters/hooks/README.md`](../adapters/hooks/README.md) — hook adapter contract (lifecycle events, dispatch shape).
- [`adapters/transcripts/README.md`](../adapters/transcripts/README.md) — transcript provider contract.
- [`docs/codex-migration.md`](codex-migration.md) — Codex CLI hooks migration note (April 2026).
- [`adapters/capabilities.json`](../adapters/capabilities.json) — capability profile (closed-set, evidence-gated).
- [`adapters/capabilities-evidence.md`](../adapters/capabilities-evidence.md) — dated vendor evidence backing every non-`none` cell.
