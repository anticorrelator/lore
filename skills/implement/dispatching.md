# Dispatching a task

`/implement` § 2 sends you here when a task goes to another agent. The judgment stays in the skill: which tasks leave the seat, what their reports mean, whether a review is warranted. This file holds the mechanics. Where a verb's `--help` or refusal and this file disagree, the verb is right and this file needs fixing.

The recipes follow the skill's conventions: inputs named on the line before, each one runnable in a fresh shell, each one executed by a test.

## What a dispatch is

A dispatched agent reads a compiled position brief bound to its task, with a knowledge packet built for that move. The binder freezes payload, native definition and manifest under `position-dispatch/<attempt-id>/` and returns a six-field reference — `manifest_path`, `manifest_sha256`, `payload_path`, `payload_sha256`, `native_path`, `native_sha256` — which is your independent copy of this attempt's identity, held per task and never read back from the report. The report lands at the path the bindings assigned, carries that identity in its headers, and is read against the reference you hold.

Three routes exist. **Native** is the same-framework subagent (Claude Code `Agent`, Codex `spawn_agent`). **Session** is an item-backed worker session whose tree the store's session host allocates; a person can watch and steer it, and it outlives this context. **Chaperone** is a Codex worker launched from another framework through the Codex chaperone, which relays the report verbatim. Choose by what the task needs — a tree of its own, steering mid-flight, a different provider — and by what the harness offers:

**Recipe inputs:** SCRIPTS_DIR.
<!-- implement-recipe: probe-operations -->
```bash
source "$SCRIPTS_DIR/lib.sh"
FRAMEWORK="$(resolve_active_framework)"
ADAPTER="$LORE_REPO_DIR/adapters/agents/$FRAMEWORK.sh"
printf 'framework=%s\nsubagents=%s\nteam_messaging=%s\ntask_completed_hook=%s\ncompletion_enforcement=%s\n' \
  "$FRAMEWORK" "$(framework_capability subagents)" "$(framework_capability team_messaging)" \
  "$(framework_capability task_completed_hook)" "$(bash "$ADAPTER" completion_enforcement)"
```

`completion_enforcement` of `native_blocking` means the harness runs the completion check when the task completes; `lead_validator` means you run it (§ Collecting). `self_attestation` or `unavailable` means no route on this harness can land a report that is checked against its reference, and the task stays with the seat or goes to a session. Whether a reply can reach a running worker mid-task is a property of the live surface for its handle, not of the framework's name; where none exists, a task with required consultations on that route is a boundary to record, not a reason to drop the requirement.

A worker's model resolves per class under the target framework's adapter — `worker`, `worker-mechanical`, `worker-judgment-dense`; a designer resolves through `advisor`:

**Recipe inputs:** SCRIPTS_DIR, ROLE.
<!-- implement-recipe: resolve-role-model -->
```bash
source "$SCRIPTS_DIR/lib.sh"
bash "$LORE_REPO_DIR/adapters/agents/$(resolve_active_framework).sh" resolve_model_for_role "$ROLE"
```

## Preparing the attempt

**Bindings.** Assign the report id first — filesystem-safe and attempt-specific, `<task-id>-r<attempt>`, fresh on every re-dispatch, because the binder refuses an id another attempt holds and the report writer refuses an existing path. Then take the task's identity from the `open` or `next-batch` envelope. `EXECUTION_ROOT` is the allocated directory for a native or chaperoned worker (the checkout it reads, for a read-only task) and empty for a session, whose host supplies the tree after the request is claimed. A task without bound identity is refused with the adoption step it needs:

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, DISPATCH_JSON, TASK_ID, SLUG, REPORT_ID, EXECUTION_ROOT, BINDINGS_FILE.
<!-- implement-recipe: worker-bindings -->
```bash
python3 "$SCRIPTS_DIR/position-bind.py" worker-bindings --dispatch "$DISPATCH_JSON" --task "$TASK_ID" --work-item "$SLUG" \
  --report-id "$REPORT_ID" --execution-root "$EXECUTION_ROOT" --kdir "$KNOWLEDGE_DIR" --out "$BINDINGS_FILE"
```

**Synthesize the packet.** The packet `open` built for this task is a candidate set: one retrieval pass at a declared scale, nobody's judgment yet, and handing it on unread is search pushed down to the worker. Read it with `lore packet show`, drop the entries the worker should not carry, add the ones it needs that retrieval missed, and give one reason each; the worker can read the `## Left out by synthesis` list and re-pull an entry. `SYNTHESIS_FILE` is JSON you write — `{"dropped": [{"path": "...", "reason": "..."}], "added": [{"path": "...", "reason": "..."}]}` — and an empty pair of lists is a judgment too. The binder refuses a packet whose latest row is not `synthesized`, and only an `assembled` row can be synthesized, so a row already handed on is re-pulled rather than repaired:

**Recipe inputs:** PACKET_ID, SYNTHESIS_FILE.
<!-- implement-recipe: synthesize-packet -->
```bash
lore packet synthesize "$PACKET_ID" --by implement-lead --spec "$SYNTHESIS_FILE"
```

**Compile.** Render guidance and compile the target immediately before binding, once per launch and retry; the rendered block becomes the payload's first component. The descriptor's `template_version` is the producer version this worker will stamp as `Template-version:`; hold it per attempt as `PRODUCER_TEMPLATE_VERSION`, never the start snapshot or the skill's own hash:

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, POSITION, TARGET_FRAMEWORK, GUIDANCE_FILE, DESCRIPTOR_FILE.
<!-- implement-recipe: compile-position -->
```bash
lore dispatch guidance > "$GUIDANCE_FILE"
bash "$SCRIPTS_DIR/position-compile.sh" "$POSITION" --framework "$TARGET_FRAMEWORK" \
  --kdir "$KNOWLEDGE_DIR" --guidance-file "$GUIDANCE_FILE" > "$DESCRIPTOR_FILE"
python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["template_version"])' "$DESCRIPTOR_FILE"
```

**Wrap.** The wrapper around the compiled brief is versioned by the verb that composes it, and that identity is recorded on the manifest apart from the producer's, so both stay attributable and an edit to the wrapper never moves the brief's version. The verb writes the identity prefix (`Packet-id:`, `Report-id:`, `Revision-id:`, `Dispatch-attempt-id:`) and the dispatching note, which tells the worker what the brief cannot know: its route, where its report goes, how a consultation travels, and the placement rule. `ROUTE` is `native`, `chaperone`, `session` or `designer`; `PLACEMENT_NOTE` names the worktree, stream, attempt and lease owner for a mutating tree, or says the task is read-only; the extract file carries the task's `tier2_extracts` rows and may be empty:

**Recipe inputs:** SCRIPTS_DIR, BINDINGS_FILE, WRAPPER_FILE, PREFIX_FILE, SUFFIX_FILE, ROUTE, WORK_TITLE, TARGET_FRAMEWORK, TEAM_NAME, LEAD_NAME, PLACEMENT_NOTE, TIER2_EXTRACT_FILE.
<!-- implement-recipe: author-wrapper -->
```bash
args=(--bindings "$BINDINGS_FILE" --route "$ROUTE" --work-title "$WORK_TITLE" --framework "$TARGET_FRAMEWORK"
      --team-name "$TEAM_NAME" --lead-name "$LEAD_NAME" --placement-note "$PLACEMENT_NOTE"
      --wrapper "$WRAPPER_FILE" --prefix-file "$PREFIX_FILE" --suffix-file "$SUFFIX_FILE")
[[ -n "$TIER2_EXTRACT_FILE" ]] && args+=(--tier2-extract-file "$TIER2_EXTRACT_FILE")
python3 "$SCRIPTS_DIR/position-bind.py" wrapper "${args[@]}"
```

**Bind.** Every route except a session binds here. `REQUIRED_BINDINGS` is `task_id revision_id packet_id packet_pointer` for a worker and `packet_id packet_pointer` for a designer; `NATIVE_MODEL` is set on the native routes and empty on the chaperone route, where the payload is consumed as a primary prompt. An identical retry returns the same reference; a changed payload under the same attempt refuses; a real retry mints a fresh attempt and report id:

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, DESCRIPTOR_FILE, BINDINGS_FILE, GUIDANCE_FILE, WRAPPER_FILE, PREFIX_FILE, SUFFIX_FILE, REQUIRED_BINDINGS, NATIVE_MODEL.
<!-- implement-recipe: bind-attempt -->
```bash
args=(--descriptor "$DESCRIPTOR_FILE" --bindings "$BINDINGS_FILE" --kdir "$KNOWLEDGE_DIR" --guidance-file "$GUIDANCE_FILE"
      --wrapper "$WRAPPER_FILE" --prefix-file "$PREFIX_FILE" --suffix-file "$SUFFIX_FILE")
for field in $REQUIRED_BINDINGS; do args+=(--require "$field"); done
[[ -n "$NATIVE_MODEL" ]] && args+=(--native-model "$NATIVE_MODEL")
python3 "$SCRIPTS_DIR/position-bind.py" bind "${args[@]}"
```

## Launching

Launching is yours; a CLI verb cannot make a harness tool call. Hold each handle in memory, and send the prepared bytes unchanged: a later reader checks them against their recorded digest.

**Native.** On Claude Code the compiled definition has to be a name the running session's `Agent` tool offers, and the binder owns the file: pass `AGENTS_SCOPE`, an absolute `.claude/agents` directory this session watches (`resolve_harness_install_path agents` names the user-level one). On Codex leave it empty; the prepared text goes to `spawn_agent` directly:

**Recipe inputs:** SCRIPTS_DIR, MANIFEST_PATH, MANIFEST_SHA256, AGENTS_SCOPE.
<!-- implement-recipe: native-input -->
```bash
if [[ -n "$AGENTS_SCOPE" ]]; then
  python3 "$SCRIPTS_DIR/position-bind.py" register-native "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256" --scope "$AGENTS_SCOPE" >&2
  python3 "$SCRIPTS_DIR/position-bind.py" native-input "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256" --scope "$AGENTS_SCOPE"
else
  python3 "$SCRIPTS_DIR/position-bind.py" native-input "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256"
fi
```

`tool_input` carries the exact payload (`prompt` with `subagent_type` and `model` on Claude Code; `message` with the split model and effort keys on Codex) and `readiness` names the check: on Claude Code, that `selection_name` is among the `subagent_type` values the live tool offers — a file on disk is not that check, because a shell cannot see which directories the session watched at startup or whether a higher-precedence definition shadows the name; on Codex, that the live `spawn_agent` accepts the fields. When the check fails, the task takes a session under fresh identities; selecting a generic agent instead would attribute the report to a brief the worker never read. Pass `tool_input` as returned, adding only the tool's own `description`, `team_name` `impl-<slug>`, `name` and `mode` (or a Codex `task_name` and non-inheriting fork setting), and keep the handle. Where the route has shared task state, `TeamCreate` runs before `TaskCreate` so tasks land in the team's list; on these routes you hold the team task — set `owner` at launch, re-read it once before the call, and record the reference as `metadata.position_dispatch` with `metadata.lore_task_id` so the completion hook reads it from there.

A mutating native worker needs a tree allocated to this seat first; `STREAM_ID` and `ATTEMPT_ID` are the coordination identities you carry into the dispatch, and a worker never allocates:

**Recipe inputs:** SLUG, STREAM_ID, ATTEMPT_ID, OWNER_ID, SOURCE_DIR.
<!-- implement-recipe: allocate-worktree -->
`lore coordinate worktree allocate --work-item "$SLUG" --stream "$STREAM_ID" --attempt "$ATTEMPT_ID" --owner-kind seat --owner-id "$OWNER_ID" --source-dir "$SOURCE_DIR" --json`

**Session.** Nothing can be published before the host claims the request, so the context is the binder's pending preparation, which retains the exact wrapper source, prefix, suffix and activation so the host publishes exactly what was admitted. `SESSION_SLUG` is the derived `<slug>--w<n>`; the report still belongs to the base item:

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, DESCRIPTOR_FILE, BINDINGS_FILE, GUIDANCE_FILE, WRAPPER_FILE, PREFIX_FILE, SUFFIX_FILE, SESSION_SLUG, CONTEXT_FILE.
<!-- implement-recipe: prepare-session -->
```bash
python3 "$SCRIPTS_DIR/position-bind.py" prepare-session --descriptor "$DESCRIPTOR_FILE" --bindings "$BINDINGS_FILE" --kdir "$KNOWLEDGE_DIR" \
  --guidance-file "$GUIDANCE_FILE" --wrapper "$WRAPPER_FILE" --prefix-file "$PREFIX_FILE" --suffix-file "$SUFFIX_FILE" --slug "$SESSION_SLUG" > "$CONTEXT_FILE"
```

Seat trees cannot host worker sessions: the store's session host, the one process that claims requests, allocates the worker checkout under ordinary placement. A worker request also needs the item to declare its source checkout, so the host knows which clone of this store the session belongs in; a session-hosted seat seeds it once with `lore work source-checkout <slug>`, and the request is refused with that remedy until it exists. `lore session request` starts the host when none is running; when it cannot, the refusal carries the error and the path of the host's log. Enqueue with `--anywhere`, the stance that adds no placement beside the item's declaration, and without `--position` or `--packet`, which would select generic preparation or add a second packet line instead of preserving the admitted composition. `SESSION_ROUTE` is the resolved framework and model as `<framework>/<model>`:

**Recipe inputs:** SESSION_SLUG, SESSION_ROUTE, CONTEXT_FILE, MIN_VINTAGE, WORKTREE_ID, EXECUTION_DIR.
<!-- implement-recipe: request-session -->
```bash
args=(--type worker --slug "$SESSION_SLUG" --session-route "$SESSION_ROUTE"
      --context "$CONTEXT_FILE" --initiator agent --json)
args+=(--anywhere)
[[ -n "$MIN_VINTAGE" ]] && args+=(--min-vintage "$MIN_VINTAGE")
[[ -z "$WORKTREE_ID" && -z "$EXECUTION_DIR" ]] || { echo "Worker sessions take ordinary placement; seat trees host native subagents." >&2; exit 1; }
lore session request "${args[@]}"
```

Keep the context file and the request id. After the host publishes, collect the attempt's reference independently of the report, with the `completion_input` the completion check reads:

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, CONTEXT_FILE.
<!-- implement-recipe: session-reference -->
`python3 "$SCRIPTS_DIR/position-bind.py" session-reference --kdir "$KNOWLEDGE_DIR" < "$CONTEXT_FILE"`

A nonzero exit means you hold no validated reference yet — the host has not published, or the bundle fails a check — and the diagnostic says which. `delivery_proven` is false by design: a prepared payload records what was admitted, not what a model consumed.

**Chaperone.** Dispatch through the Codex chaperone with the bound payload as its primary prompt and the resolved model. The chaperone relays the worker's final message verbatim and lands it at the bound report path; a relay reshaped into other fields would replace what the worker said with a claim nobody made.

Three things stop a dispatch: an unconfirmed archived item, a brief that cannot be compiled and bound (there is then no versioned prompt to attribute a report to, and an improvised one is not a substitute), or a task the seat has already done.

## Collecting

Three kinds of message come back while a worker runs: a `## Consultation` request carrying `consultation-id:`, a completion report, or a blocker. Answer a consultation at once so the worker resumes at its next turn boundary (§ Consultations). Steer a blocked worker through the follow-up operation the live surface exposes for its handle — `SendMessage` to its name on Claude Code, the tool's follow-up for the retained handle on Codex, `lore session send` for a session. Where no operation reaches it, a corrected dispatch is a new attempt with fresh ids, and the blocked report stays as the record of the first.

As each report arrives, work through these in order.

1. **Land it.** The report is the account as the file the sole writer lands at its assigned destination; the message that carried it is transport. The writer is write-once (exit 4 on a used id), so a retry never overwrites what came back. A session or chaperone lands its own report; read that file rather than re-copying the relay:

**Recipe inputs:** SLUG, REPORT_ID, REPORT_BODY_FILE.
<!-- implement-recipe: land-report -->
`lore coordinate report "$SLUG" --report-id "$REPORT_ID" < "$REPORT_BODY_FILE"`

2. **Check that it answers this attempt.** Compare against the reference you hold, never against the report. Its `Template-version` is the producer version you compiled, and its manifest pair is the reference the binder (or `session-reference`) returned. A mismatch means the report answers some other input; re-dispatch under fresh ids:

**Recipe inputs:** SCRIPTS_DIR, REPORT_PATH, REFERENCE_FILE.
<!-- implement-recipe: check-identity -->
`python3 "$SCRIPTS_DIR/position-bind.py" check-report-identity --report "$REPORT_PATH" --reference "$REFERENCE_FILE"`

3. **Run the typed completion check** where no native hook fired for the attempt — a compiled Claude worker returns rather than completing a team task, a session lands a file. `REFERENCE_FILE` is the six-field reference or the `session-reference` output, whose `completion_input` is used as is. Exit 0 means the landed report carries the assigned headers, every required label, and Tier 2 references that each resolve to one canonical row for this task; exit 2 names what did not hold. Where a chaperone completed the team task, the hook already ran against the same reference:

**Recipe inputs:** SCRIPTS_DIR, REFERENCE_FILE, TASK_ID.
<!-- implement-recipe: typed-completion -->
```bash
python3 - "$REFERENCE_FILE" "$TASK_ID" <<'PY' | bash "$SCRIPTS_DIR/task-completed-capture-check.sh"
import json, sys
ref = json.load(open(sys.argv[1]))
print(json.dumps(ref.get("completion_input") or {"position_dispatch": ref, "lore_task_id": sys.argv[2]}))
PY
```

4. **Run the report check** with the harness facts the verb cannot read. Pass the attempt's own `Revision-id`: a plan revised after dispatch may have changed the task, and the attempt answers the consultations it was dispatched with. `--transcript` is the consultation ledger, needed when the task declares required domains. Woven-norm labels come from the task's `woven_norms` in `tasks.json` (or its `honor <label>` clauses with a same-line backlink). `--spawned-advisors` names the persistent advisors you activated this run, so a `handler: agent` entry joins only to an advisor that actually ran; the verb reads the transcript provider's status itself, and `--provider-status` overrides it:

**Recipe inputs:** SLUG, TASK_ID, REPORT_PATH, REVISION_ID, TRANSCRIPT_FILE, WOVEN_NORMS, PROVIDER_STATUS, SPAWNED_ADVISORS, LEAD_TEMPLATE_VERSION.
<!-- implement-recipe: check-report -->
```bash
args=("$SLUG" --task "$TASK_ID" --report "$REPORT_PATH" --template-version "$LEAD_TEMPLATE_VERSION" --json)
[[ -n "$REVISION_ID" ]] && args+=(--revision "$REVISION_ID")
[[ -n "$TRANSCRIPT_FILE" ]] && args+=(--transcript "$TRANSCRIPT_FILE")
for label in $WOVEN_NORMS; do args+=(--woven-norm "$label"); done
[[ -n "$PROVIDER_STATUS" ]] && args+=(--provider-status "$PROVIDER_STATUS")
[[ -n "$SPAWNED_ADVISORS" || "$PROVIDER_STATUS" == full ]] && args+=(--spawned-advisors "$SPAWNED_ADVISORS")
lore impl check-report "${args[@]}"
```

   The verb runs the checks and files the findings; it never accepts or rejects. Every claim id under `**Tier 2 evidence:**` is checked against canonical `task-claims.jsonl`, never against the report's assertion; each required domain needs a consultation entry whose id the ledger holds with an acknowledged reply; convention dispositions are compared with the woven list, with divergence rationales filed verbatim for you to read. Exit 3 is `mechanical_pass: false`: send the `fail_reasons` back to the worker and expect the retry under a fresh report id, with the first report kept as the record of that attempt. Exit 0 leaves acceptance where it was.

5. **Read the work** (`/implement` § 4). Result rows the worker cited are in `results.jsonl`; rerun a criterion through the executor when you want a fresh row against the integrated tree. Then write the task's entry with the attempt's producer version and manifest pair, and set its `**Tier 3 candidates:**` block aside for close.

## Consultations

A consultation is a worker's question crossing the dispatch boundary. The durable record is `consultation-transcript.jsonl` in the item, one acknowledged reply per line, written only by `lore impl consult-log`; the report check intersects required domains against this file, so an answer given but never filed reads as never given. Answering is judgment — matching the question to plan, code and notes — and stays with the seat; the filing is the verb.

The request body carries `consultation-id` (an opaque token the worker minted), `domain`, `reason`, `question` and `task`. Route by domain through the `skill_invocation_map` `open` returned: a skill-backed domain invokes the named skill with the worker's question as its argument, and the reply records the map's `skill_template_version` with `handler: skill`; a domain with no entry is answered from your own reading with `handler: lead`; the domain of a prepared persistent advisor activates that designer (below), `handler: agent`. Reply through the follow-up operation the live surface exposes for the worker's handle; where none exists, file the consultation all the same and let the task return blocked rather than re-spawning a worker to carry the answer. The body, in order:

```text
consultation-id: <verbatim from request>
handler: <skill|lead>
lead-acknowledged: true
skill_template_version: <12-char hash from the map, when handler is skill>

<answer body — concrete, anchored, ready for the worker to apply>
```

`lead-acknowledged: true` is the acknowledgement the required-consultation check reads. File the reply at once — the transcript record and its execution-log entry in one call. `skill` takes `--skill-template-version`; `agent` takes `--advisor-template-version` and, for a compiled designer, the manifest pair of the consultation attempt you bound; `lead` takes neither. `--template-version` is your filing version on every handler:

**Recipe inputs:** SLUG, CONSULTATION_ID, WORKER_NAME, DOMAIN, HANDLER, QUESTION, ANSWER, SKILL_TEMPLATE_VERSION, ADVISOR_TEMPLATE_VERSION, MANIFEST_PATH, MANIFEST_SHA256, LEAD_TEMPLATE_VERSION.
<!-- implement-recipe: consult-log -->
```bash
args=("$SLUG" --consultation-id "$CONSULTATION_ID" --worker "$WORKER_NAME" --domain "$DOMAIN" --handler "$HANDLER"
      --question "$QUESTION" --answer "$ANSWER" --template-version "$LEAD_TEMPLATE_VERSION")
case "$HANDLER" in
  skill) args+=(--skill-template-version "$SKILL_TEMPLATE_VERSION") ;;
  agent) args+=(--advisor-template-version "$ADVISOR_TEMPLATE_VERSION")
         [[ -n "$MANIFEST_PATH" ]] && args+=(--position-dispatch-manifest "$MANIFEST_PATH" --position-dispatch-sha256 "$MANIFEST_SHA256") ;;
esac
lore impl consult-log "${args[@]}"
```

Never block other work on a consultation: reply, file, and return to whichever queue the next message arrives on.

**Persistent advisors** are compiled designers, declared in the plan with `mode: persistent`, prepared at open and activated by the first real question. The binder needs a consultation id, a domain and a reply destination to publish a consultation attempt, and none exists until a worker asks, so preparation holds the name, domain, baseline and advisor model and spawns nothing. On the first request for a domain, build a packet for the question — session-scoped, not task-bound, because a task-bound packet belongs to the worker's attempt — and synthesize it with the synthesize-packet recipe and a JSON file of its own:

**Recipe inputs:** SLUG, DOMAIN, QUESTION, SCALE_SET.
<!-- implement-recipe: designer-packet -->
`lore packet build --work-item "$SLUG" --role designer --caller implement-lead --topic "$DOMAIN: $QUESTION" --scale-set "$SCALE_SET"`

Then assemble the consultation bindings from the request; the verb refuses a request that is not a `## Consultation` body with a consultation id, domain and question, because an attempt bound to a malformed request would carry an identity no reply could join:

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, REQUEST_FILE, SLUG, PACKET_ID, ADVISOR_NAME, WORKER_NAME, TASK_ID, REVISION_ID, EXECUTION_ROOT, BINDINGS_FILE.
<!-- implement-recipe: designer-bindings -->
```bash
python3 "$SCRIPTS_DIR/position-bind.py" consultation-bindings --request "$REQUEST_FILE" --work-item "$SLUG" --packet-id "$PACKET_ID" \
  --advisor "$ADVISOR_NAME" --worker "$WORKER_NAME" --task "$TASK_ID" --revision "$REVISION_ID" \
  --execution-root "$EXECUTION_ROOT" --kdir "$KNOWLEDGE_DIR" --out "$BINDINGS_FILE"
```

Compile the designer against fresh guidance, wrap with `ROUTE=designer`, bind with `REQUIRED_BINDINGS="packet_id packet_pointer"` and the advisor model, and activate on the native surface with the native-input recipe. When the name is not offered or the tool rejects the fields, answer as `handler: lead` and record the boundary. Log the activation through the skill's log-entry recipe (`Advisor spawned:` / `Domain:` / `Mode: persistent`, under the designer's version) with framework, model, descriptor version, execution root and handle. A later request for the same domain gets its own packet, bindings and bound attempt, delivered to the running process through its follow-up operation when producer, framework, model and root match the activation; when the compiled version has changed, shut the old designer down and activate a fresh one, because the running process read a different brief than the new payload names.

The designer's reply arrives as a file at the reply destination. Its first four lines are what the ledger joins on, so read them before anything else — a reply missing one cannot be joined, and the worker's report would be held for a reason that has nothing to do with the worker:

**Recipe inputs:** SCRIPTS_DIR, REPLY_FILE, CONSULTATION_ID, DESIGNER_TEMPLATE_VERSION.
<!-- implement-recipe: check-reply -->
`python3 "$SCRIPTS_DIR/position-bind.py" check-reply --reply "$REPLY_FILE" --consultation-id "$CONSULTATION_ID" --template-version "$DESIGNER_TEMPLATE_VERSION"`

Land it with the land-report recipe under the designer's bound report id, file it with `HANDLER=agent` and the consultation attempt's manifest pair, and forward the body to the worker as it is; the designer's reply is the answer and takes no `lead-acknowledged` line.

## Teardown

At `all-complete`, send each activated designer and any still-running worker its shutdown through the adapter, and log `Advisor shutdown:` / `Domain:` for each activated designer under its version; a prepared designer no worker asked was never a process and gets no line. A Claude `Agent` subagent returns without a handle, Codex gets the lead-mediated `TaskUpdate`, and a session closes through its own lifecycle once its report is landed and the work integrated. Run `TeamDelete` only where a team was created.
