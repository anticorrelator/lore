# Advisor Spawn Template (opt-in route)

Use this when `**Advisors:**` declares one or more entries with `mode: persistent`. Persistent advisors remain active for the entire implementation session and are shut down alongside workers in Step 4.

A run opened with `--compiled-positions` dispatches each persistent advisor as the compiled designer brief in consultation mode; `open` marks those entries `position: designer`, `position_mode: consultation`. A run opened without the flag uses the long `agents/advisor.md` template exactly as before, and that route is at the end of this file. The two differ in one place worth stating first: the compiled designer is activated by a worker's first real question, not at Step 3. The binder needs a consultation id, a domain, and a reply destination to publish a consultation attempt, and none of those exists until a worker asks. Orientation at open therefore prepares the designer and spawns nothing, and the execution log records an advisor as spawned only when a process actually started.

## Compiled route

### At open (Step 3.4): prepare, do not spawn

For each persistent advisor:

1. **Build the domain baseline** — find the `## Investigations` section(s) in `plan.md` whose topic relates to the advisor's domain scope. Extract the relevant investigation entry (findings, verified assertions, key files, implications) and hold it as this advisor's baseline. The baseline describes the domain at investigation time; the designer is told so, and checks it against current code when a question is about current behavior.

2. **Hold the identity you will bind later** — the advisor's name and domain from `open`, the designer descriptor `start` returned under `position_descriptors[<framework>][designer]` (a snapshot; the actual dispatch compiles again), and the advisor model:

   ```bash
   ADVISOR_MODEL=$(bash "$ADAPTER" resolve_model_for_role advisor)
   ```

   Consultation designers resolve through the `advisor` role; this is the existing mapping, not a new one.

3. **Do not append the advisory mixin to compiled worker prompts.** `scripts/agent-protocols/advisory-consultation.md` tells a worker to message an advisor by name and wait; a compiled worker has no messaging tool and the designer is not yet running, so the mixin would describe a channel that does not exist. Compiled workers send their `## Consultation` requests to the lead, as their brief says, and Step 4.0 routes a request whose domain belongs to a persistent advisor here.

No `Advisor spawned:` line is written at this point, because nothing was spawned.

### At the first request for a domain: activate

A worker's `## Consultation` request carries `consultation-id`, `domain`, `reason`, `question`, and `task`. When `domain` is a prepared persistent advisor's, the request is what the binder was waiting for.

1. **Build the designer's packet** — session-scoped, one retrieval pass for this question at a declared scale:

   ```bash
   lore packet build --work-item "$SLUG" --role designer --caller implement-lead \
     --topic "<domain>: <question>" --scale-set <bucket>
   ```

   Do not pass `--task`. A task-bound packet is bound to the latest dispatch attempt recorded for that task, which is the worker's, and this consultation is its own attempt; the binder would refuse the collision. The packet therefore has no task or revision, and the bindings say so explicitly.

2. **Assemble the bindings.** `work_item`; `task_id` and `revision_id` null, with the reason `consultation packet is session-scoped; the worker's task and revision are in the assignment`; `packet_id` and `packet_pointer` from step 1; `dispatch_attempt_id` fresh (`consult-<uuid>`); `assignment` as a JSON object carrying the worker's request verbatim plus the worker's name, task id, and `Revision-id`; `report_id` `<advisor-name>-<consultation-id>` made filesystem-safe, `report_path` `$ITEM_DIR/worker-reports/<report-id>.md`; `execution_root` the requesting task's execution directory, because the question is about that code; `mode` `consultation`; `consultation_id`, `domain`; `reply_destination` `$ITEM_DIR/consultation-replies/<consultation-id>.md`. Each later request gets fresh attempt, report, and reply identities; a retained process is not permission to reuse an old request's manifest.

3. **Compile against fresh guidance, name the wrapper, bind.**

   ```bash
   lore dispatch guidance > "$GUIDANCE_FILE" || exit 1
   bash ~/.lore/scripts/position-compile.sh designer --framework "$FRAMEWORK" --kdir "$KDIR" --guidance-file "$GUIDANCE_FILE" > "$DESCRIPTOR_FILE"
   python3 ~/.lore/scripts/position-bind.py bind --descriptor "$DESCRIPTOR_FILE" --bindings "$BINDINGS_FILE" \
     --kdir "$KDIR" --guidance-file "$GUIDANCE_FILE" \
     --wrapper "$WRAPPER_FILE" --prefix-file "$PREFIX_FILE" --suffix-file "$SUFFIX_FILE" \
     --require packet_id --require packet_pointer --native-model "$ADVISOR_MODEL"
   ```

   The wrapper is this file (`template_id` `implement/advisor-spawn`, its `template-version.sh` hash, path, and sha256). The prefix is the identity lines `Packet-id:`, `Report-id:`, `Dispatch-attempt-id:` (no `Revision-id:`, since none is bound). The suffix is the designer note at the end of this file, filled with the advisor's name, domain, baseline, and reply destination. The descriptor's `template_version` is `$DESIGNER_TEMPLATE_VERSION[<advisor-name>]` from here on: it is what the designer stamps as `advisor_template_version`, what `consult-log` files, and what the rollup groups by. Hold the returned six-field reference with the request.

4. **Activate on the native surface.** On Claude Code:

   ```bash
   python3 ~/.lore/scripts/position-bind.py register-native "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256" --scope "$AGENTS_SCOPE"
   python3 ~/.lore/scripts/position-bind.py native-input "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256" --scope "$AGENTS_SCOPE"
   ```

   Check that `readiness.selection_name` is among the `subagent_type` values the live `Agent` tool offers; a file on disk is not that check. Then call `Agent` with `subagent_type`, `model`, and `prompt` from `tool_input`, plus `description`, `team_name` `impl-<slug>`, `name` `<advisor-name>`, and `mode`. On Codex, `native-input` without `--scope` returns the `spawn_agent` fields with `message`; add only the naming and fork fields the live tool requires. When the name is not offered, or the tool rejects the fields, the request is unanswered by a designer: record the boundary, answer inline as `handler: lead`, and do not select a generic agent, because the reply would then carry a version for a brief nobody read.

5. **Log the spawn now**, with the compiled version:

   ```bash
   printf 'Advisor spawned: %s\nDomain: %s\nMode: %s\n' \
     "<advisor-name>" "<domain scope>" "persistent" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$DESIGNER_TEMPLATE_VERSION"
   ```

   Record the activation with the advisor: framework, model, descriptor version, execution root, and the live name or handle. Later requests are compared against it.

### Collecting a reply

The compiled designer has Read, Glob, Grep, and Bash, and no messaging or task tool. It writes its reply to `reply_destination` and returns the same text as its result where the surface returns one; whichever arrives, the file is what you read. The reply is transport until landed:

1. Check the four headers against what you hold: `consultation-id` equals the request's, `handler: agent`, `advisor_template_version` equals `$DESIGNER_TEMPLATE_VERSION[<advisor-name>]`, `advisor-acknowledged: true`. A reply missing one cannot be joined to the task's required domains, and the worker's report would be held for a reason that has nothing to do with the worker; send it back to the designer for the header before anything else.
2. Land it: `printf '%s' "$REPLY" | lore coordinate report "$SLUG" --report-id "$REPORT_ID"`. The destination is the bound `report_path`, and the writer lands any nonempty body, so no worker header is fabricated for it.
3. File it: `lore impl consult-log "$SLUG" --consultation-id <id> --worker <worker-name> --domain <domain> --handler agent --advisor-template-version "$DESIGNER_TEMPLATE_VERSION" --question "<summary>" --answer "<summary>" --template-version "$LEAD_TEMPLATE_VERSION"`.
4. Forward the reply body to the requesting worker by `SendMessage` to its name; the reply resumes it.

No acknowledgment is filed before an actual answer exists, and the designer's reply never goes through the completion hook: that hook supports worker and investigator reports, and a designer reference sent to it returns an explicit unsupported error rather than a bypass.

### Later requests for the same domain

A later request needs its own packet, bindings, and bound attempt (steps 1–3 above, with fresh identities), and then a delivery to the process that is already running. Before delivering, compare the new manifest's producer and framework, the resolved model, and the execution root with the recorded activation. When they match, deliver the new payload bytes unchanged as a `SendMessage` to the designer's name on a harness whose adapter `send_message` is available (Claude Code with `team_messaging` full); the designer answers at the new `reply_destination`, and collection runs as above. Log nothing as spawned, because nothing was.

Two situations end that path, and each is recorded rather than worked around. When guidance or the brief changed so the new descriptor's version differs from the activated one, the running process read a different brief than the new payload names, and sending it would attribute the reply to text it never read; surface the mismatch, answer that request as `handler: lead`, and decide with the user whether to shut the designer down and activate a fresh one on the next request. When the harness has no message transport to a live subagent (Codex and OpenCode report `team_messaging=none`), the first request was the only one that process can receive; answer later requests as `handler: lead`, note the boundary in `notes.md`, and do not spawn a replacement designer per request, because a second process under the same advisor name would make the rollup's grouping by version claim continuity that did not exist.

### Shutdown

At `all-complete`, send `shutdown_request` to each activated designer through the adapter and write its shutdown line with `--template-version "$DESIGNER_TEMPLATE_VERSION"` (Step 4). `--spawned-advisors` for `check-report` lists the advisors actually activated, which may be fewer than the plan declared.

## Legacy route (`agents/advisor.md`)

Applies when the run was started and opened without `--compiled-positions`. For each persistent advisor:

1. **Build domain context** — find the `## Investigations` section(s) in `plan.md` whose topic relates to the advisor's domain scope. Extract the relevant investigation entry (findings, verified assertions, key files, implications) and format it as the advisor's domain baseline.

2. **Spawn the advisor** using the `advisor` agent template (resolve via `resolve_agent_template advisor`; on Claude Code that path is `~/.claude/agents/advisor.md`) with these template injections:
   - `{{team_name}}` → `impl-<slug>`
   - `{{advisor_domain}}` → the advisor's domain scope
   - `{{domain_context}}` → the investigation excerpt from sub-step 1
   - `{{template_version}}` → `$ADVISOR_TEMPLATE_VERSION`

   Per-spawn model selection for advisors routes through `bash "$ADAPTER" resolve_model_for_role advisor`. The Claude Code path produces a `delegate:TaskCreate` directive with the resolved model id; opencode honors `provider/model` syntax for advisor bindings independently of worker bindings.

   Immediately before assembling this advisor's prompt, run `lore dispatch guidance`. If rendering fails, stop before the Task call. Prepend the complete single-use output verbatim before the resolved advisor template; render again for every advisor and retry.

   ```
   ADVISOR_MODEL=$(bash "$ADAPTER" resolve_model_for_role advisor)

   Task:
     subagent_type: "general-purpose"
     model: "$ADVISOR_MODEL"
     team_name: "impl-<slug>"
     name: "<advisor-name>"
     mode: "bypassPermissions"
     prompt: |
       $DISPATCH_GUIDANCE

       <contents of the advisor agent template with {{template}} variables resolved>
   ```

3. **Write execution log entry** — log each spawn. Pass `--template-version "$ADVISOR_TEMPLATE_VERSION"` because the content logged is sourced from the advisor template:

   ```bash
   printf 'Advisor spawned: %s\nDomain: %s\nMode: %s\n' \
     "<advisor-name>" "<domain scope>" "persistent" \
     | bash ~/.lore/scripts/write-execution-log.sh --slug <slug> --source implement-lead --template-version "$ADVISOR_TEMPLATE_VERSION"
   ```

On this route the advisory mixin is appended to worker prompts and workers message the advisor directly; its reply path is `agents/advisor.md` §"Responding to Consultations".

## Designer note — the compiled consultation payload's suffix

Fill this in per request and pass it as the suffix file. It is retained as `wrapper-suffix.md` under this file's wrapper identity, so an edit here changes the recorded wrapper version and leaves the compiled designer version untouched.

```
## From the dispatching lead

The implement lead for <work item title> holds you as the persistent advisor <advisor-name> for the domain <domain> on the <team_name> team. The identity envelope above is the binder's record of this request; the values you need are in it. The worker's question, with its consultation id, task, and the plan revision it runs against, is `position_dispatch.bindings.assignment`. The `Packet-id:` line names a packet built for this question; `lore packet show <id>` renders it, and its entries are candidates to check against the code.

Your domain baseline, from the plan's investigation at the time it was written:

<baseline: findings, verified assertions, key files, implications>

Read current code in `position_dispatch.bindings.execution_root` before answering a question about current behavior; the baseline may be older than the file the worker is asking about.

You have Read, Glob, Grep, and Bash, and no messaging tool, so the reply travels as a file. Write it to `position_dispatch.bindings.reply_destination` (create the directory if needed) and also return it as your final message. The lead reads it, lands it through the sole report writer, files the acknowledgment, and forwards it to the worker. Its first four lines are the headers the ledger joins on: `consultation-id: <from the assignment>`, `handler: agent`, `advisor_template_version: <position_dispatch.producer.template_version>`, `advisor-acknowledged: true`; then **Domain:**, **Guidance:**, **Key files:**, **Cautions:**. A reply missing a header cannot be joined to the worker's required domains.

You stay available after answering. A later question arrives as a message carrying its own envelope and reply destination; answer each at the destination it names. Tier 2 rows you append go through `evidence-append.sh` with `producer_role` `advisor`. You implement no source and complete no task; the worker's task has its own report and criteria.
```
