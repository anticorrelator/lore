# Worker Spawn Template

Three spawn routes. Dispatch precedence is: an explicit per-run model or route pin, then the class's qualified standing route, then the native default. Same-framework targets spawn natively. A foreign target uses the chaperone only when `target_framework` is `codex`; every other foreign pair refuses before spawn. An unqualified binding can still use the legacy Codex route when the user or plan explicitly selects it. The **session-routed** route remains explicit — a `[route: session]` task-line marker (surfaced as the task's `route` field) or a user directive at dispatch. Confirm the effective implementation model against the stated intent before dispatch.

## Per-task judgment class → worker role

Each batch entry from `lore impl open` / `lore impl next-batch` carries a `judgment_class` (`mechanical | standard | judgment-dense`, or `null` on unannotated/legacy tasks). It selects the class-qualified worker role to resolve the model from:

| judgment_class        | worker role            |
|-----------------------|------------------------|
| `mechanical`          | `worker-mechanical`    |
| `standard` / `null`   | `worker`               |
| `judgment-dense`      | `worker-judgment-dense`|

A class role with no binding anywhere resolves identically to plain `worker` (registry `fallback_role`), so routing is byte-identical to the pre-class behavior until a user binds a class role.

**Group the batch by role before spawning:** tasks that resolve the same role can share a model resolution; distinct classes get distinct workers. When same-file serialization merges tasks of different classes onto one worker (the `chain_class` on a `next-batch` collision group), spawn that chain at its `chain_class` — the max class present (judgment-dense > standard > mechanical) — so judgment-dense work never lands on a cheaper binding.

**A user model or route pin at dispatch beats every class binding.** If the user pinned a model for this run, it applies to all classes regardless of `judgment_class`; do not resolve per-class bindings. Otherwise select the matching entry from `worker_class_routes` returned by `lore impl start`. Its keys are `binding`, `source_framework`, `target_framework`, `native_binding`, and `qualified`; `worker_class_models` remains the raw-scalar display surface. Confirm the effective per-class routes against the user's stated intent before spawning.

## Native route — same-harness worker

Use the selected route's `native_binding` when `source_framework == target_framework`, whether the original binding was qualified or not. `impl start` already resolved the `implement` ceremony, class fallback, framework registry, and target-native shape. Do not parse the original `binding` again at spawn.

```
# WORKER_ROUTE is the selected worker_class_routes entry for this group's class.
WORKER_MODEL=$(printf '%s' "$WORKER_ROUTE" | jq -r '.native_binding')

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

## Codex-routed route — chaperone worker

When a qualified standing route has different source and target frameworks and `target_framework == codex`, dispatch `agents/codex-worker.md` automatically. Pass the selected class role and the route's already-resolved `native_binding`; the chaperone must not re-read the Codex settings block for this path. A Codex source targeting Codex uses the native route. The legacy user/plan-directed Codex route remains available for unqualified bindings and passes an empty native binding so the chaperone re-resolves under `LORE_FRAMEWORK=codex`.

The relay uses the first validated tier from the source framework's cheapest-first `model_routing.tiers` ladder. The coordination ledger approved the named model-floor exception on 2026-07-21 (`haiku relay OK`); do not prompt again. Read the ladder through its capability helper rather than spelling an alias:

```
source ~/.lore/scripts/lib.sh
SOURCE_FRAMEWORK=$(printf '%s' "$WORKER_ROUTE" | jq -r '.source_framework')
CODEX_NATIVE_BINDING=$(printf '%s' "$WORKER_ROUTE" | jq -r '.native_binding')
CHAPERONE_MODEL=$(framework_model_routing_tiers "$SOURCE_FRAMEWORK" | head -n1)
```

**Empty-tiers handling:** an empty ladder has no validated relay alias. Do not guess: omit the `model:` field so the chaperone inherits the source session model, and surface that inheritance as degraded relay-tier selection. The Codex implementation route remains active.

Pass the class-qualified role as `{{worker_role}}` for task identity and the legacy resolver path: `worker` for standard/null, `worker-mechanical`, or `worker-judgment-dense`; for a merged same-file chain use the chain's max class.

```
# CHAPERONE_MODEL is empty when the source framework has no validated tiers.
# For the legacy explicit Codex route, set CODEX_NATIVE_BINDING="".

Task:
  subagent_type: "general-purpose"
  model: "$CHAPERONE_MODEL"     # omit this line entirely when CHAPERONE_MODEL is empty
  team_name: "impl-<slug>"
  name: "worker-N"
  mode: "bypassPermissions"
  prompt: |
    <contents of agents/codex-worker.md with {{template}} variables resolved,
     including {{worker_role}} set to the class-qualified role for this task
     and {{native_binding}} set to $CODEX_NATIVE_BINDING>
```

The chaperone sends only the native Codex payload to `adapters/agents/codex.sh split_model_variant`. For a standing route that payload is `{{native_binding}}`; for the legacy explicit route it comes from `LORE_FRAMEWORK=codex resolve_model_for_role {{worker_role}} implement`. The chaperone marks its result `degraded` when Codex returns no parseable report; on a degraded return, re-dispatch the task through the native same-harness route. Routing through Codex remains an optimization, never a dependency.

The chaperone also captures the Codex run's token spend (its terminal `token_count` event) plus its own wall-clock, and relays them as a `**Spend:**` section in the closed spend vocabulary (duration-only, never fabricated tokens, on a degraded run). At task acceptance the lead copies that section into the task's execution-log atom as one `Spend: task=<id> …` line (Step 4 §3); `impl-close` joins it onto the scorecard row's `task_attribution`. Native same-harness workers expose no token stream through this route, so their tasks relay no `**Spend:**` section and carry `spend: null`.

## Session-routed route — worker-session chaperone (marker/user-directed only)

The Task tool spawns Claude-native subagents that report at turn boundaries, so a PTY-hosted worker session — which completes on its own poll-based lifecycle — needs a chaperone: a cheap Claude subagent (`agents/session-worker.md`) that enqueues one `--type worker` session request, blocks in a bounded poll loop over the session journal while the session runs its brief in its own TUI panel, reads the durable report the session leaves behind, and relays it. Spend spreads the same way the codex route spreads it: the chaperone sits cheap on a poll loop while the session burns the implementation tokens.

**Select the session route only on explicit selection** — the task carries a `[route: session]` marker (surfaced as its `route` field) or the user directs session routing at dispatch. It is never a silent default: an in-harness Task worker is cheaper (no live TUI instance to claim the request, no spawn round-trip, no panel slot), so the session route is worth its cost exactly when the work wants full observability — a per-task judgment, not a policy migration.

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
