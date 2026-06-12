#!/usr/bin/env bash
# impl-check-report.sh — Mechanically verify a worker completion report
# Usage: impl-check-report.sh <ref> --task <id> --report <file> --phase <n>
#        [--transcript <file>] [--woven-norm <label>]...
#        [--provider-status <full|partial|unavailable>] [--spawned-advisors <csv>]
#        [--template-version <hash>] [--json]
#
# Absorbs the mechanical half of /implement Step 4 report verification:
#
#   1. Tier 2 cross-reference (BLOCKING) — every claim_id in the report's
#      `**Tier 2 evidence:**` section must exist as a row in the canonical
#      task-claims.jsonl. The substrate is checked, never the report's own
#      assertion. Missing ids are named in the findings.
#   2. Required-consultation acknowledgement (BLOCKING) — the phase brief's
#      `**Consultations required:**` domains must each have a matching
#      `**Consultations:**` entry whose consultation_id appears in the
#      --transcript JSONL (one acknowledged-reply record per line, shape
#      {consultation_id, worker, domain, handler, ...}).
#   3. Convention-handling completeness (non-blocking) — report dispositions
#      compared against the --woven-norm list: missing / duplicated /
#      unrecognized labels and `none in scope` conflicts are surfaced.
#      Divergence rationales are listed verbatim; assessing them is the
#      caller's judgment, not this script's.
#   4. Fabrication guard (non-blocking, metadata-only) — `handler: agent`
#      consultations are intersected with --spawned-advisors under the
#      declared --provider-status. Unverified entries are stripped from the
#      rollup payload and logged; provider unavailable (or partial without a
#      spawn list) withholds the rollup entirely rather than trusting the
#      report verbatim.
#   5. Advisor-impact rollup — the verified `handler: agent` subset is
#      forwarded to advisor-impact-rollup.sh (the scorecard sole writer).
#   6. One execution-log entry (source: impl-verb) filing the findings.
#
# Harness facts (transcript, spawned advisors, provider status) are flag- or
# file-passed: a CLI verb cannot read harness tool surfaces. This verb never
# accepts or rejects the report. mechanical_pass=false obliges the caller to
# reject; mechanical_pass=true leaves acceptance entirely with the caller.
# Every check reports a status — skips are loud, never swallowed.
#
# Exit codes:
#   0  checks ran; mechanical_pass=true (acceptance is the caller's decision)
#   1  validation error / no work-item match
#   2  ambiguous work-item reference
#   3  checks ran; mechanical_pass=false (findings name the failures)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

VALID_PROVIDER_STATUSES="full|partial|unavailable"

REF=""
TASK_ID=""
REPORT_FILE=""
PHASE=""
TRANSCRIPT_FILE=""
TRANSCRIPT_SET=0
WOVEN_NORMS=""
WOVEN_SET=0
PROVIDER_STATUS=""
PROVIDER_SET=0
SPAWNED_ADVISORS=""
SPAWNED_SET=0
TEMPLATE_VERSION=""
JSON_MODE=0

usage() {
  cat >&2 <<EOF
Usage: lore impl check-report <ref> --task <id> --report <file> --phase <n>
                              [--transcript <file>] [--woven-norm <label>]...
                              [--provider-status <full|partial|unavailable>]
                              [--spawned-advisors <csv>]
                              [--template-version <hash>] [--json]

Mechanically verify a worker completion report: Tier 2 claim_id
cross-reference (blocking), required-consultation acknowledgement (blocking),
convention-handling completeness (non-blocking), fabrication guard +
advisor-impact rollup (metadata-only), one execution-log entry.

--transcript is required when the phase brief declares required consultation
domains. --provider-status is required when the report carries handler: agent
consultations; full additionally requires --spawned-advisors (pass an empty
value when none were spawned).

Exit codes: 0 mechanical_pass=true, 1 error/no match, 2 ambiguous reference,
            3 mechanical_pass=false (caller must reject)
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
    --task)
      TASK_ID="${2:-}"
      shift 2
      ;;
    --task=*)
      TASK_ID="${1#--task=}"
      shift
      ;;
    --report)
      REPORT_FILE="${2:-}"
      shift 2
      ;;
    --report=*)
      REPORT_FILE="${1#--report=}"
      shift
      ;;
    --phase)
      PHASE="${2:-}"
      shift 2
      ;;
    --phase=*)
      PHASE="${1#--phase=}"
      shift
      ;;
    --transcript)
      TRANSCRIPT_FILE="${2:-}"
      TRANSCRIPT_SET=1
      shift 2
      ;;
    --transcript=*)
      TRANSCRIPT_FILE="${1#--transcript=}"
      TRANSCRIPT_SET=1
      shift
      ;;
    --woven-norm)
      WOVEN_NORMS="${WOVEN_NORMS}${2:-}"$'\n'
      WOVEN_SET=1
      shift 2
      ;;
    --woven-norm=*)
      WOVEN_NORMS="${WOVEN_NORMS}${1#--woven-norm=}"$'\n'
      WOVEN_SET=1
      shift
      ;;
    --provider-status)
      PROVIDER_STATUS="${2:-}"
      PROVIDER_SET=1
      shift 2
      ;;
    --provider-status=*)
      PROVIDER_STATUS="${1#--provider-status=}"
      PROVIDER_SET=1
      shift
      ;;
    --spawned-advisors)
      SPAWNED_ADVISORS="${2:-}"
      SPAWNED_SET=1
      shift 2
      ;;
    --spawned-advisors=*)
      SPAWNED_ADVISORS="${1#--spawned-advisors=}"
      SPAWNED_SET=1
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

if [[ -z "$TASK_ID" ]]; then
  fail "--task is required (the task id this report answers)"
fi

if [[ -z "$REPORT_FILE" ]]; then
  fail "--report is required (file holding the worker's completion report)"
fi

if [[ ! -f "$REPORT_FILE" ]]; then
  fail "report file not found: $REPORT_FILE"
fi

if [[ -z "$PHASE" ]]; then
  fail "--phase is required (the task's 1-based phase number; the required-consultation check reads the phase brief)"
fi

if ! [[ "$PHASE" =~ ^[0-9]+$ ]] || [[ "$PHASE" -lt 1 ]]; then
  fail "--phase must be a positive integer (got '$PHASE')"
fi

if [[ $PROVIDER_SET -eq 1 ]]; then
  case "$PROVIDER_STATUS" in
    full|partial|unavailable) ;;
    *)
      fail "--provider-status must be one of: $VALID_PROVIDER_STATUSES (got '$PROVIDER_STATUS')"
      ;;
  esac
  if [[ "$PROVIDER_STATUS" == "unavailable" && $SPAWNED_SET -eq 1 ]]; then
    fail "--provider-status unavailable does not take --spawned-advisors (no spawn surface to intersect)"
  fi
elif [[ $SPAWNED_SET -eq 1 ]]; then
  fail "--spawned-advisors requires --provider-status"
fi

if [[ $TRANSCRIPT_SET -eq 1 && ! -f "$TRANSCRIPT_FILE" ]]; then
  fail "transcript file not found: $TRANSCRIPT_FILE"
fi

# --- Resolve the work-item reference (tri-state exit passthrough) ----------
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
  fail "work item '$SLUG' is archived — report checks apply to active items"
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
ITEM_DIR="$KNOWLEDGE_DIR/_work/$SLUG"

if [[ ! -f "$ITEM_DIR/_meta.json" ]]; then
  fail "missing _meta.json for work item '$SLUG'"
fi

# --- Phase brief: source of the required-consultation domain list -----------
set +e
PHASE_BRIEF=$(bash "$SCRIPT_DIR/phase-context.sh" "$SLUG" "$PHASE" 2>&1)
BRIEF_RC=$?
set -e
if [[ $BRIEF_RC -ne 0 ]]; then
  fail "could not read phase brief for '$SLUG' phase $PHASE: $PHASE_BRIEF"
fi

# --- Run the mechanical checks ----------------------------------------------
# Exit 64 from the checker is a validation error (message on stdout); any
# other non-zero is an internal failure.
set +e
RESULT=$(CR_REPORT_FILE="$REPORT_FILE" \
  CR_CLAIMS_FILE="$ITEM_DIR/task-claims.jsonl" \
  CR_PHASE_BRIEF="$PHASE_BRIEF" \
  CR_TRANSCRIPT_FILE="$TRANSCRIPT_FILE" \
  CR_TRANSCRIPT_SET="$TRANSCRIPT_SET" \
  CR_WOVEN_NORMS="$WOVEN_NORMS" \
  CR_WOVEN_SET="$WOVEN_SET" \
  CR_PROVIDER_STATUS="$PROVIDER_STATUS" \
  CR_PROVIDER_SET="$PROVIDER_SET" \
  CR_SPAWNED="$SPAWNED_ADVISORS" \
  CR_SPAWNED_SET="$SPAWNED_SET" \
  python3 <<'PYEOF'
import json
import os
import re
import sys


def validation_error(msg):
    print(msg)
    sys.exit(64)


def clean(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'", "`"):
        value = value[1:-1]
    return value.strip("`").strip()


def split_sections(text):
    """Map '**Name:**' report sections to their lines (inline remainder first)."""
    sections = {}
    current = None
    for line in text.splitlines():
        m = re.match(r"^\s*\*\*([^*]+?):\*\*\s*(.*)$", line)
        if m:
            current = m.group(1).strip()
            sections.setdefault(current, [])
            if m.group(2).strip():
                sections[current].append(m.group(2).strip())
        elif current is not None:
            sections[current].append(line)
    return sections


with open(os.environ["CR_REPORT_FILE"], encoding="utf-8") as f:
    sections = split_sections(f.read())

fail_reasons = []

# --- 1. Tier 2 cross-reference against the canonical substrate --------------
canonical = set()
claims_file = os.environ["CR_CLAIMS_FILE"]
if os.path.isfile(claims_file):
    with open(claims_file, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
                if not isinstance(row, dict):
                    raise ValueError("not an object")
            except ValueError:
                print(f"[impl] Warning: skipping malformed line {lineno} "
                      f"in task-claims.jsonl", file=sys.stderr)
                continue
            cid = row.get("claim_id")
            if cid:
                canonical.add(cid)

if "Tier 2 evidence" not in sections:
    tier2 = {"status": "missing-section", "reported": [], "missing": [],
             "canonical_count": len(canonical)}
    fail_reasons.append("report has no 'Tier 2 evidence:' section")
else:
    text = "\n".join(sections["Tier 2 evidence"])
    tokens = [clean(t) for t in re.split(r"[,\s]+", text)]
    tokens = [t for t in tokens if t and t != "-"]
    if not tokens or (len(tokens) == 1 and tokens[0].lower() == "none"):
        tier2 = {"status": "none-reported", "reported": [], "missing": [],
                 "canonical_count": len(canonical)}
    else:
        missing = [t for t in tokens if t not in canonical]
        tier2 = {"status": "ok" if not missing else "missing-ids",
                 "reported": tokens, "missing": missing,
                 "canonical_count": len(canonical)}
        if missing:
            fail_reasons.append(
                "Tier 2 claim_ids not found in task-claims.jsonl: "
                + ", ".join(missing))

# --- Parse Consultations entries (shared by checks 2 and 4) -----------------
entries = []
consultations_present = "Consultations" in sections
if consultations_present:
    lines = sections["Consultations"]
    joined = clean("\n".join(lines))
    if joined and joined.lower() != "none":
        cur = None
        for line in lines:
            m = re.match(r"^\s*-\s+([A-Za-z_][\w-]*):\s*(.*)$", line)
            if m:
                cur = {m.group(1): clean(m.group(2))}
                entries.append(cur)
                continue
            m = re.match(r"^\s+([A-Za-z_][\w-]*):\s*(.*)$", line)
            if m and cur is not None:
                cur[m.group(1)] = clean(m.group(2))
for e in entries:
    if "was_followed" in e:
        e["was_followed"] = str(e["was_followed"]).lower() == "true"

# --- 2. Required-consultation acknowledgement -------------------------------
brief = os.environ.get("CR_PHASE_BRIEF", "")
required = []
brief_lines = brief.splitlines()
for i, line in enumerate(brief_lines):
    m = re.search(r"\*\*Consultations required:\*\*\s*(.*)$", line)
    if not m:
        continue
    inline = m.group(1).strip()
    if inline:
        required.extend(clean(d) for d in inline.split(",") if clean(d))
    for follow in brief_lines[i + 1:]:
        bm = re.match(r"^\s*-\s+(.+)$", follow)
        if bm:
            required.append(clean(bm.group(1)))
        else:
            break

if required:
    if os.environ["CR_TRANSCRIPT_SET"] != "1":
        validation_error(
            "phase brief declares required consultation domains ("
            + ", ".join(required)
            + ") — --transcript <file> is required for the acknowledgement check")
    acked = set()
    with open(os.environ["CR_TRANSCRIPT_FILE"], encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
                if not isinstance(rec, dict):
                    raise ValueError("not an object")
            except ValueError:
                print(f"[impl] Warning: skipping malformed line {lineno} "
                      f"in transcript", file=sys.stderr)
                continue
            acked.add((rec.get("consultation_id"), rec.get("domain")))
    unsatisfied = []
    for domain in required:
        matches = [e for e in entries if e.get("domain") == domain]
        if not matches:
            unsatisfied.append({"domain": domain,
                                "reason": "no Consultations entry for this domain"})
        elif not any((e.get("consultation_id"), domain) in acked for e in matches):
            ids = ", ".join(e.get("consultation_id") or "<missing id>" for e in matches)
            unsatisfied.append({"domain": domain,
                                "reason": f"consultation_id [{ids}] has no "
                                          f"acknowledged transcript record"})
    required_check = {"status": "unsatisfied" if unsatisfied else "satisfied",
                      "required_domains": required, "unsatisfied": unsatisfied}
    if unsatisfied:
        fail_reasons.append(
            "required consultation domains unsatisfied: "
            + ", ".join(u["domain"] for u in unsatisfied))
else:
    required_check = {"status": "not-required", "required_domains": [],
                      "unsatisfied": []}

# --- 3. Convention-handling completeness (non-blocking) ---------------------
woven = [l.strip() for l in os.environ.get("CR_WOVEN_NORMS", "").splitlines()
         if l.strip()]
woven_set = os.environ["CR_WOVEN_SET"] == "1"
convention = {"missing": [], "duplicated": [], "unrecognized": [],
              "none_in_scope_conflict": False, "honored": [], "diverged": []}
if "Convention handling" not in sections:
    convention["status"] = "missing-section"
else:
    lines = sections["Convention handling"]
    none_in_scope = clean("\n".join(lines)).lower() == "none in scope"
    honored = []
    diverged = []
    for line in lines:
        m = re.match(r"^\s*-\s*(honored|diverged):\s*(.*)$", line)
        if not m:
            continue
        rest = m.group(2).strip()
        if m.group(1) == "honored":
            # Workers may append a dash-separated rationale; only the label
            # participates in the completeness comparison.
            honored.append(clean(re.split(r"\s+[—–-]+\s+", rest, maxsplit=1)[0]))
        else:
            parts = re.split(r"\s+[—–-]+\s+", rest, maxsplit=1)
            diverged.append({"label": clean(parts[0]),
                             "rationale": parts[1].strip() if len(parts) > 1 else ""})
    convention["honored"] = honored
    convention["diverged"] = diverged
    dispositioned = honored + [d["label"] for d in diverged]
    if woven_set:
        convention["missing"] = [w for w in woven if w not in dispositioned]
        convention["duplicated"] = sorted(
            {l for l in dispositioned if dispositioned.count(l) > 1})
        convention["unrecognized"] = [l for l in dispositioned if l not in woven]
        convention["none_in_scope_conflict"] = none_in_scope and bool(woven)
        has_findings = (convention["missing"] or convention["duplicated"]
                        or convention["unrecognized"]
                        or convention["none_in_scope_conflict"])
        convention["status"] = "findings" if has_findings else "clean"
    else:
        convention["status"] = "skipped-no-woven-list"

# --- 4. Fabrication guard (metadata-only) ------------------------------------
agent_entries = []
invalid_entries = 0
for e in entries:
    handler = e.get("handler")
    if handler is None and e.get("advisor_template_version"):
        handler = "agent"
        e["handler"] = "agent"
    if handler == "agent":
        agent_entries.append(e)
    elif handler is None:
        invalid_entries += 1

rollup_payload = []
if not agent_entries:
    guard = {"status": "no-agent-consultations", "verified": [], "stripped": []}
else:
    if os.environ["CR_PROVIDER_SET"] != "1":
        validation_error(
            "report contains handler: agent consultations — "
            "--provider-status <full|partial|unavailable> is required")
    provider = os.environ["CR_PROVIDER_STATUS"]
    spawned_set = os.environ["CR_SPAWNED_SET"] == "1"
    spawned = {clean(t) for t in os.environ.get("CR_SPAWNED", "").split(",")
               if clean(t)}
    if provider == "unavailable":
        guard = {"status": "provider-unavailable", "verified": [], "stripped": []}
    elif provider == "partial" and not spawned_set:
        guard = {"status": "provider-partial-degraded", "verified": [],
                 "stripped": []}
    else:
        if provider == "full" and not spawned_set:
            validation_error(
                "--provider-status full requires --spawned-advisors "
                "(pass an empty value when none were spawned)")
        verified_ids = []
        stripped_ids = []
        for e in agent_entries:
            ident = e.get("advisor_template_version") or e.get("advisor") or ""
            if ident and ident in spawned:
                verified_ids.append(ident)
                rollup_payload.append(e)
            else:
                stripped_ids.append(ident or "<no-identifier>")
        if not stripped_ids:
            status = "verified"
        elif not verified_ids:
            status = "all-stripped"
        else:
            status = "partial-strip"
        guard = {"status": status, "verified": verified_ids,
                 "stripped": stripped_ids}
guard["invalid_entries"] = invalid_entries

print(json.dumps({
    "tier2": tier2,
    "required_consultations": required_check,
    "convention_handling": convention,
    "fabrication_guard": guard,
    "rollup_payload": rollup_payload,
    "fail_reasons": fail_reasons,
    "mechanical_pass": not fail_reasons,
}))
PYEOF
)
CHECK_RC=$?
set -e
if [[ $CHECK_RC -eq 64 ]]; then
  fail "$RESULT"
elif [[ $CHECK_RC -ne 0 ]]; then
  fail "report check failed (internal error, exit $CHECK_RC)"
fi

MECHANICAL_PASS=$(printf '%s' "$RESULT" \
  | python3 -c 'import json,sys; print("true" if json.load(sys.stdin)["mechanical_pass"] else "false")')
GUARD_STATUS=$(printf '%s' "$RESULT" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["fabrication_guard"]["status"])')
ROLLUP_PAYLOAD=$(printf '%s' "$RESULT" \
  | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["rollup_payload"]))')

# --- 5. Advisor-impact rollup on the verified subset -------------------------
ROLLUP_STATUS="skipped"
ROLLUP_REASON=""
case "$GUARD_STATUS" in
  no-agent-consultations) ROLLUP_REASON="no-agent-consultations" ;;
  provider-unavailable)   ROLLUP_REASON="provider-unavailable" ;;
  provider-partial-degraded) ROLLUP_REASON="provider-partial-degraded" ;;
  all-stripped)           ROLLUP_REASON="all-entries-stripped" ;;
  *)
    set +e
    ROLLUP_OUTPUT=$(printf '%s' "$ROLLUP_PAYLOAD" \
      | bash "$SCRIPT_DIR/advisor-impact-rollup.sh" --work-item "$SLUG" 2>&1)
    ROLLUP_RC=$?
    set -e
    if [[ $ROLLUP_RC -eq 0 ]]; then
      ROLLUP_STATUS="appended"
    else
      ROLLUP_STATUS="failed"
      ROLLUP_REASON="advisor-impact-rollup.sh exit $ROLLUP_RC"
      printf '%s\n' "$ROLLUP_OUTPUT" >&2
      echo "[impl] Warning: advisor-impact rollup failed; findings still filed." >&2
    fi
    ;;
esac

# --- Provenance: stamp the producing template's version at emission ---------
# Default derives from the implement skill template; --template-version overrides.
if [[ -z "$TEMPLATE_VERSION" ]]; then
  REPO_DIR="$(dirname "$(cd "$SCRIPT_DIR" && pwd -P)")"
  SKILL_TEMPLATE="$REPO_DIR/skills/implement/SKILL.md"
  if [[ -f "$SKILL_TEMPLATE" ]]; then
    TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "$SKILL_TEMPLATE" 2>/dev/null || true)
  fi
fi
if [[ -z "$TEMPLATE_VERSION" ]]; then
  TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "${BASH_SOURCE[0]}")
fi

# --- 6. File the findings via the execution-log sole writer ------------------
LOG_BODY=$(python3 - "$RESULT" "$TASK_ID" "$ROLLUP_STATUS" "$ROLLUP_REASON" <<'PYEOF'
import json
import sys

result = json.loads(sys.argv[1])
task_id, rollup_status, rollup_reason = sys.argv[2:5]
t2 = result["tier2"]
rc = result["required_consultations"]
ch = result["convention_handling"]
fg = result["fabrication_guard"]

lines = [
    f"Check-report task: {task_id}",
    f"Mechanical pass: {str(result['mechanical_pass']).lower()}",
    f"Tier2 cross-reference: {t2['status']}; reported={len(t2['reported'])}; "
    f"missing={json.dumps(t2['missing'])}",
    f"Required consultations: {rc['status']}; "
    f"domains={json.dumps(rc['required_domains'])}; "
    f"unsatisfied={json.dumps([u['domain'] for u in rc['unsatisfied']])}",
    f"Convention handling: {ch['status']}; missing={json.dumps(ch['missing'])}; "
    f"duplicated={json.dumps(ch['duplicated'])}; "
    f"unrecognized={json.dumps(ch['unrecognized'])}; "
    f"diverged={json.dumps([d['label'] for d in ch['diverged']])}",
    f"Fabrication guard: {fg['status']}; verified={json.dumps(fg['verified'])}",
]
for ident in fg["stripped"]:
    lines.append(f"fabrication-guard: skipped {ident}")
if fg["status"] == "provider-unavailable":
    lines.append("fabrication-guard: provider-unavailable; rollup skipped")
elif fg["status"] == "provider-partial-degraded":
    lines.append("fabrication-guard: provider-partial; rollup skipped")
rollup = f"Advisor rollup: {rollup_status}"
if rollup_reason:
    rollup += f" ({rollup_reason})"
lines.append(rollup)
print("\n".join(lines))
PYEOF
)

if ! printf '%s\n' "$LOG_BODY" | bash "$SCRIPT_DIR/write-execution-log.sh" \
    --slug "$SLUG" --source impl-verb --template-version "$TEMPLATE_VERSION" >/dev/null; then
  fail "execution-log append failed for '$SLUG'"
fi

# --- Output -------------------------------------------------------------------
# Printed manually (not via json_output) so mechanical_pass=false can carry
# exit 3: this verb surfaces findings; accept/reject stays with the caller.
python3 - "$RESULT" "$SLUG" "$TASK_ID" "$ROLLUP_STATUS" "$ROLLUP_REASON" \
  "$ITEM_DIR/execution-log.md" "$JSON_MODE" <<'PYEOF'
import json
import sys

result = json.loads(sys.argv[1])
slug, task_id, rollup_status, rollup_reason, log_path, json_mode = sys.argv[2:8]
t2 = result["tier2"]
rc = result["required_consultations"]
ch = result["convention_handling"]
fg = result["fabrication_guard"]

if json_mode == "1":
    print(json.dumps({
        "slug": slug,
        "task_id": task_id,
        "mechanical_pass": result["mechanical_pass"],
        "fail_reasons": result["fail_reasons"],
        "findings": {
            "tier2": t2,
            "required_consultations": rc,
            "convention_handling": ch,
            "fabrication_guard": fg,
        },
        "advisor_rollup": {"status": rollup_status,
                           "reason": rollup_reason or None},
        "execution_log": "appended",
    }, ensure_ascii=False))
    sys.exit(0)

print(f"[impl] check-report: task {task_id} @ {slug}")
if t2["status"] == "ok":
    print(f"Tier 2 cross-reference: ok — {len(t2['reported'])}/"
          f"{len(t2['reported'])} reported claim_ids found")
elif t2["status"] == "missing-ids":
    print(f"Tier 2 cross-reference: MISSING — {json.dumps(t2['missing'])} "
          f"not in task-claims.jsonl")
else:
    print(f"Tier 2 cross-reference: {t2['status']}")
if rc["status"] == "unsatisfied":
    print("Required consultations: UNSATISFIED")
    for u in rc["unsatisfied"]:
        print(f"  - {u['domain']}: {u['reason']}")
else:
    print(f"Required consultations: {rc['status']}"
          + (f" (domains: {', '.join(rc['required_domains'])})"
             if rc["required_domains"] else ""))
print(f"Convention handling: {ch['status']}")
if ch["status"] == "findings":
    if ch["missing"]:
        print(f"  missing: {', '.join(ch['missing'])}")
    if ch["duplicated"]:
        print(f"  duplicated: {', '.join(ch['duplicated'])}")
    if ch["unrecognized"]:
        print(f"  unrecognized: {', '.join(ch['unrecognized'])}")
    if ch["none_in_scope_conflict"]:
        print("  'none in scope' reported but woven norms exist")
for d in ch["diverged"]:
    print(f"  diverged: {d['label']} — {d['rationale']} (assess the rationale; "
          f"this verb does not)")
print(f"Fabrication guard: {fg['status']}"
      + (f"; stripped: {', '.join(fg['stripped'])}" if fg["stripped"] else ""))
print(f"Advisor rollup: {rollup_status}"
      + (f" ({rollup_reason})" if rollup_reason else ""))
print(f"Execution log: appended ({log_path})")
print(f"Mechanical pass: {str(result['mechanical_pass']).lower()}")
if result["mechanical_pass"]:
    print("[impl] Acceptance remains the caller's decision — "
          "mechanical checks alone never accept.")
else:
    print("[impl] mechanical_pass=false — the caller MUST reject this report "
          "back to the worker:")
    for reason in result["fail_reasons"]:
        print(f"[impl]   - {reason}")
PYEOF

if [[ "$MECHANICAL_PASS" == "true" ]]; then
  exit 0
fi
exit 3
