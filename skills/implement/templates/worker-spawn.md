# Worker Spawn Template

Three spawn routes. Dispatch precedence is: an explicit per-run model or route pin, then the class's qualified standing route, then the native default. Same-framework targets spawn natively. A foreign target uses the chaperone only when `target_framework` is `codex`; every other foreign pair refuses before spawn. An unqualified binding can still use the legacy Codex route when the user or plan explicitly selects it. The **session-routed** route remains explicit — a `[route: session]` task-line marker (surfaced as the task's `route` field) or a user directive at dispatch. Confirm the effective implementation model against the stated intent before dispatch.

Route selection and model selection are one axis; what the worker reads is another. A run opened with `--compiled-positions` sends each worker the compiled worker brief for its target framework, bound to its task through the position binder, and this file's first half describes that. A run opened without the flag stays on the long `agents/worker.md` template with the legacy hashes, and the second half is unchanged for it. Both halves keep the same pins, class roles, placement rules, and report landing, because those were never properties of the template text.

## Guidance floor

Every launch carries one invocation-fresh guidance block as its first bytes, and the two paths get it there differently.

On the compiled path, render the block to a file immediately before compiling the target: `lore dispatch guidance > "$GUIDANCE_FILE"`. If rendering fails, stop before compiling. The compiler takes that file, the binder checks the same bytes at publication, and the payload's first component is the block. Nothing is prepended at the tool call, because the frozen payload already begins with it and a second copy would change the bytes a later reader checks against `payload_sha256`.

On the legacy path, render the block immediately before each Task launch and prepend the complete output verbatim to the exact prompt, before the resolved template and task context; render again for every worker, chaperone, and retry. Nested launches receive separate renderings at their own assembly seams.

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

## Compiled dispatch

The compiled path has one preparation sequence, then a route-specific launch. The sequence exists so that what the worker reads, who it is, and where its report lands are one immutable record before anything runs.

1. **Compile the selected target against fresh guidance.** `start` returned `position_descriptors[<framework>][worker]` for every target it could resolve. Those are snapshots of what compiled at start; the guidance block is rendered per launch, so compile again now:

   ```bash
   lore dispatch guidance > "$GUIDANCE_FILE" || exit 1
   bash ~/.lore/scripts/position-compile.sh worker --framework "$TARGET_FRAMEWORK" \
     --kdir "$KDIR" --guidance-file "$GUIDANCE_FILE" > "$DESCRIPTOR_FILE"
   ```

   The descriptor's `template_version` is the producer version this worker will stamp. When guidance has not changed since start, it equals the start snapshot; when it has, this one is the version to carry, and the start value is not.

2. **Assemble the bindings.** Begin from the TaskCreate entry's `position_binding_inputs` — work item, task, revision, packet id and pointer, dispatch attempt, and the exact assignment — and add what only dispatch knows: `report_id` (`<task-id>-r<attempt>`, filesystem-safe, fresh on every re-dispatch), `report_path` (`$ITEM_DIR/worker-reports/<report-id>.md`; the binder refuses any other shape for a worker), and `execution_root` (the allocated `execution_dir` for a mutating task; the checkout the worker will read for a read-only one). `mode`, `consultation_id`, `domain`, and `reply_destination` stay null with a reason in `absence_reasons`, because they belong to the designer. Every field is present or explained; the binder refuses a missing one rather than inferring it.

   A legacy item whose entry reports `revision_id` or `dispatch_attempt_id` as `legacy-unbound` cannot take this path: compiled worker completion requires task, revision, and packet bindings, and inventing a revision would put a made-up identity on the record built to prevent them. Adopt the item through `lore plan revise` first, or leave it on the legacy route.

3. **Name the wrapper and author its bytes.** The wrapper is the routing file whose text is delivered around the compiled brief, recorded apart from the brief so both stay attributable:

   ```json
   {"template_id": "implement/worker-spawn", "template_version": "<template-version.sh of this file>",
    "path": "<absolute path of this file>", "sha256": "<sha256 of this file>"}
   ```

   The prefix is the identity header lines, in this order, one per line: `Packet-id:`, `Report-id:`, `Revision-id:`, `Dispatch-attempt-id:`. The suffix is the dispatch note at the end of this file, filled in for this task. Neither may carry a guidance block; the binder refuses a second floor. On the chaperone route the wrapper is `agents/codex-worker.md` (`template_id` `implement/codex-worker`) and the suffix is that file's chaperone note, because the text Codex reads around the brief is the chaperone's.

4. **Bind.** One call freezes payload, native definition, and manifest under `position-dispatch/<attempt-id>/` and returns the six-field reference:

   ```bash
   python3 ~/.lore/scripts/position-bind.py bind --descriptor "$DESCRIPTOR_FILE" --bindings "$BINDINGS_FILE" \
     --kdir "$KDIR" --guidance-file "$GUIDANCE_FILE" \
     --wrapper "$WRAPPER_FILE" --prefix-file "$PREFIX_FILE" --suffix-file "$SUFFIX_FILE" \
     --require task_id --require revision_id --require packet_id --require packet_pointer \
     [--native-model "$WORKER_MODEL"]
   ```

   Pass `--native-model` on the two native routes; omit it on the chaperone route, where Codex consumes the payload as a primary prompt. The reference (`manifest_path`, `manifest_sha256`, `payload_path`, `payload_sha256`, `native_path`, `native_sha256`) is the lead's independent copy of this attempt's identity. Hold it per task and record it on the team task with `TaskUpdate` as `metadata.position_dispatch`, with `metadata.lore_task_id` set to the plan task id, before any launch; the completion hook reads the reference from there and never from the report. An identical retry returns the same reference; a changed payload under the same attempt refuses, and a real retry mints a fresh attempt and report id.

5. **Launch by route.**

   - **Native, Claude Code** (`source_framework == target_framework == claude-code`). The compiled definition has to be a name the running session's `Agent` tool offers, and the binder owns the file:

     ```bash
     python3 ~/.lore/scripts/position-bind.py register-native "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256" --scope "$AGENTS_SCOPE"
     python3 ~/.lore/scripts/position-bind.py native-input "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256" --scope "$AGENTS_SCOPE"
     ```

     `$AGENTS_SCOPE` is an absolute, physically resolved `.claude/agents` directory this session already watches; `resolve_harness_install_path agents` names the user-level one lore installs into. `native-input` returns `tool_input` (`subagent_type` — the `lore-position-` name, `model`, and `prompt` filled with the exact payload) and `readiness: {kind: native-agent-inventory, selection_name}`. Check that `selection_name` is among the `subagent_type` values the live tool offers before calling. A file on disk is not that check, because a shell cannot see which directories the session watched at startup or whether a higher-precedence definition shadows the name. When the name is absent, this task stays undispatched and the run record names the readiness boundary; a `general-purpose` call instead would attribute the report to a brief the worker never read. Then call `Agent` with `subagent_type`, `model`, and `prompt` from `tool_input`, plus the tool's own `description`, `team_name` `impl-<slug>`, `name` `worker-N`, and `mode` as before. Do not rename `prompt`, drop `model`, edit the bytes, or add a digest parameter; the worker reads the manifest path from its payload and computes the digest itself.

     The compiled Claude definition carries Read, Glob, Grep, Bash, Write, and Edit, and no task or messaging tools, so the worker's report comes back as the call's result, and a required consultation comes back the same way: the worker returns its `## Consultation` request and stops, and the reply sent to its `name` resumes it. The lead holds the team task on every compiled route, because the completion reference lives with the lead: set `owner` at launch, re-read the task once before the call to confirm the claim still holds (another lead on the same team could have taken it), land the result with `lore coordinate report "$SLUG" --report-id "$REPORT_ID"`, run the completion check with `{"position_dispatch": <reference>, "lore_task_id": "<task-id>"}` on stdin (Step 4 §1), and only then mark the task completed.

   - **Native, Codex** (`source_framework == target_framework == codex`). Run `native-input` without `--scope`; nothing is registered, because Codex takes the prepared text directly. `tool_input` carries the split model and effort keys plus `message` filled with the exact payload, and `readiness` is `{kind: native-tool-schema, tool: spawn_agent}`: the check owed is that the tool exposed in this session accepts those fields. Supplement only the caller fields its schema requires — a `task_name`, a non-inheriting fork setting — and pass the rest as returned. A model or effort the tool rejects is reported as rejected, not dropped. Keep the handle the tool returns with the attempt: a Codex child's tools are supplied by its harness, not by the compiled definition, and the child's report and any consultation reach you through the collection and follow-up operations the live tool exposes for that handle.

   - **Chaperone** (a qualified route whose `target_framework` is `codex` from another source, or the legacy explicit Codex selection). Bind without `--native-model`, with the codex-worker wrapper and its note as the suffix, then dispatch `agents/codex-worker.md` with the compiled variables described in its route section below. The chaperone runs `codex exec` on the exact payload bytes and relays what Codex returned.

   - **Session** (explicit selection only). Placement decides which of two contexts the session request carries; both use this file's identity lines as the prefix and the session note in `agents/session-worker.md` as the suffix, under the wrapper identity `implement/session-worker` (that file's `template-version.sh` hash, path, and sha256), because the text the session reads around the brief is the chaperone file's. Under ordinary placement the host allocates the tree, so nothing can be published here: the bindings carry `execution_root` null with a reason, and the context is the binder's pending preparation, which retains the exact wrapper source, prefix, suffix, and activation so the host publishes exactly what was admitted. No CLI verb wraps this call, so load the library by path:

     ```bash
     python3 - "$KDIR" "$DESCRIPTOR_FILE" "$BINDINGS_FILE" "$GUIDANCE_FILE" "$WRAPPER_FILE" "$PREFIX_FILE" "$SUFFIX_FILE" > "$CONTEXT_FILE" <<'PY'
     import importlib.util, json, sys
     from pathlib import Path
     kdir, descriptor, bindings, guidance, wrapper, prefix, suffix = sys.argv[1:]
     scripts = Path.home() / '.lore/scripts'
     sys.path.insert(0, str(scripts))
     spec = importlib.util.spec_from_file_location('binder', scripts / 'position-bind.py')
     binder = importlib.util.module_from_spec(spec); spec.loader.exec_module(binder)
     context = binder.prepare_session_input(json.loads(Path(descriptor).read_bytes()), json.loads(Path(bindings).read_bytes()),
                                            Path(kdir), Path(guidance).read_bytes(), wrapper=json.loads(Path(wrapper).read_bytes()),
                                            prefix=Path(prefix).read_bytes(), suffix=Path(suffix).read_bytes())
     print(json.dumps(context))
     PY
     ```

     The result is `{"position_preparation": {...}}`; `session request` admits it at enqueue and refuses it with the reason when a binding, the descriptor, the guidance, or the composition does not validate. Under fixed placement — a manager-owned worktree already allocated to this seat — bind here exactly as on the chaperone route (no `--native-model`, the session wrapper, prefix, and suffix), write `{"dispatch_guidance": <the payload bytes as text>, "position_dispatch": <the six-field reference>}` as the context, and the request carries the worktree id and directory pair; the host revalidates that exact root before spawning, and a published attempt never moves to another directory. Pass the context, the shape it has, and the placement pair (empty under ordinary placement) to `agents/session-worker.md` as described in its section. The reference for the attempt comes from `position-bind.py session-reference` fed the retained context, after the host has published; it also returns the `completion_input` for Step 4 §1.

   - **OpenCode.** Compiled native selection is refused by its plugin before publication; an OpenCode target takes the explicit session route or the legacy template.

Whether a reply can reach a running worker mid-task is a property of the live surface for that worker's handle, not of the framework's name: Step 3.0's operation-level probe of `send_message`, plus whatever follow-up operation the session's own tools expose for a retained handle, is what answers it. When the probe finds no such operation for a handle, a task with required consultation domains on that route is a capability boundary to record, not a reason to drop the requirement and not a reason to spawn a replacement worker.

## Native route — same-harness worker (legacy template)

Applies when the run was started and opened without `--compiled-positions`. Use the selected route's `native_binding` when `source_framework == target_framework`, whether the original binding was qualified or not. `impl start` already resolved the `implement` ceremony, class fallback, framework registry, and target-native shape. Do not parse the original `binding` again at spawn.

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
    $DISPATCH_GUIDANCE

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

The chaperone's own prompt is a distinct launch and gets its own fresh guidance rendering on both paths. What differs is the inner prompt. On the compiled path the inner prompt already exists as frozen bytes, so the chaperone receives `{{payload_file}}` (the reference's `payload_path`), `{{position_dispatch}}` (the `manifest_path` and `manifest_sha256` pair), `{{producer_template_version}}` (the descriptor's version), `{{report_id}}`, `{{work_item_slug}}`, and `{{report_shape}}` (`worker` here; `investigator` when the spec skill sends a Codex investigation through this same chaperone). On the legacy path those are empty and the chaperone assembles the inner prompt itself.

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
    $DISPATCH_GUIDANCE

    <contents of agents/codex-worker.md with {{template}} variables resolved,
     including {{worker_role}} set to the class-qualified role for this task,
     {{native_binding}} set to $CODEX_NATIVE_BINDING, {{template_version}} set
     to the codex-worker file's own version, and on the compiled path the
     payload, reference, producer version, report id, slug, and shape above>
    <legacy path only — launch-seam instruction: before §4 assembles the Codex
     prompt, render a new lore dispatch guidance block, fail before codex exec
     if rendering fails, and write the complete block first in that prompt>
```

The chaperone sends only the native Codex payload to `adapters/agents/codex.sh split_model_variant`. For a standing route that payload is `{{native_binding}}`; for the legacy explicit route it comes from `LORE_FRAMEWORK=codex resolve_model_for_role {{worker_role}} implement`. The chaperone marks its result `degraded` when Codex returns no parseable report; on a degraded return, re-dispatch the task through the native same-harness route. Routing through Codex remains an optimization, never a dependency.

The chaperone also captures the Codex run's token spend (its terminal `token_count` event) plus its own wall-clock, and relays them as a `**Spend:**` section in the closed spend vocabulary (duration-only, never fabricated tokens, on a degraded run). At task acceptance the lead copies that section into the task's execution-log atom as one `Spend: task=<id> …` line (Step 4 §3); `impl-close` joins it onto the scorecard row's `task_attribution`. Native same-harness workers expose no token stream through this route, so their tasks relay no `**Spend:**` section and carry `spend: null`.

## Session-routed route — worker-session chaperone (marker/user-directed only)

The Task tool spawns Claude-native subagents that report at turn boundaries, so a PTY-hosted worker session — which completes on its own poll-based lifecycle — needs a chaperone: a cheap Claude subagent (`agents/session-worker.md`) that enqueues one `--type worker` session request, blocks in a bounded poll loop over the session journal while the session runs its brief in its own TUI panel, reads the durable report the session leaves behind, and relays it. Spend spreads the same way the codex route spreads it: the chaperone sits cheap on a poll loop while the session burns the implementation tokens.

**Select the session route only on explicit selection** — the task carries a `[route: session]` marker (surfaced as its `route` field) or the user directs session routing at dispatch. It is never a silent default: an in-harness Task worker is cheaper (no live TUI instance to claim the request, no spawn round-trip, no panel slot), so the session route is worth its cost exactly when the work wants full observability — a per-task judgment, not a policy migration. Unavailable native readiness on the compiled path does not select it either; that is a boundary to record, and the session route stays a choice.

**Derive the session slug.** A worker session runs under a derived slug `<work-item-slug>--w<n>` (`n` = a per-dispatch ordinal you increment across session-routed dispatches in this run). The derived slug is the session's identity end to end — the TUI keys its panel and journal rows on it, and it is distinct from the work-item slug on purpose (a shared slug would collide with the lead's own implement session and would double-count worker cost into retro's session-spend line). The base work item still travels with the session: in the request's context and, once running, in each journal row's `links.work_item`.

**Compose what the session receives and write it to a file.** The chaperone never reads this file; it points the request at it, which keeps its own context minimal, and the file doubles as the record of exactly what the session was asked to do. Its shape depends on the path:

- **Compiled path.** The file is the session context from the compiled dispatch section: under ordinary placement the binder's pending preparation (bindings with `execution_root` null and a reason, descriptor, admitted guidance, activation, and the composition — wrapper identity, wrapper source, identity-line prefix, session-note suffix); under fixed placement the fixed reference (`dispatch_guidance` and `position_dispatch`) from a `bind` at the manager-owned directory. `session request` admits either at enqueue; under ordinary placement the claiming host publishes the immutable payload after it knows its physical directory, and a publication or activation failure returns an error before the process spawns. The session receives the compiled brief as its native definition or prompt, then the identity lines, the identity envelope, and the session note, and the manifest path and digest in `LORE_POSITION_DISPATCH_MANIFEST` and `LORE_POSITION_DISPATCH_SHA256`. Write the context to `$KDIR/_work/<work-item-slug>/worker-reports/<report-id>.context.json` and pass that path as `{{context_file}}`, with `{{dispatch_route}}` `compiled`, `{{framework}}`, `{{report_file}}` (the bound `report_path`), `{{producer_template_version}}`, and — only for fixed placement — `{{worktree_id}}` and `{{execution_dir}}` from the allocation; leave both empty under ordinary placement, because a placement flag added to an unallocated request would name a directory nobody allocated.
- **Legacy path.** The brief needs no guidance render of its own — `session request --type worker` renders the floor and prepends it at enqueue; the brief carries task content alone. (The chaperone's own Task prompt still gets its fresh rendering.) The brief is the same worker protocol content the default route resolves from `agents/worker.md` (task assignment with its composed brief + prior knowledge + evidence contract), adapted for session execution. Write it to `$KDIR/_work/<work-item-slug>/worker-reports/<derived-slug>.brief.md` and pass that path as `{{brief_file}}`, with `{{dispatch_route}}` `legacy`. The session is a standalone harness session, not a team subagent, so the brief's adaptations are:

  - **Report lands as a file, not a SendMessage.** The session writes its completion report to `$KDIR/_work/<work-item-slug>/worker-reports/<derived-slug>.md` (`mkdir -p` the directory first) as its final step before terminus — there is no lead to message and no journal event carries a report body. The chaperone reads that file after terminus.
  - **Tier 2 rows are self-appended.** The session runs `evidence-append.sh --work-item <work-item-slug>` itself (it has knowledge-store access), landing its rows in the base work item's `task-claims.jsonl` and listing the `claim_id`s in its report — exactly as an in-harness worker does. No relay block, no chaperone-side append.
  - **No `SendMessage` / `TaskUpdate` / `TaskList`.** The session has no team-messaging or task-list tools; the chaperone owns the Claude-side task lifecycle. The brief must carry the `task_id` the Tier 2 rows require, since the session can't read it from a task object.
  - **Terminus is explicit.** The brief's closing step, after the report file is durable and the Tier 2 rows are appended, runs `lore session close --self --reason protocol_terminus`. Because the session is agent-initiated, the TUI auto-closes it and journals the `closed` event carrying the session's spend — which is what the chaperone waits on.

  On the compiled path the same four facts hold, and they reach the session through the session note, not through the brief: the compiled worker brief names the report contract and the sole writer but knows nothing of derived slugs, the terminus command, or the environment variables a hosted session receives. The note in `agents/session-worker.md` says the report lands at the bound `report_path` through `lore coordinate report` before terminus, that Tier 2 rows are self-appended with the task id from the envelope, that there are no team tools, and that terminus is `lore session close --self --reason protocol_terminus`; it is retained as `wrapper-suffix.md` under the session-worker identity, so the words the session read are the words on record.

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
    $DISPATCH_GUIDANCE

    <contents of agents/session-worker.md with {{template}} variables resolved:
     {{work_item_slug}}, {{derived_slug}}, {{worker_model}} set to
     $WORKER_SESSION_MODEL, {{dispatch_route}}, {{template_version}} set to the
     session-worker file's own version, and either {{brief_file}} (legacy) or
     {{context_file}}, {{framework}}, {{report_file}}, {{producer_template_version}},
     and the fixed-placement pair {{worktree_id}} / {{execution_dir}}, empty under
     ordinary placement (compiled)>
```

**Empty-tiers handling** is identical to the codex route: an empty `tiers` array means claude-code has no validated alias ladder — omit the `model:` line so the chaperone inherits the session default, and note the tier selection is lost (the session itself still routes to `{{worker_model}}`).

The chaperone marks its result `degraded` when the request goes unclaimed, the session never reaches terminus, or the report file is missing/unparseable. On a degraded return, re-dispatch the task as a default-route same-harness worker — session routing is an observability choice, never a dependency.

The chaperone builds the `**Spend:**` section from the session's `closed` event (the TUI's type-agnostic enrichment already measured it; the chaperone flattens the spend object and never wall-clocks the run). At task acceptance the lead copies that section into one `Spend: task=<id> …` execution-log line (Step 4 §3), the same seam codex uses; `impl-close` joins it onto `task_attribution`. Because the session runs under a derived slug, its `closed` row is intentionally invisible to retro's exact-work-item-slug session-spend line — worker cost is per-task attribution, session-spend is the orchestration's own cost.

## Dispatch note — the compiled native worker's suffix

Fill this in per task and pass it as the suffix file. It is the routing text delivered after the identity envelope, and it says what the compiled brief cannot know about this run: who dispatched, where to work, and how the report travels. It is retained as `wrapper-suffix.md` under this file's wrapper identity, so an edit here changes the recorded wrapper version and leaves the compiled producer version untouched.

```
## From the dispatching lead

The implement lead for <work item title> dispatched you as the worker for task <task-id> on the <team_name> team; the lead is <team_lead>. The identity envelope above is the binder's record of this dispatch, and the values you need are in it: your assignment is `position_dispatch.bindings.assignment`, the complete task description; your packet is the `Packet-id:` line above, rendered by `lore packet show <id>`; the `Revision-id:` and `Dispatch-attempt-id:` lines name the plan this task comes from and this attempt.

Work only in <execution_dir>. <For a mutating task: It is worktree <worktree_id> on stream <stream-id>, attempt <attempt-id>, leased to <lease owner>. The lead allocated it; a worker never allocates a tree, because two writers in one tree cannot be reconciled afterwards. | For a read-only task: No tree was allocated because the task changes no files.> A path outside your target files belongs to another attempt or to a follow-up you name in the report.

The lead holds the team task for you, so no claim or completion call is yours. When your assignment declares required consultation domains, the request has to reach the lead before you implement: where your tools include no messaging operation (the compiled Claude definition carries Read, Glob, Grep, Bash, Write, and Edit only), return the `## Consultation` request as your whole message and stop, and the reply resumes you; where your harness supplies a messaging operation, send it there and end your turn, because a reply can only arrive at a turn boundary either way.

Tier 2 rows go through `evidence-append.sh --work-item <slug>` as each claim forms, with `task_id` <task-id>; list only their claim IDs in the report. Close criteria run through `lore criteria run <slug> <task-id> <criterion-id> --execution-worktree "$PWD" --packet-id <packet-id>`; cite result IDs.

Return the complete schema 1 report as your final message. Its header lines are `Report-schema: 1`, `Report-id: <report-id>`, `Work-item: <slug>`, `Task: <subject>`, `Producer-role: worker`, `Dispatch-path: harness-subagent`, `Harness: <framework>`, `Status:`, `Template-version: <position_dispatch.producer.template_version from the envelope>`, `Position-dispatch-manifest: <position_dispatch.manifest_path, verbatim>`, `Position-dispatch-sha256: <the digest you compute>`, `Packet-id:`, `Revision-id:`, `Dispatch-attempt-id:`. A manifest cannot carry its own digest, so compute it: `shasum -a 256 <manifest_path>` (or `sha256sum`). The lead holds the digest the binder returned and checks yours against it, which is what ties the report to this attempt.

The lead lands your message at the assigned report path through the sole report writer and runs the completion check against that file; nothing on your side completes the task. Return, and stop.
```
