# Commissioning investigators

`/spec` § Commissioning investigators sends you here when the reading is wider than one context can hold. The judgment stays in the skill: which questions to ask, when to launch, and what the reports mean. This file holds the mechanics. Where a verb's `--help` or refusal and this file disagree, the verb is right and this file needs fixing.

The recipes follow the skill's conventions: inputs named on the line before, each one runnable in a fresh shell, each one executed by a test.

## The investigation document

The verb reads a JSON document. The contract is exact: unknown or missing fields refuse, array order is dispatch order, and every prefetch row declares its scale.

```json
{
  "schema_version": 1,
  "track": "full",
  "investigations": [
    {"id": "<id>", "kind": "lead-authored", "question": "<question>", "complexity": "simple|moderate|complex",
     "prefetch": [{"query": "<topic>", "scale_set": ["subsystem", "implementation"]}]}
  ]
}
```

`track` is `full`, the verb's word for a dispatched wave. Complexity is `simple` for one or two files, `moderate` for three to five, and `complex` for six or more or for cross-cutting work. Every question, label, prefetch query and scale is the seat's; the verb validates them and never invents one.

## Opening the wave

Without `dispatch` objects, `open` builds and records each investigator's packet itself, binds the researcher role's native model for the active framework, and mints fresh identities. That is the shortest path wherever native subagents work. Declare session routes instead (§ Declaring routes) when the native readiness check is not expected to pass, on OpenCode, which has no native selection under its plugin, or when someone should be able to watch the investigator work. Open the wave from the checkout the investigators should read, because `open` records its working directory as the root that snippets and line ranges are later checked against:

**Recipe inputs:** SLUG, INVESTIGATIONS_JSON.
<!-- spec-recipe: spec-open -->
```bash
DISPATCH=$(lore spec open "$SLUG" --investigations "$INVESTIGATIONS_JSON" --json)
printf '%s\n' "$DISPATCH"
```

`open` returns `created`, `reused`, `recovered` or `replaced`, or refuses and names the repair. It writes `spec-dispatch.json`, which holds the fingerprints, the source manifest, the ordered directives and the teardown payloads. It renders the guidance floor into each payload. It never calls a harness tool and never stores a live handle.

Each directive's payload has these fields:

- `prompt` — the exact bytes the investigator receives. Send them unchanged: a later reader checks them against their recorded digest.
- `position_dispatch` — the six-field reference to the frozen attempt. This is your independent copy, never read back from the report.
- `producer` — the compiled investigator's version, which the report stamps as `Template-version:`.
- `route`, `framework` and `model` — resolved once and never re-resolved, because the prompt bytes were frozen against them.
- `native_selection` — the native tool and its fields on a native route; otherwise null.
- `completion_input` — what the completion check reads. None of it comes from the report.
- `session_context` — what a session request carries.
- `bindings` — the validated envelope. Its `absence_reasons` say why a field is empty, and an absence with a reason is a legible state.
- `wrapper_template_version` — the version of `spec-open.sh` that composed the wave.

A declared session whose execution root is `null` stays `pending-execution-root`: its prompt, reference and completion input are `null` until the host publishes them at launch. Every other directive is `prepared`. Pull what one directive needs:

**Recipe inputs:** DISPATCH_JSON, INVESTIGATION_ID, CONTEXT_FILE, REFERENCE_FILE.
<!-- spec-recipe: directive-context -->
```python
import json, os, sys
from pathlib import Path
E = os.environ
data = json.loads(Path(E["DISPATCH_JSON"]).read_bytes())
artifact = data.get("artifact", data)
directive = next((d for d in artifact["directives"] if d["payload"]["investigation_id"] == E["INVESTIGATION_ID"]), None)
if directive is None:
    sys.exit("investigation not in this dispatch: " + E["INVESTIGATION_ID"])
p = directive["payload"]
Path(E["CONTEXT_FILE"]).write_text(json.dumps(p["session_context"]) + "\n")
reference = None
if p.get("position_dispatch"):
    reference = {"reference": p["position_dispatch"], "completion_input": p["completion_input"]}
Path(E["REFERENCE_FILE"]).write_text(json.dumps(reference) + "\n")
print(json.dumps({"ordinal": directive["ordinal"], "route": p["route"], "framework": p["framework"], "model": p["model"],
                  "publication_state": p["publication_state"], "producer_template_version": p["producer"]["template_version"],
                  "report_id": p["bindings"]["report_id"], "dispatch_attempt_id": p["bindings"]["dispatch_attempt_id"],
                  "adapter": directive["adapter"], "teardown": directive["teardown_payload"]}))
```

`REFERENCE_FILE` holds `null` for a pending directive until the session-reference recipe below fills the same shape.

## Launching

Launching each directive is yours: hold its handle in memory, never in `spec-dispatch.json`, and fill its teardown payload with that handle at shutdown. The investigator receives `payload.prompt`, exactly. Re-rendering or supplementing it breaks the digest.

**Native, Claude Code** (`native_selection.tool` is `Agent`). The compiled definition has to be registered where the running session's agent inventory can offer it. `AGENTS_SCOPE` is an absolute `.claude/agents` directory this session watches (`resolve_harness_install_path agents` names the user-level one); leave it empty on Codex:

**Recipe inputs:** SCRIPTS_DIR, MANIFEST_PATH, MANIFEST_SHA256, AGENTS_SCOPE.
<!-- spec-recipe: native-input -->
```bash
if [[ -n "$AGENTS_SCOPE" ]]; then
  python3 "$SCRIPTS_DIR/position-bind.py" register-native "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256" --scope "$AGENTS_SCOPE" >&2
  python3 "$SCRIPTS_DIR/position-bind.py" native-input "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256" --scope "$AGENTS_SCOPE"
else
  python3 "$SCRIPTS_DIR/position-bind.py" native-input "$MANIFEST_PATH" --sha256 "$MANIFEST_SHA256"
fi
```

Before calling, check that `selection_name` appears among the `subagent_type` values the live `Agent` tool offers. A file on disk does not establish that: the session may not watch that directory, or a higher-precedence definition may shadow the name. When the name is absent, retry the investigation as a declared session under fresh identities. Selecting a generic agent instead would attribute the report to a brief the investigator never read. Call `Agent` with `subagent_type`, `model` and `prompt` from `tool_input`, plus whatever the live schema requires (a `description`, team or background fields). Leave the prompt bytes and field names as returned.

**Native, Codex** (`native_selection.tool` is `spawn_agent`). Run the same recipe with an empty `AGENTS_SCOPE`. `tool_input` carries the split model and effort keys and the prompt as `message`. Check that the live `spawn_agent` schema accepts those fields, and supply only the caller fields it requires. Report a rejected model or effort value as rejected; don't drop it.

**Chaperone** (`route` is `codex-chaperone`, set when a native request named Codex from another framework). Dispatch through the Codex chaperone with `payload.model` and `payload.prompt`. Tell it the return shape is the investigator report, so it relays the body verbatim; a relay reshaped into worker fields would replace a finding with a claim nobody made.

**Session** (`route` is `session`). The request carries the context file the directive-context recipe wrote. `SESSION_SLUG` is `<slug>--w<n>`, and the report still belongs to the base item. Give exactly one placement stance. Name `MODEL` and `TARGET_FRAMEWORK` from the payload. Pass the worktree pair only for a `prepared` context frozen against a fixed placement, using that exact directory. A `pending-execution-root` context goes with an empty pair, and the host supplies the root:

**Recipe inputs:** SESSION_SLUG, SESSION_ROUTE, CONTEXT_FILE, TARGET_INSTANCE, MIN_VINTAGE, WORKTREE_ID, EXECUTION_DIR.
<!-- spec-recipe: request-session -->
```bash
args=(--type worker --slug "$SESSION_SLUG" --session-route "$SESSION_ROUTE"
      --context "$CONTEXT_FILE" --initiator agent --json)
if [[ -n "$TARGET_INSTANCE" ]]; then args+=(--target "$TARGET_INSTANCE"); else args+=(--anywhere); fi
[[ -n "$MIN_VINTAGE" ]] && args+=(--min-vintage "$MIN_VINTAGE")
[[ -n "$WORKTREE_ID" ]] && args+=(--worktree-id "$WORKTREE_ID" --execution-dir "$EXECUTION_DIR")
lore session request "${args[@]}"
```

Don't add `--position`: the context is already an admitted preparation, and generic bindings would drop the spec wrapper and its attribution. A slugged request derives where it may run from the item's declared source checkout. When a refusal says the declaration is missing, seed it once with `lore work source-checkout <slug>`. If publication or activation fails at launch, read the diagnostic; it is not a reason to switch routes.

When the harness has no subagents at all, read the questions yourself and say so in the plan.

## Declaring routes

Declare a route to run an investigation as a session, or to retry under fresh identities. For each investigation:

1. Resolve its model under the target framework.
2. Build its packet, then synthesize it. `open` refuses a supplied candidate set; its synthesis waiver covers only the packets it builds itself.
3. Write its bindings with an empty `EXECUTION_ROOT`, the ordinary case where the host allocates the tree.
4. Fold the bindings into the document.

Resolve with `ROLE=researcher` and `CEREMONY=spec`. The call runs under the target framework's adapter with `LORE_FRAMEWORK` set to that framework, so a Claude seat dispatching to Codex gets the Codex binding:

**Recipe inputs:** SCRIPTS_DIR, TARGET_FRAMEWORK, ROLE, CEREMONY.
<!-- spec-recipe: resolve-role-model -->
```bash
source "$SCRIPTS_DIR/lib.sh"
LORE_FRAMEWORK="$TARGET_FRAMEWORK" bash "$LORE_REPO_DIR/adapters/agents/$TARGET_FRAMEWORK.sh" resolve_model_for_role "$ROLE" "$CEREMONY"
```

**Recipe inputs:** SLUG, INVESTIGATION_ID, QUERY, SCALE_SET.
<!-- spec-recipe: investigator-packet -->
`lore packet build --work-item "$SLUG" --role investigator --caller spec-lead --topic "$INVESTIGATION_ID: $QUERY" --scale-set "$SCALE_SET"`

`SYNTHESIS_FILE` is JSON you write, with one reason per entry: `{"dropped": [{"path": "<store-relative entry path>", "reason": "..."}], "added": [{"path": "...", "reason": "..."}]}`. Two empty lists are a judgment too:

**Recipe inputs:** PACKET_ID, SYNTHESIS_FILE.
<!-- spec-recipe: packet-synthesis -->
```bash
lore packet synthesize "$PACKET_ID" --by spec-lead --spec "$SYNTHESIS_FILE"
```

`REPORT_ID` is filesystem-safe and specific to this attempt, fresh on every retry:

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, SLUG, PACKET_ID, INVESTIGATION_ID, QUESTION, COMPLEXITY, REPORT_ID, EXECUTION_ROOT, BINDINGS_FILE.
<!-- spec-recipe: investigator-bindings -->
```python
import json, os, sys, uuid
from pathlib import Path
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from packet_builder import pointer
E = os.environ
kdir = Path(E["KNOWLEDGE_DIR"]).resolve()
if E["COMPLEXITY"] not in ("simple", "moderate", "complex"):
    sys.exit("complexity must be simple, moderate or complex")
fields = ("work_item", "task_id", "revision_id", "packet_id", "packet_pointer", "dispatch_attempt_id", "assignment",
          "report_id", "report_path", "execution_root", "mode", "consultation_id", "domain", "reply_destination")
b = dict.fromkeys(fields)
b.update(work_item=E["SLUG"], packet_id=E["PACKET_ID"], packet_pointer=pointer(kdir, E["PACKET_ID"]),
         dispatch_attempt_id="spec-" + uuid.uuid4().hex, report_id=E["REPORT_ID"],
         report_path=str(kdir / "_work" / E["SLUG"] / "worker-reports" / (E["REPORT_ID"] + ".md")),
         execution_root=E["EXECUTION_ROOT"] or None,
         assignment=json.dumps({"investigation_id": E["INVESTIGATION_ID"], "question": E["QUESTION"],
                                "complexity": E["COMPLEXITY"]}, ensure_ascii=False))
reasons = {k: "no-plan-task-assigned" for k in ("task_id", "revision_id")}
reasons.update({k: "not-applicable-to-investigator" for k in ("mode", "consultation_id", "domain", "reply_destination")})
if b["execution_root"] is None:
    reasons["execution_root"] = "the ordinary session host supplies its physical worktree"
b["absence_reasons"] = reasons
Path(E["BINDINGS_FILE"]).write_text(json.dumps(b, indent=2) + "\n")
print(json.dumps({k: b[k] for k in ("dispatch_attempt_id", "report_id", "packet_id", "execution_root")}))
```

**Recipe inputs:** INVESTIGATIONS_DRAFT, BINDINGS_DIR, TARGET_FRAMEWORK, MODEL, INVESTIGATIONS_JSON.
<!-- spec-recipe: declare-dispatch -->
```python
import json, os, sys
from pathlib import Path
E = os.environ
document = json.loads(Path(E["INVESTIGATIONS_DRAFT"]).read_bytes())
bindings_dir = Path(E["BINDINGS_DIR"]) if E["BINDINGS_DIR"] else None
for inv in document["investigations"]:
    if "dispatch" in inv:
        sys.exit("the draft must not carry dispatch objects; this recipe declares them")
    if bindings_dir is None:
        continue
    path = bindings_dir / (inv["id"] + ".json")
    if not path.is_file():
        sys.exit("no bindings for investigation " + inv["id"] + "; write one with investigator-bindings or leave BINDINGS_DIR empty for open's native default")
    b = json.loads(path.read_bytes())
    if json.loads(b["assignment"]) != {"investigation_id": inv["id"], "question": inv["question"], "complexity": inv["complexity"]}:
        sys.exit("bindings assignment differs from the declared investigation " + inv["id"])
    inv["dispatch"] = {"framework": E["TARGET_FRAMEWORK"], "route": "session", "model": E["MODEL"], "bindings": b}
Path(E["INVESTIGATIONS_JSON"]).write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n")
print(json.dumps({"investigations": len(document["investigations"]), "declared_sessions": sum("dispatch" in i for i in document["investigations"])}))
```

Two route facts are declared here rather than discovered at launch. A native route toward another framework is supported only toward Codex, where it becomes the chaperone route. OpenCode investigations are declared `session`.

## Collecting

As each report arrives, work through these steps in order.

1. **Land it.** The report is evidence only as the file the sole writer lands at its assigned destination; the message that carried it is transport. The writer is write-once (exit 4 on a used id), so a retry never overwrites what came back. A session lands its own report; validate that file rather than copying the relay:

**Recipe inputs:** SLUG, REPORT_ID, REPORT_BODY_FILE.
<!-- spec-recipe: land-report -->
`lore coordinate report "$SLUG" --report-id "$REPORT_ID" < "$REPORT_BODY_FILE"`

   For a directive that was `pending-execution-root`, read the host's publication independently through the context file you kept:

**Recipe inputs:** SCRIPTS_DIR, KNOWLEDGE_DIR, CONTEXT_FILE.
<!-- spec-recipe: session-reference -->
`python3 "$SCRIPTS_DIR/position-bind.py" session-reference --kdir "$KNOWLEDGE_DIR" < "$CONTEXT_FILE"`

   A nonzero exit means you hold no validated reference, and its diagnostic says why: no manifest yet (unlaunched or refused) or a bundle that fails a check. Read launch state from the session's own lifecycle. Land a report that arrives meanwhile anyway, and leave it unaccepted with the diagnostic beside it. `delivery_proven: false` is literal: the reference records what was prepared, and only the report and the checks below say what came back.

2. **Check that it answers this attempt.** Compare against the reference you hold, never against the report:

**Recipe inputs:** REPORT_PATH, REFERENCE_FILE.
<!-- spec-recipe: check-identity -->
```python
import hashlib, json, os, sys
from pathlib import Path
ref = json.load(open(os.environ["REFERENCE_FILE"]))
ref = ref.get("reference", ref)
manifest = Path(ref["manifest_path"])
raw = manifest.read_bytes()
if hashlib.sha256(raw).hexdigest() != ref["manifest_sha256"]:
    sys.exit("held reference does not match the manifest bytes; do not read this report against it")
producer = json.loads(raw)["producer"]["template_version"]
headers = dict(l.split(": ", 1) for l in Path(os.environ["REPORT_PATH"]).read_text().splitlines()[:16] if ": " in l)
want = {"Template-version": producer, "Position-dispatch-manifest": str(manifest), "Position-dispatch-sha256": ref["manifest_sha256"]}
bad = [k for k, v in want.items() if headers.get(k) != v]
sys.exit("report answers another input; re-dispatch under fresh ids. mismatched: " + ", ".join(bad) if bad else 0)
```

   A mismatch means the report answers some other input. Re-dispatch under fresh attempt and report ids.

3. **Append its assertions** to Tier 2 with the append-tier2 recipe in the skill. Each row carries:
   - `producer_role: researcher` (the writer's word for the investigator position);
   - the attempt's producer version as `template_version`;
   - the investigation id as `task_id`;
   - `report_id` and `dispatch_attempt_id` from the bindings;
   - the `position_dispatch` pair copied from the reference you hold (`docs/position-report-contracts.md` § The dispatch reference on Tier 2 rows).

   Skip any assertion the report lists with a `claim_id`: the investigator appended it already.

4. **Run the typed completion check.** `TASK_ID` is empty before a plan exists:

**Recipe inputs:** SCRIPTS_DIR, REFERENCE_FILE, TASK_ID.
<!-- spec-recipe: typed-completion -->
```bash
python3 - "$REFERENCE_FILE" "$TASK_ID" <<'PY' | bash "$SCRIPTS_DIR/task-completed-capture-check.sh"
import json, sys
ref = json.load(open(sys.argv[1]))
completion = ref.get("completion_input") or {"position_dispatch": ref.get("reference", ref), "lore_task_id": sys.argv[2] or None}
print(json.dumps(completion))
PY
```

   Exit 0 means the report carries its identity headers, every label the investigator contract requires, Key files that exist, and assertions that each match one canonical row whose snippet is found at the named commit. Exit 2 names what did not hold. Whether the findings answer the question well enough to design from is your read, not the check's.

5. **Route the rest.** Worker leads go to the execution log, which forwards them to the off-scale writer. `None` writes nothing, and an empty `MANIFEST_PATH` drops both pair flags:

**Recipe inputs:** SCRIPTS_DIR, SLUG, INVESTIGATION_ID, REPORT_ID, WORKER_LEADS, PRODUCER_TEMPLATE_VERSION, LEAD_TEMPLATE_VERSION, MANIFEST_PATH, MANIFEST_SHA256.
<!-- spec-recipe: log-worker-leads -->
```bash
args=(--slug "$SLUG" --source spec-lead --template-version "$PRODUCER_TEMPLATE_VERSION" --filing-template-version "$LEAD_TEMPLATE_VERSION")
[[ -n "$MANIFEST_PATH" ]] && args+=(--position-dispatch-manifest "$MANIFEST_PATH" --position-dispatch-sha256 "$MANIFEST_SHA256")
printf 'Investigation: %s\nReport-id: %s\nWorker leads: %s\n' "$INVESTIGATION_ID" "$REPORT_ID" "$WORKER_LEADS" \
  | bash "$SCRIPTS_DIR/write-execution-log.sh" "${args[@]}"
```

   Unknowns go to `## Open Questions`, or into a follow-up when they gate a decision. A capture drawn from an investigator's observation keeps its attribution: `--producer-role researcher --capturer-role spec-lead --source-artifact-ids <report ids> --template-version <producer version>`. A correction that changes the ground a still-running sibling stands on is relayed now, by message or `lore session send`. When the route has no messaging, it reaches the sibling at synthesis.

6. **Tear down** once every report is in. Execute each teardown payload with its handle where one exists. A Claude `Agent` subagent returns without a handle, Codex gets the lead-mediated `TaskUpdate`, and a session closes through its own lifecycle. Run `TeamDelete` only if you created a shared team.
