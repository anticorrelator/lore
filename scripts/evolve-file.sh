#!/usr/bin/env bash
# evolve-file.sh — Accept one lead-authored evolve assignment and recover its
# sanctioned-writer fanout. This verb files judgments; it never makes them and
# never edits a proposal target.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib.sh"

QUEUE_FILE=""
DECISIONS_FILE=""
JSON_MODE=0

usage() {
  cat >&2 <<'EOF'
Usage: lore evolve file --queue <json-file> --decisions <json-file> [--json]

Validate and atomically accept one lead-authored filing manifest, then repair
only missing accepted-cluster, template-registry, and terminal cutoff sinks.
The terminal role=evolve journal row is written last. Exact replay is safe;
semantic reassignment and stale predecessor reuse are refused.
EOF
}

emit_response() {
  local status="$1" exit_code="$2" queue_json="$3" filing_json="$4"
  local accepted="$5" complete="$6" completed_json="$7" missing_json="$8"
  local warnings_json="$9" error_json="${10}"
  local result
  result=$(jq -nc --arg status "$status" --argjson exit_code "$exit_code" \
    --argjson queue "$queue_json" --argjson filing "$filing_json" \
    --argjson accepted "$accepted" --argjson complete "$complete" \
    --argjson completed "$completed_json" --argjson missing "$missing_json" \
    --argjson warnings "$warnings_json" --argjson error "$error_json" \
    '{schema_version:1,operation:"file",status:$status,exit_code:$exit_code,
      queue:$queue,filing:$filing,decision_accepted:$accepted,filing_complete:$complete,
      completed_sinks:$completed,missing_sinks:$missing,warnings:$warnings,error:$error}')
  if [[ $JSON_MODE -eq 1 ]]; then
    printf '%s\n' "$result"
  else
    jq -r '
      "[evolve file] \(.status): queue=\(.queue.id // "unknown")",
      "Decision accepted: \(.decision_accepted)",
      "Filing complete: \(.filing_complete)",
      (if .filing then "Filing: \(.filing.path)\nFiling-id: \(.filing.id)" else empty end),
      "Completed sinks: \(if (.completed_sinks|length)>0 then (.completed_sinks|join(", ")) else "none" end)",
      "Missing sinks: \(if (.missing_sinks|length)>0 then (.missing_sinks|join(", ")) else "none" end)"' <<<"$result"
    if [[ "$error_json" != null ]]; then
      jq -r '"Error: \(.error.message)\nRepair target: \(.error.repair_target)"' <<<"$result" >&2
    fi
  fi
  exit "$exit_code"
}

error_object() {
  jq -nc --arg code "$1" --arg message "$2" --arg repair_target "$3" \
    '{code:$code,message:$message,repair_target:$repair_target}'
}

refuse() {
  local code="$1" message="$2" repair="$3"
  emit_response refused 1 null null false false '[]' '[]' '[]' "$(error_object "$code" "$message" "$repair")"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --queue) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || refuse invalid_arguments "--queue requires a value" "pass a published queue-v1 artifact"; QUEUE_FILE="$2"; shift 2 ;;
    --decisions) [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || refuse invalid_arguments "--decisions requires a value" "pass a complete lead-authored manifest"; DECISIONS_FILE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) refuse invalid_arguments "unknown argument: $1" "use 'lore evolve file --help'" ;;
  esac
done

[[ -r "$QUEUE_FILE" ]] || refuse unreadable_queue "queue file is not readable: $QUEUE_FILE" "pass the published review-queue artifact"
[[ -r "$DECISIONS_FILE" ]] || refuse unreadable_decisions "decisions file is not readable: $DECISIONS_FILE" "pass a lead-authored filing manifest"

KDIR=$(resolve_knowledge_dir)
FILING_DIR="$KDIR/_evolve/review-filings"
LOCK_DIR="$KDIR/_evolve/.evolve-file.lock"
mkdir -p "$KDIR/_evolve"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  refuse filing_locked "another evolve filing owns the portable lock" "remove $LOCK_DIR only after verifying no filing process is active"
fi
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

VALIDATED="$TMP_DIR/validated.json"
set +e
python3 - "$QUEUE_FILE" "$DECISIONS_FILE" "$VALIDATED" "$KDIR" "$REPO_DIR" <<'PY'
import datetime as dt
import hashlib
import json
import os
import re
import sys

queue_path, decisions_path, output_path, kdir, repo_dir = sys.argv[1:]

def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()

def sha(data):
    return hashlib.sha256(data).hexdigest()

def reject(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)

def nonempty(value):
    return isinstance(value, str) and bool(value.strip())

try:
    queue_raw = open(queue_path, "rb").read()
    queue = json.loads(queue_raw)
except Exception as exc:
    reject(f"invalid queue JSON: {exc}")
if not isinstance(queue, dict) or queue.get("schema_version") != 1:
    reject("queue must be a schema_version 1 object")
queue_id = queue.get("queue_id")
if not isinstance(queue_id, str) or re.fullmatch(r"[0-9a-f]{64}", queue_id) is None:
    reject("queue_id must be a 64-character lowercase sha256")
expected_path = os.path.realpath(os.path.join(kdir, "_evolve", "review-queues", queue_id + ".json"))
if os.path.realpath(queue_path) != expected_path:
    reject("--queue must name the published review-queues/<queue_id>.json artifact")
claimed = queue.get("artifact_sha256")
body = {key: value for key, value in queue.items() if key != "artifact_sha256"}
if claimed != sha(canonical(body)) or queue_raw != canonical(queue):
    reject("queue canonical bytes or self-hash do not match queue-v1")
queue_file_sha = sha(queue_raw)

try:
    manifest = json.load(open(decisions_path, encoding="utf-8"))
except Exception as exc:
    reject(f"invalid decisions JSON: {exc}")
ROOT_KEYS = {"schema_version", "queue_id", "queue_sha256", "actor", "model", "decisions",
             "cluster_dispositions", "version_registrations", "summary"}
if not isinstance(manifest, dict) or set(manifest) != ROOT_KEYS:
    reject("filing manifest must declare exactly the v1 root fields")
if manifest.get("schema_version") != 1 or manifest.get("queue_id") != queue_id or manifest.get("queue_sha256") != queue_file_sha:
    reject("filing manifest queue identity does not match the published artifact")
for key in ("actor", "model", "summary"):
    if not nonempty(manifest.get(key)):
        reject(f"{key} must be a non-empty string")
for key in ("decisions", "cluster_dispositions", "version_registrations"):
    if not isinstance(manifest.get(key), list):
        reject(f"{key} must be an array")

items = {item.get("item_id"): item for item in queue.get("items", []) if isinstance(item, dict)}
reviewable = {item_id for item_id, item in items.items()
              if (item.get("eligibility") or {}).get("status") == "eligible"}
decisions = manifest["decisions"]
if any(not isinstance(row, dict) or set(row) != {"item_id", "verdict", "rationale", "escalation", "application"} for row in decisions):
    reject("every decision must declare exactly item_id, verdict, rationale, escalation, application")
decision_ids = [row.get("item_id") for row in decisions]
if len(decision_ids) != len(set(decision_ids)) or set(decision_ids) != reviewable:
    reject("decisions must assign every eligible item exactly once and no ineligible item")

applications = {}
for row in decisions:
    item_id = row["item_id"]
    verdict = row.get("verdict")
    if verdict not in {"apply", "reject", "escalate"} or not nonempty(row.get("rationale")):
        reject(f"decision {item_id} needs a lead verdict and non-empty rationale")
    escalation = row.get("escalation")
    application = row.get("application")
    effective = verdict
    if verdict == "escalate":
        if not isinstance(escalation, dict) or set(escalation) != {"reason", "resolution"}:
            reject(f"decision {item_id} escalation must declare reason and resolution")
        if escalation.get("reason") not in {"destructive-change", "high-confidence-drop", "abstain"}:
            reject(f"decision {item_id} has an invalid escalation reason")
        if escalation.get("resolution") not in {"pending", "apply", "reject", "defer"}:
            reject(f"decision {item_id} has an invalid escalation resolution")
        effective = escalation["resolution"]
    elif escalation is not None:
        reject(f"decision {item_id} may carry escalation only with verdict=escalate")
    if effective == "apply":
        if not isinstance(application, dict) or set(application) != {"outcome", "target", "pre_version", "post_version"}:
            reject(f"decision {item_id} effective apply requires the exact application shape")
        if application.get("outcome") not in {"applied", "failed", "deferred"}:
            reject(f"decision {item_id} has an invalid application outcome")
        if not all(nonempty(application.get(key)) for key in ("target", "pre_version", "post_version")):
            reject(f"decision {item_id} application fields must be non-empty")
        applications[item_id] = application
    elif application is not None:
        reject(f"decision {item_id} may carry application only for an effective apply resolution")

REG_KEYS = {"item_id", "target", "template_id", "template_path", "pre_version", "post_version", "description"}
registrations = manifest["version_registrations"]
if any(not isinstance(row, dict) or set(row) != REG_KEYS for row in registrations):
    reject("every version registration must declare the exact v1 fields")
if len({(row.get("template_id"), row.get("post_version")) for row in registrations}) != len(registrations):
    reject("version registrations contain duplicate template/version keys")
by_item = {}
for registration in registrations:
    item_id = registration.get("item_id")
    application = applications.get(item_id)
    if not application or application.get("outcome") != "applied" or application.get("pre_version") == application.get("post_version"):
        reject(f"registration {item_id} is not backed by an applied byte change")
    if any(registration.get(key) != application.get(key) for key in ("target", "pre_version", "post_version")):
        reject(f"registration {item_id} contradicts the application facts")
    if not all(nonempty(registration.get(key)) for key in ("template_id", "template_path", "post_version")):
        reject(f"registration {item_id} has empty template identity fields")
    target = application["target"]
    live_path = target if os.path.isabs(target) else os.path.join(repo_dir, target)
    try:
        digest = sha(open(live_path, "rb").read())
    except OSError as exc:
        reject(f"registration {item_id} live target is unreadable: {exc}")
    post = application["post_version"]
    if len(post) not in {12, 64} or digest[:len(post)] != post:
        reject(f"registration {item_id} post_version does not match the live target hash")
    by_item[item_id] = registration
for item_id, application in applications.items():
    changed = application.get("outcome") == "applied" and application.get("pre_version") != application.get("post_version")
    if changed and item_id not in by_item:
        reject(f"applied byte change {item_id} requires one version registration")

candidates = {row.get("candidate_id"): row for row in queue.get("recurring_clusters", []) if isinstance(row, dict)}
dispositions = manifest["cluster_dispositions"]
DISP_KEYS = {"candidate_id", "disposition", "rationale", "resulting_clusters"}
if any(not isinstance(row, dict) or set(row) != DISP_KEYS for row in dispositions):
    reject("every cluster disposition must declare the exact v1 fields")
disp_ids = [row.get("candidate_id") for row in dispositions]
if len(disp_ids) != len(set(disp_ids)) or set(disp_ids) != set(candidates):
    reject("cluster dispositions must assign every prepared candidate exactly once")

created_clusters = []
for disposition in dispositions:
    candidate_id = disposition["candidate_id"]
    action = disposition.get("disposition")
    if action not in {"merge", "edit", "split", "reject", "escalate"} or not nonempty(disposition.get("rationale")):
        reject(f"cluster {candidate_id} needs a valid lead disposition and rationale")
    resulting = disposition.get("resulting_clusters")
    if action in {"merge", "edit", "split"}:
        if not isinstance(resulting, list) or not resulting:
            reject(f"cluster {candidate_id} {action} requires resulting_clusters")
        if action in {"merge", "edit"} and len(resulting) != 1:
            reject(f"cluster {candidate_id} {action} requires exactly one resulting cluster")
        if action == "split" and len(resulting) < 2:
            reject(f"cluster {candidate_id} split requires at least two resulting clusters")
        for result in resulting:
            if not isinstance(result, dict) or set(result) != {"target", "change_types", "work_items", "journal_row_refs"}:
                reject(f"cluster {candidate_id} resulting cluster has an invalid shape")
            if not nonempty(result.get("target")) or not isinstance(result.get("change_types"), list) or not result["change_types"] or not isinstance(result.get("work_items"), list) or not result["work_items"]:
                reject(f"cluster {candidate_id} resulting cluster has empty identity members")
            if result["change_types"] != sorted(set(result["change_types"])) or result["work_items"] != sorted(set(result["work_items"])):
                reject(f"cluster {candidate_id} resulting members must be sorted and unique")
            if not isinstance(result.get("journal_row_refs"), list):
                reject(f"cluster {candidate_id} journal_row_refs must be an array")
            basis = result["target"] + "|" + "|".join(result["change_types"]) + "|" + "|".join(result["work_items"])
            cluster_id = sha(basis.encode())[:16]
            created_clusters.append({**result, "cluster_id": cluster_id, "decision": action})
    elif resulting is not None:
        reject(f"cluster {candidate_id} {action} must set resulting_clusters to null")

consumed_cluster_ids = set()
for decision in decisions:
    item = items[decision["item_id"]]
    if item.get("gate_path") != "recurring-failure":
        continue
    for ref in (item.get("eligibility") or {}).get("evidence_refs") or []:
        if isinstance(ref, dict) and ref.get("source_id") == "accepted_clusters" and ref.get("cluster_id"):
            consumed_cluster_ids.add(ref["cluster_id"])

semantic = {key: manifest[key] for key in ("queue_id", "queue_sha256", "actor", "model", "decisions",
                                             "cluster_dispositions", "version_registrations", "summary")}
filing_id = sha(canonical({"schema_version": 1, **semantic}))
run_id = "evolve-" + filing_id[:16]
accepted_at = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")

expected_sinks = []
for row in created_clusters:
    payload = {**row, "accepted_at": accepted_at, "accepted_at_run_id": run_id}
    expected_sinks.append({"kind": "accepted-cluster-create", "key": f"accepted-cluster:create:{row['cluster_id']}", "payload": payload})
for cluster_id in sorted(consumed_cluster_ids):
    expected_sinks.append({"kind": "accepted-cluster-consume", "key": f"accepted-cluster:consume:{cluster_id}:{run_id}",
                           "payload": {"cluster_id": cluster_id, "consumed_at_run_id": run_id}})
for row in registrations:
    expected_sinks.append({"kind": "template-registry", "key": f"template-registry:{row['template_id']}@{row['post_version']}", "payload": row})
expected_sinks.append({"kind": "journal-cutoff", "key": f"journal:evolve-filing:{filing_id}",
                       "payload": {"context": f"evolve-filing:{filing_id}"}})

filing = {
    "schema_version": 1,
    "filing_id": filing_id,
    "queue_id": queue_id,
    "queue_sha256": queue_file_sha,
    "run_id": run_id,
    "predecessor": (queue.get("run") or {}).get("predecessor"),
    "actor": manifest["actor"],
    "model": manifest["model"],
    "decisions": decisions,
    "cluster_dispositions": dispositions,
    "version_registrations": registrations,
    "expected_sinks": expected_sinks,
    "cutoff": queue.get("cutoff"),
    "accepted_at": accepted_at,
    "provenance": {"producer": "evolve-file.sh", "schema_version": 1,
                   "authority_boundary": "lead-supplied-decisions-only"},
}
result = {"queue_id": queue_id, "queue_sha256": queue_file_sha, "filing_id": filing_id,
          "run_id": run_id, "filing": filing, "filing_text": canonical(filing).decode(),
          "created_clusters": created_clusters, "consumed_cluster_ids": sorted(consumed_cluster_ids)}
json.dump(result, open(output_path, "w"), ensure_ascii=False, separators=(",", ":"))
PY
VALIDATE_RC=$?
set -e
if [[ $VALIDATE_RC -ne 0 ]]; then
  refuse invalid_filing_manifest "queue or lead manifest validation failed" "correct the diagnostic above before retrying"
fi

QUEUE_ID=$(jq -r .queue_id "$VALIDATED")
QUEUE_SHA=$(jq -r .queue_sha256 "$VALIDATED")
FILING_ID=$(jq -r .filing_id "$VALIDATED")
RUN_ID=$(jq -r .run_id "$VALIDATED")
FILING="$FILING_DIR/$QUEUE_ID.json"
JOURNAL="$KDIR/_meta/effectiveness-journal.jsonl"

# Lineage and authority publication happen under the portable lock. The helper
# accepts an exact retry but refuses a competing successor or semantic reuse.
AUTHORITY="$TMP_DIR/authority.json"
set +e
python3 - "$VALIDATED" "$FILING_DIR" "$JOURNAL" "$FILING" "$AUTHORITY" <<'PY'
import hashlib,json,os,sys,tempfile
validated_path,filing_dir,journal_path,filing_path,out_path=sys.argv[1:]
prepared=json.load(open(validated_path)); filing=prepared["filing"]
completed=set()
if os.path.isfile(journal_path):
 for line in open(journal_path,encoding="utf-8"):
  try: row=json.loads(line)
  except Exception: continue
  context=row.get("context") or ""
  if row.get("role")=="evolve" and context.startswith("evolve-filing:"):
   completed.add(context.split(":",1)[1])
existing=[]
if os.path.isdir(filing_dir):
 for name in sorted(os.listdir(filing_dir)):
  if not name.endswith(".json"): continue
  path=os.path.join(filing_dir,name)
  try:
   raw=open(path,"rb").read(); obj=json.loads(raw)
   if obj.get("schema_version")!=1 or not obj.get("filing_id"): raise ValueError("not filing v1")
   if raw!=json.dumps(obj,ensure_ascii=False,sort_keys=True,separators=(",",":")).encode(): raise ValueError("noncanonical")
  except Exception as exc:
   print(f"invalid existing filing {path}: {exc}",file=sys.stderr); raise SystemExit(1)
  existing.append((path,obj))
current=[row for path,row in existing if path==filing_path]
new_authority=not current
if current and current[0].get("filing_id")!=filing["filing_id"]:
 print("filing_collision: queue already has a different lead assignment",file=sys.stderr); raise SystemExit(1)
exact_retry=bool(current)
incomplete=[row for _,row in existing if row["filing_id"] not in completed and row["filing_id"]!=filing["filing_id"]]
if incomplete:
 print("accepted_filing_incomplete: another accepted filing must be recovered first",file=sys.stderr); raise SystemExit(1)
completed_rows=sorted([row for _,row in existing if row["filing_id"] in completed],key=lambda r:(r.get("accepted_at") or "",r["filing_id"]))
latest=completed_rows[-1]["filing_id"] if completed_rows else None
predecessor=filing.get("predecessor")
expected=predecessor.get("filing_id") if isinstance(predecessor,dict) else None
if not exact_retry and latest!=expected:
 print(f"stale_queue: expected predecessor {expected!r}, latest completed is {latest!r}",file=sys.stderr); raise SystemExit(1)
if not exact_retry:
 for path,row in existing:
  row_pred=row.get("predecessor")
  row_expected=row_pred.get("filing_id") if isinstance(row_pred,dict) else None
  if row["filing_id"]!=filing["filing_id"] and row_expected==expected:
   print("stale_queue: predecessor already has a different successor",file=sys.stderr); raise SystemExit(1)
if new_authority:
 os.makedirs(filing_dir,exist_ok=True)
 fd,tmp=tempfile.mkstemp(prefix=".review-filing.",dir=filing_dir)
 try:
  with os.fdopen(fd,"wb") as handle:
   handle.write(prepared["filing_text"].encode()); handle.flush(); os.fsync(handle.fileno())
  os.replace(tmp,filing_path)
 finally:
  if os.path.exists(tmp): os.unlink(tmp)
raw=open(filing_path,"rb").read()
json.dump({"new_authority":new_authority,"file_sha256":hashlib.sha256(raw).hexdigest()},open(out_path,"w"))
PY
AUTHORITY_RC=$?
set -e
if [[ $AUTHORITY_RC -ne 0 ]]; then
  refuse authority_refused "filing authority or predecessor validation failed" "retain the completed lineage and prepare a fresh queue, or replay the exact accepted filing"
fi

NEW_AUTHORITY=$(jq -r .new_authority "$AUTHORITY")
FILING_SHA=$(jq -r .file_sha256 "$AUTHORITY")
# Recovery is driven by the immutable accepted filing, including its original
# accepted_at value. A retry never regenerates sink payload timestamps.
jq --slurpfile accepted "$FILING" '.filing=$accepted[0]' "$VALIDATED" > "$VALIDATED.accepted"
mv "$VALIDATED.accepted" "$VALIDATED"

completed=()
missing=()
writes_made=0
failed=0

sink_failure_requested() {
  [[ "${LORE_EVOLVE_FILE_FAIL_SINK:-}" == "$1" ]]
}

cluster_state() {
  local payload="$1" mode="$2"
  python3 - "$KDIR/_evolve/accepted-clusters.jsonl" "$payload" "$mode" <<'PY'
import json,os,sys
path,payload_raw,mode=sys.argv[1:]; payload=json.loads(payload_raw); matches=[]
if os.path.isfile(path):
 for line in open(path,encoding="utf-8"):
  try: row=json.loads(line)
  except Exception: print("conflict"); raise SystemExit
  if row.get("cluster_id")==payload.get("cluster_id"): matches.append(row)
if len(matches)>1: print("conflict")
elif mode=="create":
 want={"schema_version":"1","vocabulary_version":"1","cluster_id":payload["cluster_id"],"target":payload["target"],"change_types":payload["change_types"],"work_items":payload["work_items"],"journal_row_refs":payload["journal_row_refs"],"accepted_at":payload["accepted_at"],"accepted_at_run_id":payload["accepted_at_run_id"],"accepted_by_maintainer_decision":payload["decision"],"consumed_at_run_id":None}
 print("missing" if not matches else "landed" if matches[0]==want else "conflict")
else:
 print("missing" if not matches or matches[0].get("consumed_at_run_id") is None else "landed" if matches[0].get("consumed_at_run_id")==payload["consumed_at_run_id"] else "conflict")
PY
}

while IFS= read -r sink; do
  [[ -n "$sink" ]] || continue
  kind=$(jq -r .kind <<<"$sink")
  key=$(jq -r .key <<<"$sink")
  payload=$(jq -c .payload <<<"$sink")
  case "$kind" in
    accepted-cluster-create)
      state=$(cluster_state "$payload" create)
      if [[ "$state" == landed ]]; then completed+=("$key")
      elif [[ "$state" == conflict ]] || sink_failure_requested "$key"; then missing+=("$key"); failed=1
      else
        target=$(jq -r .target <<<"$payload")
        changes=$(jq -r '.change_types|join(",")' <<<"$payload")
        work_items=$(jq -r '.work_items|join(",")' <<<"$payload")
        decision=$(jq -r .decision <<<"$payload")
        accepted_at=$(jq -r .accepted_at <<<"$payload")
        accepted_run=$(jq -r .accepted_at_run_id <<<"$payload")
        refs=$(jq -r '[.journal_row_refs[] | .timestamp+":"+.work_item] | join(",")' <<<"$payload")
        args=(--append-exact --target "$target" --change-types "$changes" --work-items "$work_items" --decision "$decision" --accepted-at-run-id "$accepted_run" --accepted-at "$accepted_at" --kdir "$KDIR")
        [[ -z "$refs" ]] || args+=(--journal-row-refs "$refs")
        if bash "$SCRIPT_DIR/accepted-cluster-append.sh" "${args[@]}" >/dev/null && [[ $(cluster_state "$payload" create) == landed ]]; then completed+=("$key"); writes_made=$((writes_made+1)); else missing+=("$key"); failed=1; fi
      fi
      ;;
    accepted-cluster-consume)
      state=$(cluster_state "$payload" consume)
      if [[ "$state" == landed ]]; then completed+=("$key")
      elif [[ "$state" == conflict ]] || sink_failure_requested "$key"; then missing+=("$key"); failed=1
      else
        cid=$(jq -r .cluster_id <<<"$payload")
        consumed=$(jq -r .consumed_at_run_id <<<"$payload")
        if bash "$SCRIPT_DIR/accepted-cluster-append.sh" --consume --cluster-id "$cid" --consumed-at-run-id "$consumed" --kdir "$KDIR" >/dev/null && [[ $(cluster_state "$payload" consume) == landed ]]; then completed+=("$key"); writes_made=$((writes_made+1)); else missing+=("$key"); failed=1; fi
      fi
      ;;
    template-registry)
      template_id=$(jq -r .template_id <<<"$payload")
      post=$(jq -r .post_version <<<"$payload")
      if jq -e --arg id "$template_id" --arg ver "$post" '.entries[]? | select(.template_id==$id and .template_version==$ver)' "$KDIR/_scorecards/template-registry.json" >/dev/null 2>&1; then completed+=("$key")
      elif sink_failure_requested "$key"; then missing+=("$key"); failed=1
      else
        template_path=$(jq -r .template_path <<<"$payload")
        description=$(jq -r '.description // empty' <<<"$payload")
        args=(--template-id "$template_id" --template-version "$post" --template-path "$template_path" --kdir "$KDIR")
        [[ -z "$description" ]] || args+=(--description "$description")
        if bash "$SCRIPT_DIR/template-registry-register.sh" "${args[@]}" >/dev/null && jq -e --arg id "$template_id" --arg ver "$post" '.entries[]? | select(.template_id==$id and .template_version==$ver)' "$KDIR/_scorecards/template-registry.json" >/dev/null 2>&1; then completed+=("$key"); writes_made=$((writes_made+1)); else missing+=("$key"); failed=1; fi
      fi
      ;;
    journal-cutoff) : ;;
  esac
done < <(jq -c '.filing.expected_sinks[] | select(.kind != "journal-cutoff")' "$VALIDATED")

journal_state() {
  python3 - "$JOURNAL" "$FILING_ID" <<'PY'
import json,os,sys
path,fid=sys.argv[1:]; matches=[]
if os.path.isfile(path):
 for line in open(path,encoding="utf-8"):
  try: row=json.loads(line)
  except Exception: continue
  if row.get("role")=="evolve" and row.get("context")=="evolve-filing:"+fid: matches.append(row)
print("missing" if not matches else "landed" if len(matches)==1 else "conflict")
PY
}

JOURNAL_KEY="journal:evolve-filing:$FILING_ID"
JOURNAL_STATE=$(journal_state)
if [[ $failed -eq 0 ]]; then
  if [[ "$JOURNAL_STATE" == landed ]]; then completed+=("$JOURNAL_KEY")
  elif [[ "$JOURNAL_STATE" == conflict ]] || sink_failure_requested "$JOURNAL_KEY"; then missing+=("$JOURNAL_KEY"); failed=1
  else
    OBSERVATION=$(jq -c '.filing as $f | {queue_id:$f.queue_id,filing_id:$f.filing_id,run_id:$f.run_id,counts:{decisions:($f.decisions|length),cluster_dispositions:($f.cluster_dispositions|length),version_registrations:($f.version_registrations|length)},proposal_ids:[$f.decisions[].item_id],bumps:[$f.version_registrations[]|(.template_id+"@"+.pre_version+".."+.post_version)],cutoff:$f.cutoff.upper}' "$VALIDATED")
    if LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/journal.sh" write --observation "$OBSERVATION" --context "evolve-filing:$FILING_ID" --work-item "$QUEUE_ID" --role evolve --model "$(jq -r .filing.model "$VALIDATED")" >/dev/null && [[ $(journal_state) == landed ]]; then completed+=("$JOURNAL_KEY"); writes_made=$((writes_made+1)); else missing+=("$JOURNAL_KEY"); failed=1; fi
  fi
else
  [[ "$JOURNAL_STATE" == landed ]] && completed+=("$JOURNAL_KEY") || missing+=("$JOURNAL_KEY")
fi

array_json() {
  if [[ $# -eq 0 ]]; then printf '[]'; else printf '%s\n' "$@" | jq -Rsc 'split("\n")[:-1]'; fi
}
COMPLETED_JSON=$(array_json "${completed[@]:-}")
MISSING_JSON=$(array_json "${missing[@]:-}")
QUEUE_JSON=$(jq -nc --arg id "$QUEUE_ID" --arg sha256 "$QUEUE_SHA" --arg path "${QUEUE_FILE#"$KDIR"/}" '{id:$id,sha256:$sha256,path:$path}')
FILING_JSON=$(jq -nc --arg id "$FILING_ID" --arg sha256 "$FILING_SHA" --arg path "${FILING#"$KDIR"/}" '{id:$id,sha256:$sha256,path:$path}')

if [[ $failed -ne 0 ]]; then
  emit_response partial 1 "$QUEUE_JSON" "$FILING_JSON" true false "$COMPLETED_JSON" "$MISSING_JSON" '[]' \
    "$(error_object recoverable_partial "the decision is accepted but sanctioned filing sinks remain incomplete" "repair the named sink and replay this exact queue/manifest pair")"
fi
if [[ "$NEW_AUTHORITY" == true ]]; then STATUS=created
elif [[ $writes_made -gt 0 ]]; then STATUS=recovered
else STATUS=reused
fi
emit_response "$STATUS" 0 "$QUEUE_JSON" "$FILING_JSON" true true "$COMPLETED_JSON" '[]' '[]' null
