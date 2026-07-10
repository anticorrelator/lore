#!/usr/bin/env bash
# retro-file.sh — Accept one explicit retro judgment assignment and recover its
# sanctioned-writer fanout. The verb validates and files judgments; it never
# derives, ranks, repairs, or proposes them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REF=""
PACK_FILE=""
JUDGMENTS_FILE=""
JSON_MODE=0

usage() {
  cat >&2 <<'EOF'
Usage: lore retro file <ref> --pack <json-file> --judgments <json-file> [--json]

Atomically accept one lead-authored v1 judgment assignment, then invoke only
missing sanctioned sinks. Exact replay is idempotent; semantic reassignment is
refused. Terminal scorecard telemetry is written last.
EOF
}

emit_response() {
  local status="$1" exit_code="$2" cycle_id="$3" artifact_json="$4"
  local accepted="$5" complete="$6" completed_json="$7" missing_json="$8" warnings_json="$9" error_json="${10}"
  local result
  result=$(python3 - "$status" "$exit_code" "$cycle_id" "$artifact_json" "$accepted" "$complete" "$completed_json" "$missing_json" "$warnings_json" "$error_json" <<'PY'
import json,sys
(status,exit_code,cycle_id,artifact,accepted,complete,completed,missing,warnings,error)=sys.argv[1:]
print(json.dumps({"schema_version":1,"operation":"file","status":status,"exit_code":int(exit_code),
 "cycle_id":cycle_id or None,"artifact":json.loads(artifact),"judgment_accepted":accepted=="true",
 "filing_complete":complete=="true","completed_sinks":json.loads(completed),"missing_sinks":json.loads(missing),
 "warnings":json.loads(warnings),"error":json.loads(error)},ensure_ascii=False,separators=(",",":")))
PY
)
  if [[ $JSON_MODE -eq 1 ]]; then printf '%s\n' "$result"; else
    python3 - "$result" <<'PY'
import json,sys
r=json.loads(sys.argv[1]); print(f"[retro file] {r['status']}: cycle={r['cycle_id']}")
print(f"Judgment accepted: {str(r['judgment_accepted']).lower()}")
print(f"Filing complete: {str(r['filing_complete']).lower()}")
if r["artifact"]:
 print(f"Artifact: {r['artifact']['path']}"); print(f"Filing-id: {r['artifact']['id']}"); print(f"SHA-256: {r['artifact']['sha256']}")
print("Completed sinks: "+(", ".join(r["completed_sinks"]) or "none"))
print("Missing sinks: "+(", ".join(r["missing_sinks"]) or "none"))
for w in r["warnings"]: print("Warning: "+w)
if r["error"]:
 print("Error: "+r["error"]["message"],file=sys.stderr); print("Repair target: "+r["error"]["repair_target"],file=sys.stderr)
PY
  fi
  exit "$exit_code"
}

error_json() {
  python3 - "$1" "$2" "$3" <<'PY'
import json,sys; print(json.dumps({"code":sys.argv[1],"message":sys.argv[2],"repair_target":sys.argv[3]},ensure_ascii=False))
PY
}

refuse() {
  local code="$1" message="$2" repair="$3" cycle_id="${4:-}"
  emit_response refused 1 "$cycle_id" null false false '[]' '[]' '[]' "$(error_json "$code" "$message" "$repair")"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pack) [[ $# -ge 2 ]] || refuse invalid-arguments "--pack requires a value" "supply the published pack path"; PACK_FILE="$2"; shift 2 ;;
    --judgments) [[ $# -ge 2 ]] || refuse invalid-arguments "--judgments requires a value" "supply the lead-authored manifest path"; JUDGMENTS_FILE="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) refuse invalid-arguments "unknown flag: $1" "use 'lore retro file --help'" ;;
    *) [[ -z "$REF" ]] || refuse invalid-arguments "unexpected extra argument: $1" "pass one cycle reference"; REF="$1"; shift ;;
  esac
done

[[ -n "$REF" ]] || { usage; refuse invalid-arguments "missing required argument: <ref>" "pass a cycle reference"; }
[[ -r "$PACK_FILE" ]] || refuse unreadable-pack "pack file is not readable: $PACK_FILE" "pass the published retro-evidence-pack.json"
[[ -r "$JUDGMENTS_FILE" ]] || refuse unreadable-judgments "judgments file is not readable: $JUDGMENTS_FILE" "pass a complete lead-authored v1 manifest"

set +e
RESOLVED=$(bash "$SCRIPT_DIR/resolve-work-ref.sh" "$REF" --include-archived)
RESOLVE_RC=$?
set -e
[[ $RESOLVE_RC -eq 0 ]] || exit "$RESOLVE_RC"
SLUG=$(printf '%s\n' "$RESOLVED" | sed -n '1p')
ARCHIVED=$(printf '%s\n' "$RESOLVED" | sed -n '2p')
KDIR=$(resolve_knowledge_dir)
if [[ "$ARCHIVED" == true ]]; then ITEM_DIR="$KDIR/_work/_archive/$SLUG"; else ITEM_DIR="$KDIR/_work/$SLUG"; fi
PUBLISHED_PACK="$ITEM_DIR/retro-evidence-pack.json"
FILING="$ITEM_DIR/retro-filing.json"
[[ "$(cd "$(dirname "$PACK_FILE")" && pwd -P)/$(basename "$PACK_FILE")" == "$(cd "$ITEM_DIR" && pwd -P)/retro-evidence-pack.json" ]] || refuse wrong-pack-path "--pack must name this cycle's published retro-evidence-pack.json" "$PUBLISHED_PACK" "$SLUG"

LOCK_DIR="$ITEM_DIR/.retro-file.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then refuse filing-locked "another filing operation owns the cycle lock" "remove $LOCK_DIR only after verifying no file process is active" "$SLUG"; fi
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

VALIDATED="$TMP_DIR/validated.json"
set +e
python3 - "$PACK_FILE" "$JUDGMENTS_FILE" "$VALIDATED" "$SLUG" <<'PY'
import hashlib,json,sys

pack_path,judgments_path,out_path,slug=sys.argv[1:]
def reject(msg): print(msg,file=sys.stderr); raise SystemExit(1)
def canonical(v): return json.dumps(v,ensure_ascii=False,sort_keys=True,separators=(",",":")).encode()
def nonempty(v): return isinstance(v,str) and bool(v.strip())
try: pack=json.load(open(pack_path,encoding="utf-8"))
except Exception as exc: reject(f"invalid pack JSON: {exc}")
try: raw=json.load(open(judgments_path,encoding="utf-8"))
except Exception as exc: reject(f"invalid judgments JSON: {exc}")
if not isinstance(pack,dict) or pack.get("schema_version")!=1: reject("pack schema_version must be integer 1")
if pack.get("cycle",{}).get("slug")!=slug: reject("pack cycle slug does not match resolved cycle")
claimed=pack.get("artifact_sha256"); body={k:v for k,v in pack.items() if k!="artifact_sha256"}
if not nonempty(claimed) or hashlib.sha256(canonical(body)).hexdigest()!=claimed: reject("pack artifact_sha256 verification failed")

ROOT={"schema_version","cycle_id","pack_id","pack_sha256","actor","model","key_finding","most_actionable_gap",
      "dimension_judgments","behavioral_health","causal_diagnoses","escalation_judgment","scale_access_judgment",
      "channel_flags","suggestion_outcome","suggestions"}
if not isinstance(raw,dict) or set(raw)!=ROOT: reject("judgment manifest must declare exactly the v1 root fields")
if raw.get("schema_version")!=1: reject("judgment schema_version must be integer 1")
if raw.get("cycle_id")!=slug: reject("judgment cycle_id does not match resolved cycle")
if raw.get("pack_id")!=pack.get("pack_id"): reject("judgment pack_id does not match the accepted pack")
if raw.get("pack_sha256")!=claimed: reject("judgment pack_sha256 must equal the pack artifact_sha256")
for name in ("actor","model","key_finding","most_actionable_gap"):
 if not nonempty(raw.get(name)): reject(f"{name} must be non-empty prose")

sources={r.get("source_id") for r in pack.get("source_manifest",[]) if isinstance(r,dict)}
calcs={r.get("calculation_id") for r in pack.get("calculations",[]) if isinstance(r,dict)}
def pointer_exists(pointer):
 if pointer=="": return True
 if not pointer.startswith("/"): return False
 cur=pack
 for token in pointer[1:].split("/"):
  token=token.replace("~1","/").replace("~0","~")
  try: cur=cur[int(token)] if isinstance(cur,list) else cur[token]
  except (KeyError,IndexError,ValueError,TypeError): return False
 return True
def validate_refs(refs,where):
 if not isinstance(refs,list) or not refs: reject(f"{where}.evidence_refs must be a non-empty array")
 for ref in refs:
  if not nonempty(ref): reject(f"{where}.evidence_refs contains an empty reference")
  if ref.startswith("source:") and ref[7:] in sources: continue
  if ref.startswith("calculation:") and ref[12:] in calcs: continue
  if ref.startswith("pack:") and pointer_exists(ref[5:]): continue
  reject(f"{where}.evidence_refs does not resolve: {ref}")

dims=raw.get("dimension_judgments")
if not isinstance(dims,list) or len(dims)!=5: reject("dimension_judgments must contain exactly D1-D5")
if [d.get("dimension_id") for d in dims if isinstance(d,dict)]!=["D1","D2","D3","D4","D5"]: reject("dimension_judgments must be ordered exactly D1-D5")
for i,d in enumerate(dims):
 if not isinstance(d,dict) or set(d)!={"dimension_id","score","rationale","evidence_refs"}: reject(f"dimension_judgments[{i}] has invalid fields")
 if type(d.get("score")) is not int or not 1<=d["score"]<=5: reject(f"dimension_judgments[{i}].score must be integer 1..5")
 if not nonempty(d.get("rationale")): reject(f"dimension_judgments[{i}].rationale must be non-empty")
 validate_refs(d.get("evidence_refs"),f"dimension_judgments[{i}]")

behavior=raw.get("behavioral_health")
if not isinstance(behavior,list) or not behavior: reject("behavioral_health must be a non-empty ordered array")
seen_checks=[]
for i,row in enumerate(behavior):
 if not isinstance(row,dict) or set(row)!={"check_id","answer","evidence_refs"}: reject(f"behavioral_health[{i}] has invalid fields")
 cid=str(row.get("check_id")); seen_checks.append(cid)
 if not nonempty(row.get("answer")): reject(f"behavioral_health[{i}].answer must be non-empty")
 validate_refs(row.get("evidence_refs"),f"behavioral_health[{i}]")
if not any(c in {"7","C7","Check 7"} for c in seen_checks): reject("behavioral_health must include Check 7")

diagnoses=raw.get("causal_diagnoses")
if not isinstance(diagnoses,list): reject("causal_diagnoses must be an array")
for i,row in enumerate(diagnoses):
 if not isinstance(row,dict) or set(row)!={"diagnosis_id","interpretation","evidence_refs"}: reject(f"causal_diagnoses[{i}] has invalid fields")
 if not nonempty(row.get("diagnosis_id")) or not nonempty(row.get("interpretation")): reject(f"causal_diagnoses[{i}] strings must be non-empty")
 validate_refs(row.get("evidence_refs"),f"causal_diagnoses[{i}]")

def conditional(name,validator):
 row=raw.get(name)
 if not isinstance(row,dict) or row.get("applicability") not in {"applicable","not-applicable"}: reject(f"{name}.applicability is invalid")
 if row["applicability"]=="not-applicable":
  if set(row)!={"applicability","reason"} or not nonempty(row.get("reason")): reject(f"{name} not-applicable requires exactly a non-empty reason")
  return
 if set(row)!={"applicability","value"}: reject(f"{name} applicable requires exactly value")
 validator(row.get("value"),name+".value")
def escalation(value,where):
 if not isinstance(value,dict) or set(value)!={"observation","evidence_refs"} or not nonempty(value.get("observation")): reject(f"{where} has invalid fields")
 validate_refs(value.get("evidence_refs"),where)
def scale(value,where):
 keys={"abstraction_grade","abstraction_rationale","counterfactual_better","counterfactual_rationale","evidence_refs"}
 if not isinstance(value,dict) or set(value)!=keys: reject(f"{where} has invalid fields")
 if value.get("abstraction_grade") not in {"right-sized","too-coarse","too-fine"}: reject(f"{where}.abstraction_grade is invalid")
 if value.get("counterfactual_better") not in {"better","same","worse"}: reject(f"{where}.counterfactual_better is invalid")
 if not nonempty(value.get("abstraction_rationale")) or not nonempty(value.get("counterfactual_rationale")): reject(f"{where} rationales must be non-empty")
 validate_refs(value.get("evidence_refs"),where)
def channels(value,where):
 if not isinstance(value,list): reject(f"{where} must be an array")
 keys={"role","slot","signal_type","rate","window_cycles","remedy_hint","evidence_refs"}
 seen=set()
 for i,row in enumerate(value):
  if not isinstance(row,dict) or set(row)!=keys: reject(f"{where}[{i}] has invalid fields")
  key=(row.get("role"),row.get("slot"),row.get("signal_type"))
  if key in seen: reject(f"{where} has duplicate natural key")
  seen.add(key)
  if not all(nonempty(x) for x in key): reject(f"{where}[{i}] natural-key fields must be non-empty")
  if row.get("signal_type") not in {"under_routing","over_capture","evidence_only_durable"}: reject(f"{where}[{i}].signal_type is invalid")
  if type(row.get("rate")) not in {int,float} or isinstance(row.get("rate"),bool) or not 0<=row["rate"]<=1: reject(f"{where}[{i}].rate must be 0..1")
  if type(row.get("window_cycles")) is not int or row["window_cycles"]<1: reject(f"{where}[{i}].window_cycles must be positive")
  if row.get("remedy_hint") is not None and not nonempty(row.get("remedy_hint")): reject(f"{where}[{i}].remedy_hint must be null or non-empty")
  validate_refs(row.get("evidence_refs"),f"{where}[{i}]")
conditional("escalation_judgment",escalation); conditional("scale_access_judgment",scale); conditional("channel_flags",channels)

outcome=raw.get("suggestion_outcome"); suggestions=raw.get("suggestions")
if outcome not in {"substantive","no-substantive-suggestion"}: reject("suggestion_outcome is invalid")
if not isinstance(suggestions,list): reject("suggestions must be an array")
if outcome=="substantive" and not suggestions: reject("substantive requires at least one suggestion")
if outcome=="no-substantive-suggestion" and suggestions: reject("no-substantive-suggestion requires suggestions=[]")
skeys={"target","change_type","section","suggestion","evidence","evidence_refs"}
for i,row in enumerate(suggestions):
 if not isinstance(row,dict) or set(row)!=skeys or not all(nonempty(row.get(k)) for k in skeys-{"evidence_refs"}): reject(f"suggestions[{i}] has invalid fields")
 validate_refs(row.get("evidence_refs"),f"suggestions[{i}]")

semantic={k:raw[k] for k in sorted(raw)}
filing_id=hashlib.sha256(canonical({"schema_version":1,"cycle_id":slug,"pack_id":pack["pack_id"],"pack_sha256":claimed,"judgments":semantic})).hexdigest()
artifact={"schema_version":1,"filing_id":filing_id,"cycle_id":slug,"pack_id":pack["pack_id"],"pack_sha256":claimed,"judgments":semantic}
artifact["artifact_sha256"]=hashlib.sha256(canonical(artifact)).hexdigest()
text=canonical(artifact)
with open(out_path,"w",encoding="utf-8") as f: json.dump({"artifact":artifact,"text":text.decode(),"file_sha256":hashlib.sha256(text).hexdigest()},f,ensure_ascii=False)
PY
VALIDATE_RC=$?
set -e
[[ $VALIDATE_RC -eq 0 ]] || refuse invalid-judgments "pack or lead-authored judgment validation failed" "use the diagnostic above to correct the v1 manifest before retrying" "$SLUG"

FILING_ID=$(jq -r '.artifact.filing_id' "$VALIDATED")
FILING_ARTIFACT_HASH=$(jq -r '.artifact.artifact_sha256' "$VALIDATED")
FILING_FILE_HASH=$(jq -r '.file_sha256' "$VALIDATED")
NEW_ASSIGNMENT=1
if [[ -f "$FILING" ]]; then
  set +e
  CURRENT=$(python3 - "$FILING" <<'PY'
import hashlib,json,sys
try:
 data=open(sys.argv[1],"rb").read(); obj=json.loads(data); claimed=obj.pop("artifact_sha256")
 assert obj.get("schema_version")==1 and claimed==hashlib.sha256(json.dumps(obj,ensure_ascii=False,sort_keys=True,separators=(",",":")).encode()).hexdigest()
 print(json.dumps({"filing_id":obj.get("filing_id"),"artifact_sha256":claimed,"file_sha256":hashlib.sha256(data).hexdigest()}))
except Exception as exc: print(str(exc),file=sys.stderr); raise SystemExit(1)
PY
  )
  CURRENT_RC=$?
  set -e
  [[ $CURRENT_RC -eq 0 ]] || refuse corrupt-filing "existing retro-filing.json is malformed or fails its self-hash" "repair $FILING before retrying" "$SLUG"
  [[ "$(jq -r .filing_id <<<"$CURRENT")" == "$FILING_ID" ]] || refuse filing-collision "this cycle already has a different accepted judgment assignment" "retain the existing immutable filing or design an explicit supersession lifecycle" "$SLUG"
  NEW_ASSIGNMENT=0
else
  PUBLISH_TMP=$(mktemp "$ITEM_DIR/.retro-filing.XXXXXX")
  jq -r .text "$VALIDATED" | tr -d '\n' > "$PUBLISH_TMP"
  mv "$PUBLISH_TMP" "$FILING"
fi

JOURNAL="$KDIR/_meta/effectiveness-journal.jsonl"
SCALE_SIDECAR="$KDIR/_scorecards/retro-scale-access.jsonl"
CHANNEL_SIDECAR="$KDIR/_scorecards/retro-channel-flags.jsonl"
ROWS="$KDIR/_scorecards/rows.jsonl"

has_journal_sink() {
  local role="$1" sink="$2"
  python3 - "$JOURNAL" "$role" "$SLUG" "$FILING_ID" "$sink" <<'PY'
import json,os,sys
p,role,slug,fid,sink=sys.argv[1:]
matches=[]
if os.path.isfile(p):
 for line in open(p,encoding="utf-8"):
  try: r=json.loads(line)
  except Exception: continue
  if r.get("role")==role and r.get("work_item")==slug and f"filing_id={fid}" in r.get("context","") and f"sink={sink}" in r.get("context",""): matches.append(r)
raise SystemExit(0 if len(matches)==1 else 1)
PY
}

write_journal_sink() {
  local role="$1" sink="$2" observation="$3" scores="${4:-}"
  if [[ "${LORE_RETRO_FILE_FAIL_SINK:-}" == "$sink" ]]; then return 97; fi
  local args=(write --observation "$observation" --context "$role: $SLUG | filing_id=$FILING_ID | sink=$sink" --work-item "$SLUG" --role "$role" --model "$(jq -r '.artifact.judgments.model' "$VALIDATED")")
  [[ -z "$scores" ]] || args+=(--scores "$scores")
  LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/journal.sh" "${args[@]}" >/dev/null
}

completed=(); missing=(); failed=0; WRITES_MADE=0
land_or_write_journal() {
  local role="$1" sink="$2" observation="$3" scores="${4:-}"
  if has_journal_sink "$role" "$sink"; then completed+=("$sink"); return; fi
  if write_journal_sink "$role" "$sink" "$observation" "$scores" && has_journal_sink "$role" "$sink"; then completed+=("$sink"); WRITES_MADE=$((WRITES_MADE+1)); else missing+=("$sink"); failed=1; fi
}

PRIMARY_OBS=$(jq -c '.artifact.judgments | {key_finding,most_actionable_gap,causal_diagnoses}' "$VALIDATED")
PRIMARY_SCORES=$(jq -c '[.artifact.judgments.dimension_judgments[]] | {d1_delivery:.[0].score,d2_quality:.[1].score,d3_gaps:.[2].score,d4_alignment:.[3].score,d5_spec_utility:.[4].score}' "$VALIDATED")
land_or_write_journal retro journal:retro "$PRIMARY_OBS" "$PRIMARY_SCORES"

BEHAVIOR_OBS=$(jq -c '.artifact.judgments.behavioral_health' "$VALIDATED")
land_or_write_journal retro-behavioral-health journal:behavioral "$BEHAVIOR_OBS"

ESC_APP=$(jq -r '.artifact.judgments.escalation_judgment.applicability' "$VALIDATED")
if [[ "$ESC_APP" == applicable ]]; then
  ESC_OBS=$(jq -r '.artifact.judgments.escalation_judgment.value.observation' "$VALIDATED")
  land_or_write_journal retro-escalations journal:escalation "$ESC_OBS"
fi

SUGGESTION_COUNT=$(jq '.artifact.judgments.suggestions | length' "$VALIDATED")
if [[ "$SUGGESTION_COUNT" -gt 0 ]]; then
  i=0
  while [[ $i -lt "$SUGGESTION_COUNT" ]]; do
    ordinal=$((i+1)); sink="journal:suggestion:$ordinal"
    SUGGESTION_OBS=$(jq -r --argjson i "$i" '.artifact.judgments.suggestions[$i] | "Target: \(.target) | Change type: \(.change_type) | Section: \(.section) | Suggestion: \(.suggestion) | Evidence: \(.evidence)"' "$VALIDATED")
    land_or_write_journal retro-evolution "$sink" "$SUGGESTION_OBS"
    i=$((i+1))
  done
fi

SCALE_APP=$(jq -r '.artifact.judgments.scale_access_judgment.applicability' "$VALIDATED")
if [[ "$SCALE_APP" == applicable ]]; then
  SCALE_VALUE=$(jq -c '.artifact.judgments.scale_access_judgment.value' "$VALIDATED")
  set +e
  SCALE_STATE=$(python3 - "$SCALE_SIDECAR" "$SLUG" "$SCALE_VALUE" <<'PY'
import json,os,sys
p,slug,want_raw=sys.argv[1:]; want=json.loads(want_raw); rows=[]
if os.path.isfile(p):
 for line in open(p,encoding="utf-8"):
  try:r=json.loads(line)
  except Exception:continue
  if r.get("cycle_id")==slug:rows.append(r)
keys=("abstraction_grade","abstraction_rationale","counterfactual_better","counterfactual_rationale")
if not rows: print("missing"); raise SystemExit(0)
if len(rows)==1 and all(rows[0].get(k)==want.get(k) for k in keys): print("landed"); raise SystemExit(0)
print("collision"); raise SystemExit(0)
PY
  )
  set -e
  if [[ "$SCALE_STATE" == landed ]]; then completed+=(scale-access)
  elif [[ "$SCALE_STATE" == collision ]]; then missing+=(scale-access); failed=1
  elif [[ "${LORE_RETRO_FILE_FAIL_SINK:-}" == scale-access ]]; then missing+=(scale-access); failed=1
  else
    set +e
    LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/retro-scale-access-append.sh" --kdir "$KDIR" --cycle-id "$SLUG" \
      --abstraction-grade "$(jq -r .abstraction_grade <<<"$SCALE_VALUE")" --abstraction-rationale "$(jq -r .abstraction_rationale <<<"$SCALE_VALUE")" \
      --counterfactual-better "$(jq -r .counterfactual_better <<<"$SCALE_VALUE")" --counterfactual-rationale "$(jq -r .counterfactual_rationale <<<"$SCALE_VALUE")" >/dev/null
    rc=$?; set -e
    if [[ $rc -eq 0 ]]; then completed+=(scale-access); WRITES_MADE=$((WRITES_MADE+1)); else missing+=(scale-access); failed=1; fi
  fi
fi

CHANNEL_APP=$(jq -r '.artifact.judgments.channel_flags.applicability' "$VALIDATED")
if [[ "$CHANNEL_APP" == applicable ]]; then
  CHANNEL_COUNT=$(jq '.artifact.judgments.channel_flags.value | length' "$VALIDATED")
  i=0
  while [[ $i -lt "$CHANNEL_COUNT" ]]; do
    flag=$(jq -c --argjson i "$i" '.artifact.judgments.channel_flags.value[$i]' "$VALIDATED")
    role=$(jq -r .role <<<"$flag"); slot=$(jq -r .slot <<<"$flag"); signal=$(jq -r .signal_type <<<"$flag")
    sink="channel:$role:$slot:$signal"
    state=$(python3 - "$CHANNEL_SIDECAR" "$SLUG" "$flag" <<'PY'
import json,os,sys
p,slug,want_raw=sys.argv[1:]; want=json.loads(want_raw); rows=[]
if os.path.isfile(p):
 for line in open(p,encoding="utf-8"):
  try:r=json.loads(line)
  except Exception:continue
  if (r.get("cycle_id"),r.get("role"),r.get("slot"),r.get("signal_type"))==(slug,want.get("role"),want.get("slot"),want.get("signal_type")):rows.append(r)
keys=("role","slot","signal_type","rate","window_cycles","remedy_hint")
print("missing" if not rows else "landed" if len(rows)==1 and all(rows[0].get(k)==want.get(k) for k in keys) else "collision")
PY
)
    if [[ "$state" == landed ]]; then completed+=("$sink")
    elif [[ "$state" == collision || "${LORE_RETRO_FILE_FAIL_SINK:-}" == "$sink" ]]; then missing+=("$sink"); failed=1
    else
      args=(--kdir "$KDIR" --cycle-id "$SLUG" --role "$role" --slot "$slot" --signal-type "$signal" --rate "$(jq -r .rate <<<"$flag")" --window-cycles "$(jq -r .window_cycles <<<"$flag")")
      remedy=$(jq -r '.remedy_hint // empty' <<<"$flag"); [[ -z "$remedy" ]] || args+=(--remedy-hint "$remedy")
      set +e; LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/retro-channel-flag-append.sh" "${args[@]}" >/dev/null; rc=$?; set -e
      if [[ $rc -eq 0 ]]; then completed+=("$sink"); WRITES_MADE=$((WRITES_MADE+1)); else missing+=("$sink"); failed=1; fi
    fi
    i=$((i+1))
  done
fi

# The completion marker is deliberately last. A prior sink failure cannot be
# hidden behind terminal telemetry, and recovery scans exact keys before retry.
TELEMETRY_SINK=scorecard:retro-filing
telemetry_landed() {
  python3 - "$ROWS" "$FILING_ID" <<'PY'
import json,os,sys
p,fid=sys.argv[1:]; n=0
if os.path.isfile(p):
 for line in open(p,encoding="utf-8"):
  try:r=json.loads(line)
  except Exception:continue
  if r.get("kind")=="telemetry" and r.get("event_type")=="retro-filing" and r.get("filing_id")==fid:n+=1
raise SystemExit(0 if n==1 else 1)
PY
}
if [[ $failed -eq 0 ]]; then
  if telemetry_landed; then completed+=("$TELEMETRY_SINK")
  elif [[ "${LORE_RETRO_FILE_FAIL_SINK:-}" == "$TELEMETRY_SINK" ]]; then missing+=("$TELEMETRY_SINK"); failed=1
  else
    TELEMETRY=$(jq -nc --arg fid "$FILING_ID" --arg slug "$SLUG" --arg pack_id "$(jq -r '.artifact.pack_id' "$VALIDATED")" \
      --arg pack_sha "$(jq -r '.artifact.pack_sha256' "$VALIDATED")" --arg outcome "$(jq -r '.artifact.judgments.suggestion_outcome' "$VALIDATED")" \
      --arg model "$(jq -r '.artifact.judgments.model' "$VALIDATED")" '{schema_version:1,kind:"telemetry",tier:"telemetry",calibration_state:"unknown",event_type:"retro-filing",filing_id:$fid,work_item:$slug,pack_id:$pack_id,pack_sha256:$pack_sha,suggestion_outcome:$outcome,judgment_accepted:true,filing_complete:true,source_artifact_ids:[$slug],model:$model}')
    set +e; printf '%s\n' "$TELEMETRY" | LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KDIR" >/dev/null; rc=$?; set -e
    if [[ $rc -eq 0 ]] && telemetry_landed; then completed+=("$TELEMETRY_SINK"); WRITES_MADE=$((WRITES_MADE+1)); else missing+=("$TELEMETRY_SINK"); failed=1; fi
  fi
else
  telemetry_landed && completed+=("$TELEMETRY_SINK") || missing+=("$TELEMETRY_SINK")
fi

array_json() { printf '%s\n' "$@" | sed '/^$/d' | python3 -c 'import json,sys; print(json.dumps([x.rstrip("\n") for x in sys.stdin]))'; }
COMPLETED_JSON=$(array_json "${completed[@]:-}")
MISSING_JSON=$(array_json "${missing[@]:-}")
REL_FILING="${FILING#"$KDIR"/}"
ARTIFACT_JSON=$(python3 - "$REL_FILING" "$FILING_ID" "$FILING_FILE_HASH" <<'PY'
import json,sys; print(json.dumps({"path":sys.argv[1],"id":sys.argv[2],"sha256":sys.argv[3]}))
PY
)
if [[ $failed -ne 0 ]]; then
  emit_response partial 1 "$SLUG" "$ARTIFACT_JSON" true false "$COMPLETED_JSON" "$MISSING_JSON" '[]' "$(error_json recoverable-partial "the judgment is accepted but one or more sanctioned sinks are missing or collided" "repair the named sink condition and replay this exact filing")"
fi
if [[ $NEW_ASSIGNMENT -eq 1 ]]; then STATUS=created
elif [[ $WRITES_MADE -eq 0 ]]; then STATUS=reused
else STATUS=recovered
fi
emit_response "$STATUS" 0 "$SLUG" "$ARTIFACT_JSON" true true "$COMPLETED_JSON" '[]' '[]' null
