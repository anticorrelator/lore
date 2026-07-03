#!/usr/bin/env bash
# impl-promote-batch.sh — Mechanically file Tier 3 promotion for lead-selected candidates
# Usage: impl-promote-batch.sh <ref> --candidates <file>
#        [--lead-template-version <hash>] [--worker-template-version <hash>]
#        [--advisor-template-version <hash>] [--template-version <hash>] [--json]
#
# Judgment in, filing out: the candidates file is the lead's already-made
# Tier 3 selection — this script never selects candidates. It performs the
# mechanical Step 5 envelope for each row:
#   1. Source-artifact verification: every id in source_artifact_ids must
#      exist as a claim_id in this work item's task-claims.jsonl (scope is
#      this work item only — cross-work-item references are rejected).
#   2. producer_role -> template-version attribution: worker/advisor/
#      implement-lead map to the corresponding template version; an absent
#      producer_role defaults to implement-lead and the defaulting is noted
#      in the summary log; any other role is rejected (mis-attribution).
#   3. One `lore promote` call per accepted candidate (lore-promote.sh forces
#      confidence=unaudited and validates via validate-tier3.sh); a non-zero
#      exit moves the candidate to the rejected list.
#   4. One summary execution-log entry (via write-execution-log.sh,
#      --source impl-verb), always written — an empty candidate list is valid
#      input and still files the `0 accepted, 0 rejected` summary.
#
# The candidates file is a JSON array of Tier 3 row objects, or JSONL (one
# object per line). Rejections are results, not command failures: the verb
# exits 0 once the batch is processed and the summary is logged.
#
# Role template versions default from the implement skill / worker / advisor
# templates when the flags are omitted; an unresolvable version degrades to a
# stderr warning and the promote runs unstamped.
#
# Exit codes:
#   0  batch processed; accepted/rejected lists on stdout, summary logged
#   1  usage error / unreadable or malformed candidates file / no work-item
#      match / summary log append failure
#   2  ambiguous work-item reference

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REF=""
CANDIDATES_FILE=""
LEAD_TV=""
WORKER_TV=""
ADVISOR_TV=""
TEMPLATE_VERSION=""
JSON_MODE=0
CANDIDATES_SET=0

usage() {
  cat >&2 <<EOF
Usage: lore impl promote-batch <ref> --candidates <file>
                               [--lead-template-version <hash>] [--worker-template-version <hash>]
                               [--advisor-template-version <hash>] [--template-version <hash>] [--json]

Promote the lead-selected Tier 3 candidates in <file> (JSON array or JSONL):
verifies source_artifact_ids against this work item's task-claims.jsonl,
attributes producer_role -> template version, runs one \`lore promote\` per
accepted candidate, and files the summary execution-log entry. Returns the
accepted/rejected lists with reasons; it never selects candidates.

Exit codes: 0 batch processed (rejections are results, not failures),
            1 error/no match, 2 ambiguous reference
EOF
}

fail() {
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$1"
  fi
  echo "[impl] Error: $1" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --candidates)
      CANDIDATES_FILE="${2:-}"
      CANDIDATES_SET=1
      shift 2
      ;;
    --candidates=*)
      CANDIDATES_FILE="${1#--candidates=}"
      CANDIDATES_SET=1
      shift
      ;;
    --lead-template-version)
      LEAD_TV="${2:-}"
      shift 2
      ;;
    --lead-template-version=*)
      LEAD_TV="${1#--lead-template-version=}"
      shift
      ;;
    --worker-template-version)
      WORKER_TV="${2:-}"
      shift 2
      ;;
    --worker-template-version=*)
      WORKER_TV="${1#--worker-template-version=}"
      shift
      ;;
    --advisor-template-version)
      ADVISOR_TV="${2:-}"
      shift 2
      ;;
    --advisor-template-version=*)
      ADVISOR_TV="${1#--advisor-template-version=}"
      shift
      ;;
    --template-version)
      TEMPLATE_VERSION="${2:-}"
      shift 2
      ;;
    --template-version=*)
      TEMPLATE_VERSION="${1#--template-version=}"
      shift
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      fail "Unknown flag: $1"
      ;;
    *)
      if [[ -z "$REF" ]]; then
        REF="$1"
      else
        fail "Unexpected extra argument: $1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$REF" ]]; then
  usage
  fail "Missing required argument: <ref>"
fi

if [[ $CANDIDATES_SET -eq 0 || -z "$CANDIDATES_FILE" ]]; then
  fail "--candidates <file> is required (the lead-selected Tier 3 candidate file; this script never selects candidates)"
fi

if [[ ! -f "$CANDIDATES_FILE" ]]; then
  fail "candidates file not found: $CANDIDATES_FILE"
fi

# --- Resolve the work-item reference (tri-state exit passthrough) ------------
set +e
RESOLVED=$(bash "$SCRIPT_DIR/resolve-work-ref.sh" "$REF")
RESOLVE_RC=$?
set -e
if [[ $RESOLVE_RC -ne 0 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    printf '{"error": "could not resolve work-item reference (exit %s)"}\n' "$RESOLVE_RC"
  fi
  exit "$RESOLVE_RC"
fi

SLUG=$(printf '%s\n' "$RESOLVED" | head -1)
ARCHIVED=$(printf '%s\n' "$RESOLVED" | sed -n '2p')

if [[ "$ARCHIVED" == "true" ]]; then
  fail "work item '$SLUG' is archived — Tier 3 promotion files against active items"
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
ITEM_DIR="$KNOWLEDGE_DIR/_work/$SLUG"

if [[ ! -f "$ITEM_DIR/_meta.json" ]]; then
  fail "missing _meta.json for work item '$SLUG'"
fi

# --- Provenance: stamp the producing template's version at emission ----------
# Default derives from the implement skill template; --template-version overrides.
REPO_DIR="$(dirname "$(cd "$SCRIPT_DIR" && pwd -P)")"
SKILL_TEMPLATE="$REPO_DIR/skills/implement/SKILL.md"
if [[ -z "$TEMPLATE_VERSION" && -f "$SKILL_TEMPLATE" ]]; then
  TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "$SKILL_TEMPLATE" 2>/dev/null || true)
fi

# --- Role -> template-version attribution defaults (warn + "" on failure) ----
template_version_or_empty() {
  local label="$1" path="$2" tv
  if [[ -n "$path" ]] && tv=$(bash "$SCRIPT_DIR/template-version.sh" "$path" 2>/dev/null) && [[ -n "$tv" ]]; then
    printf '%s' "$tv"
  else
    echo "[impl] Warning: no template version resolved for role '$label' — its promotions run unstamped" >&2
    printf ''
  fi
}

[[ -n "$LEAD_TV" ]] || LEAD_TV=$(template_version_or_empty implement-lead "$SKILL_TEMPLATE")
[[ -n "$WORKER_TV" ]] || WORKER_TV=$(template_version_or_empty worker "$(resolve_agent_template worker 2>/dev/null || true)")
[[ -n "$ADVISOR_TV" ]] || ADVISOR_TV=$(template_version_or_empty advisor "$(resolve_agent_template advisor 2>/dev/null || true)")

# --- Parse + verify + promote -------------------------------------------------
# One python pass owns the whole batch: parse failure is a command failure
# before any write; per-candidate promote failures are contained as rejections
# so one bad row never aborts the batch. lore-promote.sh is the sole promotion
# writer — this script never touches the commons or promoted-commons.jsonl.
set +e
RESULT=$(python3 - "$CANDIDATES_FILE" "$ITEM_DIR/task-claims.jsonl" "$SLUG" \
  "$SCRIPT_DIR/lore-promote.sh" "$LEAD_TV" "$WORKER_TV" "$ADVISOR_TV" <<'PYEOF'
import json, subprocess, sys

(cand_path, claims_path, slug, promote_sh,
 lead_tv, worker_tv, advisor_tv) = sys.argv[1:8]

with open(cand_path, encoding="utf-8") as f:
    raw = f.read()

candidates = None
stripped = raw.strip()
if not stripped:
    candidates = []
else:
    try:
        parsed = json.loads(stripped)
        if isinstance(parsed, list):
            candidates = parsed
        elif isinstance(parsed, dict):
            candidates = [parsed]
    except ValueError:
        pass
    if candidates is None:
        candidates = []
        for lineno, line in enumerate(stripped.splitlines(), 1):
            line = line.strip()
            if not line:
                continue
            try:
                candidates.append(json.loads(line))
            except ValueError:
                print(json.dumps({"parse_error":
                    f"candidates file is neither a JSON array nor JSONL (line {lineno})"}))
                sys.exit(1)

claim_ids = set()
try:
    with open(claims_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict) and row.get("claim_id"):
                claim_ids.add(row["claim_id"])
except FileNotFoundError:
    pass

ROLE_TV = {"worker": worker_tv, "advisor": advisor_tv, "implement-lead": lead_tv}

accepted, rejected, defaulted_ids = [], [], []
seen_ids = set()
for i, cand in enumerate(candidates, 1):
    label = f"candidate-{i}"
    if not isinstance(cand, dict):
        rejected.append({"claim_id": label, "reason": "not a JSON object"})
        continue
    cid = cand.get("claim_id") or ""
    if not (isinstance(cid, str) and cid.strip()):
        rejected.append({"claim_id": label, "reason": "missing claim_id"})
        continue
    cid = cid.strip()
    if cid in seen_ids:
        rejected.append({"claim_id": cid, "reason": "duplicate claim_id in batch"})
        continue
    seen_ids.add(cid)

    wi = cand.get("work_item")
    if wi and wi != slug:
        rejected.append({"claim_id": cid,
                         "reason": f"work_item '{wi}' does not match '{slug}' (cross-work-item references are rejected)"})
        continue

    sids = cand.get("source_artifact_ids")
    if not (isinstance(sids, list) and sids):
        rejected.append({"claim_id": cid, "reason": "source_artifact_ids missing or empty"})
        continue
    missing = [s for s in sids if s not in claim_ids]
    if missing:
        rejected.append({"claim_id": cid,
                         "reason": "source_artifact_ids refer to missing claim_ids: " + ", ".join(missing)})
        continue

    role = (cand.get("producer_role") or "").strip()
    role_defaulted = False
    if not role:
        # validate-tier3.sh requires producer_role on the row itself, so the
        # default is injected into the row, not just the attribution flag.
        role = "implement-lead"
        role_defaulted = True
        cand = {**cand, "producer_role": role}
    if role not in ROLE_TV:
        rejected.append({"claim_id": cid,
                         "reason": f"no template-version attribution for producer_role '{role}'"})
        continue
    tv = ROLE_TV[role]

    argv = ["bash", promote_sh, "--work-item", slug, "--producer-role", role]
    if tv:
        argv += ["--template-version", tv]
    # errors="replace": a child that emits invalid UTF-8 on stderr (e.g. a
    # tool error message carrying a truncated multibyte byte) must land as a
    # per-candidate rejection, not a decode crash that aborts the whole batch.
    proc = subprocess.run(argv, input=json.dumps(cand), capture_output=True,
                          text=True, errors="replace")
    if proc.returncode != 0:
        detail = (proc.stderr.strip().splitlines() or proc.stdout.strip().splitlines() or [""])[-1]
        sys.stderr.write(proc.stderr)
        rejected.append({"claim_id": cid,
                         "reason": f"lore promote rejected (exit {proc.returncode}): {detail}"})
        continue

    entry_path = None
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if isinstance(obj, dict) and obj.get("path"):
            entry_path = obj["path"]
            break
    if role_defaulted:
        defaulted_ids.append(cid)
    accepted.append({"claim_id": cid, "producer_role": role,
                     "producer_role_defaulted": role_defaulted,
                     "template_version": tv or None, "entry_path": entry_path})

print(json.dumps({
    "candidates_total": len(candidates),
    "accepted": accepted,
    "rejected": rejected,
    "defaulted_ids": defaulted_ids,
}, ensure_ascii=False))
PYEOF
)
BATCH_RC=$?
set -e
if [[ $BATCH_RC -ne 0 ]]; then
  PARSE_ERROR=$(printf '%s' "$RESULT" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("parse_error", ""))
except Exception:
    print("")' 2>/dev/null || true)
  fail "${PARSE_ERROR:-candidate batch processing failed (exit $BATCH_RC)}"
fi

# --- Summary execution-log entry (always written, even for an empty batch) ---
BODY=$(python3 - "$RESULT" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
accepted = d["accepted"]
rejected = d["rejected"]
lines = [f"Tier 3 promotion summary: {len(accepted)} accepted, {len(rejected)} rejected"]
lines.append("Accepted ids: " + (", ".join(a["claim_id"] for a in accepted) or "None"))
reasons = [f"{r['claim_id']}: {r['reason']}" for r in rejected]
lines.append("Rejected reasons: " + (json.dumps(reasons, ensure_ascii=False) if reasons else "None"))
if d["defaulted_ids"]:
    lines.append("Producer-role defaulting: " +
                 ", ".join(f"{cid} (defaulted to implement-lead)" for cid in d["defaulted_ids"]))
print("\n".join(lines))
PYEOF
)

WLOG_ARGS=(--slug "$SLUG" --source impl-verb)
if [[ -n "$TEMPLATE_VERSION" ]]; then
  WLOG_ARGS+=(--template-version "$TEMPLATE_VERSION")
fi

if ! printf '%s\n' "$BODY" | bash "$SCRIPT_DIR/write-execution-log.sh" "${WLOG_ARGS[@]}" >/dev/null; then
  fail "summary execution-log append failed for '$SLUG'"
fi

# --- Output -------------------------------------------------------------------
if [[ $JSON_MODE -eq 1 ]]; then
  json_output "$(python3 - "$RESULT" "$SLUG" "$ITEM_DIR/execution-log.md" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
print(json.dumps({
    "slug": sys.argv[2],
    "candidates_total": d["candidates_total"],
    "accepted_count": len(d["accepted"]),
    "rejected_count": len(d["rejected"]),
    "accepted": d["accepted"],
    "rejected": d["rejected"],
    "log_path": sys.argv[3],
}, ensure_ascii=False))
PYEOF
)"
fi

python3 - "$RESULT" "$SLUG" "$ITEM_DIR/execution-log.md" <<'PYEOF'
import json, sys
d = json.loads(sys.argv[1])
slug, log_path = sys.argv[2:4]
print(f"[impl] Tier 3 promotion summary for {slug}: "
      f"{len(d['accepted'])} accepted, {len(d['rejected'])} rejected")
for a in d["accepted"]:
    note = " (producer_role defaulted to implement-lead)" if a["producer_role_defaulted"] else ""
    print(f"[impl]   accepted: {a['claim_id']} ({a['producer_role']}){note}")
for r in d["rejected"]:
    print(f"[impl]   rejected: {r['claim_id']} — {r['reason']}")
print(f"[impl] Execution-log entry appended: {log_path}")
PYEOF
