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
RESEARCHER_MODEL=$(resolve_model_for_role researcher spec 2>/dev/null) || emit_error "researcher model could not be resolved for the spec ceremony"
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
  "$RESEARCHER_MODEL" "$RESEARCHER_TEMPLATE_VERSION" "$SCRIPT_DIR/prefetch-knowledge.sh" "$ADAPTER" "$GUIDANCE_FILE" <<'PY'
import hashlib, json, os, subprocess, sys

(input_path, output_path, slug, framework, subagents, team_messaging,
 researcher_model, researcher_template_version, prefetch_script, adapter,
 guidance_path) = sys.argv[1:]

def reject(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)

try:
    raw = json.load(open(input_path, encoding="utf-8"))
except Exception as exc:
    reject(f"invalid investigations JSON: {exc}")

if not isinstance(raw, dict): reject("investigations document must be an object")
allowed_root = {"schema_version", "track", "investigations"}
unknown = sorted(set(raw) - allowed_root)
if unknown: reject("unknown investigations document field(s): " + ", ".join(unknown))
if raw.get("schema_version") != 1: reject("schema_version must be the integer 1")
if raw.get("track") != "full": reject("track must be declared as 'full'; short track cannot be opened")
investigations = raw.get("investigations")
if not isinstance(investigations, list) or not investigations: reject("investigations must be a non-empty array")

allowed_inv = {"id", "kind", "question", "complexity", "prefetch"}
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
    if set(inv) != allowed_inv: reject(f"{where} must declare exactly: id, kind, question, complexity, prefetch")
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
    lowered = question.lower()
    if inv.get("kind") == "fixed" and "external skill" in lowered and "agent" in lowered:
        fixed_external += 1
    if inv.get("kind") == "fixed" and "preference" in lowered and "convention" in lowered:
        fixed_preferences += 1
    normalized.append({"id": ident, "kind": inv["kind"], "question": question,
                       "complexity": inv["complexity"], "prefetch": normalized_prefetch})

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

input_shape = {"schema_version": 1, "slug": slug, "ordered_investigations": normalized}
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

capabilities = {"subagents": subagents, "team_messaging": team_messaging}
source_shape = {"active_framework": framework, "adapter_capabilities": capabilities,
                "researcher_model": researcher_model,
                "researcher_template_version": researcher_template_version,
                "dispatch_guidance_identity": guidance_identity,
                "ordered_prefetch": prefetch_manifest}
source_fp = hashlib.sha256(canonical(source_shape)).hexdigest()

directives = []
handle_slots = {}
for ordinal, inv in enumerate(normalized, 1):
    op_id = hashlib.sha256((input_fp + "\0" + inv["id"]).encode("utf-8")).hexdigest()[:20]
    payload = {"role": "researcher", "model": researcher_model,
               "investigation_id": inv["id"], "question": inv["question"],
               "complexity": inv["complexity"], "prior_knowledge": knowledge_by_id[inv["id"]],
               "dispatch_guidance": dispatch_guidance}
    directives.append({"ordinal": ordinal, "operation_id": op_id, "adapter": adapter,
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
