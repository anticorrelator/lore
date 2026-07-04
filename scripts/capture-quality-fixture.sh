#!/usr/bin/env bash
# capture-quality-fixture.sh — Package a reverse-auditor omission emission into
# a substrate-bearing quality-regression fixture.
#
# Usage:
#   capture-quality-fixture.sh <work-item-slug> <source-claim-id> \
#       --candidate-id <candidate-id> [--fixture-id <id>] \
#       [--allow-dirty-worktree] [--kdir <path>] [--note <text>]
#
# <source-claim-id> selects the row whose reverse-auditor input is
# reconstructed: first matched against claim_id in the work item's
# task-claims.jsonl, then against candidate_id in audit-candidates.jsonl
# (an omission candidate re-audited via the per-kind path).
# --candidate-id selects the row in audit-candidates.jsonl whose omission
# defines the strict-bar expectation. The two ids identify different rows:
# the reverse-auditor's emitted omission target can differ from the source
# claim's anchor, so the candidate is never inferred from the source row.
#
# The fixture is written to
#   $KDIR/_quality-fixtures/reverse-auditor/<fixture-id>/
# and carries the frozen assembled reverse-auditor input packet
# (04-reverse-auditor-input.json, whose inlined_evidence block is the
# complete substrate the no-tool-use judge adjudicates from), capture
# provenance, and the expected emission. The fixture directory path is
# printed on stdout on success.
#
# Evidence source resolution (queue rows vs verdict envelopes):
#   The queue row named by --candidate-id is joined to a reverse-auditor
#   verdict envelope in verdicts/*.jsonl by judge_run_at == the queue row's
#   created_at. When the envelope exists (it carries the omission_claim as
#   emitted, pre-reanchor, plus the exact inlined_evidence the judge
#   adjudicated on), both are frozen verbatim. When only the lean queue row
#   survives, the expectation is built from the queue row's fields and the
#   inlined_evidence is rebuilt against current HEAD via
#   reverse-auditor-inline-evidence.py — only appropriate for a fresh
#   emission whose substrate has not yet drifted.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

LORE_REPO="${LORE_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  sed -n '2,20p' "$0" >&2
  exit 1
}

SLUG=""
SRC_ID=""
CAND_ID=""
FIXTURE_ID=""
ALLOW_DIRTY=0
KDIR_OVERRIDE=""
NOTE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --candidate-id) CAND_ID="${2:?--candidate-id requires a value}"; shift 2 ;;
    --fixture-id)   FIXTURE_ID="${2:?--fixture-id requires a value}"; shift 2 ;;
    --allow-dirty-worktree) ALLOW_DIRTY=1; shift ;;
    --kdir)         KDIR_OVERRIDE="${2:?--kdir requires a value}"; shift 2 ;;
    --note)         NOTE="${2:?--note requires a value}"; shift 2 ;;
    -h|--help)      usage ;;
    -*)             echo "[capture-fixture] Error: unknown flag: $1" >&2; usage ;;
    *)
      if [[ -z "$SLUG" ]]; then SLUG="$1"
      elif [[ -z "$SRC_ID" ]]; then SRC_ID="$1"
      else echo "[capture-fixture] Error: unexpected argument: $1" >&2; usage
      fi
      shift ;;
  esac
done

[[ -n "$SLUG" && -n "$SRC_ID" ]] || { echo "[capture-fixture] Error: <work-item-slug> and <source-claim-id> are required" >&2; usage; }
[[ -n "$CAND_ID" ]] || { echo "[capture-fixture] Error: --candidate-id is required (the omission expectation is never inferred from the source row)" >&2; usage; }

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KDIR" ]] || die "knowledge dir not found: $KDIR"

WI_DIR=""
for d in "$KDIR/_work/$SLUG" "$KDIR/_work/_archive/$SLUG"; do
  if [[ -d "$d" ]]; then WI_DIR="$d"; break; fi
done
[[ -n "$WI_DIR" ]] || die "work item not found (active or archived): $SLUG"

[[ -n "$FIXTURE_ID" ]] || FIXTURE_ID="$(slugify "$SLUG-$CAND_ID")"
FIXTURE_DIR="$KDIR/_quality-fixtures/reverse-auditor/$FIXTURE_ID"
if [[ -e "$FIXTURE_DIR" ]]; then
  die "fixture already exists: $FIXTURE_DIR (pick another --fixture-id or retire the existing fixture)"
fi
mkdir -p "$FIXTURE_DIR"

# Remove the partial fixture on any failure path; disarmed on success.
CAPTURE_OK=0
cleanup_partial() {
  if [[ "$CAPTURE_OK" -ne 1 ]]; then
    rm -rf "$FIXTURE_DIR" 2>/dev/null || true
  fi
}
trap cleanup_partial EXIT

# Assemble source row + upstream verdicts + packet shell + expectation.
# Prints a JSON summary {capture_mode, evidence_files[], packet_shell_path}
# on stdout; writes 01/02/03/resolved-input/expected-emission into the
# fixture dir, and 04-reverse-auditor-input.json in envelope mode.
SUMMARY=$(python3 - "$WI_DIR" "$SRC_ID" "$CAND_ID" "$FIXTURE_DIR" "$SLUG" "$KDIR" << 'PYEOF'
import json
import sys
from pathlib import Path

wi_dir, src_id, cand_id, fixture_dir, slug, kdir = sys.argv[1:7]
wi = Path(wi_dir)
fx = Path(fixture_dir)


def fail(msg):
    print(f"[capture-fixture] Error: {msg}", file=sys.stderr)
    sys.exit(1)


def load_jsonl(p):
    rows = []
    if not p.exists():
        return rows
    for line_no, line in enumerate(p.read_text().splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        try:
            rows.append((line_no, json.loads(line)))
        except json.JSONDecodeError:
            continue
    return rows


# --- Source row: task-claims.jsonl by claim_id, else audit-candidates.jsonl
# by candidate_id (omission candidates re-audited via the per-kind path). ---
source_row = None
source_line = None
source_kind = None
source_path = None
tc_path = wi / "task-claims.jsonl"
for ln, row in load_jsonl(tc_path):
    if row.get("claim_id") == src_id:
        source_row, source_line, source_kind, source_path = row, ln, "task-claim", tc_path
        break
if source_row is None:
    ac_path = wi / "audit-candidates.jsonl"
    for ln, row in load_jsonl(ac_path):
        if row.get("candidate_id") == src_id:
            source_row, source_line, source_kind, source_path = row, ln, "omission", ac_path
            break
if source_row is None:
    fail(f"source row '{src_id}' not found in {tc_path} (claim_id) or {wi / 'audit-candidates.jsonl'} (candidate_id)")

# --- Upstream gate + curator verdicts for the source claim. ---
verdicts_path = wi / "verdicts" / source_path.name
gate_rows = []
curator_row = None
for _, obj in load_jsonl(verdicts_path):
    j = str(obj.get("judge") or "")
    if j.startswith("correctness-gate"):
        if any(v.get("claim_id") == src_id for v in obj.get("verdicts", [])):
            gate_rows.append(obj)
    elif j == "curator":
        if any(s.get("claim_id") == src_id for s in obj.get("selected", [])):
            if curator_row is None:
                curator_row = obj
if not gate_rows:
    fail(f"no correctness-gate verdict for '{src_id}' in {verdicts_path}")
if curator_row is None:
    fail(f"no curator verdict selecting '{src_id}' in {verdicts_path}")

# --- Resolved input, mirroring the audit-artifact.sh extractor branches. ---
if source_kind == "task-claim":
    src = source_row.get("source") if isinstance(source_row.get("source"), dict) else {}
    claim = {
        "claim_id": str(source_row.get("claim_id") or ""),
        "claim_text": str(source_row.get("claim") or source_row.get("claim_text") or ""),
        "file": source_row.get("file") or src.get("file") or None,
        "line_range": source_row.get("line_range") or src.get("line_range") or None,
        "exact_snippet": source_row.get("exact_snippet") or None,
        "normalized_snippet_hash": source_row.get("normalized_snippet_hash") or None,
        "provenance": source_row.get("provenance") or None,
        "falsifier": source_row.get("falsifier") or source_row.get("why_this_work_needs_it") or None,
        "severity_hint": source_row.get("significance") or source_row.get("scale") or None,
        "producer_role": source_row.get("producer_role") or None,
        "protocol_slot": source_row.get("protocol_slot") or None,
        "task_id": source_row.get("task_id") or None,
        "phase_id": source_row.get("phase_id") or None,
        "scale": source_row.get("scale") or None,
        "evidence_ref": {"path": str(source_path), "line": source_line},
    }
    raw_ctx = source_row.get("change_context")
    ctx = None
    if isinstance(raw_ctx, dict):
        changed = [f for f in (raw_ctx.get("changed_files") or []) if isinstance(f, str) and f.strip()]
        summary = raw_ctx.get("summary") if isinstance(raw_ctx.get("summary"), str) else ""
        if changed and summary.strip():
            ctx = {
                "diff_ref": raw_ctx.get("diff_ref") if isinstance(raw_ctx.get("diff_ref"), str) else None,
                "changed_files": list(dict.fromkeys(changed)),
                "summary": summary.strip(),
            }
    if ctx is None and claim["file"]:
        fallback = source_row.get("why_this_work_needs_it") or claim["claim_text"]
        if fallback:
            ctx = {
                "diff_ref": source_row.get("captured_at_sha") if isinstance(source_row.get("captured_at_sha"), str) else None,
                "changed_files": [claim["file"]],
                "summary": str(fallback).strip(),
            }
    claim["change_context"] = ctx
    artifact_type = "task-claims"
    producer_role = "worker"
    producer_template_version = "task-claims-jsonl"
else:
    if not (source_row.get("file") and source_row.get("line_range") and source_row.get("falsifier")):
        fail(f"omission source row '{src_id}' missing one of file/line_range/falsifier")
    claim = {
        "claim_id": src_id,
        "claim_text": source_row.get("rationale") or source_row.get("why_it_matters") or "",
        "file": source_row.get("file"),
        "line_range": source_row.get("line_range"),
        "exact_snippet": source_row.get("exact_snippet") or None,
        "normalized_snippet_hash": source_row.get("normalized_snippet_hash") or None,
        "falsifier": source_row.get("falsifier"),
        "evidence_ref": {"path": str(source_path), "line": source_line},
    }
    claim["change_context"] = {
        "diff_ref": None,
        "changed_files": [claim["file"]],
        "summary": str(claim["claim_text"]).strip() or claim["file"],
    }
    artifact_type = "omission"
    producer_role = "reverse-auditor"
    producer_template_version = "audit-candidates-jsonl"

resolved = {
    "artifact_id": slug,
    "artifact_path": str(source_path),
    "artifact_type": artifact_type,
    "kdir": kdir,
    "work_item": slug,
    "claim_payload": [claim],
    "claim_count": 1,
    "change_context": claim.get("change_context"),
    "producer_role": producer_role,
    "producer_template_version": producer_template_version,
}

selected_ids = {s.get("claim_id") for s in curator_row.get("selected", []) if s.get("claim_id")}
curated = [c for c in resolved["claim_payload"] if c.get("claim_id") in selected_ids]
if not curated:
    fail(f"curator selected ids {sorted(selected_ids)} do not include source claim '{src_id}'")
packet_shell = {
    "artifact_id": resolved["artifact_id"],
    "artifact_type": resolved["artifact_type"],
    "artifact_path": resolved["artifact_path"],
    "work_item": resolved["work_item"],
    "curated_top_k": curated,
    "change_context": resolved.get("change_context"),
    "referenced_files": resolved.get("referenced_files"),
}

# --- Expectation: queue row by exact candidate_id, joined to a reverse-
# auditor verdict envelope by judge_run_at == the queue row's created_at. ---
queue_path = wi / "audit-candidates.jsonl"
queue_row = None
queue_line = None
available = []
for ln, row in load_jsonl(queue_path):
    cid = row.get("candidate_id")
    if cid:
        available.append(cid)
    if cid == cand_id:
        queue_row, queue_line = row, ln
if queue_row is None:
    fail(f"candidate '{cand_id}' not found in {queue_path} (available: {', '.join(available) or 'none'})")

# The queue row is written moments after the envelope is persisted, so the
# join tolerates a small clock gap between judge_run_at and created_at.
def parse_ts(s):
    from datetime import datetime
    try:
        return datetime.strptime(str(s), "%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, TypeError):
        return None


queue_ts = parse_ts(queue_row.get("created_at"))
envelopes = []
for vname in ("audit-candidates.jsonl", "task-claims.jsonl"):
    vpath = wi / "verdicts" / vname
    for ln, row in load_jsonl(vpath):
        if row.get("judge") != "reverse-auditor" or row.get("omission_claim") is None:
            continue
        env_ts = parse_ts(row.get("judge_run_at"))
        if queue_ts and env_ts and abs((queue_ts - env_ts).total_seconds()) <= 2:
            envelopes.append((vpath, ln, row))
if len(envelopes) > 1:
    locs = ", ".join(f"{p}:{ln}" for p, ln, _ in envelopes)
    fail(f"ambiguous: {len(envelopes)} reverse-auditor envelopes share judge_run_at {queue_row.get('created_at')} ({locs})")

if envelopes:
    capture_mode = "envelope"
    env_path, env_line, envelope = envelopes[0]
    inlined = envelope.get("inlined_evidence")
    if not isinstance(inlined, dict):
        fail(f"envelope at {env_path}:{env_line} has no inlined_evidence block; cannot freeze substrate")
    expected = {k: v for k, v in envelope.items() if k != "inlined_evidence"}
    packet = dict(packet_shell)
    packet["inlined_evidence"] = inlined
    (fx / "04-reverse-auditor-input.json").write_text(json.dumps(packet, indent=2) + "\n")
    expectation_source = {"path": str(env_path), "line": env_line}
else:
    capture_mode = "queue"
    expected = {
        "judge": "reverse-auditor",
        "reconstructed_from": "queue-row",
        "candidate_id": cand_id,
        "omission_claim": {
            "file": queue_row.get("file"),
            "line_range": queue_row.get("line_range"),
            "exact_snippet": queue_row.get("exact_snippet"),
            "normalized_snippet_hash": queue_row.get("normalized_snippet_hash"),
            "falsifier": queue_row.get("falsifier"),
            "why_it_matters": queue_row.get("rationale") or queue_row.get("why_it_matters"),
        },
    }
    if not (expected["omission_claim"]["file"] and expected["omission_claim"]["line_range"]):
        fail(f"queue row '{cand_id}' lacks file/line_range; cannot define the strict-bar expectation")
    (fx / "packet-shell.tmp.json").write_text(json.dumps(packet_shell, indent=2) + "\n")
    expectation_source = {"path": str(queue_path), "line": queue_line}

(fx / "01-source-row.json").write_text(json.dumps(source_row, indent=2) + "\n")
(fx / "02-gate-verdicts.json").write_text(json.dumps(gate_rows, indent=2) + "\n")
(fx / "03-curator-verdict.json").write_text(json.dumps(curator_row, indent=2) + "\n")
(fx / "resolved-input.json").write_text(json.dumps(resolved, indent=2) + "\n")
(fx / "expected-emission.json").write_text(json.dumps(expected, indent=2) + "\n")

manifest = {
    "fixture_id": fx.name,
    "judge": "reverse-auditor",
    "source_work_item": slug,
    "source_claim_id": src_id,
    "source_kind": source_kind,
    "candidate_id": cand_id,
    "capture_mode": capture_mode,
    "source_paths": {
        "source_jsonl": str(source_path),
        "source_line": source_line,
        "verdicts_jsonl": str(verdicts_path),
        "expectation": expectation_source,
    },
    "expected_omission": {
        "file": (expected.get("omission_claim") or {}).get("file"),
        "line_range": (expected.get("omission_claim") or {}).get("line_range"),
    },
    "curated_top_k_size": len(curated),
}
(fx / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

print(json.dumps({"capture_mode": capture_mode}))
PYEOF
)

CAPTURE_MODE=$(printf '%s' "$SUMMARY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["capture_mode"])')

PACKET_FILE="$FIXTURE_DIR/04-reverse-auditor-input.json"

# Queue mode: the lean queue row carries no captured evidence, so the packet's
# inlined_evidence is resolved fresh against current HEAD — sound only for a
# fresh emission whose substrate has not drifted since the judge saw it.
if [[ "$CAPTURE_MODE" == "queue" ]]; then
  echo "[capture-fixture] queue-mode capture: rebuilding inlined_evidence against current HEAD via reverse-auditor-inline-evidence.py" >&2
  if ! LORE_REPO_ROOT="$LORE_REPO" KDIR="$KDIR" \
      python3 "$SCRIPT_DIR/reverse-auditor-inline-evidence.py" \
      "$FIXTURE_DIR/packet-shell.tmp.json" "$PACKET_FILE" \
      --lore-repo "$LORE_REPO" --kdir "$KDIR"; then
    rm -rf "$FIXTURE_DIR"
    die "inline-evidence resolution failed; fixture not created"
  fi
  rm -f "$FIXTURE_DIR/packet-shell.tmp.json"
fi

# Worktree-integrity check on the files the packet's evidence was assembled
# from. Fails closed unless --allow-dirty-worktree.
EVIDENCE_FILES=$(python3 - "$PACKET_FILE" << 'PYEOF'
import json, sys
packet = json.load(open(sys.argv[1]))
ie = packet.get("inlined_evidence") or {}
files = []
for w in ie.get("claim_windows") or []:
    if w.get("file"):
        files.append(w["file"])
for h in ie.get("diff_hunks") or []:
    if h.get("file"):
        files.append(h["file"])
print("\n".join(dict.fromkeys(files)))
PYEOF
)

DIRTY_PATHS=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  for repo in "$LORE_REPO" "$KDIR"; do
    case "$f" in
      "$repo"/*)
        rel="${f#"$repo"/}"
        status=$(git -C "$repo" status --porcelain -- "$rel" 2>/dev/null || true)
        if [[ -n "$status" ]]; then
          DIRTY_PATHS+="$f"$'\n'
        fi
        break
        ;;
    esac
  done
done <<< "$EVIDENCE_FILES"

WORKTREE_DIRTY=false
GIT_STATUS_PORCELAIN=$(git -C "$LORE_REPO" status --porcelain 2>/dev/null || true)
if [[ -n "$DIRTY_PATHS" ]]; then
  WORKTREE_DIRTY=true
  if [[ "$ALLOW_DIRTY" -ne 1 ]]; then
    rm -rf "$FIXTURE_DIR"
    echo "[capture-fixture] Error: worktree is dirty for evidence file(s):" >&2
    printf '%s' "$DIRTY_PATHS" | sed 's/^/  /' >&2
    echo "[capture-fixture] Commit or stash, or pass --allow-dirty-worktree to capture anyway." >&2
    exit 1
  fi
  echo "[capture-fixture] warning: capturing with dirty worktree (recorded in provenance)" >&2
fi

# --- Provenance ---
CAPTURED_AT_SHA=$(git -C "$LORE_REPO" rev-parse HEAD 2>/dev/null || echo "unknown")
CAPTURED_AT_BRANCH=$(git -C "$LORE_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
CAPTURED_AT_MERGE_BASE=$(git -C "$LORE_REPO" merge-base HEAD main 2>/dev/null || echo "unknown")
CAPTURED_AT_ISO=$(timestamp_iso)
MODEL_VARIANT=$(resolve_model_for_role judge)
SCHEMA_FILE="$SCRIPT_DIR/judge-schemas/reverse-auditor-output.schema.json"
SCHEMA_VERSION=$(shasum -a 256 "$SCHEMA_FILE" | cut -c1-12)
RA_TEMPLATE=$(resolve_agent_template reverse-auditor)
TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "$RA_TEMPLATE")
INSTALL_TARGET=$(readlink "$HOME/.lore/scripts" 2>/dev/null || echo "$SCRIPT_DIR")
LORE_INSTALL_SHA=$(git -C "$(dirname "$INSTALL_TARGET")" rev-parse HEAD 2>/dev/null || echo "unknown")
PACKET_CONTENT_HASH=$(shasum -a 256 "$PACKET_FILE" | cut -d' ' -f1)

CAPTURED_AT_SHA="$CAPTURED_AT_SHA" CAPTURED_AT_BRANCH="$CAPTURED_AT_BRANCH" \
CAPTURED_AT_MERGE_BASE="$CAPTURED_AT_MERGE_BASE" CAPTURED_AT_ISO="$CAPTURED_AT_ISO" \
MODEL_VARIANT="$MODEL_VARIANT" SCHEMA_VERSION="$SCHEMA_VERSION" \
TEMPLATE_VERSION="$TEMPLATE_VERSION" LORE_INSTALL_SHA="$LORE_INSTALL_SHA" \
WORKTREE_DIRTY="$WORKTREE_DIRTY" GIT_STATUS_PORCELAIN="$GIT_STATUS_PORCELAIN" \
PACKET_CONTENT_HASH="$PACKET_CONTENT_HASH" CAPTURE_MODE="$CAPTURE_MODE" \
python3 - "$FIXTURE_DIR/provenance.json" << 'PYEOF'
import json, os, sys
prov = {
    "captured_at_sha": os.environ["CAPTURED_AT_SHA"],
    "captured_at_branch": os.environ["CAPTURED_AT_BRANCH"],
    "captured_at_merge_base_sha": os.environ["CAPTURED_AT_MERGE_BASE"],
    "captured_at_iso": os.environ["CAPTURED_AT_ISO"],
    "model_variant": os.environ["MODEL_VARIANT"],
    "schema_version": os.environ["SCHEMA_VERSION"],
    "template_version": os.environ["TEMPLATE_VERSION"],
    "lore_install_sha": os.environ["LORE_INSTALL_SHA"],
    "worktree_dirty": os.environ["WORKTREE_DIRTY"] == "true",
    "git_status_porcelain": os.environ["GIT_STATUS_PORCELAIN"],
    "packet_content_hash": os.environ["PACKET_CONTENT_HASH"],
    "capture_mode": os.environ["CAPTURE_MODE"],
}
open(sys.argv[1], "w").write(json.dumps(prov, indent=2) + "\n")
PYEOF

if [[ -n "$NOTE" ]]; then
  python3 - "$FIXTURE_DIR/manifest.json" "$NOTE" << 'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
m["note"] = sys.argv[2]
open(sys.argv[1], "w").write(json.dumps(m, indent=2) + "\n")
PYEOF
fi

CAPTURE_OK=1
echo "[capture-fixture] captured '$FIXTURE_ID' (mode=$CAPTURE_MODE, template=$TEMPLATE_VERSION, model=$MODEL_VARIANT)" >&2
echo "$FIXTURE_DIR"
