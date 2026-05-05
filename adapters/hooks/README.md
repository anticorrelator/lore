# Lore Hook Adapter Contract

This file is the canonical reference for how Lore's lifecycle events map
to per-harness hook surfaces. Every adapter under `adapters/hooks/` and
`adapters/{opencode,codex}/` consumes this contract.

> **Status:** Phase 3 contract — closed event set, dispatch shape, per-event
> blocking semantics, per-harness signaling protocols, and degradation
> levels are settled (T24). Adapter implementations land in T25 (Claude
> Code hook installer refactor), T26 (OpenCode plugin), T27 (Codex
> hooks), T28 (per-harness settings/permissions installer), and T30
> (bats smoke tests). Until those land, the only fully-wired adapter is
> the Claude Code hook surface that ships in `install.sh` today;
> OpenCode and Codex adapters are placeholders.

## Lifecycle Events (Closed Set)

Lore defines exactly nine lifecycle event names. Adapters MUST handle
every event, either by mapping to a native harness hook or by reporting
degraded status (per the support level in
[`adapters/capabilities.json`](../capabilities.json)).

| Lore event           | Fires when                                                                                       | Capability cell consumed         |
|----------------------|--------------------------------------------------------------------------------------------------|----------------------------------|
| `session_start`      | A new agent session begins (first user prompt of a session).                                     | `session_start_hook`             |
| `user_prompt`        | The user submits a prompt within an active session.                                              | `tool_hooks` (proxy in practice) |
| `pre_tool`           | Before a tool call is executed.                                                                  | `tool_hooks`                     |
| `post_tool`          | After a tool call returns.                                                                       | `tool_hooks`                     |
| `permission_request` | The agent requests permission for a privileged operation.                                        | `permission_hooks`               |
| `pre_compact`        | Before context-window compaction discards prior messages.                                        | `pre_compact_hook`               |
| `stop`               | The agent stops a turn (end-of-turn, may be followed by another `user_prompt`).                  | `stop_hook`                      |
| `session_end`        | The user explicitly closes/clears the session (e.g. `/clear`).                                   | `stop_hook` (terminal variant)   |
| `task_completed`     | A spawned worker subagent completes a task and returns its report (Lore-specific, blocking gate). | `task_completed_hook`            |

**Why these nine?** They cover the full set of Lore protocols that need
to react to harness state: knowledge/work/thread loading at session
start, plan-persistence reminders before compaction, novelty review at
stop, worker-report verification at task completion, and tool-policy
enforcement throughout the turn. Adding a new lifecycle event requires a
schema bump (closed set; not free-form).

## Dispatch Contract

Every adapter exposes a single dispatch entrypoint that translates
**native harness hook events** into one of the nine Lore lifecycle
events listed above. The shape is identical across adapters; the
implementation language differs (bash for claude-code/codex, TypeScript
for opencode).

### Inputs

Every dispatch invocation receives exactly four arguments. The first
three are Lore-normalized; the fourth is the raw harness payload.

```text
event_name      = one of the nine lifecycle event names (closed set)
session_id      = harness session identifier (UUID-shaped) or empty
work_item_slug  = Lore work item slug if active, else empty
payload         = harness-native event payload (JSON), unmodified
```

The adapter MUST NOT mutate `payload` before dispatch — Lore handlers
may need the raw harness shape (e.g. for transcript path resolution
on stop-novelty-check.py, or matcher fields on guard-work-writes.sh).

#### Per-event payload schema

Every Lore handler is shaped around an expected payload. Adapters
translate the native harness payload into the schema below before
invoking the handler. Fields marked optional are absent when the harness
does not surface them (e.g., codex SessionStart does not carry
`source`); handlers MUST tolerate absence.

| Lore event           | Required payload fields                                                       | Optional payload fields                                  |
|----------------------|-------------------------------------------------------------------------------|----------------------------------------------------------|
| `session_start`      | `session_id`, `cwd`                                                           | `source` (`startup` \| `resume` \| `compact`), `transcript_path` |
| `user_prompt`        | `session_id`, `prompt_text`                                                   | `prompt_id`, `transcript_path`                           |
| `pre_tool`           | `session_id`, `tool_name`, `tool_input` (raw JSON)                            | `matcher_match` (true if tool matched a configured matcher) |
| `post_tool`          | `session_id`, `tool_name`, `tool_output` (raw JSON), `tool_status` (ok\|err) | `tool_input`, `duration_ms`                              |
| `permission_request` | `session_id`, `tool_name`, `tool_input`, `permission_kind`                    | `escalation_reason`                                      |
| `pre_compact`        | `session_id`                                                                  | `transcript_path`, `compaction_reason`                   |
| `stop`               | `session_id`                                                                  | `transcript_path`, `stop_reason`                         |
| `session_end`        | `session_id`, `end_reason` (`clear` \| `quit` \| `crash`)                    | `transcript_path`                                        |
| `task_completed`     | `session_id`, `task_id`, `task_subject`, `worker_report_text`                 | `team_name`, `task_owner`, `transcript_path`             |

Adapters that cannot derive a required field from the native payload
MUST classify the event as `unsupported` (see Outputs); they MUST NOT
invent values or pass empty strings, since Lore handlers branch on
required-field presence.

### Outputs

Every dispatch invocation returns exactly one of five outcomes. The
allowed outcomes per event are constrained by the **blocking matrix**
below; an outcome that is not allowed for an event is itself an `error`.

| Outcome           | Meaning                                                                                                  | Wire shape                                                |
|-------------------|----------------------------------------------------------------------------------------------------------|-----------------------------------------------------------|
| `allow`           | The harness should proceed with the operation that triggered the hook.                                   | exit 0, optional stdout/stderr informational messages     |
| `deny`            | The harness must block the operation and surface the reason to the agent.                                | exit non-zero or `{decision: "block", reason: ...}` JSON (per harness, see below) |
| `notify`          | The hook fired for a non-blocking event (e.g. session_start). Lore handlers ran; no decision is required. | exit 0 (same wire as `allow`; semantic distinction only) |
| `unsupported`     | The harness has no native equivalent for this Lore event; lore-side handler did not run.                  | exit 0 with stderr: `[lore] unsupported event: <name>`    |
| `error`           | A hook script failed unexpectedly (parse error, missing dependency, contract violation).                  | exit non-zero with stderr describing the failure          |

Hook **failures** (`error`) MUST be reported on stderr, never silently
swallowed. The capability profile dictates whether `error` is fatal to
the session: `support=full` events MUST treat `error` as fatal;
`support=partial`/`support=fallback` events SHOULD log and continue.

#### Blocking matrix (which outcomes are valid per event)

Only three of the nine events may legitimately `deny`. For the rest,
`deny` is a contract violation and adapters MUST translate it into
`error` before forwarding to the harness — otherwise a buggy handler
could break a non-blockable lifecycle event (e.g., aborting
`session_start` after the session is already running).

| Lore event           | `allow` | `deny`     | `notify` | `unsupported` | Rationale                                                         |
|----------------------|---------|------------|----------|---------------|-------------------------------------------------------------------|
| `session_start`      | yes     | NO         | yes      | yes           | Session has already begun; no operation left to block.            |
| `user_prompt`        | yes     | yes        | yes      | yes           | Adapter MAY block a prompt that violates a workspace policy.      |
| `pre_tool`           | yes     | yes        | yes      | yes           | Canonical blocking surface (guard-work-writes.sh).                |
| `post_tool`          | yes     | NO         | yes      | yes           | Tool already executed; only post-hoc observation is meaningful.   |
| `permission_request` | yes     | yes        | yes      | yes           | Permission escalation is the textbook deny case.                  |
| `pre_compact`        | yes     | NO         | yes      | yes           | Compaction is harness-driven; Lore advises, never blocks.         |
| `stop`               | yes     | NO         | yes      | yes           | Stop is a notification; novelty check and plan persistence advise only. |
| `session_end`        | yes     | NO         | yes      | yes           | Session is terminating; nothing left to block.                    |
| `task_completed`     | yes     | yes        | yes      | yes           | Lead-side gate that rejects malformed worker reports.             |

A handler that wishes to advise without blocking on a `deny`-capable
event SHOULD return `notify` and write its advice to stderr; the
distinction lets adapters that lack a native blocking channel (codex,
opencode for `task_completed`) downgrade gracefully.

### Per-harness signaling protocols

The four outcomes above are the abstract Lore contract; each harness
encodes them differently on the wire. The footgun is that **the same
harness uses different signaling protocols for different event types**
— a Claude Code `pre_tool` hook that uses `exit 2` to attempt to block
will silently fail (PreToolUse needs JSON stdout), while a
TaskCompleted hook that uses JSON stdout will be ignored (it needs
`exit 2`). Adapter implementors MUST honor the table below; the
authoritative source for the Claude Code protocols is
[`gotchas/hooks/hook-system-gotchas.md`](https://github.com/anticorrelator/lore/blob/main/gotchas/hooks/hook-system-gotchas.md),
mirrored here for adapter convenience.

#### Claude Code wire protocols (per native event type)

| Native event       | `allow`                  | `deny`                                                  | `notify` (informational)        |
|--------------------|--------------------------|---------------------------------------------------------|---------------------------------|
| SessionStart       | exit 0                   | _not blockable; treat deny as `error`_                  | exit 0 + stdout/stderr          |
| UserPromptSubmit   | exit 0                   | `{"decision":"block","reason":"..."}` JSON on stdout    | exit 0 + stderr                 |
| PreToolUse         | exit 0 (or `{"decision":"approve"}`) | `{"decision":"block","reason":"..."}` JSON on stdout | exit 0 + stderr                |
| PostToolUse        | exit 0                   | _not blockable; treat deny as `error`_                  | exit 0 + stderr                 |
| PreCompact         | exit 0                   | _not blockable; treat deny as `error`_                  | exit 0 + stdout/stderr          |
| Stop               | exit 0 (or `{ok:true,...}`) | `{"decision":"block","reason":"..."}` JSON on stdout (or `{ok:false,reason:...}`) | exit 0 + stderr |
| SessionEnd         | exit 0                   | _not blockable; treat deny as `error`_                  | exit 0 + stderr                 |
| TaskCompleted      | exit 0                   | **`exit 2` + stderr feedback** (NOT JSON)               | exit 0 + stderr                 |

The TaskCompleted exit-2 protocol predates the JSON protocol and is the
single asymmetric case in Claude Code's hook surface. Cross-reference
[`scripts/task-completed-capture-check.sh`](https://github.com/anticorrelator/lore/blob/main/scripts/task-completed-capture-check.sh)
for the canonical implementation pattern.

#### OpenCode plugin returns (per plugin event)

OpenCode plugins are TypeScript modules; each plugin function returns a
typed result object rather than communicating via exit codes/JSON
stdout. Adapter MUST translate Lore outcomes into the plugin runtime's
return shape:

| Lore outcome     | OpenCode plugin return (typical shape)                       |
|------------------|--------------------------------------------------------------|
| `allow`          | `return { allow: true }` (or simply `return undefined`)      |
| `deny`           | `return { allow: false, reason: "..." }`                     |
| `notify`         | `return undefined` after side-effecting (logging, capture writes) |
| `unsupported`    | _adapter-side: skip plugin registration entirely_            |
| `error`          | `throw new Error("...")` — OpenCode logs and continues       |

The exact field names are owned by the OpenCode plugin SDK;
[`adapters/opencode/lore-hooks.ts`](https://github.com/anticorrelator/lore/blob/main/adapters/opencode/lore-hooks.ts)
(T26) is the source of truth and MUST validate against the SDK at
build time. The contract here is the Lore-side semantic mapping; the
TypeScript shape may rename fields without breaking this contract.

#### Codex hook returns (per native event)

Codex hooks (introduced in Codex CLI 0.123.0, stable in 0.124.0) signal
via a structured `behavior` field rather than exit codes for the
permission-style events, and via exit codes for the
notification-shaped events:

| Native event       | `allow`                                | `deny`                                  | `notify`                       |
|--------------------|----------------------------------------|-----------------------------------------|--------------------------------|
| SessionStart       | exit 0                                 | _not blockable; treat deny as `error`_  | exit 0 + stderr                |
| PreToolUse         | exit 0                                 | exit non-zero (Codex aborts the tool)   | exit 0 + stderr                |
| PostToolUse        | exit 0                                 | _not blockable; treat deny as `error`_  | exit 0 + stderr                |
| PermissionRequest  | `{"behavior":"allow"}` JSON on stdout  | `{"behavior":"deny","reason":"..."}` JSON on stdout (or `{"behavior":"abstain"}` to delegate) | exit 0 + stderr |
| Stop               | exit 0                                 | _not blockable; treat deny as `error`_  | exit 0 + stderr                |

PreCompact and TaskCompleted-blocking are not part of the Codex native
hook surface. The codex adapter MUST classify them as `unsupported` and
the orchestration layer (T31/T32) MUST provide the lead-side validator
fallback for the `task_completed` blocking semantics. See
[`docs/codex-migration.md`](https://github.com/anticorrelator/lore/blob/main/docs/codex-migration.md)
(T67) for the migration narrative superseding the prior "notify-only"
premise.

### Adapter implementor's checklist

Every adapter (T25 claude-code, T26 opencode, T27 codex) MUST tick the
following items before it is considered Phase 3 complete. The hook
smoke test (T30) asserts items 5 and 6; items 1-4 are reviewed at
land-time and pinned by Tier 2 evidence rows on the implementing PR.

- [ ] **1. Translate.** Receive a native harness hook event, decide
      which (if any) of the nine Lore events it represents, and invoke
      the matching Lore handler script (`scripts/load-knowledge.sh`,
      `scripts/load-work.sh`, `scripts/load-threads.sh`,
      `scripts/pre-compact.sh`, `scripts/stop-novelty-check.py`,
      `scripts/check-plan-persistence.py`,
      `scripts/task-completed-capture-check.sh`, plus any
      adapter-specific shims).
- [ ] **2. Honor capability gates.** Read
      `adapters/capabilities.json:.frameworks[<active>].capabilities[<cap>].support`
      before dispatching. If the cell is `none`, return `unsupported`
      immediately without invoking handlers. Source of truth for the
      cell value is `framework_capability <cap>` (lib.sh) /
      `config.FrameworkCapability` (Go); do NOT re-implement the
      override-then-static-profile lookup inline.
- [ ] **3. Honor the blocking matrix.** Reject `deny` outcomes from
      events flagged non-blockable in the matrix above by translating
      them to `error` with stderr
      `[lore] contract violation: deny on non-blockable event <name>`.
- [ ] **4. Surface degraded status.** Adapters with `support=fallback`
      MUST include a one-line stderr notice on every dispatch:
      `[lore] degraded: <event> via <fallback mechanism> (capability=<level>)`.
      Adapters with `support=partial` SHOULD log on first dispatch per
      session (latched via env var or sentinel file).
- [ ] **5. Smoke output.** Each adapter MUST expose a smoke subcommand
      (`<adapter> --smoke` or equivalent) that prints, for the active
      framework, every Lore lifecycle event paired with its support
      level and (if applicable) the native harness hook it routes
      through. Phase 3 verification:
      *"Each adapter can run a local smoke command that prints which
      Lore lifecycle events are native, fallback, or unavailable."*
- [ ] **6. Stable script paths.** All `command` strings written to
      harness settings MUST use the
      `~/.lore/scripts/<name>` form (resolved via the install.sh
      symlink chain), not `$(pwd)`-relative or repo-absolute paths.
      Per [[knowledge:conventions/scripting/shell-script-conventions]]:
      "hook shims should shell out through shared helpers and stable
      `~/.lore/scripts` paths." Justified exceptions (e.g., debug
      bootstrap before installation) MUST be documented inline.
- [ ] **7. Path resolution via helper, not hardcoded.** When a hook
      script needs a harness install path (e.g., to read a settings
      file or write an ephemeral plan), it MUST consult
      `resolve_harness_install_path <kind>` (T7) and branch on the
      `unsupported` sentinel rather than hardcoding `~/.claude/...`.
      Pattern from worker-4's T29/T69 migrations:
      `if path=$(resolve_harness_install_path teams); [[ "$path" != "unsupported" ]]; then ... fi`.
- [ ] **8. Evidence anchor.** Each cell that is wired as `full`,
      `partial`, or `fallback` MUST resolve to a dated evidence id in
      [`adapters/capabilities-evidence.md`](../capabilities-evidence.md)
      (D8 evidence-gating rule). Adapters do NOT re-state the evidence;
      they consume the cell support level only.

## Per-Harness Mapping (Today)

The mappings below are the dispatch table. Each cell carries the
support level from
[`adapters/capabilities.json`](../capabilities.json) inline so adapter
implementors don't have to round-trip through the JSON to read it; the
JSON remains the source of truth and any divergence here is a bug.
Evidence ids resolve in
[`adapters/capabilities-evidence.md`](../capabilities-evidence.md).

| Lore event           | claude-code adapter (T25)                                    | opencode adapter (T26)                            | codex adapter (T27)                              |
|----------------------|--------------------------------------------------------------|---------------------------------------------------|--------------------------------------------------|
| `session_start`      | **full** — SessionStart hook                                 | **partial** — plugin `session.start`              | **full** — SessionStart hook                     |
| `user_prompt`        | **full** — UserPromptSubmit hook                             | **partial** — plugin `prompt.submit`              | **fallback** — derive from SessionStart bookend  |
| `pre_tool`           | **full** — PreToolUse hook                                   | **partial** — plugin `tool.before`                | **full** — PreToolUse hook                       |
| `post_tool`          | **full** — PostToolUse hook                                  | **partial** — plugin `tool.after`                 | **full** — PostToolUse hook                      |
| `permission_request` | **full** — PreToolUse JSON-stdout decision protocol          | **partial** — plugin `permission.request`         | **full** — PermissionRequest hook                |
| `pre_compact`        | **full** — PreCompact hook                                   | **fallback** — SessionStart bookend               | **fallback** — SessionStart bookend              |
| `stop`               | **full** — Stop hook                                         | **partial** — plugin `session.stop`               | **full** — Stop hook                             |
| `session_end`        | **full** — SessionEnd hook (matcher=`clear`)                 | **partial** — plugin `session.end`                | **fallback** — derive from Stop                  |
| `task_completed`     | **full** — TaskCompleted hook (exit-2 blocking)              | **fallback** — lead-side validator (see T31, T32) | **fallback** — lead-side validator (see T31, T32) |

**`user_prompt` proxy mapping.** There is no dedicated
`user_prompt_hook` cell in `adapters/capabilities.json`; the support
level for this row is derived from the harness's `tool_hooks` cell on
claude-code/opencode (UserPromptSubmit and prompt.submit are the
relevant native events) and downgraded to `fallback` on codex (no
native equivalent — derive from SessionStart bookend on every new
turn). If `user_prompt` ever needs differentiated capability tracking,
T21's sidecar manifest is the right place to add it without bloating
the global capabilities map.

**Why opencode cells are `partial`, not `full`.** OpenCode's plugin
runtime exposes the right event names but its accept/deny shape and
matcher semantics differ from Claude Code's PreToolUse JSON-stdout
contract; the T26 adapter has to translate plugin return values into
Lore's outcome shape and may lose fidelity on edge cases (e.g.,
fine-grained matcher patterns). `partial` is the honest status until
the T26 implementation has been driven against the full Lore handler
suite. Promotion to `full` is allowed only after T30's hooks.bats
suite covers every Lore outcome on opencode without
adapter-introduced divergence.

`task_completed` is a Lore-only contract — only Claude Code has a
native blocking hook for it. On opencode and codex the
**orchestration adapter** (not the hook adapter) provides the
lead-side validator fallback: the spawning agent re-reads the worker
report, asserts the required-section invariants
(`Tier 2 evidence`, `Surfaced concerns`, etc.), and rejects the worker
turn with an explicit message instead of relying on a harness hook to
block. This is the hook ↔ orchestration cross-reference; see
[`adapters/agents/README.md`](../agents/README.md) sections "Completion
enforcement degradation modes" (T32) and the orchestration adapter
contract (T31) for the exact validator semantics.

Per [[knowledge:architecture/knowledge/retrieval/three-layer-knowledge-delivery-architecture]],
the `session_start` row is the load-bearing one for memory delivery —
all three harnesses need it `full` for SessionStart to drive
load-knowledge.sh / load-work.sh / load-threads.sh in the same shape.
That's the explicit Phase 3 verification gate:
*"Session-start memory loading works through the native hook path for
every framework that advertises `session_start_hook`."*

## Implementation Targets

| Adapter file                                           | Owner task | Purpose                                                                  |
|--------------------------------------------------------|------------|--------------------------------------------------------------------------|
| `adapters/hooks/claude-code.sh`                        | T25        | Refactor of current `install.sh` Claude hook installation. Reference impl that other adapters can compare against. |
| `adapters/opencode/lore-hooks.ts`                      | T26        | OpenCode plugin runtime mapping plugin events to Lore handlers.          |
| `adapters/codex/hooks.sh`                              | T27        | Codex native-hooks-first installer; PreCompact + TaskCompleted-blocking handled by orchestration adapter (T31, T32) per the hook ↔ orchestration cross-reference above. |
| `install.sh` (per-harness installer split, T28)        | T28        | Reads the cell support levels from this contract and writes the
correct settings/permissions block per harness; depends on T25 landing first. |
| `tests/frameworks/hooks.bats`                          | T30        | Smoke coverage for input/output shape across all four outcomes per harness. Asserts adapter implementor's checklist items 5 (smoke output) and 6 (stable script paths). |

### Cross-cutting touchpoints

- **Evidence attachment on degraded harnesses (T55).** When the
  capability cell is `partial` or `fallback`, Tier 2 evidence emission
  via `evidence-append.sh` MUST keep working — degraded hook surfaces
  do not exempt the adapter from the work-evidence trail. The
  orchestration adapter is responsible for ensuring evidence rows
  still attach to the active work item even when the native
  `task_completed` hook is unavailable.
- **Path resolution (T7).** Every hook script that needs a harness
  install path goes through `resolve_harness_install_path <kind>` per
  checklist item 7; this is the same dispatch table used by
  `agent-toggle/{enable,disable}.sh` (T19) and `scripts/load-work.sh`
  (T29). New adapters MUST NOT hardcode `~/.claude/...` or any other
  per-harness root.
- **Closed-set framework rejection (T6).** Adapters resolve the active
  framework via `resolve_active_framework` (lib.sh) /
  `config.ResolveActiveFramework` (Go). An adapter that hardcodes a
  framework name in a `case "$FRAMEWORK"` switch reintroduces the
  framework-name conditional pattern Phase 1 D1 forbids; use the
  capability lookup instead.

## Hook Pitfalls (Read Before Wiring)

The Claude-Code-specific hook signaling protocol footguns are
documented in
[`gotchas/hooks/hook-system-gotchas.md`](https://github.com/anticorrelator/lore/blob/main/gotchas/hooks/hook-system-gotchas.md).
The April 2026 update there also covers Codex's current hook surface
and the two genuine gaps (PreCompact, TaskCompleted-blocking) that this
contract handles via fallback. Do not implement an adapter without
reading that file first.

## Versioning

This contract is versioned implicitly via Lore's `adapters/capabilities.json:.version`
(currently `1`). Adding a new lifecycle event, or changing the four-outcome
output shape, requires a schema bump and a coordinated rewrite of all
three adapters plus the bats smoke tests.
