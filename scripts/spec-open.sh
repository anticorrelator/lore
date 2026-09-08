#!/usr/bin/env bash
# spec-open.sh — Validate and publish one reusable /spec dispatch manifest.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REF=""
INVESTIGATIONS_FILE=""
JSON_MODE=0

usage() {
  cat >&2 <<'EOF'
Usage: lore spec open <ref> --investigations <json-file> [--json]

Validate a lead-authored full-track investigation set, atomically publish
spec-dispatch.json, and return ordered harness adapter directives. This verb
does not author questions, select applicability, or execute harness calls.
EOF
}

emit_error() {
  local message="$1" corrective="${2:-correct the declared input and retry}"
  if [[ $JSON_MODE -eq 1 ]]; then
    python3 - "$message" "$corrective" <<'PY'
import json, sys
print(json.dumps({"status":"refused", "error":sys.argv[1], "corrective_action":sys.argv[2]}, ensure_ascii=False))
PY
  else
    echo "[spec open] Refused: $message" >&2
    echo "Corrective action: $corrective" >&2
  fi
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --investigations) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || emit_error "--investigations requires a value"; INVESTIGATIONS_FILE="$2"; shift 2 ;;
    --investigations=*) INVESTIGATIONS_FILE="${1#--investigations=}"; [[ -n "$INVESTIGATIONS_FILE" ]] || emit_error "--investigations requires a value"; shift ;;
    --json) JSON_MODE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) emit_error "unknown flag: $1" ;;
    *) [[ -z "$REF" ]] || emit_error "unexpected extra argument: $1"; REF="$1"; shift ;;
  esac
done

[[ -n "$REF" ]] || { usage; emit_error "missing required argument: <ref>"; }
[[ -n "$INVESTIGATIONS_FILE" ]] || emit_error "missing required declaration: --investigations <json-file>"
[[ -f "$INVESTIGATIONS_FILE" && -r "$INVESTIGATIONS_FILE" ]] || emit_error "investigations file is not readable: $INVESTIGATIONS_FILE"

set +e
RESOLVED=$(bash "$SCRIPT_DIR/resolve-work-ref.sh" "$REF" 2>&1)
RESOLVE_RC=$?
set -e
if [[ $RESOLVE_RC -ne 0 ]]; then printf '%s\n' "$RESOLVED" >&2; exit "$RESOLVE_RC"; fi
SLUG=$(printf '%s\n' "$RESOLVED" | head -1)
ARCHIVED=$(printf '%s\n' "$RESOLVED" | sed -n '2p')
[[ "$ARCHIVED" == "false" ]] || emit_error "work item '$SLUG' is archived" "restore it before preparing dispatch"

KDIR=$(resolve_knowledge_dir)
ITEM_DIR="$KDIR/_work/$SLUG"
ARTIFACT="$ITEM_DIR/spec-dispatch.json"
LOG_FILE="$ITEM_DIR/execution-log.md"
FRAMEWORK=$(resolve_active_framework) || emit_error "active framework could not be resolved"
RESEARCHER_ROUTE=$(resolve_route_for_role researcher spec 2>/dev/null) || emit_error "researcher route could not be resolved for the spec ceremony"
RESEARCHER_MODEL=$(printf '%s' "$RESEARCHER_ROUTE" | jq -r '.model')
RESEARCHER_NATIVE_ROUTE=$(resolve_native_route_for_role researcher spec "$FRAMEWORK" 2>/dev/null) || emit_error "native researcher route could not be resolved"
RESEARCHER_TEMPLATE=$(resolve_agent_template researcher 2>/dev/null) || emit_error "researcher template could not be resolved"
RESEARCHER_TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "$RESEARCHER_TEMPLATE" 2>/dev/null) || emit_error "researcher template version could not be resolved"
LEAD_TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "$LORE_REPO_DIR/skills/spec/SKILL.md" 2>/dev/null) || emit_error "spec lead template version could not be resolved"
SUBAGENTS=$(framework_capability subagents "$FRAMEWORK" 2>/dev/null || printf 'none')
TEAM_MESSAGING=$(framework_capability team_messaging "$FRAMEWORK" 2>/dev/null || printf 'none')
ADAPTER="$LORE_REPO_DIR/adapters/agents/$FRAMEWORK.sh"
[[ -f "$ADAPTER" ]] || emit_error "agent adapter is missing for framework '$FRAMEWORK'"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
PREPARED="$TMP_DIR/prepared.json"
GUIDANCE_FILE="$TMP_DIR/dispatch-guidance.txt"

# The published directive carries the same prompt floor enforced at the launch
# boundary. Render and validate it before any investigation prefetch or artifact
# write, so a broken floor cannot produce a reusable dispatch manifest.
# shellcheck disable=SC2119
render_dispatch_guidance > "$GUIDANCE_FILE"
validate_dispatch_guidance --prompt-file "$GUIDANCE_FILE" || \
  emit_error "canonical dispatch guidance failed validation" "run 'lore dispatch guidance' and repair the renderer/validator contract"

set +e
python3 - "$INVESTIGATIONS_FILE" "$PREPARED" "$SLUG" "$FRAMEWORK" "$SUBAGENTS" "$TEAM_MESSAGING" \
  "$RESEARCHER_MODEL" "$RESEARCHER_TEMPLATE_VERSION" "$SCRIPT_DIR/prefetch-knowledge.sh" "$ADAPTER" "$GUIDANCE_FILE" \
  "$SCRIPT_DIR" "$KDIR" "$LEAD_TEMPLATE_VERSION" "$ARTIFACT" "$RESEARCHER_TEMPLATE" "$RESEARCHER_ROUTE" "$RESEARCHER_NATIVE_ROUTE" <<'PY'
import hashlib, importlib.util, json, os, subprocess, sys, uuid
from pathlib import Path

(input_path, output_path, slug, framework, subagents, team_messaging,
 researcher_model, researcher_template_version, prefetch_script, adapter,
 guidance_path, script_dir, kdir, lead_template_version, artifact_path, legacy_template, researcher_route, researcher_native_route) = sys.argv[1:]
researcher_route = json.loads(researcher_route)
researcher_native_route = json.loads(researcher_native_route)
sys.path.insert(0, script_dir)
from position_compile import compile_position, validate_descriptor
from packet_builder import build_packet, pointer
from route_config import parse_route
module = importlib.util.spec_from_file_location("position_bind", Path(script_dir) / "position-bind.py")
binder = importlib.util.module_from_spec(module)
module.loader.exec_module(binder)
kdir = Path(kdir).resolve()

def reject(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)

try:
    raw = json.load(open(input_path, encoding="utf-8"))
except Exception as exc:
    reject(f"invalid investigations JSON: {exc}")

if not isinstance(raw, dict): reject("investigations document must be an object")
allowed_root = {"schema_version", "track", "investigations", "template"}
if raw.get("template") not in (None, "researcher"):
    reject("template must name the explicit legacy researcher template")
legacy = raw.get("template") == "researcher"
unknown = sorted(set(raw) - allowed_root)
if unknown: reject("unknown investigations document field(s): " + ", ".join(unknown))
if raw.get("schema_version") != 1: reject("schema_version must be the integer 1")
if raw.get("track") != "full": reject("track must be declared as 'full'; short track cannot be opened")
investigations = raw.get("investigations")
if not isinstance(investigations, list) or not investigations: reject("investigations must be a non-empty array")

required_inv = {"id", "kind", "question", "complexity", "prefetch"}
allowed_inv = required_inv | {"dispatch"}
allowed_prefetch = {"query", "scale_set"}
allowed_scales = {"abstract", "architecture", "subsystem", "implementation"}
seen = set()
fixed_external = 0
fixed_preferences = 0
normalized = []
for index, inv in enumerate(investigations):
    where = f"investigations[{index}]"
    if not isinstance(inv, dict): reject(f"{where} must be an object")
    unknown = sorted(set(inv) - allowed_inv)
    if unknown: reject(f"{where} has unknown field(s): {', '.join(unknown)}")
    if not required_inv.issubset(inv): reject(f"{where} must declare exactly: id, kind, question, complexity, prefetch")
    ident = inv.get("id")
    if not isinstance(ident, str) or not ident.strip(): reject(f"{where}.id must be a non-empty string")
    if ident in seen: reject(f"duplicate investigation id: {ident}")
    seen.add(ident)
    if inv.get("kind") not in {"fixed", "lead-authored"}: reject(f"{where}.kind is invalid")
    question = inv.get("question")
    if not isinstance(question, str) or not question.strip(): reject(f"{where}.question must be non-empty")
    if inv.get("complexity") not in {"simple", "moderate", "complex"}: reject(f"{where}.complexity is invalid")
    prefetch = inv.get("prefetch")
    if not isinstance(prefetch, list): reject(f"{where}.prefetch must be an array")
    normalized_prefetch = []
    for pidx, row in enumerate(prefetch):
        pwhere = f"{where}.prefetch[{pidx}]"
        if not isinstance(row, dict) or set(row) != allowed_prefetch:
            reject(f"{pwhere} must declare exactly query and scale_set")
        query = row.get("query")
        if not isinstance(query, str) or not query.strip(): reject(f"{pwhere}.query must be non-empty")
        scales = row.get("scale_set")
        if isinstance(scales, str): scales = [s.strip() for s in scales.split(",") if s.strip()]
        if not isinstance(scales, list) or not scales or any(not isinstance(s, str) or s not in allowed_scales for s in scales):
            reject(f"{pwhere}.scale_set must declare one or more of: abstract, architecture, subsystem, implementation")
        if len(scales) != len(set(scales)): reject(f"{pwhere}.scale_set contains duplicates")
        normalized_prefetch.append({"query": query, "scale_set": scales})
    dispatch = inv.get("dispatch")
    if dispatch is not None:
        if legacy or not isinstance(dispatch, dict) or set(dispatch) != {"framework", "route", "model", "bindings"}:
            reject(f"{where}.dispatch must declare framework, route, model, bindings on a compiled path")
        if dispatch["framework"] not in {"codex", "claude-code", "opencode"} or dispatch["route"] not in {"native", "session"}:
            reject(f"{where}.dispatch has an unsupported framework or route")
        if not isinstance(dispatch["model"], str) or not dispatch["model"].strip():
            reject(f"{where}.dispatch.model must be resolved before publication")
        model_check = subprocess.run(["bash", "-c", 'source "$1/lib.sh"; _model_route_json researcher "$2"',
                                      "spec-model", script_dir, dispatch["model"]],
                                     env={**os.environ, "LORE_FRAMEWORK": dispatch["framework"]},
                                     capture_output=True, text=True)
        if model_check.returncode or json.loads(model_check.stdout)["target_framework"] != dispatch["framework"]:
            reject(f"{where}.dispatch.model is not a native binding for the selected framework")
        if dispatch["route"] == "native" and dispatch["framework"] not in {framework, "codex"}:
            reject(f"{where}.dispatch cannot launch {dispatch['framework']} through the {framework} native surface; use route=session")
        binder.validate_bindings(dispatch["bindings"], "investigator", kdir, ("packet_id", "packet_pointer"),
                                 pending_root=dispatch["route"] == "session")
        expected_assignment = {"investigation_id": ident, "question": question, "complexity": inv["complexity"]}
        try:
            assigned_question = json.loads(dispatch["bindings"]["assignment"])
        except (TypeError, ValueError):
            reject(f"{where}.dispatch.bindings.assignment must encode the investigation object")
        if assigned_question != expected_assignment:
            reject(f"{where}.dispatch assignment conflicts with investigation")
        if dispatch["bindings"]["work_item"] != slug:
            reject(f"{where}.dispatch work_item mismatch")
        report_destination = kdir / "_work" / slug / "worker-reports" / (dispatch["bindings"]["report_id"] + ".md")
        if dispatch["bindings"]["report_path"] != str(report_destination):
            reject(f"{where}.dispatch report_path must match the coordinate report destination")
    lowered = question.lower()
    if inv.get("kind") == "fixed" and "external skill" in lowered and "agent" in lowered:
        fixed_external += 1
    if inv.get("kind") == "fixed" and "preference" in lowered and "convention" in lowered:
        fixed_preferences += 1
    normalized.append({"id": ident, "kind": inv["kind"], "question": question,
                       "complexity": inv["complexity"], "prefetch": normalized_prefetch,
                       **({"dispatch": dispatch} if dispatch is not None else {})})

if fixed_external != 1: reject("exactly one fixed external-skill/agent investigation is required")
if fixed_preferences != 1: reject("exactly one fixed preference/convention investigation is required")

def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")

try:
    dispatch_guidance = open(guidance_path, encoding="utf-8").read()
except Exception as exc:
    reject(f"canonical dispatch guidance is unreadable: {exc}")
marker = "Defaults-Digest: sha256:"
matches = [line.removeprefix(marker) for line in dispatch_guidance.splitlines()
           if line.startswith(marker)]
if len(matches) != 1 or len(matches[0]) != 64:
    reject("canonical dispatch guidance lacks one defaults digest identity")
guidance_identity = {"schema_version": 1, "defaults_digest": f"sha256:{matches[0]}"}

input_shape = {"schema_version": 1, "slug": slug, "ordered_investigations": normalized,
               "template": raw.get("template")}
input_fp = hashlib.sha256(canonical(input_shape)).hexdigest()
prefetch_manifest = []
knowledge_by_id = {}
for inv in normalized:
    delivered = []
    for row in inv["prefetch"]:
        scale_arg = ",".join(row["scale_set"])
        proc = subprocess.run(["bash", prefetch_script, row["query"], "--format", "prompt", "--limit", "5",
                               "--scale-set", scale_arg], text=True, capture_output=True, check=False)
        if proc.returncode != 0:
            reject(f"prefetch failed for investigation '{inv['id']}' query {row['query']!r}: {(proc.stderr or proc.stdout).strip()}")
        result_hash = hashlib.sha256(proc.stdout.encode("utf-8")).hexdigest()
        manifest_row = {"investigation_id": inv["id"], "query": row["query"],
                        "scale_set": row["scale_set"], "result_sha256": result_hash}
        prefetch_manifest.append(manifest_row)
        delivered.append({**manifest_row, "content": proc.stdout})
    knowledge_by_id[inv["id"]] = delivered

def resolved_launch(inv):
    request = inv.get("dispatch", {})
    route = request.get("route", "native")
    base = researcher_native_route if route == "native" else researcher_route
    target = request.get("framework", base["framework"])
    if route == "native" and target == "codex" and target != framework:
        route = "codex-chaperone"
    return target, route, request.get("model", base["model"])

def resolved_session_route(inv):
    request = inv.get("dispatch", {})
    launch = request.get("route", "native")
    base = researcher_native_route if launch == "native" else researcher_route
    target, _, model = resolved_launch(inv)
    if "framework" in request or "model" in request:
        return parse_route({"framework": target, "model": model}, Path(script_dir).parent,
                           {"layer": "override", "role": "researcher", "ceremony": "spec"})
    return base

capabilities = {"subagents": subagents, "team_messaging": team_messaging}
source_shape = {"active_framework": framework, "adapter_capabilities": capabilities,
                "researcher_model": researcher_model, "researcher_route": researcher_route,
                "researcher_template_version": researcher_template_version,
                "dispatch_guidance_identity": guidance_identity,
                "ordered_prefetch": prefetch_manifest}
descriptors = {}
if not legacy:
    for target in sorted({resolved_launch(inv)[0] for inv in normalized}):
        descriptors[target] = compile_position("investigator", target, kdir, Path(guidance_path))
source_shape.update(lead_template_version=lead_template_version,
                    wrapper={"path": str(Path(script_dir) / "spec-open.sh"),
                             "sha256": hashlib.sha256((Path(script_dir) / "spec-open.sh").read_bytes()).hexdigest()},
                    producers={key: {field: value[field] for field in ("template_id", "template_version", "descriptor_path", "descriptor_sha256")}
                               for key, value in descriptors.items()},
                    legacy_template_path=legacy_template if legacy else None)
source_fp = hashlib.sha256(canonical(source_shape)).hexdigest()

# The collector's note closes every compiled investigator payload. It is
# emitted prose, retained as wrapper-suffix.md and covered by the wrapper
# identity, so a change here changes the recorded wrapper version.
COLLECTOR_NOTE = """
## From the collector

A spec lead dispatched you to answer one investigation for one work item. The identity envelope above is the binder's record of this dispatch; the values you need are in it.

- Your question is `position_dispatch.bindings.assignment`, a JSON object with `investigation_id`, `question`, and `complexity`. The question is the scope; a finding outside it goes under Worker leads or Unknowns.
- The `Packet-id:` line above names your packet, and `lore packet show <id>` renders it. Its entries were retrieved for this question at one declared scale and are candidates to test against the code, not answers.
- No `Revision-id:` line means no plan revision exists yet; this investigation runs before the plan. Say so under Unknowns where it matters instead of inferring a task or revision.
- `position_dispatch.manifest_path` is the immutable manifest for this attempt. Your report needs its digest, and a manifest cannot carry its own, so compute it: `shasum -a 256 <manifest_path>` (or `sha256sum`). The collector holds the digest the binder returned at publication and checks your header against it; agreement ties your report to this attempt and to nothing else.

Write the report in the investigator shape the brief names: Question, Findings, Key files, Implications, Assertions, Observations, optional Narrative, Worker leads, Unknowns. Directly after the `**Question:**` line, add three header lines, plain, one per line:

```
Template-version: <position_dispatch.producer.template_version, from the envelope>
Position-dispatch-manifest: <position_dispatch.manifest_path, verbatim>
Position-dispatch-sha256: <the digest you computed>
```

Findings are copied into the plan verbatim, so write each to stand alone. Assertions have no count; each grounded one carries file, line range, verbatim snippet, its normalized hash, a falsifier, and a significance. `None` is complete under Assertions and Observations when nothing grounded or nothing surprising came up. If you append an assertion to `task-claims.jsonl` yourself, it goes through `evidence-append.sh` with `producer_role` `researcher` (that writer's legacy name for this position), `report_id` and `dispatch_attempt_id` copied from the envelope, `position_dispatch` as one object holding `manifest_path` from the envelope and `manifest_sha256` as the digest you computed for your headers (the same two values, so the row and the report name one attempt; the writer resolves them against the manifest and reads a pair it cannot resolve as unknown, never as a template's version), and `task_id` taken from the envelope as well: `position_dispatch.bindings.task_id` when it is set, because the completion check then matches your row by that task id and a row filed under any other label leaves the assertion ungrounded; when it is null, the pre-plan case the missing `Revision-id:` line describes, use your `investigation_id`, and the two copied ids are what tie the row to this attempt. Then give that assertion its `claim_id` in the report, so the collector does not write the row a second time.

Return the complete report as your final message. The collector lands it at the assigned report destination through the sole report writer, appends the remaining assertions canonically, and only then runs the completion check that reads your headers against the reference it holds. Nothing on your side completes that sequence early, and a task tool marked complete before the report is landed leaves the check reading an empty destination; return, and stop. A correction you made to a packet entry is already recorded by `lore verify`; when it would change the ground under another investigation in this wave, say so plainly in Findings, because the collector reads Findings while the other investigations are still running.
""".encode("utf-8")


def session_composition(bindings):
    fields = {"Packet-id": bindings["packet_id"], "Report-id": bindings["report_id"],
              "Dispatch-attempt-id": bindings["dispatch_attempt_id"]}
    if bindings["revision_id"] is not None:
        fields["Revision-id"] = bindings["revision_id"]
    return {"prefix": "".join(f"{key}: {value}\n" for key, value in fields.items()).encode(),
            "suffix": COLLECTOR_NOTE,
            "wrapper": {"template_id": "spec-open", "template_version": source_shape["wrapper"]["sha256"][:12],
                        "path": source_shape["wrapper"]["path"], "sha256": source_shape["wrapper"]["sha256"]}}

previous = None
if Path(artifact_path).is_file():
    previous = json.loads(Path(artifact_path).read_bytes())
if previous and previous.get("input_fingerprint") == input_fp and previous.get("source_fingerprint") == source_fp:
    if len(previous["directives"]) != len(normalized):
        reject("published investigation count differs from the declared input")
    for directive, inv in zip(previous["directives"], normalized):
        reference = directive["payload"].get("position_dispatch")
        if not legacy and reference is None and directive["payload"].get("publication_state") == "pending-execution-root":
            payload = directive["payload"]
            target, route, model = resolved_launch(inv)
            bindings = inv.get("dispatch", {}).get("bindings")
            if route != "session" or bindings is None or bindings["execution_root"] is not None:
                reject("pending investigator session differs from declared placement")
            context = binder.prepare_session_input(descriptors[target], bindings, kdir, payload["dispatch_guidance"].encode(),
                                                   **session_composition(bindings))
            expected = {"framework": target, "route": route, "model": model, "bindings": bindings,
                        "investigation_id": inv["id"], "question": inv["question"], "complexity": inv["complexity"],
                        "session_context": context, "descriptor": descriptors[target], "position": "investigator",
                        "producer": {key: descriptors[target][key] for key in ("template_id", "template_version")},
                        "prompt": None, "position_dispatch": None, "native_selection": None, "completion_input": None,
                        "wrapper_template_version": source_shape["wrapper"]["sha256"][:12],
                        "lead_template_version": lead_template_version}
            if any(payload.get(key) != value for key, value in expected.items()):
                reject("pending investigator input differs from admitted preparation")
            continue
        if not legacy and not isinstance(reference, dict):
            reject("published investigator reference is missing")
        if reference:
            resolved = binder.resolve_dispatch(reference["manifest_path"], reference["manifest_sha256"],
                                               expected={"work_item": slug, "position": "investigator"})
            frozen = resolved["manifest"]
            payload = directive["payload"]
            target, route, model = resolved_launch(inv)
            expected_fields = {"framework": target, "route": route, "model": model, "publication_state": "prepared",
                               "investigation_id": inv["id"], "question": inv["question"],
                               "complexity": inv["complexity"]}
            if any(payload.get(key) != value for key, value in expected_fields.items()):
                reject("published investigator launch differs from the declared input")
            expected_assignment = {"investigation_id": inv["id"], "question": inv["question"], "complexity": inv["complexity"]}
            if json.loads(frozen["bindings"]["assignment"]) != expected_assignment:
                reject("published investigator assignment differs from the declared input")
            if payload["prompt"] != Path(resolved["payload_path"]).read_text() or payload["bindings"] != frozen["bindings"]:
                reject("published investigator input differs from its immutable dispatch")
            if payload["session_context"] != {"dispatch_guidance": payload["prompt"], "position_dispatch": reference}:
                reject("published investigator session context differs from its immutable dispatch")
            if payload["completion_input"] != {"position_dispatch": reference, "lore_task_id": frozen["bindings"]["task_id"]}:
                reject("published investigator completion reference differs from its immutable dispatch")
            if payload["producer"] != {key: frozen["producer"][key] for key in ("template_id", "template_version")}:
                reject("published investigator producer differs from its immutable dispatch")
            bundle = Path(resolved["resolved_manifest_path"]).parent
            if payload["descriptor"] != json.loads((bundle / "descriptor.json").read_bytes()):
                reject("published investigator descriptor differs from its immutable dispatch")
            selected = json.loads((bundle / "selection.json").read_bytes()) if frozen.get("dispatch_route") == "native-subagent" else None
            if payload["native_selection"] != selected:
                reject("published investigator native selection differs from its immutable dispatch")
    artifact_bytes = canonical(previous)
    Path(output_path).write_text(json.dumps({"artifact": previous, "artifact_text": artifact_bytes.decode(),
                                            "artifact_sha256": hashlib.sha256(artifact_bytes).hexdigest()}))
    raise SystemExit(0)


directives = []
handle_slots = {}
for ordinal, inv in enumerate(normalized, 1):
    op_id = hashlib.sha256((input_fp + "\0" + inv["id"]).encode("utf-8")).hexdigest()[:20]
    payload = {"role": "researcher", "model": researcher_model,
               "investigation_id": inv["id"], "question": inv["question"],
               "complexity": inv["complexity"], "prior_knowledge": knowledge_by_id[inv["id"]],
               "dispatch_guidance": dispatch_guidance}
    if legacy:
        payload.update(template_path=legacy_template, template_version=researcher_template_version,
                       provenance="explicit-legacy-template")
    else:
        request = inv.get("dispatch", {})
        target, route, model = resolved_launch(inv)
        descriptor = descriptors[target]
        bindings = request.get("bindings")
        if bindings is None:
            attempt = "spec-" + uuid.uuid4().hex
            packet_id = "pkt-" + uuid.uuid4().hex[:12]
            scales = list(dict.fromkeys(s for r in inv["prefetch"] for s in r["scale_set"]))
            row = {"packet_id": packet_id, "packet_scope": "session", "work_item": slug,
                   "session_id": None, "arm": None, "phase": None, "task_scale_set": ",".join(scales) or None,
                   "task_id": None, "template_version": lead_template_version,
                   "prefetch_queries": [r["query"] for r in inv["prefetch"]],
                   "synthesis_waiver": {"by": "spec-lead", "reason": "full-wave investigator dispatch assembles and dispatches in one verb; the wave is judged as a set when the lead writes its questions"}}
            build_packet(kdir, row, role="investigator", caller="spec-lead", scales=scales,
                         assembly=("\n".join(r["content"] for r in knowledge_by_id[inv["id"]]), {}))
            bindings = dict.fromkeys(binder.FIELDS)
            bindings.update(work_item=slug, dispatch_attempt_id=attempt, report_id=attempt,
                            report_path=str(kdir / "_work" / slug / "worker-reports" / (attempt + ".md")),
                            execution_root=str(Path.cwd().resolve()), packet_id=packet_id,
                            packet_pointer=pointer(kdir, packet_id), assignment=json.dumps({
                                "investigation_id": inv["id"], "question": inv["question"], "complexity": inv["complexity"]}, ensure_ascii=False))
            bindings["absence_reasons"] = {field: "no-plan-task-assigned" if field in {"task_id", "revision_id"}
                                          else "not-applicable-to-investigator" for field in binder.FIELDS if bindings[field] is None}
        composition = session_composition(bindings)
        if route == "session" and bindings["execution_root"] is None:
            reference = prompt = selection = completion = None
            context = binder.prepare_session_input(descriptor, bindings, kdir, dispatch_guidance.encode(), **composition)
            state = "pending-execution-root"
        else:
            reference = binder.publish(descriptor, bindings, kdir, dispatch_guidance.encode(),
                                       native_model=model if route == "native" else None,
                                       required=("packet_id", "packet_pointer"), **composition)
            prompt = Path(reference["payload_path"]).read_text()
            selection_path = Path(reference["manifest_path"]).parent / "selection.json"
            selection = json.loads(selection_path.read_bytes()) if route == "native" else None
            completion = {"position_dispatch": reference, "lore_task_id": bindings["task_id"]}
            context = {"dispatch_guidance": prompt, "position_dispatch": reference}
            state = "prepared"
        payload.update(position="investigator", framework=target, route=route, model=model,
                       session_route=resolved_session_route(inv),
                       prompt=prompt, position_dispatch=reference, descriptor=descriptor,
                       producer={key: descriptor[key] for key in ("template_id", "template_version")},
                       native_selection=selection, completion_input=completion, publication_state=state,
                       wrapper_template_version=source_shape["wrapper"]["sha256"][:12],
                       lead_template_version=lead_template_version, bindings=bindings, session_context=context)
    directives.append({"ordinal": ordinal, "operation_id": op_id,
                       "adapter": str(Path(script_dir).parent / "adapters/agents" / (payload.get("framework", framework) + ".sh")),
                       "action": "spawn", "payload": payload,
                       "teardown_payload": {"action": "shutdown", "handle_slot": op_id, "approve": True}})
    handle_slots[op_id] = None

artifact = {"schema_version": 1, "slug": slug, "input_fingerprint": input_fp,
            "source_fingerprint": source_fp, "source_manifest": source_shape,
            "directives": directives, "handle_slots": handle_slots}
artifact_bytes = canonical(artifact)
artifact_sha = hashlib.sha256(artifact_bytes).hexdigest()
with open(output_path, "w", encoding="utf-8") as f:
    json.dump({"artifact": artifact, "artifact_text": artifact_bytes.decode("utf-8"),
               "artifact_sha256": artifact_sha}, f, ensure_ascii=False)
PY
PREP_RC=$?
set -e
if [[ $PREP_RC -ne 0 ]]; then
  emit_error "investigation manifest validation or preparation failed" "use the diagnostic above to correct the declared schema or prefetch source"
fi

INPUT_FP=$(jq -r '.artifact.input_fingerprint' "$PREPARED")
SOURCE_FP=$(jq -r '.artifact.source_fingerprint' "$PREPARED")
NEW_SHA=$(jq -r '.artifact_sha256' "$PREPARED")

# Parse the latest durable open atom. The execution log is the only history
# source; the artifact is the current liveness source.
LATEST_ATOM=$(python3 - "$LOG_FILE" <<'PY'
import json, re, sys
latest = None
try:
    text = open(sys.argv[1], encoding="utf-8").read()
except FileNotFoundError:
    text = ""
for m in re.finditer(r"(?m)^Spec-open-atom: (\{.*\})$", text):
    try: latest = json.loads(m.group(1))
    except Exception: pass
print(json.dumps(latest))
PY
)

STATUS="created"
NEED_PUBLISH=1
NEED_ATOM=1
if [[ -f "$ARTIFACT" ]]; then
  set +e
  CURRENT=$(python3 - "$ARTIFACT" <<'PY'
import hashlib, json, sys
p = sys.argv[1]
try:
    data = open(p, "rb").read()
    obj = json.loads(data)
    assert obj.get("schema_version") == 1
    assert isinstance(obj.get("slug"), str)
    assert isinstance(obj.get("input_fingerprint"), str)
    assert isinstance(obj.get("source_fingerprint"), str)
    print(json.dumps({"slug": obj["slug"], "input": obj["input_fingerprint"],
                      "source": obj["source_fingerprint"], "sha": hashlib.sha256(data).hexdigest()}))
except Exception as exc:
    print(str(exc), file=sys.stderr)
    raise SystemExit(1)
PY
  )
  CURRENT_RC=$?
  set -e
  [[ $CURRENT_RC -eq 0 ]] || emit_error "existing spec-dispatch.json is invalid" "repair or remove $ARTIFACT after reviewing the damaged artifact"
  [[ "$(jq -r '.slug' <<<"$CURRENT")" == "$SLUG" ]] || emit_error "existing dispatch artifact slug does not match '$SLUG'" "repair $ARTIFACT"
  CURRENT_SHA=$(jq -r '.sha' <<<"$CURRENT")
  if [[ "$LATEST_ATOM" != "null" ]]; then
    ATOM_SHA=$(jq -r '.artifact_sha256 // empty' <<<"$LATEST_ATOM")
    [[ "$ATOM_SHA" == "$CURRENT_SHA" ]] || emit_error "existing dispatch artifact hash contradicts its latest completion atom" "restore the matching artifact or remove the corrupt atom/artifact pair after review"
  fi
  if [[ "$(jq -r '.input' <<<"$CURRENT")" == "$INPUT_FP" && "$(jq -r '.source' <<<"$CURRENT")" == "$SOURCE_FP" ]]; then
    NEED_PUBLISH=0
    if [[ "$LATEST_ATOM" == "null" ]]; then
      STATUS="recovered"
    else
      STATUS="reused"
      NEED_ATOM=0
    fi
  else
    STATUS="replaced"
  fi
elif [[ "$LATEST_ATOM" != "null" ]]; then
  emit_error "a spec-open completion atom exists but spec-dispatch.json is absent" "restore the artifact named by the atom or remove the stale atom after review"
fi

if [[ $NEED_PUBLISH -eq 1 ]]; then
  PUBLISH_TMP=$(mktemp "$ITEM_DIR/.spec-dispatch.XXXXXX")
  ARTIFACT_TEXT=$(jq -r '.artifact_text' "$PREPARED")
  printf '%s' "$ARTIFACT_TEXT" > "$PUBLISH_TMP"
  mv "$PUBLISH_TMP" "$ARTIFACT"
fi

if [[ $NEED_ATOM -eq 1 ]]; then
  ATOM=$(jq -cn --arg slug "$SLUG" --arg status "$STATUS" --arg input "$INPUT_FP" \
    --arg source "$SOURCE_FP" --arg sha "$NEW_SHA" \
    '{schema_version:1,slug:$slug,verb:"open",status:$status,input_fingerprint:$input,source_fingerprint:$source,artifact_sha256:$sha}')
  if ! printf 'Spec verb: open\nSpec-open-atom: %s\nStatus: %s\nInput-fingerprint: %s\nSource-fingerprint: %s\nPublished-artifact-sha256: %s\n' \
    "$ATOM" "$STATUS" "$INPUT_FP" "$SOURCE_FP" "$NEW_SHA" \
    | bash "$SCRIPT_DIR/write-execution-log.sh" --slug "$SLUG" --source spec-verb --template-version "$LEAD_TEMPLATE_VERSION" >/dev/null; then
    emit_error "dispatch artifact was published but its completion atom failed" "retry the same command to recover the missing atom"
  fi
fi

if [[ $NEED_PUBLISH -eq 1 ]]; then
  RESULT=$(jq -c --arg status "$STATUS" --arg path "$ARTIFACT" \
    '.artifact + {status:$status, artifact_path:$path, artifact_sha256:.artifact_sha256}' "$PREPARED")
else
  RESULT=$(jq -c --arg status "$STATUS" --arg path "$ARTIFACT" --arg sha "$CURRENT_SHA" \
    '. + {status:$status, artifact_path:$path, artifact_sha256:$sha}' "$ARTIFACT")
fi
if [[ $JSON_MODE -eq 1 ]]; then
  printf '%s\n' "$RESULT"
else
  python3 - "$RESULT" <<'PY'
import json, sys
d=json.loads(sys.argv[1])
print(f"[spec open] {d['status']}: {d['slug']}")
print(f"Artifact: {d['artifact_path']}")
print(f"Directives prepared: {len(d['directives'])}; harness calls executed: 0")
print(f"Input fingerprint: {d['input_fingerprint']}")
print(f"Source fingerprint: {d['source_fingerprint']}")
PY
fi
