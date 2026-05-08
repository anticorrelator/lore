# Codex Migration Note

Lore's Codex integration changed shape in May 2026. This file is the
operator-facing note explaining what changed, why, and where to look for
current capability evidence.

## TL;DR

The earlier Lore plan treated Codex CLI as a **wrapper-only** harness on
the premise that Codex exposed a single `notify` event with type
`agent-turn-complete` and that maintainers had rejected adding session
lifecycle hooks. As of Codex CLI 0.123.0 (April 2026, hooks introduced)
and 0.124.0 (April 2026, hooks marked stable), Codex now ships native
**SessionStart**, **Stop**, **PreToolUse**, **PostToolUse**, and
**PermissionRequest** hooks plus subagent workflows. The notify-only
assumption is stale.

The Codex adapter is therefore native-hooks-first. Wrapper / MCP fallback
paths are reserved for two genuine gaps that Codex still does not cover:

- **PreCompact** — no native event. Lore mitigates with Stop /
  SessionStart bookends to remind users to persist plans.
- **TaskCompleted-style worker-output blocking** — no native
  subagent-completion blocking event. The orchestration adapter falls
  back to a lead-side validator that rejects worker reports missing
  required structure.

## Capability cells (current)

The authoritative capability profile lives in
[`adapters/capabilities.json`](../adapters/capabilities.json) under
`frameworks.codex.capabilities.*`. Today's cells:

| Capability             | Support  | Notes |
|------------------------|----------|-------|
| `instructions`         | full     | AGENTS.md project instructions + layered config. |
| `skills`               | partial  | Native skills surface; per-skill discovery semantics may differ from Claude's eager session-start load. |
| `mcp`                  | full     | Native MCP server registration. |
| `session_start_hook`   | full     | Native SessionStart hook. Supersedes the prior "no session lifecycle hooks" claim. |
| `stop_hook`            | full     | Native Stop hook. Supersedes the prior "no session lifecycle hooks" claim. |
| `pre_compact_hook`     | fallback | No native PreCompact event; lore uses Stop/SessionStart bookends. |
| `tool_hooks`           | full     | Native PreToolUse and PostToolUse hooks. |
| `permission_hooks`     | full     | Native PermissionRequest hook (`allow` / `deny` / `abstain`). |
| `task_completed_hook`  | fallback | No native subagent-completion blocking event; lead-side validator. |
| `subagents`            | partial  | Subagent workflows enabled by default per current docs; team-state semantics differ from Claude. |
| `team_messaging`       | none     | No native TeamCreate / SendMessage equivalent; skills run lead-orchestrated. |
| `transcript_provider`  | partial  | Session artifacts exist; format differs from Claude JSONL. |
| `headless_runner`      | full     | Non-interactive prompt invocation works. |
| `plugin_runtime`       | none     | Hooks are shell commands; no in-process plugin runtime. |
| `model_routing.shape`  | single   | Single provider per session. The role->model map collapses to one binding. |

Every non-`none` cell carries a dated evidence pointer in
[`adapters/capabilities-evidence.md`](../adapters/capabilities-evidence.md)
under the `codex-*` anchors (retrieved 2026-05-03 from
`https://developers.openai.com/codex/hooks` and the Codex changelog).

## What changed in the codebase

- [`gotchas/hooks/hook-system-gotchas.md`](../gotchas/hooks/hook-system-gotchas.md)
  rewrote the "Codex CLI Has No Session Lifecycle Hooks" subsection
  in-place with a "Codex CLI Hooks Surface (April 2026 Update)" section
  that opens with **Superseded prior claim.** so retrieval ties break
  on the new framing. The metadata footer flips
  `learned: 2026-05-03 | source: worker-fix`.
- [`adapters/capabilities.json`](../adapters/capabilities.json) sets the
  Codex capability cells listed above.
- [`adapters/capabilities-evidence.md`](../adapters/capabilities-evidence.md)
  carries the dated vendor-doc pointers for every non-`none` cell.
- The Codex orchestration adapter
  ([`adapters/agents/codex.sh`](../adapters/agents/codex.sh), arrives in
  T40) uses native subagent workflows where possible with explicit
  handling for the fact that Codex only spawns subagents when asked.
- The Codex hook adapter
  ([`adapters/codex/hooks.sh`](../adapters/codex/hooks.sh), arrives in
  T27) wires the native SessionStart / Stop / PreToolUse /
  PostToolUse / PermissionRequest hooks.

## Migration steps for an existing Codex install

1. Re-run `bash install.sh --framework codex` to write the
   `framework.json` config and the per-harness packaging targets.
2. Confirm `lore status` reports `framework=codex` and the capability
   cells above.
3. If you previously installed wrapper scripts that intercepted Codex
   sessions, you can remove them — the native hooks now cover
   SessionStart and Stop. Wrappers are still required for PreCompact
   and TaskCompleted; the install script handles those automatically.

## Where to file follow-ups

- Vendor capability changes (new hooks, dropped hooks, subagent
  semantics shift) → update
  [`adapters/capabilities-evidence.md`](../adapters/capabilities-evidence.md)
  with a fresh `Retrieved:` date, then flip the matching
  [`adapters/capabilities.json`](../adapters/capabilities.json) cell.
  Anything that is not surfaced in `lore status` is invisible to
  operators.
- Lore-side regressions in the codex adapter → file under the
  `multi-framework-agent-support` work item or its successor.
