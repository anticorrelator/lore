# Capability Evidence

Dated vendor-doc evidence backing every non-`none` capability cell in
`adapters/capabilities.json`. Each entry has a stable id (used as the
`evidence` field in the capability profile) and the six fields the plan's
D8 evidence contract requires:

- **Source:** vendor or community docs page (or local artifact).
- **URL / path:** durable pointer.
- **Retrieved:** ISO date the URL was fetched.
- **Product / version:** product name and version when the docs name one;
  otherwise `unversioned`.
- **Claim:** what this evidence supports.
- **Consumed by:** the `frameworks.<id>.capabilities.<cap>` cells (and
  `frameworks.<id>.model_routing`) that point at this evidence id.

Workers wiring a capability to `full`, `partial`, or `fallback` in any
Phase 2-7 task MUST cite a row here. If a row is older than 90 days,
undated, versionless, or disputed, the cell may be used only as `partial`
or `fallback` until the evidence is refreshed; otherwise the cell drops
to `none` plus a degraded-status note (D8).

The `_index` block at the bottom enumerates every evidence id so
`tests/frameworks/capabilities.bats` (T13) can validate that every
non-`none` cell points at an id that exists here.

---

## Claude Code

### claude-code-instructions

- **Source:** Anthropic — Claude Code Memory reference
- **URL / path:** https://code.claude.com/docs/en/memory
- **Retrieved:** 2026-05-03
- **Product / version:** Claude Code, unversioned (docs site, current)
- **Claim:** Claude Code loads `~/.claude/CLAUDE.md` (user) and
  `./CLAUDE.md` (project) as instruction files at session start.
- **Consumed by:** `claude-code.capabilities.instructions`.

### claude-code-skills

- **Source:** Anthropic — Claude Code Skills reference
- **URL / path:** https://code.claude.com/docs/en/skills
- **Retrieved:** 2026-05-03
- **Product / version:** Claude Code, unversioned (docs site, current)
- **Claim:** Personal skills live at `~/.claude/skills/<name>/SKILL.md`,
  project skills at `.claude/skills/<name>/SKILL.md`. SKILL.md uses YAML
  frontmatter (`name`, `description`, `allowed-tools`, `model`,
  `disable-model-invocation`, `context: fork`, etc.) and is invoked via
  `/<skill-name>` or auto-loaded by description match.
- **Consumed by:** `claude-code.capabilities.skills`.

### claude-code-mcp

- **Source:** Anthropic — Claude Code MCP reference
- **URL / path:** https://code.claude.com/docs/en/mcp
- **Retrieved:** 2026-05-03
- **Product / version:** Claude Code, unversioned
- **Claim:** MCP servers are configured in `~/.claude/settings.json`
  under the top-level `mcpServers` key (stdio, SSE, and streamable-HTTP
  transports supported).
- **Consumed by:** `claude-code.capabilities.mcp`.

### claude-code-session-start-hook

- **Source:** Anthropic — Claude Code Hooks reference
- **URL / path:** https://code.claude.com/docs/en/hooks
- **Retrieved:** 2026-05-03
- **Product / version:** Claude Code, unversioned
- **Claim:** `SessionStart` is one of the documented session-cadence
  hooks; it fires when a session begins or resumes (matcher distinguishes
  `startup`, `resume`, `clear`).
- **Consumed by:** `claude-code.capabilities.session_start_hook`.

### claude-code-stop-hook

- **Source:** Anthropic — Claude Code Hooks reference
- **URL / path:** https://code.claude.com/docs/en/hooks
- **Retrieved:** 2026-05-03
- **Product / version:** Claude Code, unversioned
- **Claim:** `Stop` (and `SubagentStop`, `StopFailure`) hooks are
  documented turn-cadence events; Stop accepts JSON-stdout
  `{"decision":"block","reason":"..."}` for fine-grained control.
- **Consumed by:** `claude-code.capabilities.stop_hook`.

### claude-code-pre-compact-hook

- **Source:** Anthropic — Claude Code Hooks reference
- **URL / path:** https://code.claude.com/docs/en/hooks
- **Retrieved:** 2026-05-03
- **Product / version:** Claude Code, unversioned
- **Claim:** `PreCompact` (paired with `PostCompact`) is a documented
  hook event that fires before and after context compaction. `SessionEnd`
  with matcher `clear` is the documented partner used by lore for the
  `/clear` path.
- **Consumed by:** `claude-code.capabilities.pre_compact_hook`.

### claude-code-tool-hooks

- **Source:** Anthropic — Claude Code Hooks reference
- **URL / path:** https://code.claude.com/docs/en/hooks
- **Retrieved:** 2026-05-03
- **Product / version:** Claude Code, unversioned
- **Claim:** `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, and
  `PostToolBatch` are documented per-tool-call hooks; `PreToolUse`
  accepts a `matcher` field (e.g. `"Write"`) that scopes invocation to
  named tools.
- **Consumed by:** `claude-code.capabilities.tool_hooks`.

### claude-code-permission-hooks

- **Source:** Anthropic — Claude Code Hooks reference
- **URL / path:** https://code.claude.com/docs/en/hooks
- **Retrieved:** 2026-05-03
- **Product / version:** Claude Code, unversioned
- **Claim:** `PreToolUse` accepts JSON-stdout `{"decision":"block",
  "reason":"..."}` to deny a tool call before it executes;
  `PermissionRequest` and `PermissionDenied` events are also documented.
- **Consumed by:** `claude-code.capabilities.permission_hooks`.

### claude-code-task-completed-hook

- **Source:** Anthropic — Claude Code Hooks reference
- **URL / path:** https://code.claude.com/docs/en/hooks
- **Retrieved:** 2026-05-03
- **Product / version:** Claude Code, unversioned
- **Claim:** `TaskCompleted` is a documented hook event that fires when
  a task is being marked completed; it uses exit-code signaling
  (`exit 0` allow, `exit 2` block with stderr fed back to the model).
  `TaskCreated`, `SubagentStart`, `SubagentStop` are the related
  task/subagent-lifecycle events.
- **Consumed by:** `claude-code.capabilities.task_completed_hook`.

### claude-code-subagents

- **Source:** Anthropic — Claude Code Subagents reference
- **URL / path:** https://code.claude.com/docs/en/sub-agents
- **Retrieved:** 2026-05-03
- **Product / version:** Claude Code, unversioned
- **Claim:** Subagents (`general-purpose`, `Explore`, `Plan`, plus
  custom agents under `~/.claude/agents/` and `.claude/agents/`) spawn
  fresh isolated contexts via the Task tool or `context: fork` skills;
  the spawned context does not inherit the parent's conversation history.
- **Consumed by:** `claude-code.capabilities.subagents`.

### claude-code-team-messaging

- **Source:** Anthropic — Claude Code Agent Teams reference
- **URL / path:** https://code.claude.com/docs/en/agent-teams
- **Retrieved:** 2026-05-03
- **Product / version:** Claude Code, unversioned
- **Claim:** Agent teams expose `TeamCreate`, `SendMessage`, and the
  `TeammateIdle` hook so a lead can spawn workers, deliver inter-agent
  messages, and observe idle teammates; persistent team state lives
  under `~/.claude/teams/`.
- **Consumed by:** `claude-code.capabilities.team_messaging`.

### claude-code-transcript-provider

- **Source:** Anthropic — Claude Code Hooks reference (transcript_path
  in hook payload) and Claude Code Logging reference
- **URL / path:** https://code.claude.com/docs/en/hooks (hook payload
  schema), https://code.claude.com/docs/en/logging
- **Retrieved:** 2026-05-03
- **Product / version:** Claude Code, unversioned
- **Claim:** Each session writes a JSONL transcript at
  `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`; hook payloads
  include `transcript_path` so external scripts can parse the JSONL for
  digest, novelty, and ceremony detection.
- **Consumed by:** `claude-code.capabilities.transcript_provider`.

### claude-code-headless-runner

- **Source:** Anthropic — Claude Code CLI reference (`-p` / `--print`)
- **URL / path:** https://code.claude.com/docs/en/cli-reference
- **Retrieved:** 2026-05-03
- **Product / version:** Claude Code, unversioned
- **Claim:** `claude -p <prompt>` (also `--print`) runs Claude Code
  non-interactively, prints the assistant response to stdout, and exits;
  used by `audit-artifact.sh` and other batch judges.
- **Consumed by:** `claude-code.capabilities.headless_runner`.

### claude-code-model-routing

- **Source:** Anthropic — Claude Code CLI reference (`--model`) and
  Claude Code Models reference
- **URL / path:** https://code.claude.com/docs/en/cli-reference,
  https://code.claude.com/docs/en/model-config
- **Retrieved:** 2026-05-03
- **Product / version:** Claude Code, unversioned
- **Claim:** Claude Code accepts `--model <id>` and `/model` to choose
  among Anthropic-provider models (Opus, Sonnet, Haiku). Provider is
  fixed to Anthropic; per-spawn provider routing across non-Anthropic
  providers is not supported. This justifies the `single` model_routing
  shape — the role→model map collapses to one binding.
- **Consumed by:** `claude-code.model_routing` (`shape: single`).

---

## OpenCode

### opencode-instructions

- **Source:** OpenCode — Rules reference
- **URL / path:** https://opencode.ai/docs/rules/
- **Retrieved:** 2026-05-03
- **Product / version:** OpenCode, "Last updated: May 1, 2026" per the
  page footer
- **Claim:** OpenCode reads `AGENTS.md` (project) and
  `~/.config/opencode/AGENTS.md` (global) as instruction files; for
  Claude Code migration it falls back to `CLAUDE.md` (project) and
  `~/.claude/CLAUDE.md` (global). Compatibility is on by default and
  can be disabled via `OPENCODE_DISABLE_CLAUDE_CODE`.
- **Consumed by:** `opencode.capabilities.instructions`.

### opencode-skills

- **Source:** OpenCode — Skills reference
- **URL / path:** https://opencode.ai/docs/skills/
- **Retrieved:** 2026-05-03
- **Product / version:** OpenCode, "Last updated: May 1, 2026"
- **Claim:** OpenCode discovers SKILL.md from project paths
  (`.opencode/skills/<name>/SKILL.md`, `.claude/skills/<name>/SKILL.md`,
  `.agents/skills/<name>/SKILL.md`) and global paths
  (`~/.config/opencode/skills/<name>/SKILL.md`,
  `~/.claude/skills/<name>/SKILL.md`,
  `~/.agents/skills/<name>/SKILL.md`). Existing `~/.claude/skills/`
  symlinks created by lore's `install.sh` are picked up natively.
- **Consumed by:** `opencode.capabilities.skills`.

### opencode-mcp

- **Source:** OpenCode — MCP servers / Config reference
- **URL / path:** https://opencode.ai/docs/mcp/, https://opencode.ai/docs/config/
- **Retrieved:** 2026-05-03
- **Product / version:** OpenCode, "Last updated: May 1, 2026"
- **Claim:** OpenCode supports MCP servers configured in its own
  `opencode.json` config (project or `~/.config/opencode/opencode.json`).
  Path differs from `~/.claude/settings.json`, requiring per-harness MCP
  packaging — hence the `partial` cell.
- **Consumed by:** `opencode.capabilities.mcp`.

### opencode-session-start-hook

- **Source:** OpenCode — Plugins reference (event list)
- **URL / path:** https://opencode.ai/docs/plugins/
- **Retrieved:** 2026-05-03
- **Product / version:** OpenCode, "Last updated: May 1, 2026"
- **Claim:** Plugin events `session.created`, `session.updated`,
  `server.connected` fire at session lifecycle moments. The plugin
  runtime is the surface lore uses to wire SessionStart-equivalent
  behavior; coverage is `partial` because the lore-side first-turn
  pipeline (pending captures, pending digest) depends on plugin runtime
  guarantees not yet exercised end-to-end.
- **Consumed by:** `opencode.capabilities.session_start_hook`.

### opencode-stop-hook

- **Source:** OpenCode — Plugins reference (event list)
- **URL / path:** https://opencode.ai/docs/plugins/
- **Retrieved:** 2026-05-03
- **Product / version:** OpenCode, "Last updated: May 1, 2026"
- **Claim:** Plugin events `session.idle`, `session.status`, and
  `message.updated` fire at end-of-turn / agent-stop boundaries. Used to
  trigger novelty-check and plan-persistence reminders; degraded if the
  harness does not surface full transcript context to the plugin.
- **Consumed by:** `opencode.capabilities.stop_hook`.

### opencode-pre-compact-hook

- **Source:** OpenCode — Plugins reference (experimental events)
- **URL / path:** https://opencode.ai/docs/plugins/
- **Retrieved:** 2026-05-03
- **Product / version:** OpenCode, "Last updated: May 1, 2026"
- **Claim:** `experimental.session.compacting` fires before the LLM
  generates a continuation summary, and `session.compacted` fires after.
  The `experimental.` prefix downgrades this to `fallback` because the
  event is explicitly not stable per the docs.
- **Consumed by:** `opencode.capabilities.pre_compact_hook`.

### opencode-tool-hooks

- **Source:** OpenCode — Plugins reference (tool events)
- **URL / path:** https://opencode.ai/docs/plugins/
- **Retrieved:** 2026-05-03
- **Product / version:** OpenCode, "Last updated: May 1, 2026"
- **Claim:** `tool.execute.before` and `tool.execute.after` fire around
  tool invocations. Matcher coverage and blocking semantics differ from
  Claude `PreToolUse` (event-bus shape rather than synchronous JSON
  decision), so the cell is `partial`.
- **Consumed by:** `opencode.capabilities.tool_hooks`.

### opencode-permission-hooks

- **Source:** OpenCode — Plugins reference (permission events)
- **URL / path:** https://opencode.ai/docs/plugins/
- **Retrieved:** 2026-05-03
- **Product / version:** OpenCode, "Last updated: May 1, 2026"
- **Claim:** `permission.asked` and `permission.replied` events expose
  permission lifecycle. The accept/deny shape is event-driven rather
  than blocking-decision JSON, so adapter translation is required —
  `partial`.
- **Consumed by:** `opencode.capabilities.permission_hooks`.

### opencode-task-completed-hook

- **Source:** OpenCode — Plugins reference (event list, no
  TaskCompleted-equivalent)
- **URL / path:** https://opencode.ai/docs/plugins/
- **Retrieved:** 2026-05-03
- **Product / version:** OpenCode, "Last updated: May 1, 2026"
- **Claim:** No native subagent-completion blocking event in the
  documented event list; `todo.updated` is the closest signal. Lore
  falls back to the lead-side validator pattern (D9 fallback mode:
  lead-side validator after result collection).
- **Consumed by:** `opencode.capabilities.task_completed_hook`.

### opencode-subagents

- **Source:** OpenCode — Agents reference
- **URL / path:** https://opencode.ai/docs/agents/
- **Retrieved:** 2026-05-03
- **Product / version:** OpenCode, "Last updated: May 1, 2026"
- **Claim:** OpenCode supports custom agents via Markdown files at
  `.opencode/agents/<name>.md` (project) and
  `~/.config/opencode/agents/<name>.md` (global), or JSON entries in
  `opencode.json`. The Markdown filename becomes the agent name. Fresh
  context for spawned subagents is supported; team-state semantics are
  not equivalent to Claude's TeamCreate, hence `partial`.
- **Consumed by:** `opencode.capabilities.subagents`.

### opencode-transcript-provider

- **Source:** OpenCode — Plugins reference (`message.updated`,
  `session.diff`, `session.updated`) and Sessions reference
- **URL / path:** https://opencode.ai/docs/plugins/, https://opencode.ai/docs/sessions/
- **Retrieved:** 2026-05-03
- **Product / version:** OpenCode, "Last updated: May 1, 2026"
- **Claim:** OpenCode persists session artifacts and exposes them via
  plugin events; format differs from Claude JSONL (no compatible
  `transcript_path` field passed to hooks). Provider stub translates
  what it can and reports degraded for missing fields — `partial`.
- **Consumed by:** `opencode.capabilities.transcript_provider`.

### opencode-headless-runner

- **Source:** OpenCode — Commands reference (`opencode run`)
- **URL / path:** https://opencode.ai/docs/cli/, https://opencode.ai/docs/commands/
- **Retrieved:** 2026-05-03
- **Product / version:** OpenCode, "Last updated: May 1, 2026"
- **Claim:** OpenCode supports non-interactive prompt invocation via
  `opencode run <prompt>` (subcommand spelling differs from Claude's
  `claude -p`). `audit-artifact.sh` routes through the
  `headless_runner` adapter rather than calling the binary directly,
  hence `partial` until the per-harness invocation table is finalized.
- **Consumed by:** `opencode.capabilities.headless_runner`.

### opencode-plugin-runtime

- **Source:** OpenCode — Plugins reference (TypeScript/JavaScript
  plugin runtime)
- **URL / path:** https://opencode.ai/docs/plugins/
- **Retrieved:** 2026-05-03
- **Product / version:** OpenCode, "Last updated: May 1, 2026"
- **Claim:** OpenCode loads plugins from `.opencode/plugins/` (project)
  and `~/.config/opencode/plugins/` (global) at startup; npm packages
  are also loadable via the `plugin` config option and cached at
  `~/.cache/opencode/node_modules/`. Plugins are TypeScript/JavaScript
  modules that subscribe to the documented event list; lore ships
  `adapters/opencode/lore-hooks.ts` here.
- **Consumed by:** `opencode.capabilities.plugin_runtime`.

### opencode-model-routing

- **Source:** OpenCode — Models / Providers reference
- **URL / path:** https://opencode.ai/docs/models/, https://opencode.ai/docs/providers/
- **Retrieved:** 2026-05-03
- **Product / version:** OpenCode, "Last updated: May 1, 2026"
- **Claim:** OpenCode uses the AI SDK + Models.dev to support 75+ LLM
  providers; model IDs in agent config use the
  `<provider>/<model-id>` shape. Per-agent / per-spawn provider routing
  is supported, justifying the `multi` model_routing shape — the
  role→model map honors per-role bindings (e.g., Opus for lead, Haiku
  for worker fanout, GPT-class for review).
- **Consumed by:** `opencode.model_routing` (`shape: multi`).

---

## Codex

### codex-instructions

- **Source:** OpenAI Developers — Codex AGENTS.md guide
- **URL / path:** https://developers.openai.com/codex/guides/agents-md
- **Retrieved:** 2026-05-03
- **Product / version:** Codex CLI, current docs (versionless on the
  page; D8 90-day-freshness rule applies)
- **Claim:** Codex reads `AGENTS.md` (and `AGENTS.override.md`) at
  global scope (`$CODEX_HOME`, default `~/.codex`) and project scope
  (walked from the git root downward). `project_doc_fallback_filenames`
  in `config.toml` lets users add `CLAUDE.md` to the discovery list, so
  the existing assembled CLAUDE.md is reachable on Codex when the user
  configures the fallback. `assemble-instructions.sh --framework codex`
  emits AGENTS.md instead of CLAUDE.md as the primary path.
- **Consumed by:** `codex.capabilities.instructions`.

### codex-skills

- **Source:** OpenAI Developers — Codex Skills reference
- **URL / path:** https://developers.openai.com/codex/skills
- **Retrieved:** 2026-05-03
- **Product / version:** Codex CLI, current docs
- **Claim:** Codex documents a native skills surface that loads
  SKILL.md files. Per-skill discovery semantics (eager vs. lazy load,
  description-budget behavior, frontmatter field set) differ from
  Claude Code's documented behavior, so the cell is `partial` until the
  Codex side is exercised end-to-end by lore.
- **Consumed by:** `codex.capabilities.skills`.

### codex-mcp

- **Source:** OpenAI Developers — Codex MCP reference
- **URL / path:** https://developers.openai.com/codex/mcp
- **Retrieved:** 2026-05-03
- **Product / version:** Codex CLI, current docs
- **Claim:** Codex registers MCP servers via `[mcp_servers.<name>]`
  TOML tables in `~/.codex/config.toml` (global) or
  `.codex/config.toml` (project, trusted only). Both stdio and
  streamable-HTTP transports are supported. Lore packages MCP servers
  to this path through the per-harness MCP packaging adapter.
- **Consumed by:** `codex.capabilities.mcp`.

### codex-session-start-hook

- **Source:** OpenAI Developers — Codex Hooks reference and Codex
  changelog
- **URL / path:** https://developers.openai.com/codex/hooks,
  https://developers.openai.com/codex/changelog
- **Retrieved:** 2026-05-03
- **Product / version:** Codex CLI 0.123.0 (hooks introduced) /
  0.124.0 (hooks marked stable), April 2026 per the changelog
- **Claim:** Codex's `SessionStart` hook fires when a session begins,
  with a matcher that distinguishes `startup`, `resume`, and `clear`.
  Hooks share the JSON shape `{continue, stopReason, systemMessage,
  suppressOutput}` and SessionStart stdout is appended as developer
  context. **This evidence supersedes the February 2026 'Codex has no
  session lifecycle hooks' premise** in `gotchas/hooks/hook-system-gotchas.md`
  and is the source of record for T16 / T67.
- **Consumed by:** `codex.capabilities.session_start_hook`.

### codex-stop-hook

- **Source:** OpenAI Developers — Codex Hooks reference
- **URL / path:** https://developers.openai.com/codex/hooks
- **Retrieved:** 2026-05-03
- **Product / version:** Codex CLI 0.124.0 (hooks stable), April 2026
- **Claim:** Codex's `Stop` hook fires when a conversation turn stops;
  hooks can return continuation instructions rather than reject. No
  matcher support.
- **Consumed by:** `codex.capabilities.stop_hook`.

### codex-pre-compact-hook

- **Source:** OpenAI Developers — Codex Hooks reference (event list,
  no PreCompact-equivalent in current docs)
- **URL / path:** https://developers.openai.com/codex/hooks
- **Retrieved:** 2026-05-03
- **Product / version:** Codex CLI 0.124.0, April 2026
- **Claim:** No native PreCompact event documented in the current
  Codex hook surface (SessionStart, UserPromptSubmit, PreToolUse,
  PermissionRequest, PostToolUse, Stop). Lore falls back to using
  Stop / SessionStart bookends to remind the user to persist plans
  before compaction events the harness does not expose.
- **Consumed by:** `codex.capabilities.pre_compact_hook`.

### codex-tool-hooks

- **Source:** OpenAI Developers — Codex Hooks reference
- **URL / path:** https://developers.openai.com/codex/hooks
- **Retrieved:** 2026-05-03
- **Product / version:** Codex CLI 0.124.0 (hooks stable, MCP-aware),
  April 2026
- **Claim:** `PreToolUse` fires before tool execution for Bash, file
  edits via `apply_patch`, and MCP tools (matcher filters by tool
  name). `PostToolUse` fires after supported tools complete (including
  failures). PreToolUse can block by returning
  `permissionDecision: "deny"`.
- **Consumed by:** `codex.capabilities.tool_hooks`.

### codex-permission-hooks

- **Source:** OpenAI Developers — Codex Hooks reference
- **URL / path:** https://developers.openai.com/codex/hooks
- **Retrieved:** 2026-05-03
- **Product / version:** Codex CLI 0.124.0, April 2026
- **Claim:** `PermissionRequest` fires when Codex requests approval
  (e.g., shell escalation), with matcher by tool name. Hooks return
  `behavior: "allow" | "deny" | "abstain"`; any `deny` blocks the
  request. Distinct from PreToolUse's `permissionDecision` shape, so
  the hook adapter must use the right field per event.
- **Consumed by:** `codex.capabilities.permission_hooks`.

### codex-task-completed-hook

- **Source:** OpenAI Developers — Codex Hooks reference (event list,
  no TaskCompleted-equivalent)
- **URL / path:** https://developers.openai.com/codex/hooks
- **Retrieved:** 2026-05-03
- **Product / version:** Codex CLI 0.124.0, April 2026
- **Claim:** No native subagent-completion blocking event in the
  documented hook surface. The `Stop` hook fires at turn end but does
  not target a per-task report and does not have an `exit 2 + stderr`
  blocking interface like Claude's TaskCompleted. Lore falls back to
  the lead-side validator pattern (D9 fallback mode: lead-side
  validator after result collection).
- **Consumed by:** `codex.capabilities.task_completed_hook`.

### codex-subagents

- **Source:** OpenAI Developers — Codex Subagents reference
- **URL / path:** https://developers.openai.com/codex/subagents
- **Retrieved:** 2026-05-03
- **Product / version:** Codex CLI, current docs (subagents enabled by
  default per docs)
- **Claim:** Custom subagents are TOML files in `~/.codex/agents/`
  (personal) or `.codex/agents/` (project) with `name`, `description`,
  and `developer_instructions` fields. Codex orchestrates spawn /
  follow-up / wait / consolidate when explicitly asked. Defaults:
  `agents.max_threads=6`, `agents.max_depth=1`. Fresh-context
  guarantees match Claude's Task spawn but team-state semantics differ,
  hence `partial`.
- **Consumed by:** `codex.capabilities.subagents`.

### codex-transcript-provider

- **Source:** OpenAI Developers — Codex CLI reference (session rollout
  files via `codex exec resume`)
- **URL / path:** https://developers.openai.com/codex/cli/reference
- **Retrieved:** 2026-05-03
- **Product / version:** Codex CLI, current docs
- **Claim:** Codex persists session rollout files to disk by default
  (`--ephemeral` opts out). `codex exec resume [SESSION_ID]` reloads
  them. Format differs from Claude JSONL, so the provider stub
  translates available fields and reports degraded for missing ones —
  `partial`.
- **Consumed by:** `codex.capabilities.transcript_provider`.

### codex-headless-runner

- **Source:** OpenAI Developers — Codex CLI reference (`codex exec`)
- **URL / path:** https://developers.openai.com/codex/cli/reference
- **Retrieved:** 2026-05-03
- **Product / version:** Codex CLI, current docs
- **Claim:** `codex exec [PROMPT]` (alias `codex e`) runs without
  human interaction. Supports stdin (`codex exec -`), `--json`
  newline-delimited event output, `--ephemeral`, and `--model, -m`.
  Used by `audit-artifact.sh` and other batch judges via the
  `headless_runner` adapter.
- **Consumed by:** `codex.capabilities.headless_runner`.

### codex-model-routing

- **Source:** OpenAI Developers — Codex CLI reference (`--model, -m`)
- **URL / path:** https://developers.openai.com/codex/cli/reference
- **Retrieved:** 2026-05-03
- **Product / version:** Codex CLI, current docs
- **Claim:** `--model, -m <id>` selects the model (e.g., gpt-5.4).
  `--oss` routes through a local Ollama provider; `--profile, -p` picks
  a configured provider profile. Although profiles let users define
  multiple providers in `config.toml`, a single Codex session selects
  one provider/model — there is no per-spawn multi-provider routing
  primitive lore can target. This justifies the `single` model_routing
  shape.
- **Consumed by:** `codex.model_routing` (`shape: single`).

---

## Known gaps and harness-specific exclusions

These are intentionally `none` (or out of scope) and are listed here so
T70 / `lore doctor` can distinguish a gap from a missing-evidence error.

- **`claude-code.plugin_runtime` = none.** Claude Code hooks are shell
  or python commands; there is no in-process plugin runtime equivalent
  to OpenCode's TypeScript plugins. Scripts handle every extension
  need. No evidence pointer required.
- **`codex.plugin_runtime` = none.** Codex hooks are shell commands
  invoked from `config.toml`; no in-process plugin runtime. (The
  changelog mentions `0.128.0` "plugin workflows" via marketplace, but
  that is plugin distribution, not an in-process event-bus runtime.)
- **`opencode.team_messaging` = none and `codex.team_messaging` = none.**
  Neither harness exposes a TeamCreate / SendMessage primitive. Skills
  that require inter-agent messaging (`/spec`, `/implement` team mode)
  must run in lead-orchestrated fanout/aggregation mode. T41 encodes
  the gating.
- **`scripts/claude-billing.sh` (Claude Pro/Max keychain wrapper) is
  harness-specific by design.** It is not migrated to other harnesses
  because it wraps Anthropic Pro/Max subscription billing, which only
  applies under Claude Code. T70 tags it; `lore doctor` does not flag
  its absence on non-Claude harnesses.

---

## Refresh policy

- **Cadence:** Re-fetch every URL on a 90-day rolling window. The D8
  rule downgrades any cell whose evidence row is older than 90 days
  to at most `partial`.
- **Disputed evidence:** If a worker hits a behavior that contradicts
  the cited row, mark the cell `partial` or `fallback`, file the
  dispute in `gotchas/hooks/`, and refresh the row before the next
  release.
- **Source preference:** Prefer first-party vendor docs over community
  changelogs / blog posts. When only a community source exists, capture
  it but flag the source explicitly so `lore doctor` can warn that the
  evidence is non-canonical.

---

## _index

Every evidence id used by `adapters/capabilities.json`. T13's
`tests/frameworks/capabilities.bats` should validate that this list
matches the union of all `evidence:` fields in capabilities.json.

- claude-code-instructions
- claude-code-skills
- claude-code-mcp
- claude-code-session-start-hook
- claude-code-stop-hook
- claude-code-pre-compact-hook
- claude-code-tool-hooks
- claude-code-permission-hooks
- claude-code-task-completed-hook
- claude-code-subagents
- claude-code-team-messaging
- claude-code-transcript-provider
- claude-code-headless-runner
- claude-code-model-routing
- opencode-instructions
- opencode-skills
- opencode-mcp
- opencode-session-start-hook
- opencode-stop-hook
- opencode-pre-compact-hook
- opencode-tool-hooks
- opencode-permission-hooks
- opencode-task-completed-hook
- opencode-subagents
- opencode-transcript-provider
- opencode-headless-runner
- opencode-plugin-runtime
- opencode-model-routing
- codex-instructions
- codex-skills
- codex-mcp
- codex-session-start-hook
- codex-stop-hook
- codex-pre-compact-hook
- codex-tool-hooks
- codex-permission-hooks
- codex-task-completed-hook
- codex-subagents
- codex-transcript-provider
- codex-headless-runner
- codex-model-routing
