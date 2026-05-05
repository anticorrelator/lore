# Lore Orchestration Adapter Contract

This file is the canonical reference for how Lore spawns, coordinates,
and collects results from agent fanouts (workers, researchers, reviewers,
judges) across harnesses. Every adapter under `adapters/agents/` consumes
this contract.

> **Status:** Phase 4 contract — operation surface, model routing,
> completion-enforcement *categories* (T31), and the four
> degradation-mode definitions + per-harness assignments + skill
> behavior matrix (T32) are settled. The per-harness adapter
> implementations land in T33 (claude-code), T39 (opencode), T40
> (codex), and the TUI launch + flag-injection integration lives in
> T42-T44. Skill-side wiring lands in T34 (`/spec`), T35
> (`/implement`), and T36-T38 (batch + audit scripts). Until those
> land, the only fully-wired orchestration is the in-tree Claude Code
> TeamCreate/SendMessage path that ships in
> `skills/implement/SKILL.md` and `tui/internal/work/specpanel.go`
> today; opencode and codex are placeholders.

## Operation Surface (Closed Set)

Every adapter exposes exactly seven operations. The shape is identical
across adapters; the implementation language is bash for
claude-code/codex and TypeScript for opencode (mirroring the hook
adapter language split).

| Operation                  | Inputs                                                    | Outputs                                                                                  |
|----------------------------|-----------------------------------------------------------|------------------------------------------------------------------------------------------|
| `spawn`                    | role, task_prompt, work_item_slug, optional model override | spawn_handle (opaque adapter-internal id), or error                                      |
| `wait`                     | spawn_handle, optional timeout                            | `running` / `completed` / `failed` / `timed_out` status                                  |
| `send_message`             | spawn_handle, message body                                | `delivered` / `unsupported` / `error` (unsupported when team_messaging capability=`none`) |
| `collect_result`           | spawn_handle                                              | result_envelope (full text + structured report) or error                                 |
| `shutdown`                 | spawn_handle, optional approve flag                       | `shut_down` / `error`                                                                    |
| `completion_enforcement`   | (no inputs — read-only capability query)                  | one of: `native_blocking` / `lead_validator` / `self_attestation` / `unavailable`        |
| `resolve_model_for_role`   | role                                                      | model id string (delegated to lib.sh / config.go helper) or error                        |

`spawn_handle` is opaque: a Claude Code adapter may use the harness's
internal subagent UUID; an OpenCode adapter may use a plugin runtime
session id; a Codex adapter may use the subagent index. Lore handlers
(`scripts/batch-*`, `skills/{spec,implement}/SKILL.md`) carry the handle
back to subsequent `wait` / `send_message` / `collect_result` /
`shutdown` calls without inspecting it.

**Why these seven?** They cover the full lifecycle of a fanout:

- `spawn` + `wait` + `collect_result` + `shutdown` are the minimum needed
  for a lead-orchestrated fanout (works on every harness).
- `send_message` is the messaging primitive needed by `/spec` and
  `/implement` to pass mid-flight context (Claude Code only today;
  others return `unsupported`).
- `completion_enforcement` is the *capability query* that
  `task-completed-capture-check.sh` and the lead-side validator both
  consult to decide whether worker reports are blocking-checked or
  post-hoc-checked.
- `resolve_model_for_role` is the integration point for D10 — every
  spawn must route through this resolver so role → model bindings take
  effect regardless of harness.

## Capability Gates Per Operation

The adapter MUST consult the active framework's capability profile in
[`adapters/capabilities.json`](../capabilities.json) before exposing an
operation:

| Operation                 | Capability cells consulted                                   | Behavior on insufficient support                                  |
|---------------------------|--------------------------------------------------------------|-------------------------------------------------------------------|
| `spawn`                   | `subagents`                                                  | `subagents=none` → adapter is single-agent only; `spawn` errors.  |
| `wait`                    | `subagents`                                                  | Inherits `spawn` gate.                                            |
| `send_message`            | `team_messaging`                                             | `team_messaging=none` → returns `unsupported`.                    |
| `collect_result`          | `subagents` + `transcript_provider`                          | `transcript_provider=none` → result_envelope omits transcript fields. |
| `shutdown`                | `subagents`                                                  | Inherits `spawn` gate.                                            |
| `completion_enforcement`  | `task_completed_hook` + `subagents`                          | See "Completion Enforcement Degradation Modes" below.             |
| `resolve_model_for_role`  | `model_routing`                                              | `shape=single` → role map collapses to one binding.               |

`completion_enforcement` is the only operation that always returns a
value (not an error) — even on unsupported harnesses, it returns
`unavailable` so callers can branch to a soft warning instead of
treating it as a fatal error.

## Model Routing Integration (D10)

`resolve_model_for_role` is **the** entry point for model selection.
Every adapter operation that spawns a process MUST go through it:

1. The skill or script calls `resolve_model_for_role <role>`
   (bash → `scripts/lib.sh`, Go → `tui/internal/config/framework.go`).
2. The resolver returns a model id that respects the precedence
   (env override → per-repo `.lore.config` → user `framework.json` →
   roles default).
3. The adapter translates the resolved id into the harness-native
   spawn flag:
   - Claude Code: `--model <id>` argument.
   - OpenCode: provider/model selector in the plugin spawn API
     (multi-provider; honors `provider/model` syntax like
     `anthropic/sonnet` or `openai/gpt-4o`).
   - Codex: model selector at session start (single-provider; bare
     model id only).
4. If `validate_role_model_binding` rejects the resolved binding
   (e.g. multi-provider syntax on a single-shape harness), the adapter
   surfaces the error to the caller — no silent fallback to the
   harness default.

The legacy per-invocation `--model` flag remains as a per-call
override at the skill/script level, but the adapter does not see it
directly — the override sets `LORE_MODEL_<ROLE>` for the duration of
the call, and the adapter still resolves through `resolve_model_for_role`.

## Completion Enforcement Degradation Modes

D9 from the multi-framework-agent-support plan: completion enforcement
has four explicit degradation modes, and every fanout-using skill MUST
know which mode it is in *before* it shapes its retry / abandon /
proceed decision. The four modes form a quality ladder — `native_blocking`
gives the strongest correctness guarantee, `unavailable` gives none —
and each has a different failure shape that callers must reason about.

### The four modes

#### `native_blocking`

The harness fires a blocking hook at worker-completion time that can
reject the worker's report **before** the lead resumes orchestration.
A rejected worker is observable to the lead as a non-`completed` task
status; the worker has the chance to fix-and-retry the same turn it
finished on.

- **Where the check fires:** harness-side, synchronously, between the
  worker's last tool use and the lead's next turn.
- **Failure shape:** worker visibly fails the report; lead sees a
  hook-rejected task and can re-prompt the same worker.
- **Required capability cells:** `task_completed_hook=full` AND
  `subagents=full`. Either `partial` on `task_completed_hook` knocks
  the mode down to `lead_validator`.
- **Reference implementation:** `scripts/task-completed-capture-check.sh`
  (Claude Code TaskCompleted hook with exit-2 + stderr feedback per
  the Claude Code wire protocol in
  [`adapters/hooks/README.md`](../hooks/README.md#per-harness-signaling-protocols)).

#### `lead_validator`

No harness-native blocking hook exists. The orchestration adapter's
`collect_result` return path includes a structural validator that the
lead invokes immediately after collection; if the report is malformed,
the lead emits a rejection message back to the worker via the
`send_message` operation (where supported) or, on harnesses without
`send_message`, surfaces the rejection in its own session and re-spawns
the same task.

- **Where the check fires:** lead-side, post-hoc, after the worker's
  turn is fully complete.
- **Failure shape:** report-rejection feedback arrives one round-trip
  later than `native_blocking` (worker has already used a full turn
  emitting the bad report); the lead absorbs the round-trip cost. On
  harnesses without `send_message`, the worker is re-spawned with a
  fresh context rather than getting feedback in-flight, which costs
  one extra prefetch + knowledge load per rejection.
- **Required capability cells:** `subagents` ∈ {`full`, `partial`}
  AND the structural validator (`scripts/validate-worker-report.sh`,
  documented contract; binding implementation lands with T33/T39/T40).
- **Stderr notice contract:** every adapter operating in this mode
  MUST emit, on each rejected report,
  `[lore] degraded: completion_enforcement=lead_validator (report=<task_id> reason=<short>)`
  so the run-time log makes the post-hoc rejection observable to
  the same audit channel that catches `native_blocking` rejections.

#### `self_attestation`

The harness has neither a blocking hook nor a reliable post-hoc
collection path that exposes worker output to the lead with enough
fidelity to validate (e.g., harnesses that surface only summary
strings rather than the full report body). The worker emits a
self-attestation line in its own report — a literal
`Self-attestation: report-conforms-to-template` declaration plus the
worker's own `template_version` — and the lead logs the attestation
without re-validating structure. The audit channel relies on
post-session retro to catch attestation/structure drift.

- **Where the check fires:** worker-side, by self-declaration; lead
  does not re-check.
- **Failure shape:** structurally invalid reports pass the worker's
  attestation gate as long as the worker template was rendered. Catch
  is deferred to retro / `/retro` (manual audit + accumulated drift
  detection over many runs). This is the weakest of the three
  "available" modes and SHOULD only be selected when neither
  `native_blocking` nor `lead_validator` is achievable on the harness.
- **Required capability cells:** `subagents` ∈ {`full`, `partial`,
  `fallback`} AND a worker-rendered template that includes the
  attestation declaration.
- **Reserved for future use.** No harness in the closed
  capabilities.json set selects `self_attestation` today; it is named
  in the contract so that adapter implementors faced with a
  validate-impossible harness have a documented downgrade path before
  resorting to `unavailable`.

#### `unavailable`

No completion-enforcement mechanism is wired. Skills that hard-require
enforcement (today: `bootstrap`, `implement`, `spec` — every skill
whose `task_completed_hook` membership in the T21 capability manifest
[`adapters/capabilities.json:.skills.<name>.requires`](../capabilities.json)
is non-empty) MUST refuse to run rather than proceed silently — the
manifest's `task_completed_hook` requirement is the gate. Skills that
do not require enforcement may proceed; T41 is the task that audits
whether each skill's `requires` array still reflects its real need.

- **Where the check fires:** nowhere.
- **Failure shape:** invalid reports are accepted; downstream pipelines
  (Tier 2 evidence, Tier 3 promotion, work-item index) corrupt
  silently. The retro channel cannot rely on observable rejections
  to detect drift, since none ever fire.
- **Required capability cells:** none — `unavailable` is precisely the
  state where every relevant cell is at `none` or below the
  `lead_validator` threshold.
- **Operator surface:** `lore status` / `lore framework status`
  (T59, T60) MUST display "completion enforcement: UNAVAILABLE" in
  bold whenever this mode is active so the operator sees the
  capability gap before invoking a fanout skill.

### Mode resolution rule

Adapters MUST compute `completion_enforcement` from the active
framework's capability profile at every call (no caching across
sessions — capability overrides may change mid-run). The resolution
table is closed; new combinations require a schema bump.

| `task_completed_hook` cell | `subagents` cell | Resolved mode      | Notes                                                          |
|----------------------------|------------------|--------------------|----------------------------------------------------------------|
| `full`                     | `full`           | `native_blocking`  | Strongest mode; the only mode `bootstrap`/`implement` accept. |
| `full`                     | `partial`        | `native_blocking`  | Subagent context degradation does not weaken hook enforcement. |
| `partial`                  | any              | `lead_validator`   | Partial hook coverage cannot guarantee blocking.               |
| `fallback`                 | `full`/`partial` | `lead_validator`   | Fallback hook exists but is not blocking; lead must validate.  |
| `fallback`                 | `fallback`       | `self_attestation` | Reserved degradation for harnesses where the lead cannot collect a structured report; not used today. |
| `none`                     | any              | `unavailable`      | No hook surface; skills requiring enforcement refuse to run.   |
| any                        | `none`           | `unavailable`      | No subagent surface; the operation is moot.                    |

Two adapter helpers MUST agree on the result of this table: the
bash-side `resolve_completion_enforcement_mode` (lib.sh, lands with
T33) and the Go-side `config.ResolveCompletionEnforcementMode` (TUI,
lands with T42-T43). Parity is asserted in `tests/frameworks/adapters.bats`
(T63) the same way the resolver helpers in T7 are parity-tested in
[`harness_args.bats`](../../tests/frameworks/harness_args.bats).

### Per-harness assignment (today)

Confirmed against the capabilities.json profile and the evidence ids
in [`adapters/capabilities-evidence.md`](../capabilities-evidence.md):

| Harness     | `task_completed_hook` cell | `subagents` cell | Resolved mode     | Evidence                                                                   |
|-------------|----------------------------|------------------|-------------------|----------------------------------------------------------------------------|
| claude-code | `full`                     | `full`           | `native_blocking` | `claude-code-task-completed-hook`, `claude-code-subagents`                |
| opencode    | `fallback`                 | `partial`        | `lead_validator`  | `opencode-task-completed-hook`, `opencode-subagents`                      |
| codex       | `fallback`                 | `partial`        | `lead_validator`  | `codex-task-completed-hook`, `codex-subagents`                            |

When the cells in capabilities.json change, the assignment table here
MUST be updated in lockstep — the bats contract test in T63 asserts
the table rows match the live profile.

### Skill behavior expectations per mode

Skills consume the resolved mode through the `completion_enforcement`
operation; the matrix below is what each skill MUST do per mode. T34
(spec) and T35 (implement) wire these into the skill bodies; T41
encodes the "team-heavy skill gating" gates in capabilities.json.

| Skill                 | `native_blocking`              | `lead_validator`                                | `self_attestation`                              | `unavailable`                                  |
|-----------------------|--------------------------------|-------------------------------------------------|-------------------------------------------------|------------------------------------------------|
| `bootstrap`           | proceed                        | proceed with one-shot stderr degradation notice | refuse (out-of-policy for bootstrap fanout)     | refuse                                         |
| `implement`           | proceed                        | proceed with one-shot stderr degradation notice | refuse                                          | refuse                                         |
| `spec` (team mode)    | proceed                        | proceed with one-shot stderr degradation notice | proceed with per-spawn warning                  | refuse                                         |
| `spec short`          | proceed                        | proceed                                         | proceed                                         | proceed (single-pass; no fanout)               |
| `pr-review`           | proceed                        | proceed (lens fanout is read-only)              | proceed                                         | proceed (sequential lens fallback)             |
| `retro`               | proceed                        | proceed                                         | proceed                                         | proceed                                        |

The "refuse" cells are the load-bearing rows: those are the skills
where running with too-weak enforcement produces silent commons
corruption (Tier 3 promotion of unvalidated reports, work-item index
drift). The capability manifest in
[`adapters/capabilities.json:.skills.<name>.requires`](../capabilities.json)
encodes this as `task_completed_hook` membership in the `requires`
array. As of T32 the manifest already lists `task_completed_hook` for
`bootstrap`, `implement`, and `spec` — matching the "refuse on
unavailable" rows above. T41 (this task) sharpens the gate: the
flat-string requirement form (`"task_completed_hook"` ≡ "must be
`full`") is preserved as a legacy short-hand, and the team-heavy
skills now use the object form to declare a `partial_below` floor
that splits "downgrade to partial-mode" from "refuse outright". See
the next section for the resolution rule and degradation vocabulary.

### Skill requirement schema (T41 partial-mode gating)

`adapters/capabilities.json:.skills.<name>.requires` accepts two
forms; both resolve through the same rule documented in the JSON file's
`skills._description`:

- **Legacy string form** — `"team_messaging"` is shorthand for
  `{"id": "team_messaging", "min_level": "full", "partial_below": "full"}`.
  The cell must reach `full` or the skill is `unavailable` for that
  framework.
- **Object form** — `{"id": "<cap-or-tool>", "min_level": "<level>",
  "partial_below": "<level>", "notes": "<...>"}`. `min_level` is the
  threshold below which the skill enters partial-mode; `partial_below`
  is the threshold below which the skill MUST refuse. Both levels are
  drawn from `support_levels` (`full|partial|fallback|none`), ordered
  most→least capable in `skills._levels_order`.

**Resolution rule (consumed by adapter helpers + `lore framework
doctor`):** for each requirement, look up the active framework's cell
support (or, for tool ids in `tools`, the tool availability). Compare
against `min_level` and `partial_below`:

| Cell support relative to thresholds                | Skill state for that requirement |
|----------------------------------------------------|----------------------------------|
| `cell >= min_level`                                | `full`                           |
| `partial_below <= cell < min_level`                | `partial-mode`                   |
| `cell < partial_below`                             | `unavailable`                    |

Aggregate across the whole `requires` array by taking the worst state
(`unavailable` > `partial-mode` > `full`). A skill is `full` only when
every requirement reads `full`; one `partial-mode` requirement makes
the skill `partial-mode`; one `unavailable` requirement makes the
skill `unavailable` (refuse).

#### Degradation vocabulary

`adapters/capabilities.json:.skills._degradation_vocab` enumerates the
closed set of tokens the orchestration adapter MAY emit on its
`[lore] degraded:` stderr notices and that `lore framework doctor`
SHOULD use in its skill-availability column. Adapter strings outside
this set are a contract violation:

- `partial` — at least one requirement is below `min_level` but at or
  above `partial_below`. Skill ran in partial-mode; adapter emits a
  one-line stderr notice naming the requirement and observed level.
- `fallback` — operation routed through a fallback path declared by
  the requirement (e.g., `lead_validator` instead of
  `native_blocking`). User-visible behavior matches `partial` but the
  underlying cell is named at `fallback` support, not `partial`.
- `none` — at least one requirement is below `partial_below`. Skill
  is `unavailable`; the adapter MUST refuse and emit a stderr notice
  naming the missing requirement.
- `no-evidence` — a depended-on cell has support `> none` but no
  `evidence` pointer. Treat as a soft block: proceed in partial-mode
  with the missing-evidence notice until evidence is refreshed.
- `unverified-support(<level>)` — scoped form for stderr notices when
  a cell has been overridden in `framework.json` without a refreshed
  evidence pointer. The parenthetical level is the original cell's
  level so the operator sees both the override and its source.

#### Today's team-heavy gating (matches the matrix above)

The three team-heavy skills' `requires` arrays now express partial-mode
tolerance. Resolution against today's per-harness profile lands in the
same buckets the skill-behavior matrix calls out:

| Skill       | Requirement              | claude-code (`full`) | opencode profile         | codex profile            |
|-------------|--------------------------|----------------------|--------------------------|--------------------------|
| `bootstrap` | `team_messaging`         | `full`               | `partial-mode` (none)    | `partial-mode` (none)    |
| `bootstrap` | `task_completed_hook`    | `full`               | `partial-mode` (fallback)| `partial-mode` (fallback)|
| `implement` | `team_messaging`         | `full`               | `partial-mode` (none)    | `partial-mode` (none)    |
| `implement` | `task_completed_hook`    | `full`               | `partial-mode` (fallback)| `partial-mode` (fallback)|
| `spec`      | `team_messaging`         | `full`               | `partial-mode` (none)    | `partial-mode` (none)    |
| `spec`      | `task_completed_hook`    | `full`               | `partial-mode` (fallback)| `partial-mode` (fallback)|

For `bootstrap` and `implement` the aggregate state on opencode/codex
is `partial-mode` — the skills proceed but emit the one-shot stderr
degradation notice and route through the lead-orchestrated /
post-hoc-validator paths the SKILL bodies already document. For `spec`
the same `partial-mode` state collapses the team-mode flow to the
spec-short branch (single-pass synthesis, no researcher fanout). None
of the three skills resolve to `unavailable` against today's three
profiles; `unavailable` would require a future harness with
`team_messaging=none` AND `partial_below=full` (i.e., a future
schema regression that lifted the `partial_below` knob back to `full`)
or with `subagents=none` outright.

## Adapter Responsibilities

1. **Mirror the seven operations.** Every adapter file exposes exactly
   the seven operations listed above. Adding an operation requires a
   schema bump to adapters/capabilities.json:.version and a coordinated
   rewrite of all three adapters.
2. **Honor capability gates.** Read
   `adapters/capabilities.json:.frameworks[<active>].capabilities[<cap>].support`
   before each operation. If insufficient, return the documented
   degraded outcome (error, `unsupported`, or specific category like
   `unavailable` for completion_enforcement).
3. **Surface degraded status on every spawn.** When operating with any
   capability cell at `partial` or `fallback`, include a one-line
   stderr notice: `[lore] degraded: <op> via <fallback> (capability=<level>)`.
4. **Smoke output.** Each adapter MUST expose a smoke subcommand that
   prints, for the active framework, every operation paired with its
   support level and (if applicable) the native harness API it routes
   through. Mirrors the hook adapter smoke contract in
   [`adapters/hooks/README.md`](../hooks/README.md).

## Per-Harness Mapping (Today)

| Operation                  | claude-code (T33)                            | opencode (T39)                              | codex (T40)                              |
|----------------------------|----------------------------------------------|---------------------------------------------|------------------------------------------|
| `spawn`                    | TeamCreate / Task spawn                      | plugin runtime spawn                        | subagent spawn (opt-in, requires prompt) |
| `wait`                     | poll TaskList                                | plugin event subscription                   | poll subagent state                      |
| `send_message`             | SendMessage                                  | _unsupported_ (lead-orchestrated only)      | _unsupported_                            |
| `collect_result`           | TaskGet description + transcript             | plugin runtime collect + transcript stub    | subagent output + transcript stub        |
| `shutdown`                 | shutdown_request via SendMessage             | plugin runtime kill                         | subagent stop                            |
| `completion_enforcement`   | `native_blocking`                            | `lead_validator`                            | `lead_validator`                         |
| `resolve_model_for_role`   | `--model <id>` (single)                      | provider/model selector (multi)             | model selector (single)                  |

Cells in italics mark `unsupported`/`fallback` operations per
[`adapters/capabilities.json`](../capabilities.json). Unsupported
operations return the wire-shape `unsupported` documented in the
Operation Surface table; they do not error.

## TUI Launch Concerns (T44)

The TUI's primary-agent launch path (`tui/internal/work/specpanel.go`
`StartTerminalCmd`) is a peer consumer of the orchestration adapter —
it spawns the active harness's binary (resolved via `config.HarnessBinary`)
with adapter-mediated args and optional system-prompt injection.
T42 wired the binary lookup; T43 wires the flag injection; T44
(this section) documents which TUI-injected concerns each harness
supports natively and the per-harness CLI flag spelling.

The three concerns follow the same "harness-native or degraded" model
as the subagent operation surface above: when a concern is
`unsupported`, the TUI skips the injection and the `doctor` surface
(T21) reports `degraded:none` for that concern.

### Concern: `skip_permissions`

Bypasses the harness's interactive permission gate so the TUI-launched
agent does not pause waiting for user approval of tool calls.

Routing: the TUI reads this from `config.LoadHarnessConfig(activeFramework).Args`
(Go) / `load_harness_args` (bash). The flag is **not injected by the
TUI directly** — it must appear in the user-configured harness args
(harness-args.json) or the harness's built-in default. The built-in
default for claude-code is `--dangerously-skip-permissions`; other
harnesses have no built-in default and the operator must configure it.

| Harness      | Flag spelling                         | Support    | Notes                                                                        |
|--------------|---------------------------------------|------------|------------------------------------------------------------------------------|
| `claude-code` | `--dangerously-skip-permissions`     | `full`     | Built-in harness-args default; injected via `LoadHarnessConfig().Args`.     |
| `opencode`   | _(none documented)_                   | `none`     | No equivalent flag in OpenCode CLI surface as of T44; operator configures via harness settings file. |
| `codex`      | `--approve-all-tool-calls` _(approx)_ | `partial`  | Codex approves tool calls via `--approval-policy allow-all`; not a CLI flag — must be set via environment or settings. Operator configures harness-args if needed. |

### Concern: `inline_settings_override`

Injects a JSON settings fragment into the harness session at launch,
overriding per-session configuration without modifying the user's
settings file. Used by the TUI to pin settings for the session scope.

Routing (T11): the TUI resolves the flag spelling via
`config.HarnessSettingsOverrideFlag(activeFramework)` and either appends
`<flag> {}` to args (when the active harness names a flag) or skips
the injection entirely with a one-line `[lore] degraded:` stderr
notice (when the cell is `unsupported`). The flag spelling lives at
`adapters/capabilities.json:.frameworks[<fw>].tui_launch_flags.inline_settings_override`.

| Harness      | Flag spelling       | Support    | Notes                                                                        |
|--------------|---------------------|------------|------------------------------------------------------------------------------|
| `claude-code` | `--settings <json>` | `full`     | Documented Claude Code CLI flag; accepts JSON object. TUI passes `{}` to establish an in-session override anchor. |
| `opencode`   | _(none)_            | `none`     | No inline-settings CLI flag in OpenCode; session config is file-based. T11 skips the injection on opencode. |
| `codex`      | _(none)_            | `none`     | No inline-settings CLI flag in Codex; config is file-based. T11 skips the injection on codex. |

When `inline_settings_override=unsupported` for a harness, the doctor
surface reports `degraded:none` for this concern. The agent still
launches; it just cannot receive an in-flight settings override.

### Concern: `append_system_prompt`

Appends a text block to the harness's system prompt for the session,
used in followup-discuss mode to inject prior-finding context without
editing the user's CLAUDE.md / instructions file.

Routing (T11): the TUI injects this only when `followupMode=true` and
a followup context string is available; the flag spelling is resolved
via `config.HarnessSystemPromptFlag(activeFramework)` and either
prepends `<flag> <sysPrompt>` to args (supported) or skips the
injection with a one-line `[lore] degraded:` stderr notice
(unsupported). Flag spelling lives at
`adapters/capabilities.json:.frameworks[<fw>].tui_launch_flags.append_system_prompt`.

| Harness      | Flag spelling                   | Support    | Notes                                                                        |
|--------------|---------------------------------|------------|------------------------------------------------------------------------------|
| `claude-code` | `--append-system-prompt <text>` | `full`     | Documented Claude Code CLI flag; appended immediately before the positional prompt arg. |
| `opencode`   | _(none)_                        | `none`     | OpenCode has no CLI flag for appending to the system prompt. Adapter-equivalent would require a plugin-runtime injection path (T44 follow-up). |
| `codex`      | _(none)_                        | `none`     | Codex has no equivalent CLI flag. System prompt is configured statically via instructions file or session init. |

When `append_system_prompt=unsupported` for a harness, the TUI skips
the injection and followup-discuss mode launches without the prior
finding context pre-loaded. The user can still invoke
`/followup-discuss` manually; the skill will load context from the
knowledge store on its own.

### Cross-reference

The binary lookup (`config.HarnessBinary`, T42) and harness-args
loading (`config.LoadHarnessConfig`, T10) are the Go-side entry points.
Their bash counterparts (`framework_binary`, `load_harness_args` in
`scripts/lib.sh`) are the parity implementations used by non-TUI
callers. The flag-injection gating (T11) introduced per-concern
capability checks so the TUI does not pass unsupported flags to
opencode or codex; Go-side helpers
`config.HarnessSystemPromptFlag` / `config.HarnessSettingsOverrideFlag`
mirror the bash helper `framework_tui_launch_flag` and the per-adapter
subcommands `system_prompt_flag` / `settings_override_flag`.

## Implementation Targets

| Adapter file                                  | Owner task | Purpose                                                              |
|-----------------------------------------------|------------|----------------------------------------------------------------------|
| `adapters/agents/claude-code.sh`              | T33        | Reference impl. Reads TeamCreate/SendMessage + Task spawn paths.     |
| `adapters/agents/opencode.sh`                 | T39        | Multi-provider plugin runtime; honors `provider/model` bindings.     |
| `adapters/agents/codex.sh`                    | T40        | Native Codex subagent workflows (April 2026 docs); explicit fallback. |
| `tests/frameworks/adapters.bats`              | T63        | Contract tests for every operation × every harness × support level. |

## Pitfalls (Read Before Implementing)

- **Subagent context isolation is necessary but not sufficient.** Fresh
  subagents preserve context efficiency, but `task_completed_hook`
  enforcement is what preserves protocol compliance. Lead-validator
  fallbacks have a different failure mode (post-hoc rejection vs.
  pre-commit blocking) — make sure the skill knows which mode it is in
  before it shapes its retry/abandon decision.
- **`send_message` is opt-in for skills.** Today's `/spec` and
  `/implement` use SendMessage as a primary coordination channel.
  Skills must check `team_messaging` capability before relying on it
  and degrade to lead-only orchestration when `unsupported`. The
  adapter does not silently fake messaging on harnesses that lack it.
- **Model routing is per-spawn, not per-session.** A single fanout
  may resolve `lead → opus`, `worker → sonnet`, `researcher → opus`
  on a multi-provider harness. The adapter MUST re-resolve at every
  `spawn` call; caching a model id across a fanout breaks role
  routing.

## Versioning

This contract is versioned implicitly via
`adapters/capabilities.json:.version` (currently `1`). Adding an
operation, changing the seven-shape return contract, or introducing
a fifth completion-enforcement mode requires a schema bump and a
coordinated rewrite of all three adapters plus the bats coverage in
T63.
