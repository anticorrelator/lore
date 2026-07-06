# Worker Spawn Template

Three spawn routes. **Default is a same-harness Claude worker.** The **codex-routed** route activates **only on explicit user or plan direction** (e.g. the user asked to route implementation to Codex, or the plan names Codex workers) — never silently inherited. The **session-routed** route dispatches the task to a PTY-hosted worker session and activates **only on explicit selection** — a `[route: session]` task-line marker (surfaced as the task's `route` field) or a user directive at dispatch — never a silent default. Before dispatching any route, confirm the resolved worker model against the stated intent; if they disagree, surface it rather than dispatch.

## Per-task judgment class → worker role

Each batch entry from `lore impl open` / `lore impl next-batch` carries a `judgment_class` (`mechanical | standard | judgment-dense`, or `null` on unannotated/legacy tasks). It selects the class-qualified worker role to resolve the model from:

| judgment_class        | worker role            |
|-----------------------|------------------------|
| `mechanical`          | `worker-mechanical`    |
| `standard` / `null`   | `worker`               |
| `judgment-dense`      | `worker-judgment-dense`|

A class role with no binding anywhere resolves identically to plain `worker` (registry `fallback_role`), so routing is byte-identical to the pre-class behavior until a user binds a class role.

**Group the batch by role before spawning:** tasks that resolve the same role can share a model resolution; distinct classes get distinct workers. When same-file serialization merges tasks of different classes onto one worker (the `chain_class` on a `next-batch` collision group), spawn that chain at its `chain_class` — the max class present (judgment-dense > standard > mechanical) — so judgment-dense work never lands on a cheaper binding.

**A user model pin at dispatch beats every class binding.** If the user pinned a model for this run, that model applies to all classes regardless of `judgment_class`; do not resolve per-class bindings. Either way, confirm the effective per-class models against the user's stated intent before spawning — `lore impl start` prints the three class bindings for exactly this check.

## Default route — same-harness worker

Per-spawn model selection routes through the adapter's `resolve_model_for_role <role> implement` operation, where `<role>` is the class-qualified role for the group. The ceremony argument `implement` lets a `ceremony_roles.implement.<role>` binding win over the plain `roles.<role>` binding; with no ceremony binding set, resolution is identical to the role-only form. On Claude Code the adapter returns the model id the lead passes to `TaskCreate`; it validates the binding against the active framework's `model_routing.shape` and rejects mismatches without silent fallback.

```
# WORKER_ROLE is the class-qualified role for this group: worker-mechanical,
# worker, or worker-judgment-dense (see the mapping table above).
WORKER_MODEL=$(bash "$ADAPTER" resolve_model_for_role "$WORKER_ROLE" implement)

Task:
  subagent_type: "general-purpose"
  model: "$WORKER_MODEL"
  team_name: "impl-<slug>"
  name: "worker-N"
  mode: "bypassPermissions"
  prompt: |
    <contents of the worker agent template with {{template}} variables resolved>
    <if advisors: contents of advisory-consultation.md with {{advisors}} resolved>
```

## Codex-routed route — chaperone worker (user/plan-directed only)

The Task tool spawns Claude-native subagents only, so a Codex implementation worker is a chaperone: a cheap Claude subagent (`agents/codex-worker.md`) whose body drives `codex exec` and relays the result. Spend spreads because the chaperone sits blocked on the Codex call at cheap-tier cost while Codex burns the implementation tokens.

**Put the chaperone's Claude tier to the user at codex-dispatch — never default it.** The chaperone only relays (it sits blocked on the Codex call doing no implementation work), so the wrapper design wants it on the cheapest validated tier — `tiers[0]`, haiku. But the standing model-floor directive ([[knowledge:preferences/model-floor-directive-2026-07-05-for-time-being]]) holds work-doing agents at opus minimum and names this chaperone as the one exception *pending an explicit user decision when codex dispatch activates*. So at the dispatch that first routes workers to Codex, ask the user which tier the chaperone runs on — `tiers[0]` (cheapest, per the wrapper design) or opus (per the floor) — and use their answer. Do not silently pick `tiers[0]`; do not silently apply the floor. `model_routing.tiers` is ordered **cheapest-first (ascending capability)**; enumerate the ladder to present the options:

```
source ~/.lore/scripts/lib.sh
framework_model_routing_tiers claude-code   # validated claude-code alias ladder, cheapest-first — present tiers[0] and the opus option to the user
CHAPERONE_MODEL=<the tier the user chose at this dispatch>
```

**Empty-tiers handling:** an empty `tiers` array means claude-code has no validated alias ladder — do not guess an alias (a wrong alias fails only at spawn time). Omit the `model:` field so the chaperone inherits the session default model. The chaperone still routes the implementation to Codex; only its own tier selection is lost.

The class-qualified role is passed to the chaperone as `{{worker_role}}` so it resolves the Codex-side binding for the right class. Resolve it the same way (mapping table above): `worker` for standard/null, `worker-mechanical`, or `worker-judgment-dense`; for a merged same-file chain use the chain's max class.

```
# CHAPERONE_MODEL is empty when claude-code has no validated tiers.

Task:
  subagent_type: "general-purpose"
  model: "$CHAPERONE_MODEL"     # omit this line entirely when CHAPERONE_MODEL is empty
  team_name: "impl-<slug>"
  name: "worker-N"
  mode: "bypassPermissions"
  prompt: |
    <contents of agents/codex-worker.md with {{template}} variables resolved,
     including {{worker_role}} set to the class-qualified role for this task>
```

The chaperone resolves the Codex-side worker binding itself via `LORE_FRAMEWORK=codex resolve_model_for_role {{worker_role}} implement` and reports the effective Codex model back — that resolved model is what to confirm against the user/plan's stated intent. The chaperone marks its result `degraded` when Codex returns no parseable report; on a degraded return, re-dispatch the task as a default-route same-harness worker (codex routing is an optimization, never a dependency).

The chaperone also captures the Codex run's token spend (its terminal `token_count` event) plus its own wall-clock, and relays them as a `**Spend:**` section in the closed spend vocabulary (duration-only, never fabricated tokens, on a degraded run). At task acceptance the lead copies that section into the task's execution-log atom as one `Spend: task=<id> …` line (Step 4 §3); `impl-close` joins it onto the scorecard row's `task_attribution`. Default-route claude-native workers expose no token stream, so their tasks relay no `**Spend:**` section and carry `spend: null`.

## Session-routed route — worker-session chaperone (marker/user-directed only)

The Task tool spawns Claude-native subagents that report at turn boundaries, so a PTY-hosted worker session — which completes on its own poll-based lifecycle — needs a chaperone: a cheap Claude subagent (`agents/session-worker.md`) that enqueues one `--type worker` session request, blocks in a bounded poll loop over the session journal while the session runs its brief in its own TUI panel, reads the durable report the session leaves behind, and relays it. Spend spreads the same way the codex route spreads it: the chaperone sits cheap on a poll loop while the session burns the implementation tokens.

**Select the session route only on explicit selection** — the task carries a `[route: session]` marker (surfaced as its `route` field) or the user directs session routing at dispatch. It is never a silent default: an in-harness Task worker is cheaper (no live TUI instance to claim the request, no spawn round-trip, no panel slot), so the session route is worth its cost exactly when the work wants full observability — a per-task judgment, not a policy migration. The default and codex routes are unchanged.

**Derive the session slug.** A worker session runs under a derived slug `<work-item-slug>--w<n>` (`n` = a per-dispatch ordinal you increment across session-routed dispatches in this run). The derived slug is the session's identity end to end — the TUI keys its panel and journal rows on it, and it is distinct from the work-item slug on purpose (a shared slug would collide with the lead's own implement session and would double-count worker cost into retro's session-spend line). The base work item still travels with the session: in the request's `--context` brief and, once running, in each journal row's `links.work_item`.

**Compose the session-adapted brief and write it to a file.** The brief is the same worker protocol content the default route resolves from `agents/worker.md` (task assignment + phase brief + prior knowledge + evidence contract), adapted for session execution. Write the composed brief to a durable file the chaperone will point `--context` at — `$KDIR/_work/<work-item-slug>/worker-reports/<derived-slug>.brief.md` sits right beside where the report lands and doubles as the observability record of exactly what the session was asked to do. Pass that path to the chaperone as `{{brief_file}}`; the chaperone never reads the brief, it only references the file, which keeps its own context minimal. The session is a standalone harness session, not a team subagent, so the brief's adaptations are:

- **Report lands as a file, not a SendMessage.** The session writes its completion report to `$KDIR/_work/<work-item-slug>/worker-reports/<derived-slug>.md` (`mkdir -p` the directory first) as its final step before terminus — there is no lead to message and no journal event carries a report body. The chaperone reads that file after terminus.
- **Tier 2 rows are self-appended.** The session runs `evidence-append.sh --work-item <work-item-slug>` itself (it has knowledge-store access), landing its rows in the base work item's `task-claims.jsonl` and listing the `claim_id`s in its report — exactly as an in-harness worker does. No relay block, no chaperone-side append.
- **No `SendMessage` / `TaskUpdate` / `TaskList`.** The session has no team-messaging or task-list tools; the chaperone owns the Claude-side task lifecycle. The brief must carry the `task_id` and `phase_id` the Tier 2 rows require, since the session can't read them from a task object.
- **Terminus is explicit.** The brief's closing step, after the report file is durable and the Tier 2 rows are appended, runs `lore session close --self --reason protocol_terminus`. Because the session is agent-initiated, the TUI auto-closes it and journals the `closed` event carrying the session's spend — which is what the chaperone waits on.

**Resolve the worker-session model and surface it — two model decisions, both user-facing.** The worker *session* model resolves per judgment class through the same role bindings the default route uses (`resolve_model_for_role <role> implement`, class-qualified per the mapping table above), held at the opus floor for the session itself, and **surfaced to the user at dispatch** — never silently inherited from the interactive session (honor [[knowledge:preferences/worker-sub-agent-model-selection-is-user-directed]]). That resolved model is passed to the chaperone as `{{worker_model}}` and becomes the session request's `--model`.

The chaperone's *own* Claude tier is the second decision, and it mirrors the codex precedent exactly. The chaperone only relays (it sits blocked on the poll loop doing no implementation work), so the wrapper design wants it on the cheapest validated tier — `tiers[0]`. But the standing model-floor directive ([[knowledge:preferences/model-floor-directive-2026-07-05-for-time-being]]) holds work-doing agents at opus minimum and reserves the chaperone-tier question to the user. So at the dispatch that first routes a worker to a session, ask the user which tier the chaperone runs on — `tiers[0]` (cheapest, per the wrapper design) or opus (per the floor) — and use their answer; do not silently pick either.

```
source ~/.lore/scripts/lib.sh
framework_model_routing_tiers claude-code   # cheapest-first alias ladder — present tiers[0] and the opus option to the user
CHAPERONE_MODEL=<the tier the user chose at this dispatch>   # empty when claude-code has no validated tiers

# WORKER_SESSION_MODEL is resolved per class (opus floor) and confirmed with the user above.
WORKER_SESSION_MODEL=$(bash "$ADAPTER" resolve_model_for_role "$WORKER_ROLE" implement)

Task:
  subagent_type: "general-purpose"
  model: "$CHAPERONE_MODEL"     # omit this line entirely when CHAPERONE_MODEL is empty
  team_name: "impl-<slug>"
  name: "worker-N"
  mode: "bypassPermissions"
  prompt: |
    <contents of agents/session-worker.md with {{template}} variables resolved:
     {{work_item_slug}}, {{derived_slug}}, {{worker_model}} set to
     $WORKER_SESSION_MODEL, and {{brief_file}} set to the path of the brief
     file you wrote above>
```

**Empty-tiers handling** is identical to the codex route: an empty `tiers` array means claude-code has no validated alias ladder — omit the `model:` line so the chaperone inherits the session default, and note the tier selection is lost (the session itself still routes to `{{worker_model}}`).

The chaperone marks its result `degraded` when the request goes unclaimed, the session never reaches terminus, or the report file is missing/unparseable. On a degraded return, re-dispatch the task as a default-route same-harness worker — session routing is an observability choice, never a dependency.

The chaperone builds the `**Spend:**` section from the session's `closed` event (the TUI's type-agnostic enrichment already measured it; the chaperone flattens the spend object and never wall-clocks the run). At task acceptance the lead copies that section into one `Spend: task=<id> …` execution-log line (Step 4 §3), the same seam codex uses; `impl-close` joins it onto `task_attribution`. Because the session runs under a derived slug, its `closed` row is intentionally invisible to retro's exact-work-item-slug session-spend line — worker cost is per-task attribution, session-spend is the orchestration's own cost.
