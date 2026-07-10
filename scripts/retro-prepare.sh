#!/usr/bin/env bash
# retro-prepare.sh — Publish the deterministic evidence envelope for one /retro.
#
# This verb resolves sources, records their coverage, and computes only fixed
# arithmetic. It never chooses a window, interprets a cause, scores D1-D5,
# answers behavioral checks, selects a suggestion, or decides graduation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REF=""
WINDOW_START=""
WINDOW_END=""
JSON_MODE=0

usage() {
  cat >&2 <<'EOF'
Usage: lore retro prepare <ref> --window-start <RFC3339> --window-end <RFC3339> [--json]

Publish <cycle>/retro-evidence-pack.json from published readers. Window bounds
are caller-supplied; missing and unreadable evidence is explicit and never green.
EOF
}

emit_response() {
  local status="$1" exit_code="$2" cycle_id="$3" artifact_json="$4"
  local warnings_json="$5" error_json="$6"
  local result
  result=$(python3 - "$status" "$exit_code" "$cycle_id" "$artifact_json" "$warnings_json" "$error_json" <<'PY'
import json, sys
status, exit_code, cycle_id, artifact, warnings, error = sys.argv[1:]
print(json.dumps({
    "schema_version": 1,
    "operation": "prepare",
    "status": status,
    "exit_code": int(exit_code),
    "cycle_id": cycle_id or None,
    "artifact": json.loads(artifact),
    "judgment_accepted": None,
    "filing_complete": None,
    "completed_sinks": [],
    "missing_sinks": [],
    "warnings": json.loads(warnings),
    "error": json.loads(error),
}, ensure_ascii=False, separators=(",", ":")))
PY
)
  if [[ $JSON_MODE -eq 1 ]]; then
    printf '%s\n' "$result"
  else
    python3 - "$result" <<'PY'
import json, sys
r=json.loads(sys.argv[1])
print(f"[retro prepare] {r['status']}: cycle={r['cycle_id']}")
if r["artifact"]:
    a=r["artifact"]
    print(f"Artifact: {a['path']}")
    print(f"Pack-id: {a['id']}")
    print(f"SHA-256: {a['sha256']}")
for warning in r["warnings"]:
    print(f"Warning: {warning}")
if r["error"]:
    print(f"Error: {r['error']['message']}", file=sys.stderr)
    print(f"Repair target: {r['error']['repair_target']}", file=sys.stderr)
PY
  fi
  exit "$exit_code"
}

refuse() {
  local code="$1" message="$2" repair="$3" cycle_id="${4:-}"
  local error
  error=$(python3 - "$code" "$message" "$repair" <<'PY'
import json,sys
print(json.dumps({"code":sys.argv[1],"message":sys.argv[2],"repair_target":sys.argv[3]}, ensure_ascii=False))
PY
)
  emit_response refused 1 "$cycle_id" null '[]' "$error"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --window-start) [[ $# -ge 2 ]] || refuse invalid-arguments "--window-start requires a value" "supply both RFC3339 bounds"; WINDOW_START="$2"; shift 2 ;;
    --window-end) [[ $# -ge 2 ]] || refuse invalid-arguments "--window-end requires a value" "supply both RFC3339 bounds"; WINDOW_END="$2"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) refuse invalid-arguments "unknown flag: $1" "use 'lore retro prepare --help'" ;;
    *) [[ -z "$REF" ]] || refuse invalid-arguments "unexpected extra argument: $1" "pass one work-item reference"; REF="$1"; shift ;;
  esac
done

[[ -n "$REF" ]] || { usage; refuse invalid-arguments "missing required argument: <ref>" "pass a cycle reference"; }
[[ -n "$WINDOW_START" && -n "$WINDOW_END" ]] || refuse invalid-window "both --window-start and --window-end are required" "supply explicit RFC3339 bounds"

set +e
WINDOW_JSON=$(python3 - "$WINDOW_START" "$WINDOW_END" <<'PY'
import json,sys
from datetime import datetime,timezone
def parse(raw):
    if not isinstance(raw,str) or not raw.strip(): raise ValueError("empty boundary")
    value=raw[:-1]+"+00:00" if raw.endswith("Z") else raw
    dt=datetime.fromisoformat(value)
    if dt.tzinfo is None: raise ValueError("timezone is required")
    return dt.astimezone(timezone.utc)
start,end=map(parse,sys.argv[1:3])
if start >= end: raise ValueError("window start must be earlier than window end")
fmt=lambda dt: dt.isoformat(timespec="seconds").replace("+00:00","Z")
print(json.dumps({"start":fmt(start),"end":fmt(end),"basis":"caller-supplied","timezone":"UTC"}))
PY
)
WINDOW_RC=$?
set -e
[[ $WINDOW_RC -eq 0 ]] || refuse invalid-window "window bounds must be ordered RFC3339 timestamps with timezones" "correct --window-start/--window-end"

set +e
RESOLVED=$(bash "$SCRIPT_DIR/resolve-work-ref.sh" "$REF" --include-archived)
RESOLVE_RC=$?
set -e
[[ $RESOLVE_RC -eq 0 ]] || exit "$RESOLVE_RC"
SLUG=$(printf '%s\n' "$RESOLVED" | sed -n '1p')
ARCHIVED=$(printf '%s\n' "$RESOLVED" | sed -n '2p')
KDIR=$(resolve_knowledge_dir)
if [[ "$ARCHIVED" == true ]]; then
  ITEM_DIR="$KDIR/_work/_archive/$SLUG"
else
  ITEM_DIR="$KDIR/_work/$SLUG"
fi
ARTIFACT="$ITEM_DIR/retro-evidence-pack.json"
FILING="$ITEM_DIR/retro-filing.json"
LOG_FILE="$ITEM_DIR/execution-log.md"

LOCK_DIR="$ITEM_DIR/.retro-prepare.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  refuse prepare-locked "another prepare operation owns the cycle lock" "remove $LOCK_DIR only after verifying no prepare process is active" "$SLUG"
fi
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

WARNINGS_FILE="$TMP_DIR/warnings.jsonl"
: > "$WARNINGS_FILE"
warn() { printf '%s\n' "$1" >&2; python3 - "$1" >> "$WARNINGS_FILE" <<'PY'
import json,sys; print(json.dumps(sys.argv[1]))
PY
}

# DUE handling is observability, not a pack precondition. Capture the published
# fold after the attempt so the manifest describes the state used by the pack.
DUE_DISPOSITION="absent"
DUE_WARNING=""
set +e
DUE_BEFORE=$(LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/retro-queue.sh" queue --cycle-id "$SLUG" --json 2>"$TMP_DIR/due-before.err")
DUE_READ_RC=$?
set -e
if [[ $DUE_READ_RC -eq 0 ]]; then
  DUE_IDS=$(printf '%s' "$DUE_BEFORE" | jq -r '.unhandled_due[].outcome_id' 2>/dev/null || true)
  if [[ -n "$DUE_IDS" ]]; then
    set +e
    LORE_KNOWLEDGE_DIR="$KDIR" bash "$SCRIPT_DIR/retro-queue.sh" handle --cycle-id "$SLUG" \
      --action dispatched --handled-by retro-lead --json >"$TMP_DIR/due-handle.out" 2>"$TMP_DIR/due-handle.err"
    DUE_HANDLE_RC=$?
    set -e
    if [[ $DUE_HANDLE_RC -eq 0 ]]; then DUE_DISPOSITION="handled"; else
      DUE_DISPOSITION="failed"
      DUE_WARNING="best-effort DUE claim failed"
      warn "$DUE_WARNING"
    fi
  else
    DUE_DISPOSITION="absent"
  fi
else
  DUE_DISPOSITION="failed"
  DUE_WARNING="DUE queue reader failed"
  warn "$DUE_WARNING"
fi

run_reader() {
  local source_id="$1"; shift
  set +e
  LORE_KNOWLEDGE_DIR="$KDIR" "$@" >"$TMP_DIR/$source_id.out" 2>"$TMP_DIR/$source_id.err"
  local rc=$?
  set -e
  printf '%s\n' "$rc" >"$TMP_DIR/$source_id.rc"
}

run_reader cycle_work bash "$SCRIPT_DIR/load-work-item.sh" --json "$SLUG"
run_reader due_queue bash "$SCRIPT_DIR/retro-queue.sh" queue --cycle-id "$SLUG" --json
run_reader settlement bash "$SCRIPT_DIR/settlement-queue.sh" status --kdir "$KDIR" --json
run_reader scorecard_rows "$LORE_REPO_DIR/cli/lore" scorecard rows
run_reader scorecard_current "$LORE_REPO_DIR/cli/lore" scorecard current
run_reader session_events bash "$SCRIPT_DIR/session-events.sh" --since 0 --kdir "$KDIR" --json
run_reader journal "$LORE_REPO_DIR/cli/lore" journal read \
  --since "$(printf '%s' "$WINDOW_JSON" | jq -r .start)" \
  --until "$(printf '%s' "$WINDOW_JSON" | jq -r .end)" --json

# The consumer lifecycle has no sanctioned public reader in v1. Its row is
# generated inside the pack builder and no private file is touched here.
PREPARED="$TMP_DIR/prepared.json"
set +e
python3 - "$TMP_DIR" "$PREPARED" "$SLUG" "$ARCHIVED" "$WINDOW_JSON" "$DUE_DISPOSITION" "$DUE_WARNING" <<'PY'
import hashlib,json,os,sys
from datetime import datetime,timezone

tmp,out_path,slug,archived_raw,window_raw,due_disposition,due_warning=sys.argv[1:]
window=json.loads(window_raw); archived=archived_raw=="true"

SOURCE_REGISTRY=[
 ("cycle_work","lore work show --json",f"_work/{'_archive/' if archived else ''}{slug}"),
 ("due_queue","lore retro queue --json","_scorecards/retro-deferred-queue.jsonl"),
 ("settlement","lore settlement status --json","_settlement"),
 ("scorecard_rows","lore scorecard rows","_scorecards/rows.jsonl"),
 ("scorecard_current","lore scorecard current","_scorecards/_current.json"),
 ("session_events","lore session events --json","_sessions/events.jsonl"),
 ("journal",f"lore journal read --since {window['start']} --until {window['end']} --json","_meta/effectiveness-journal.jsonl"),
 ("consumer_contradiction_lifecycle",None,None),
]
FACT_REGISTRY={
 "cycle_artifacts":["cycle_work"],
 "task_context_backlinks":["cycle_work"],
 "concerns_contradictions":["cycle_work","consumer_contradiction_lifecycle"],
 "session_retrieval_friction_packets":["session_events","journal"],
 "review_events":["session_events","journal"],
 "scale_signals":["session_events","journal"],
 "scorecard_eligibility_deltas":["scorecard_rows","scorecard_current","journal"],
 "telemetry_attribution_rework":["scorecard_rows","cycle_work"],
 "settlement_health_inputs":["settlement","consumer_contradiction_lifecycle"],
}
CALC_REGISTRY=[
 "channel_contract_drift","scorecard_delta_readiness","template_headline_readiness",
 "audit_lag","audit_realization","trigger_realization","grounding_failure_rate",
 "candidate_queue_backlog","judge_liveness","consumer_contradiction_routing",
]

def canonical(value):
 return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(",",":")).encode()
def load_reader(source_id):
 if source_id=="consumer_contradiction_lifecycle":
  return None,{"coverage":"not-computable","warnings":[],"reason":"no-published-reader","cursor":None}
 rc_path=os.path.join(tmp,source_id+".rc")
 rc=int(open(rc_path).read().strip()) if os.path.exists(rc_path) else 1
 data=open(os.path.join(tmp,source_id+".out"),"rb").read() if os.path.exists(os.path.join(tmp,source_id+".out")) else b""
 err=open(os.path.join(tmp,source_id+".err"),encoding="utf-8",errors="replace").read().strip() if os.path.exists(os.path.join(tmp,source_id+".err")) else ""
 if rc!=0:
  reason="source-absent" if any(x in err.lower() for x in ("does not exist","not found","no journal")) else "reader-failed"
  return None,{"coverage":"absent" if reason=="source-absent" else "unreadable","warnings":[err] if err else [],"reason":reason,"cursor":None}
 if source_id=="scorecard_rows" and not data.strip():
  obj=[]
 else:
  try: obj=json.loads(data) if data.strip() else None
  except Exception:
   # rows.jsonl is a published NDJSON stream.
   try: obj=[json.loads(line) for line in data.decode().splitlines() if line.strip()]
   except Exception as exc:
    return None,{"coverage":"unreadable","warnings":[str(exc)],"reason":"invalid-reader-output","cursor":None}
 identity_obj=obj
 if source_id=="cycle_work" and isinstance(obj,dict):
  # The sanctioned work reader includes execution-log.md. Prepare appends its
  # own completion atom there, so hashing the whole reader response would make
  # the source fingerprint recursively invalidate itself. Only fields capable
  # of changing this pack's facts participate in this source identity.
  identity_obj={k:obj.get(k) for k in ("slug","title","status","archived","plan_content","notes_content","has_tasks","extra_files")}
 elif source_id=="settlement" and isinstance(obj,dict):
  # Exclude clock-derived display telemetry such as seconds_since_last. The
  # pack reads only these published state fields.
  dispatch=obj.get("dispatch") or {}
  identity_obj={"queue":obj.get("queue"),"counts":obj.get("counts"),"health":obj.get("health"),
                "batch":obj.get("batch"),"items":obj.get("items"),"terminal_items":obj.get("terminal_items"),
                "dispatch":{"census_enabled":dispatch.get("census_enabled"),"mode":dispatch.get("mode"),
                            "verify_volume":dispatch.get("verify_volume")}}
 return (obj,{"coverage":"read","warnings":[err] if err else [],"reason":None,
              "cursor":obj.get("next_cursor") if isinstance(obj,dict) else None,
              "identity":hashlib.sha256(canonical(identity_obj)).hexdigest()})

objects={}; manifest=[]
for sid,reader,resolved in SOURCE_REGISTRY:
 obj,meta=load_reader(sid); objects[sid]=obj
 manifest.append({"source_id":sid,"reader":reader,"resolved_source":resolved,
  "coverage":meta["coverage"],"content_identity":meta.get("identity"),"cursor":meta.get("cursor"),
  "window_field":"timestamp-or-source-native-window" if sid not in {"cycle_work","scorecard_current"} else None,
  "warnings":meta["warnings"],"reason":meta["reason"]})

def fact(status,source_ids,values=None,reason=None):
 return {"status":status,"source_ids":source_ids,"values":values if status=="available" else None,
         "reason":None if status=="available" else reason}
work=objects.get("cycle_work")
if isinstance(work,dict):
 plan=work.get("plan_content") or ""; notes=work.get("notes_content") or ""; log=work.get("exec_log_content") or ""
 cycle_values={"has_plan":bool(plan),"has_notes":bool(notes),
               "extra_artifact_count":len(work.get("extra_files",[])),"status":work.get("status")}
 task_values={"checked_tasks":plan.count("- [x]"),"unchecked_tasks":plan.count("- [ ]"),
              "knowledge_links":plan.count("[[knowledge:"),"work_links":plan.count("[[work:"),
              "prior_knowledge_mentions":plan.count("Prior Knowledge")}
else: cycle_values=task_values=None
events=objects.get("session_events")
event_rows=events.get("events",[]) if isinstance(events,dict) else []
journal=objects.get("journal") if isinstance(objects.get("journal"),list) else []
rows=objects.get("scorecard_rows") if isinstance(objects.get("scorecard_rows"),list) else []
settlement=objects.get("settlement")
facts={
 "cycle_artifacts":fact("available",FACT_REGISTRY["cycle_artifacts"],cycle_values) if cycle_values is not None else fact("not-computable",FACT_REGISTRY["cycle_artifacts"],reason="cycle-reader-unavailable"),
 "task_context_backlinks":fact("available",FACT_REGISTRY["task_context_backlinks"],task_values) if task_values is not None else fact("not-computable",FACT_REGISTRY["task_context_backlinks"],reason="cycle-reader-unavailable"),
 "concerns_contradictions":fact("not-computable",FACT_REGISTRY["concerns_contradictions"],reason="no-published-reader"),
 "session_retrieval_friction_packets":fact("available",FACT_REGISTRY["session_retrieval_friction_packets"],{"session_events":len(event_rows),"journal_entries":len(journal)}) if isinstance(events,dict) else fact("not-computable",FACT_REGISTRY["session_retrieval_friction_packets"],reason="session-reader-unavailable"),
 "review_events":fact("available",FACT_REGISTRY["review_events"],{"review_like_events":sum(1 for e in event_rows if "review" in str(e.get("event","")).lower())}),
 "scale_signals":fact("available",FACT_REGISTRY["scale_signals"],{"declared_scale_events":sum(1 for e in event_rows if e.get("scale_declared") is True or isinstance(e.get("scale_declared"),str) and e.get("scale_declared"))}),
 "scorecard_eligibility_deltas":fact("available",FACT_REGISTRY["scorecard_eligibility_deltas"],{"rows_total":len(rows),"calibrated_template_rows":sum(1 for r in rows if r.get("kind")=="scored" and r.get("tier")=="template" and r.get("calibration_state")=="calibrated"),"prior_retro_windows":len(journal)}) if isinstance(objects.get("scorecard_rows"),list) else fact("absent",FACT_REGISTRY["scorecard_eligibility_deltas"],reason="scorecard-rows-absent"),
 "telemetry_attribution_rework":fact("available",FACT_REGISTRY["telemetry_attribution_rework"],{"telemetry_rows":sum(1 for r in rows if r.get("kind")=="telemetry" or r.get("tier")=="telemetry"),"correction_rows":sum(1 for r in rows if r.get("tier")=="correction")}) if isinstance(objects.get("scorecard_rows"),list) else fact("absent",FACT_REGISTRY["telemetry_attribution_rework"],reason="scorecard-rows-absent"),
 "settlement_health_inputs":fact("available",FACT_REGISTRY["settlement_health_inputs"],{"queue":settlement.get("queue"),"counts":settlement.get("counts"),"health":settlement.get("health"),"dispatch":settlement.get("dispatch"),"batch":settlement.get("batch")}) if isinstance(settlement,dict) else fact("not-computable",FACT_REGISTRY["settlement_health_inputs"],reason="settlement-reader-unavailable"),
}

def calc(cid,sources,n=None,d=None,value=None,unit="ratio",floor=None,threshold=None,disposition="not-computable",reason=None):
 return {"calculation_id":cid,"calculation_version":"1","source_ids":sources,"numerator":n,"denominator":d,"value":value,"unit":unit,"sample_floor":floor,"threshold":threshold,"disposition":disposition,"reason":reason}
calcs=[]
calcs.append(calc("channel_contract_drift",["cycle_work","journal"],floor=3,threshold=">0.30",reason="published readers do not expose role-slot denominators"))
eligible=facts["scorecard_eligibility_deltas"].get("values") or {}
eligible_n=eligible.get("calibrated_template_rows")
if eligible_n is None: calcs.append(calc("scorecard_delta_readiness",["scorecard_rows","journal"],floor=10,threshold="both-windows-n>=10",reason="scorecard rows unavailable"))
elif eligible_n<10: calcs.append(calc("scorecard_delta_readiness",["scorecard_rows","journal"],n=eligible_n,d=10,value=eligible_n,unit="rows",floor=10,threshold="both-windows-n>=10",disposition="abstained",reason="below-sample"))
else: calcs.append(calc("scorecard_delta_readiness",["scorecard_rows","journal"],n=eligible_n,d=eligible_n,value=eligible_n,unit="rows",floor=10,threshold="both-windows-n>=10",disposition="green",reason=None))
if eligible_n is None: calcs.append(calc("template_headline_readiness",["scorecard_rows"],floor=10,threshold="metric-n>=10",reason="scorecard rows unavailable"))
elif eligible_n<10: calcs.append(calc("template_headline_readiness",["scorecard_rows"],n=eligible_n,d=10,value=eligible_n,unit="rows",floor=10,threshold="metric-n>=10",disposition="abstained",reason="below-sample"))
else: calcs.append(calc("template_headline_readiness",["scorecard_rows"],n=eligible_n,d=eligible_n,value=eligible_n,unit="rows",floor=10,threshold="metric-n>=10",disposition="green",reason=None))
calcs.append(calc("audit_lag",["settlement"],unit="days",threshold="<=7",reason="enqueue time is not reconstructible from the published status reader"))
calcs.append(calc("audit_realization",["settlement"],floor=10,threshold=">=0.50 or >=3 completions below floor",reason="published status omits completed run envelopes"))
calcs.append(calc("trigger_realization",["session_events","settlement"],floor=10,threshold="relative-divergence<=0.50",reason="published readers do not expose configured probability per roll"))
calcs.append(calc("grounding_failure_rate",["settlement","scorecard_rows"],floor=10,threshold=">0.30 or reason-concentration>0.50@failed>=5",reason="source-drift"))
dispatch=(settlement or {}).get("dispatch",{}) if isinstance(settlement,dict) else {}
if dispatch.get("census_enabled") is False:
 calcs.append(calc("candidate_queue_backlog",["settlement"],unit="items",floor=10,threshold="growth>2 or pending-kind>25 or total>50",reason="dormant-census"))
else:
 calcs.append(calc("candidate_queue_backlog",["settlement"],unit="items",floor=10,threshold="growth>2 or pending-kind>25 or total>50",reason="published status lacks trustworthy per-kind window transitions"))
calcs.append(calc("judge_liveness",["settlement"],floor=5,threshold="unverified>0.80 or silence>0.90 or zero-runs-with-routing",reason="published status omits per-gate completed run envelopes"))
calcs.append(calc("consumer_contradiction_routing",["consumer_contradiction_lifecycle"],floor=10,threshold="verdicts/produced<0.10",reason="no-published-reader"))

load_bearing={"audit_lag","audit_realization","grounding_failure_rate","candidate_queue_backlog","judge_liveness","consumer_contradiction_routing"}
selected=[c for c in calcs if c["calculation_id"] in load_bearing]
if any(c["disposition"]=="not-computable" for c in selected): state="not-computable"
elif any(c["disposition"]=="tripped" for c in selected): state="pipeline-degraded"
elif any(c["disposition"]=="abstained" for c in selected): state="warmup"
else: state="normal"
fixed_health={"state":state,"calculation_ids":[c["calculation_id"] for c in selected],"tripped_calculation_ids":[c["calculation_id"] for c in selected if c["disposition"]=="tripped"]}

input_fp=hashlib.sha256(canonical({"schema_version":1,"slug":slug,"window":window})).hexdigest()
source_shape=[{k:r[k] for k in ("source_id","reader","resolved_source","coverage","content_identity","cursor","window_field","warnings")} for r in manifest]
source_fp=hashlib.sha256(canonical({"sources":source_shape,"calculations":[{"calculation_id":c,"calculation_version":"1"} for c in CALC_REGISTRY]})).hexdigest()
pack_id=hashlib.sha256(canonical({"input_fingerprint":input_fp,"source_fingerprint":source_fp})).hexdigest()
work_title=work.get("title","") if isinstance(work,dict) else ""
pack={"schema_version":1,"pack_id":pack_id,"input_fingerprint":input_fp,"source_fingerprint":source_fp,"artifact_sha256":None,
 "cycle":{"slug":slug,"title":work_title,"archived":archived,"cycle_type":None},"window":window,
 "due_claim":{"attempted":due_disposition!="absent","outcome_ids":[],"disposition":due_disposition,"warning":due_warning or None},
 "source_manifest":manifest,"facts":facts,"calculations":calcs,"fixed_health":fixed_health,
 "provenance":{"producer":"retro-prepare.sh","schema_version":1,"captured_at":window["end"],"judgment_boundary":"deterministic-facts-only"}}
pack["artifact_sha256"]=hashlib.sha256(canonical({k:v for k,v in pack.items() if k!="artifact_sha256"})).hexdigest()
text=canonical(pack)
with open(out_path,"w",encoding="utf-8") as f: json.dump({"pack":pack,"text":text.decode(),"sha256":hashlib.sha256(text).hexdigest()},f,ensure_ascii=False)
PY
BUILD_RC=$?
set -e
[[ $BUILD_RC -eq 0 ]] || refuse pack-build-failed "published reader output could not be normalized into pack v1" "inspect reader diagnostics and retry" "$SLUG"

NEW_ID=$(jq -r '.pack.pack_id' "$PREPARED")
NEW_ARTIFACT_HASH=$(jq -r '.pack.artifact_sha256' "$PREPARED")
NEW_FILE_HASH=$(jq -r '.sha256' "$PREPARED")
LATEST_ATOM=$(python3 - "$LOG_FILE" <<'PY'
import json,re,sys
try: text=open(sys.argv[1],encoding="utf-8").read()
except FileNotFoundError: text=""
latest=None
for match in re.finditer(r"(?m)^Retro-prepare-atom: (\{.*\})$",text):
 try: latest=json.loads(match.group(1))
 except Exception: pass
print(json.dumps(latest))
PY
)

STATUS="created"; NEED_PUBLISH=1; NEED_MARKER=1
if [[ -f "$ARTIFACT" ]]; then
  set +e
  CURRENT=$(python3 - "$ARTIFACT" <<'PY'
import hashlib,json,sys
try:
 data=open(sys.argv[1],"rb").read(); obj=json.loads(data)
 claimed=obj.get("artifact_sha256"); body={k:v for k,v in obj.items() if k!="artifact_sha256"}
 recomputed=hashlib.sha256(json.dumps(body,ensure_ascii=False,sort_keys=True,separators=(",",":")).encode()).hexdigest()
 assert obj.get("schema_version")==1 and claimed==recomputed
 print(json.dumps({"pack_id":obj.get("pack_id"),"artifact_sha256":claimed,"file_sha256":hashlib.sha256(data).hexdigest()}))
except Exception as exc: print(str(exc),file=sys.stderr); raise SystemExit(1)
PY
  )
  CURRENT_RC=$?
  set -e
  [[ $CURRENT_RC -eq 0 ]] || refuse corrupt-pack "existing retro-evidence-pack.json is malformed or fails its self-hash" "repair or remove $ARTIFACT after review" "$SLUG"
  CURRENT_FILE_HASH=$(jq -r .file_sha256 <<<"$CURRENT")
  if [[ "$LATEST_ATOM" != null ]]; then
    ATOM_HASH=$(jq -r '.artifact_file_sha256 // empty' <<<"$LATEST_ATOM")
    [[ "$ATOM_HASH" == "$CURRENT_FILE_HASH" ]] || refuse marker-collision "pack bytes contradict the latest completion marker" "restore the marked artifact or repair the marker/artifact pair" "$SLUG"
  fi
  if [[ "$(jq -r .pack_id <<<"$CURRENT")" == "$NEW_ID" && "$(jq -r .artifact_sha256 <<<"$CURRENT")" == "$NEW_ARTIFACT_HASH" ]]; then
    NEED_PUBLISH=0
    if [[ "$LATEST_ATOM" == null ]]; then STATUS="recovered"; else STATUS="reused"; NEED_MARKER=0; fi
  else
    [[ ! -f "$FILING" ]] || refuse accepted-pack-frozen "the accepted filing freezes the current evidence pack" "retain the accepted pack bytes; use a new retro cycle for new judgments" "$SLUG"
    STATUS="replaced"
  fi
elif [[ "$LATEST_ATOM" != null ]]; then
  refuse missing-pack "a prepare completion marker exists but the evidence pack is absent" "restore the artifact named by the marker or repair the stale marker" "$SLUG"
fi

if [[ $NEED_PUBLISH -eq 1 ]]; then
  PUBLISH_TMP=$(mktemp "$ITEM_DIR/.retro-evidence-pack.XXXXXX")
  jq -r .text "$PREPARED" | tr -d '\n' > "$PUBLISH_TMP"
  mv "$PUBLISH_TMP" "$ARTIFACT"
fi

if [[ $NEED_MARKER -eq 1 ]]; then
  ATOM=$(python3 - "$NEW_ID" "$NEW_ARTIFACT_HASH" "$NEW_FILE_HASH" <<'PY'
import json,sys
print(json.dumps({"schema_version":1,"pack_id":sys.argv[1],"artifact_sha256":sys.argv[2],"artifact_file_sha256":sys.argv[3]},separators=(",",":")))
PY
)
  if [[ "$ARCHIVED" == false ]]; then
    printf 'Retro-prepare-atom: %s\n' "$ATOM" | bash "$SCRIPT_DIR/write-execution-log.sh" --slug "$SLUG" --source manual >/dev/null
  else
    warn "archived cycle pack published without an execution-log marker because the sanctioned writer accepts active items only"
  fi
fi

WARNINGS=$(python3 - "$WARNINGS_FILE" <<'PY'
import json,sys
rows=[]
for line in open(sys.argv[1],encoding="utf-8"):
 try: rows.append(json.loads(line))
 except Exception: pass
print(json.dumps(rows))
PY
)
REL_ARTIFACT="${ARTIFACT#"$KDIR"/}"
ARTIFACT_JSON=$(python3 - "$REL_ARTIFACT" "$NEW_ID" "$NEW_FILE_HASH" <<'PY'
import json,sys; print(json.dumps({"path":sys.argv[1],"id":sys.argv[2],"sha256":sys.argv[3]}))
PY
)
emit_response "$STATUS" 0 "$SLUG" "$ARTIFACT_JSON" "$WARNINGS" null
