#!/usr/bin/env bash
# audit-artifact.sh — Route a producer artifact through the settlement judges.
#
# All three judges are wired: correctness-gate (task #12), curator (task #17),
# and reverse-auditor (task #22). The reverse-auditor emission is routed
# through scripts/grounding-preflight.py and persisted via
# scripts/audit-queue-route.sh (when a work-item slug resolves) or the owning
# sidecar directory otherwise.
#
# Contract: the canonical input/output contract lives at
#   $KDIR/architecture/audit-pipeline/contract.md
# Scripts and judge templates cite that file rather than duplicating field
# lists inline. Any divergence between this script and the contract doc
# is a bug in this script.
#
# Usage:
#   lore audit <artifact-id> [--kdir <path>] [--json] [--dry-run]
#                             [--gate-output-file <path>]
#                             [--curator-output-file <path>]
#                             [--reverse-auditor-output-file <path>]
#                             [--skip-scorecard]
#
# Exits:
#   0  artifact resolved, judges ran (or --dry-run succeeded)
#   1  usage error (missing <artifact-id>, unknown flag, artifact unresolvable)
#   2  judge contract violation (judge output failed shape validator)
#   3  grounding preflight failed on reverse-auditor output
#  ≥64 reserved for future judge-liveness failures
#
# Correctness-gate invocation model:
#   The judge template at `agents/correctness-gate.md` is an agent prompt
#   (Claude Code Task-tool conventions). A bash script cannot directly
#   spawn it. Two integration modes are supported:
#
#   1. **Orchestrator injection** (`--gate-output-file <path>`): the caller
#      (a Claude Code skill like /retro, a Stop hook, or a test harness)
#      runs the judge via whatever spawn mechanism it has, captures the
#      judge's stdout as JSON, writes it to a file, and passes that file
#      path. This script validates the shape, persists verdicts, and
#      appends scorecard rows. This is the primary path in automated
#      pipelines and the only path exercised by tests.
#
#   2. **headless_runner fallback** (no flag): if the active harness's
#      `headless_runner` capability is `full|partial|fallback` (i.e.,
#      anything but `none`) and `claude` is on PATH (T39/T40 will route
#      this through the per-harness adapter binary), the script shells
#      out to the harness's headless single-turn surface with the agent
#      body appended as the system prompt and the resolved input object
#      as the user prompt (consistent with
#      `scripts/judge-batch-candidates.sh` conventions). Output is
#      captured to a tmp file and processed identically to mode 1.
#      Without a working headless surface and without
#      `--gate-output-file`, the script fails with exit 1 (or a clear
#      error from `headless_runner_invoke`) and refuses to proceed.
#      The model is resolved from role `judge` via
#      `resolve_model_for_role` — `--model <name>` overrides for one
#      invocation. The agent template is resolved via
#      `resolve_agent_template <name>` rather than hardcoding
#      `~/.claude/agents/<name>.md`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

ARTIFACT_ID=""
KDIR_OVERRIDE=""
JSON_MODE=0
DRY_RUN=0
GATE_OUTPUT_FILE=""
CURATOR_OUTPUT_FILE=""
REVERSE_AUDITOR_OUTPUT_FILE=""
SKIP_SCORECARD=0
PRIORITY_CLAIMS_FILE=""
# JUDGE_MODEL stays empty until after arg parsing; resolution from the
# `judge` role runs after we know whether all three judges might be
# spawned via the headless runner. The --model flag (added in T38) lets
# the operator override the role binding for one invocation.
JUDGE_MODEL=""

# headless_runner_invoke <system_prompt_file> <user_prompt_string> <output_file>
#
# Spawn the active harness's headless single-turn agent and capture its
# stdout into <output_file>. Today only claude-code is wired; codex and
# opencode currently route through the same `claude` binary when their
# `headless_runner` cell is `full` AND the operator has `claude` on
# PATH (opencode/codex headless surfaces with provider-native binaries
# land in T39/T40 along with adapters/agents/{opencode,codex}.sh).
#
# Returns 0 on success, non-zero on subprocess failure. Stderr is
# silenced because callers pattern-match warning/error strings on it.
headless_runner_invoke() {
  local system_prompt_file="$1"
  local user_prompt="$2"
  local output_file="$3"

  # Capability gate. The capability cells are the source of truth — if
  # the active harness reports `none`, we refuse rather than silently
  # falling through to claude.
  local cap
  cap=$(framework_capability headless_runner 2>/dev/null) || cap="none"
  if [[ "$cap" == "none" ]]; then
    echo "[audit] Error: active framework reports headless_runner=none — cannot spawn judges via direct invocation." >&2
    echo "[audit]   Supply --gate-output-file / --curator-output-file / --reverse-auditor-output-file to inject pre-computed judge outputs." >&2
    return 64
  fi

  # claude-code, codex, and opencode all expose a `claude`-compatible
  # headless surface today (claude-code natively; opencode reads
  # ~/.claude/skills natively; codex is the gap that T40 closes). The
  # claude binary is the load-bearing dispatch primitive until the
  # orchestration adapters in T39/T40 land — at that point this helper
  # routes through adapters/agents/<framework>.sh runner subcommand.
  if ! command -v claude >/dev/null 2>&1; then
    echo "[audit] Error: claude CLI not found on PATH — cannot spawn judges." >&2
    return 64
  fi

  printf '%s' "$user_prompt" | claude -p \
    --append-system-prompt "$(cat "$system_prompt_file")" \
    --model "$JUDGE_MODEL" \
    --output-format text \
    --max-turns 1 \
    > "$output_file" 2>/dev/null
}

usage() {
  cat >&2 <<EOF
lore audit — route a producer artifact through the settlement judges

Usage: lore audit <artifact-id> [--kdir <path>] [--json] [--dry-run]
                                [--gate-output-file <path>]
                                [--curator-output-file <path>]
                                [--reverse-auditor-output-file <path>]
                                [--skip-scorecard]
                                [--priority-claims <path>]

Arguments:
  <artifact-id>    Work-item slug or absolute path to a supported artifact
                   (lens-findings.json, plan-assertions, worker-observations).

Options:
  --kdir <path>              Override resolved knowledge directory.
  --json                     Emit JSON on stdout (one top-level object).
  --dry-run                  Resolve artifact and enumerate candidates without
                             spawning any judge. Prints the resolved input.
  --gate-output-file P       Read correctness-gate output JSON from P instead
                             of invoking \`claude -p\`. Used by test harnesses
                             and by orchestrators that spawn the judge
                             themselves.
  --curator-output-file P    Read curator output JSON from P. Same conventions
                             as --gate-output-file. Only consulted when the
                             correctness-gate stage produced ≥1 verified
                             verdict (curator is skipped otherwise).
  --reverse-auditor-output-file P
                             Read reverse-auditor output JSON from P. Same
                             conventions as --gate-output-file. Only consulted
                             when the curator stage produced ≥1 selected
                             claim (reverse-auditor is skipped otherwise).
  --skip-scorecard           Persist verdicts but do not append scorecard rows.
                             Used by tests to exercise shape validation
                             without polluting the scorecard substrate.
  --priority-claims P        Read a JSON array of claim_id strings from P and
                             pre-filter claim_payload to that subset before
                             judge 1. When absent, behavior is unchanged.
                             Validation and filtering are wired in later phases.
  --model <model>            Override resolve_model_for_role judge for this
                             invocation. All three judges share the same model
                             unless they are injected via the --*-output-file
                             flags above. When absent and no role binding is
                             set, the script attempts the role lookup and
                             refuses to spawn judges if neither resolves.
  -h, --help                 Show this help.

Contract: see \$KDIR/architecture/audit-pipeline/contract.md for the canonical
input object shape, per-judge output shapes, scorecard-row mapping, and exit
codes.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --kdir)
      KDIR_OVERRIDE="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --gate-output-file)
      GATE_OUTPUT_FILE="$2"
      shift 2
      ;;
    --curator-output-file)
      CURATOR_OUTPUT_FILE="$2"
      shift 2
      ;;
    --reverse-auditor-output-file)
      REVERSE_AUDITOR_OUTPUT_FILE="$2"
      shift 2
      ;;
    --skip-scorecard)
      SKIP_SCORECARD=1
      shift
      ;;
    --priority-claims)
      PRIORITY_CLAIMS_FILE="$2"
      shift 2
      ;;
    --model)
      [[ $# -lt 2 ]] && { echo "[audit] Error: --model requires a value" >&2; exit 1; }
      JUDGE_MODEL="$2"
      shift 2
      ;;
    -*)
      echo "[audit] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -z "$ARTIFACT_ID" ]]; then
        ARTIFACT_ID="$1"
        shift
      else
        echo "[audit] Error: unexpected positional argument '$1'" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$ARTIFACT_ID" ]]; then
  echo "[audit] Error: <artifact-id> is required" >&2
  usage
  exit 1
fi

# --- Resolve judge model from role ---
# All three judges (correctness-gate, curator, reverse-auditor) run as
# role `judge`. The single resolution applies to every judge invocation
# unless --model overrode it. Resolution is deferred from script load
# (so --help and --dry-run paths that never spawn judges don't require
# a binding) only inasmuch as we resolve it after positional argument
# validation; the resolved value is required by the time any judge
# runs. When --gate-output-file (and curator/reverse-auditor variants)
# inject pre-computed outputs, the resolved JUDGE_MODEL is unused — the
# script does not error, since the test-injection path bypasses the
# runner entirely.
if [[ -z "$JUDGE_MODEL" ]] && [[ -z "$GATE_OUTPUT_FILE" || -z "$CURATOR_OUTPUT_FILE" || -z "$REVERSE_AUDITOR_OUTPUT_FILE" ]]; then
  if ! JUDGE_MODEL=$(resolve_model_for_role judge 2>/dev/null) || [[ -z "$JUDGE_MODEL" ]]; then
    # Soft-fail: only error if the judge actually needs to run. The
    # gate/curator/reverse-auditor blocks below check JUDGE_MODEL
    # before invoking the runner; when all three are injected via
    # --*-output-file, the role binding is unnecessary.
    JUDGE_MODEL=""
  fi
fi

# --- Resolve knowledge directory ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR=$(resolve_knowledge_dir)
fi

if [[ ! -d "$KDIR" ]]; then
  echo "[audit] Error: knowledge directory not found: $KDIR" >&2
  exit 1
fi

# --- Validate --priority-claims file (D3 pre-filter gate) ---
# When --priority-claims <path> is supplied, the file must:
#   1. exist on disk
#   2. parse as a JSON array of strings (claim_id values)
#   3. contain at least one entry
# When the flag is absent ($PRIORITY_CLAIMS_FILE empty), this block is a no-op
# and behavior is bit-for-bit identical to pre-flag runs. Filtering itself is
# wired in a subsequent task — this is the validation gate only.
if [[ -n "$PRIORITY_CLAIMS_FILE" ]]; then
  if [[ ! -f "$PRIORITY_CLAIMS_FILE" ]]; then
    echo "[audit] priority-claims file not found: $PRIORITY_CLAIMS_FILE" >&2
    exit 1
  fi
  if ! jq -e 'type == "array" and all(.[]; type == "string")' "$PRIORITY_CLAIMS_FILE" >/dev/null 2>&1; then
    echo "[audit] priority-claims must be a JSON array of claim_id strings" >&2
    exit 1
  fi
  if ! jq -e 'length > 0' "$PRIORITY_CLAIMS_FILE" >/dev/null 2>&1; then
    echo "[audit] priority-claims array is empty; supply at least one claim_id" >&2
    exit 1
  fi
fi

# --- Resolve artifact path ---
# Precedence:
#   1. absolute path that exists
#   2. $KDIR/_work/<slug>/ directory
#   3. $KDIR/_followups/<slug>/ directory
# Wired artifact types: lens-findings, worker-observations, plan-assertions.
# spec-investigation is deferred (D7). Type refinement runs after path resolution
# and sets LENS_FINDINGS_PATH / WORKER_OBSERVATIONS_PATH / PLAN_ASSERTIONS_PATH.

ARTIFACT_PATH=""
ARTIFACT_TYPE=""

if [[ -f "$ARTIFACT_ID" || -d "$ARTIFACT_ID" ]]; then
  ARTIFACT_PATH="$ARTIFACT_ID"
  ARTIFACT_TYPE="path-provided"
elif [[ -d "$KDIR/_work/$ARTIFACT_ID" ]]; then
  ARTIFACT_PATH="$KDIR/_work/$ARTIFACT_ID"
  ARTIFACT_TYPE="work-item"
elif [[ -d "$KDIR/_followups/$ARTIFACT_ID" ]]; then
  ARTIFACT_PATH="$KDIR/_followups/$ARTIFACT_ID"
  ARTIFACT_TYPE="followup"
else
  echo "[audit] Error: could not resolve artifact-id '$ARTIFACT_ID'" >&2
  echo "[audit]   Tried: \$ARTIFACT_ID as path, \$KDIR/_work/\$ARTIFACT_ID, \$KDIR/_followups/\$ARTIFACT_ID" >&2
  exit 1
fi

# --- Artifact-type refinement ---
# Explicit file paths (path-provided) select their matching artifact type
# unconditionally. Directory detection order: lens-findings, worker-observations,
# plan-assertions; first match wins (latest-evidence wins for dirs with multiple
# files — execution-log.md beats plan.md). spec-investigation is deferred (D7).
LENS_FINDINGS_PATH=""
WORKER_OBSERVATIONS_PATH=""
PLAN_ASSERTIONS_PATH=""
if [[ "$ARTIFACT_TYPE" == "followup" && -f "$ARTIFACT_PATH/lens-findings.json" ]]; then
  LENS_FINDINGS_PATH="$ARTIFACT_PATH/lens-findings.json"
  ARTIFACT_TYPE="lens-findings"
elif [[ "$ARTIFACT_TYPE" == "path-provided" ]]; then
  if [[ "$ARTIFACT_PATH" == *"/lens-findings.json" && -f "$ARTIFACT_PATH" ]]; then
    LENS_FINDINGS_PATH="$ARTIFACT_PATH"
    ARTIFACT_TYPE="lens-findings"
  elif [[ "$ARTIFACT_PATH" == *"/execution-log.md" && -f "$ARTIFACT_PATH" ]]; then
    WORKER_OBSERVATIONS_PATH="$ARTIFACT_PATH"
    ARTIFACT_TYPE="worker-observations"
  elif [[ "$ARTIFACT_PATH" == *"/plan.md" && -f "$ARTIFACT_PATH" ]]; then
    PLAN_ASSERTIONS_PATH="$ARTIFACT_PATH"
    ARTIFACT_TYPE="plan-assertions"
  elif [[ -d "$ARTIFACT_PATH" && -f "$ARTIFACT_PATH/lens-findings.json" ]]; then
    LENS_FINDINGS_PATH="$ARTIFACT_PATH/lens-findings.json"
    ARTIFACT_TYPE="lens-findings"
  elif [[ -d "$ARTIFACT_PATH" && -f "$ARTIFACT_PATH/execution-log.md" ]]; then
    WORKER_OBSERVATIONS_PATH="$ARTIFACT_PATH/execution-log.md"
    ARTIFACT_TYPE="worker-observations"
  elif [[ -d "$ARTIFACT_PATH" && -f "$ARTIFACT_PATH/plan.md" ]]; then
    PLAN_ASSERTIONS_PATH="$ARTIFACT_PATH/plan.md"
    ARTIFACT_TYPE="plan-assertions"
  fi
elif [[ "$ARTIFACT_TYPE" == "work-item" ]]; then
  if [[ -f "$ARTIFACT_PATH/execution-log.md" ]]; then
    WORKER_OBSERVATIONS_PATH="$ARTIFACT_PATH/execution-log.md"
    ARTIFACT_TYPE="worker-observations"
  elif [[ -f "$ARTIFACT_PATH/plan.md" ]]; then
    PLAN_ASSERTIONS_PATH="$ARTIFACT_PATH/plan.md"
    ARTIFACT_TYPE="plan-assertions"
  fi
fi

# --- Build the resolved input object once (per contract.md) ---
# Used by both the dry-run path and the judge invocation path. Per
# architecture/audit-pipeline/contract.md the shape is:
#   {artifact_id, artifact_type, artifact_path, kdir,
#    claim_payload[], referenced_files[], change_context, ...}
# Phase 1 populates claim_payload from lens-findings.json. referenced_files
# and change_context are still stubbed (non-lens-findings artifact types
# land with later pilots; branch-aware reconciliation per Appendix B of the
# plan is future work).
build_resolved_input() {
  local dry_run_flag="$1"  # "true" or "false"
  python3 - "$ARTIFACT_ID" "$ARTIFACT_PATH" "$ARTIFACT_TYPE" "$KDIR" "$LENS_FINDINGS_PATH" "$PLAN_ASSERTIONS_PATH" "$WORKER_OBSERVATIONS_PATH" "$dry_run_flag" << 'PYEOF'
import json, re, sys
artifact_id, artifact_path, artifact_type, kdir, lens_findings_path, plan_assertions_path, worker_observations_path, dry_run_flag = sys.argv[1:9]

out = {
    "artifact_id": artifact_id,
    "artifact_path": artifact_path,
    "artifact_type": artifact_type,
    "kdir": kdir,
}
if dry_run_flag == "true":
    out["dry_run"] = True
    out["note"] = "See architecture/audit-pipeline/contract.md for the full resolved-input object shape."

# Populate work_item from path when artifact lives under $KDIR/_work/<slug>/.
# Required for audit-queue-route.sh canonical routing (vs. direct-write fallback).
_work_match = re.search(r'/_work/([^/]+)(?:/|$)', artifact_path)
if _work_match:
    out["work_item"] = _work_match.group(1)

# Lens-findings pilot: parse findings into claim_payload per the contract.
# Per-finding fields follow the resolved-input shape in
# architecture/audit-pipeline/contract.md — claim_id is finding-<i>, the
# per-finding file/line/body/severity/lens/grounding/selected fields are
# mapped through, and missing grounding on severity=question/info is
# preserved (only blocking/suggestion require grounding per
# create-followup.sh validation).
if lens_findings_path:
    try:
        with open(lens_findings_path) as fh:
            raw = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        out["lens_findings_error"] = f"{type(e).__name__}: {e}"
    else:
        findings = raw.get("findings", []) or []
        claims = []
        for i, f in enumerate(findings):
            claim = {
                "claim_id": f"finding-{i}",
                "claim_text": f.get("title", "") + (": " + f.get("body", "") if f.get("body") else ""),
                "file": f.get("file") or None,
                "line_range": (f"{f.get('line')}-{f.get('line')}" if f.get("line") else None),
                "exact_snippet": None,
                "normalized_snippet_hash": None,
                "falsifier": f.get("grounding") or None,
                "severity_hint": f.get("severity"),
                "grounding": f.get("grounding") or None,
                "lens": f.get("lens"),
                "selected": f.get("selected"),
            }
            claims.append(claim)
        out["lens_findings_path"] = lens_findings_path
        out["claim_payload"] = claims
        out["claim_count"] = len(claims)
        out["pr"] = raw.get("pr")
        # sidecar work_item takes precedence over path-derived value; path-derived
        # value is the fallback when the JSON omits it.
        if raw.get("work_item"):
            out["work_item"] = raw["work_item"]

elif plan_assertions_path:
    V1_REQUIRED = ("claim", "file", "line_range", "exact_snippet", "normalized_snippet_hash", "falsifier", "significance")

    def _extract_field(entry_text, field):
        # Match field at line start with optional leading whitespace or '- ' prefix.
        m = re.search(rf'(?m)^(?:[ \t]*-\s*|[ \t]+){re.escape(field)}\s*:\s*(.*)', entry_text)
        return m.group(1).strip().strip('"\'') or None if m else None

    def _has_field(entry_text, field):
        return bool(re.search(rf'(?m)^(?:[ \t]*-\s*|[ \t]+){re.escape(field)}\s*:', entry_text))

    try:
        with open(plan_assertions_path) as fh:
            text = fh.read()
    except OSError as e:
        print(f"[audit] extractor: could not read plan.md — {e}", file=sys.stderr)
        sys.exit(1)

    inv_m = re.search(r'(?m)^##\s+Investigations\b', text)
    if not inv_m:
        print("[audit] extractor: no ## Investigations section found in plan.md", file=sys.stderr)
        sys.exit(1)

    # Bound ## Investigations region at the next ## heading.
    inv_start = inv_m.end()
    next_h2 = re.search(r'(?m)^##\s+(?!#)', text[inv_start:])
    inv_region = text[inv_start: inv_start + next_h2.start()] if next_h2 else text[inv_start:]

    # Producer provenance from first Template-version: line in the region.
    tv_m = re.search(r'(?m)^Template-version:\s*(\S+)', inv_region)
    producer_template_version = tv_m.group(1).strip() if tv_m else "unknown"

    claims = []
    skipped = []
    claim_index = 0

    topic_starts = [m.start() for m in re.finditer(r'(?m)^###\s+', inv_region)]
    for t_idx, t_start in enumerate(topic_starts):
        t_end = topic_starts[t_idx + 1] if t_idx + 1 < len(topic_starts) else len(inv_region)
        topic_block = inv_region[t_start:t_end]

        assertions_m = re.search(r'\*\*Assertions:\*\*', topic_block)
        if not assertions_m:
            continue
        assertions_region = topic_block[assertions_m.end():]
        next_bold = re.search(r'\n\*\*[A-Z][a-zA-Z ]+:\*\*', assertions_region)
        if next_bold:
            assertions_region = assertions_region[:next_bold.start()]

        entry_starts = [m.start() for m in re.finditer(r'(?m)^\s*-\s*claim\s*:', assertions_region)]
        for e_idx, e_start in enumerate(entry_starts):
            e_end = entry_starts[e_idx + 1] if e_idx + 1 < len(entry_starts) else len(assertions_region)
            entry_text = assertions_region[e_start:e_end]

            missing = [f for f in V1_REQUIRED if not _has_field(entry_text, f)]
            if missing:
                skipped.append(f"assertion-{claim_index} missing: {', '.join(missing)}")
                claim_index += 1
                continue

            claim = {
                "claim_id": f"assertion-{claim_index}",
                "claim_text": _extract_field(entry_text, "claim"),
                "file": _extract_field(entry_text, "file"),
                "line_range": _extract_field(entry_text, "line_range"),
                "exact_snippet": _extract_field(entry_text, "exact_snippet"),
                "normalized_snippet_hash": _extract_field(entry_text, "normalized_snippet_hash"),
                "falsifier": _extract_field(entry_text, "falsifier"),
                "severity_hint": _extract_field(entry_text, "significance"),
            }
            for opt in ("context_before", "context_after", "symbol_anchor", "extends_observation"):
                v = _extract_field(entry_text, opt)
                if v is not None:
                    claim[opt] = v
            claims.append(claim)
            claim_index += 1

    if not claims:
        reason = "; ".join(skipped) if skipped else "no **Assertions:** entries found in ## Investigations"
        print(f"[audit] extractor: {reason}", file=sys.stderr)
        sys.exit(1)

    out["plan_assertions_path"] = plan_assertions_path
    out["claim_payload"] = claims
    out["claim_count"] = len(claims)
    out["producer_role"] = "researcher"
    out["producer_template_version"] = producer_template_version
    if skipped:
        out["plan_assertions_skipped"] = skipped

elif worker_observations_path:
    V1_REQUIRED = ("claim", "file", "line_range", "exact_snippet", "normalized_snippet_hash", "falsifier", "significance")

    def _extract_field(entry_text, field):
        m = re.search(rf'(?m)^(?:[ \t]*-\s*|[ \t]+){re.escape(field)}\s*:\s*(.*)', entry_text)
        return m.group(1).strip().strip('"\'') or None if m else None

    def _has_field(entry_text, field):
        return bool(re.search(rf'(?m)^(?:[ \t]*-\s*|[ \t]+){re.escape(field)}\s*:', entry_text))

    try:
        with open(worker_observations_path) as fh:
            text = fh.read()
    except OSError as e:
        print(f"[audit] extractor: could not read execution-log.md — {e}", file=sys.stderr)
        sys.exit(1)

    # Producer provenance: first Template-version: line in the file.
    tv_m = re.search(r'(?m)^Template-version:\s*(\S+)', text)
    producer_template_version = tv_m.group(1).strip() if tv_m else "unknown"

    claims = []
    skipped = []
    claim_index = 0

    # Collect all **Observations:** blocks — may be fenced (```yaml...```) or plain.
    # Strategy: find each **Observations:** marker, then consume until the next
    # ## section heading or end of file. Within each block, handle both a leading
    # ```yaml fence and raw YAML.
    for obs_m in re.finditer(r'\*\*Observations:\*\*[ \t]*\n', text):
        region_start = obs_m.end()
        next_h2 = re.search(r'(?m)^##\s+', text[region_start:])
        region = text[region_start: region_start + next_h2.start()] if next_h2 else text[region_start:]

        # Strip optional leading yaml code fence.
        fence_m = re.match(r'[ \t]*```ya?ml\n(.*?)```', region, re.DOTALL)
        if fence_m:
            region = fence_m.group(1)

        entry_starts = [m.start() for m in re.finditer(r'(?m)^\s*-\s*claim\s*:', region)]
        for e_idx, e_start in enumerate(entry_starts):
            e_end = entry_starts[e_idx + 1] if e_idx + 1 < len(entry_starts) else len(region)
            entry_text = region[e_start:e_end]

            missing = [f for f in V1_REQUIRED if not _has_field(entry_text, f)]
            if missing:
                skipped.append(f"observation-{claim_index} missing: {', '.join(missing)}")
                claim_index += 1
                continue

            claim = {
                "claim_id": f"observation-{claim_index}",
                "claim_text": _extract_field(entry_text, "claim"),
                "file": _extract_field(entry_text, "file"),
                "line_range": _extract_field(entry_text, "line_range"),
                "exact_snippet": _extract_field(entry_text, "exact_snippet"),
                "normalized_snippet_hash": _extract_field(entry_text, "normalized_snippet_hash"),
                "falsifier": _extract_field(entry_text, "falsifier"),
                "severity_hint": _extract_field(entry_text, "significance"),
            }
            for opt in ("context_before", "context_after", "symbol_anchor"):
                v = _extract_field(entry_text, opt)
                if v is not None:
                    claim[opt] = v
            claims.append(claim)
            claim_index += 1

    if not claims:
        reason = "; ".join(skipped) if skipped else "no **Observations:** entries found in execution-log.md"
        print(f"[audit] extractor: {reason}", file=sys.stderr)
        sys.exit(1)

    out["worker_observations_path"] = worker_observations_path
    out["claim_payload"] = claims
    out["claim_count"] = len(claims)
    out["producer_role"] = "worker"
    out["producer_template_version"] = producer_template_version
    if skipped:
        out["worker_observations_skipped"] = skipped

print(json.dumps(out, indent=2))
PYEOF
}

# --- Dry-run emits the resolved input object and exits ---
if [[ $DRY_RUN -eq 1 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    build_resolved_input "true"
  else
    echo "[audit] dry-run:"
    echo "[audit]   artifact_id:   $ARTIFACT_ID"
    echo "[audit]   artifact_path: $ARTIFACT_PATH"
    echo "[audit]   artifact_type: $ARTIFACT_TYPE"
    echo "[audit]   kdir:          $KDIR"
    if [[ -n "$LENS_FINDINGS_PATH" ]]; then
      echo "[audit]   lens_findings: $LENS_FINDINGS_PATH"
      _claim_count=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get("findings",[]) or []))' "$LENS_FINDINGS_PATH" 2>/dev/null || echo "?")
      echo "[audit]   claim_count:   $_claim_count (per-finding → claim_id=finding-<i>)"
    fi
    if [[ -n "$PLAN_ASSERTIONS_PATH" ]]; then
      echo "[audit]   plan_assertions: $PLAN_ASSERTIONS_PATH"
      _claim_count=$(python3 -c '
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"\*\*Assertions:\*\*\s*\n```ya?ml\n(.*?)```", text, re.DOTALL)
if m:
    block = m.group(1)
    print(len([l for l in block.splitlines() if l.strip().startswith("- claim:")]))
else:
    print("?")
' "$PLAN_ASSERTIONS_PATH" 2>/dev/null || echo "?")
      echo "[audit]   claim_count:   $_claim_count (per-assertion → claim_id=assertion-<i>)"
    fi
    if [[ -n "$WORKER_OBSERVATIONS_PATH" ]]; then
      echo "[audit]   worker_observations: $WORKER_OBSERVATIONS_PATH"
      _claim_count=$(python3 -c '
import re, sys
text = open(sys.argv[1]).read()
blocks = re.findall(r"```ya?ml\n(.*?)```", text, re.DOTALL)
total = sum(len([l for l in b.splitlines() if l.strip().startswith("- claim:")]) for b in blocks)
print(total if total > 0 else "?")
' "$WORKER_OBSERVATIONS_PATH" 2>/dev/null || echo "?")
      echo "[audit]   claim_count:   $_claim_count (per-observation → claim_id=observation-<i>)"
    fi
    echo "[audit] Stub implementation — no judges spawned."
    echo "[audit] See $KDIR/architecture/audit-pipeline/contract.md for the full pipeline."
  fi
  exit 0
fi

# --- Judge pipeline ---
# Judge 1 (correctness-gate) is wired (task #12). Judge 2 (curator, task #17)
# and Judge 3 (reverse-auditor, task #22) land with their own wiring tasks
# and replace the placeholders below.

if ! CORRECTNESS_GATE_TEMPLATE=$(resolve_agent_template correctness-gate 2>/dev/null); then
  echo "[audit] Error: correctness-gate agent template not resolvable via resolve_agent_template." >&2
  echo "[audit]   Run install.sh to populate the canonical agents/ directory and the active harness's agent install path." >&2
  exit 1
fi

GATE_TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "$CORRECTNESS_GATE_TEMPLATE")

# Build the resolved input object and stash it in a tmp file.
RESOLVED_INPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/audit-input-XXXXXX.json")
GATE_RAW_TMP=""
CURATOR_RAW_TMP=""
REVERSE_AUDITOR_RAW_TMP=""
REVERSE_AUDITOR_PREFLIGHT_TMP=""
cleanup_tmp() {
  rm -f "$RESOLVED_INPUT_FILE" 2>/dev/null || true
  # Only remove *_RAW_TMP if we created them ourselves (mktemp path).
  # User-supplied --gate-output-file / --curator-output-file /
  # --reverse-auditor-output-file must never be deleted.
  if [[ -n "$GATE_RAW_TMP" ]]; then
    rm -f "$GATE_RAW_TMP" 2>/dev/null || true
  fi
  if [[ -n "$CURATOR_RAW_TMP" ]]; then
    rm -f "$CURATOR_RAW_TMP" 2>/dev/null || true
  fi
  if [[ -n "$REVERSE_AUDITOR_RAW_TMP" ]]; then
    rm -f "$REVERSE_AUDITOR_RAW_TMP" 2>/dev/null || true
  fi
  if [[ -n "$REVERSE_AUDITOR_PREFLIGHT_TMP" ]]; then
    rm -f "$REVERSE_AUDITOR_PREFLIGHT_TMP" 2>/dev/null || true
  fi
}
trap cleanup_tmp EXIT
if ! build_resolved_input "false" > "$RESOLVED_INPUT_FILE"; then
  # Extractor printed [audit] extractor: diagnostic to stderr; propagate exit.
  exit 1
fi

# --- Apply --priority-claims pre-filter (D3) ---
# When --priority-claims <path> was supplied and validated above, narrow
# claim_payload to only entries whose claim_id is in the priority list. The
# filter is transparent to downstream stages — judges receive the same
# resolved-input shape, just with a narrower claim_payload. claim_count is
# updated in place so scorecard/rollup math stays consistent. The priority
# list was already validated (non-empty JSON array of strings) in the
# validation gate above.
if [[ -n "$PRIORITY_CLAIMS_FILE" ]]; then
  _priority_narrowed=$(mktemp "${TMPDIR:-/tmp}/audit-input-narrowed-XXXXXX.json")
  if ! jq --slurpfile priority "$PRIORITY_CLAIMS_FILE" '
    ($priority[0]) as $ids
    | (.claim_payload // []) as $orig
    | .claim_payload = [ $orig[] | select(.claim_id as $cid | $ids | index($cid)) ]
    | .claim_count = (.claim_payload | length)
  ' "$RESOLVED_INPUT_FILE" > "$_priority_narrowed"; then
    rm -f "$_priority_narrowed"
    echo "[audit] Error: priority-claims filter failed (jq error)" >&2
    exit 1
  fi
  mv "$_priority_narrowed" "$RESOLVED_INPUT_FILE"
  _kept=$(jq -r '.claim_count' "$RESOLVED_INPUT_FILE")
  if [[ "$_kept" -eq 0 ]]; then
    echo "[audit] Error: priority-claims filter yielded 0 claims; no claim_id in $PRIORITY_CLAIMS_FILE matched the resolved claim_payload" >&2
    exit 1
  fi
  echo "[audit] priority-claims: narrowed claim_payload to $_kept claim(s) per $PRIORITY_CLAIMS_FILE" >&2
fi

# Short-circuit if the lens-findings parse failed — no point invoking judges.
if jq -e 'has("lens_findings_error")' "$RESOLVED_INPUT_FILE" >/dev/null 2>&1; then
  LENS_ERR=$(jq -r '.lens_findings_error' "$RESOLVED_INPUT_FILE")
  echo "[audit] Error: could not parse lens-findings.json — $LENS_ERR" >&2
  exit 1
fi

# Obtain correctness-gate output JSON.
GATE_RAW_FILE=""
if [[ -n "$GATE_OUTPUT_FILE" ]]; then
  # Mode 1: orchestrator/test injection.
  if [[ ! -f "$GATE_OUTPUT_FILE" ]]; then
    echo "[audit] Error: --gate-output-file not found: $GATE_OUTPUT_FILE" >&2
    exit 1
  fi
  GATE_RAW_FILE="$GATE_OUTPUT_FILE"
  echo "[audit] correctness-gate: reading pre-computed output from $GATE_OUTPUT_FILE" >&2
else
  # Mode 2: headless_runner direct invocation (T38 — formerly hardcoded
  # `claude -p`). Routed through the active harness's headless_runner
  # capability so codex/opencode-targeted runs honor capability
  # degradation. JUDGE_MODEL is supplied via resolve_model_for_role
  # judge unless the operator overrode with --model.
  if [[ -z "$JUDGE_MODEL" ]]; then
    # No role binding AND no --gate-output-file means the operator
    # has not chosen either integration mode. Name both so the error
    # is actionable: pass --gate-output-file (orchestrator/test
    # injection), or set a model binding so the headless runner
    # (today: `claude` on PATH) can spawn the correctness-gate judge.
    echo "[audit] Error: no model binding for role 'judge' and no --gate-output-file supplied." >&2
    echo "[audit]   Either pass --gate-output-file <path> (orchestrator-injected judge output)," >&2
    echo "[audit]   or set roles.judge in ~/.lore/config/framework.json (or pass --model <model>)" >&2
    echo "[audit]   to use the \`claude\` headless runner direct-invocation fallback." >&2
    exit 1
  fi
  GATE_RAW_TMP=$(mktemp "${TMPDIR:-/tmp}/audit-gate-output-XXXXXX.json")
  GATE_RAW_FILE="$GATE_RAW_TMP"
  GATE_SYSTEM_PROMPT_FILE="$CORRECTNESS_GATE_TEMPLATE"
  GATE_USER_PROMPT="Resolved input object (per architecture/audit-pipeline/contract.md):

$(cat "$RESOLVED_INPUT_FILE")

Emit exactly one JSON object matching the Correctness-gate output shape. No markdown fences. No prose outside the JSON."
  echo "[audit] correctness-gate: invoking headless runner (template-version: $GATE_TEMPLATE_VERSION, model: $JUDGE_MODEL)" >&2
  if ! headless_runner_invoke "$GATE_SYSTEM_PROMPT_FILE" "$GATE_USER_PROMPT" "$GATE_RAW_FILE"; then
    echo "[audit] Error: headless runner invocation failed for correctness-gate" >&2
    exit 64
  fi
fi

# Validate correctness-gate output shape per contract.md. Required:
#   judge == "correctness-gate"
#   judge_template_version present (non-empty)
#   verdicts is an array; every entry has claim_id, verdict ∈ {verified,
#     unverified, contradicted}, evidence non-empty; contradicted ⇒
#     correction non-empty; verified/unverified ⇒ correction absent or
#     empty.
GATE_SHAPE_OK=$(python3 - "$GATE_RAW_FILE" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        obj = json.load(fh)
except Exception as e:
    print(f"parse-error: {type(e).__name__}: {e}")
    sys.exit(0)

errs = []
if not isinstance(obj, dict):
    errs.append("output is not a JSON object")
else:
    if obj.get("judge") != "correctness-gate":
        errs.append(f"judge != 'correctness-gate' (got {obj.get('judge')!r})")
    if not obj.get("judge_template_version"):
        errs.append("judge_template_version missing or empty")
    verdicts = obj.get("verdicts")
    if not isinstance(verdicts, list):
        errs.append("verdicts is not an array")
    else:
        for i, v in enumerate(verdicts):
            if not isinstance(v, dict):
                errs.append(f"verdicts[{i}] is not an object")
                continue
            if not v.get("claim_id"):
                errs.append(f"verdicts[{i}].claim_id missing")
            verdict = v.get("verdict")
            if verdict not in ("verified", "unverified", "contradicted"):
                errs.append(f"verdicts[{i}].verdict invalid: {verdict!r}")
            if not v.get("evidence"):
                errs.append(f"verdicts[{i}].evidence missing/empty")
            if verdict == "contradicted":
                if not v.get("correction"):
                    errs.append(f"verdicts[{i}].correction missing on contradicted verdict")
            elif verdict in ("verified", "unverified"):
                if v.get("correction"):
                    errs.append(f"verdicts[{i}].correction must be absent/empty on {verdict} verdict")

if errs:
    print("invalid: " + "; ".join(errs))
else:
    print("ok")
PYEOF
)

if [[ "$GATE_SHAPE_OK" != "ok" ]]; then
  echo "[audit] contract violation: correctness-gate output failed shape validator" >&2
  echo "[audit]   reason: $GATE_SHAPE_OK" >&2
  echo "[audit]   raw output: $GATE_RAW_FILE" >&2
  exit 2
fi

# Persist per-claim verdicts to the artifact's settlement record (append-only).
# Resolution rules (matching contract.md "Wrapper-level side effects"):
#   - If the artifact lives under $KDIR/_work/<slug>/ (directly or via a
#     lens-findings.json sidecar), verdicts land at
#     $KDIR/_work/<slug>/verdicts/<basename>.jsonl.
#   - If the artifact lives under $KDIR/_followups/<slug>/, verdicts land at
#     $KDIR/_followups/<slug>/verdicts/<basename>.jsonl.
#   - Otherwise, verdicts land at $KDIR/_audit/verdicts/<basename>.jsonl.
# The basename is the resolved artifact path's last segment, stripped of any
# file extension, so repeated audits of the same artifact append to the same
# file.

OWNING_DIR=""
if [[ "$ARTIFACT_PATH" == "$KDIR/_work/"* ]]; then
  # $KDIR/_work/<slug>/ or $KDIR/_work/<slug>/lens-findings.json
  if [[ -d "$ARTIFACT_PATH" ]]; then
    OWNING_DIR="$ARTIFACT_PATH"
  else
    OWNING_DIR=$(dirname "$ARTIFACT_PATH")
  fi
elif [[ "$ARTIFACT_PATH" == "$KDIR/_followups/"* ]]; then
  if [[ -d "$ARTIFACT_PATH" ]]; then
    OWNING_DIR="$ARTIFACT_PATH"
  else
    OWNING_DIR=$(dirname "$ARTIFACT_PATH")
  fi
fi

if [[ -n "$OWNING_DIR" ]]; then
  VERDICTS_DIR="$OWNING_DIR/verdicts"
else
  VERDICTS_DIR="$KDIR/_audit/verdicts"
fi

mkdir -p "$VERDICTS_DIR"

# Basename stripped of extension, falling back to "artifact" for unnamed inputs.
_base=$(basename "$ARTIFACT_PATH")
_base="${_base%.*}"
if [[ -z "$_base" ]]; then
  _base="artifact"
fi
VERDICTS_FILE="$VERDICTS_DIR/${_base}.jsonl"

# One JSONL line per judge run: the full judge output with a wrapper header.
python3 - "$GATE_RAW_FILE" "$ARTIFACT_ID" "$VERDICTS_FILE" << 'PYEOF'
import json, sys, datetime
gate_file, artifact_id, verdicts_file = sys.argv[1:4]
with open(gate_file) as fh:
    obj = json.load(fh)
wrapped = {
    "artifact_id": artifact_id,
    "judge_run_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    **obj,
}
with open(verdicts_file, "a") as fh:
    fh.write(json.dumps(wrapped) + "\n")
PYEOF

# Compute + append correctness-gate scorecard rows per contract.md table:
#   factual_precision       (producer template, scored, claim-local)
#   falsifier_quality       (producer template, scored, claim-local)
#   audit_contradiction_rate(producer template, scored, claim-local)
#
# factual_precision        = verified / total
# audit_contradiction_rate = contradicted / total
# falsifier_quality        = fraction of contradicted verdicts whose correction
#                            is non-trivial (≥1 char after strip). Low-bar
#                            heuristic for now; task-14 (scorecard-row
#                            authoring) will refine the metric definition
#                            and calibration posture.
#
# Attribution: the producer template_id/version come from the artifact's
# lens-findings payload (lens-findings.json carries producer_role +
# producer_template_version on first-class write per F0 Phase 4). If those
# are missing — lens-findings from a pre-F0 producer — we fall back to
# template_id="unknown", template_version="unknown" and calibration_state
# pre-calibration, which /retro can surface but /evolve's gate rejects.

if [[ $SKIP_SCORECARD -eq 0 ]]; then
  ROWS_JSON=$(python3 - "$GATE_RAW_FILE" "$RESOLVED_INPUT_FILE" "$GATE_TEMPLATE_VERSION" << 'PYEOF'
import json, sys, datetime

gate_file, input_file, gate_template_version = sys.argv[1:4]
with open(gate_file) as fh:
    gate = json.load(fh)
with open(input_file) as fh:
    resolved = json.load(fh)

verdicts = gate.get("verdicts", [])
total = len(verdicts)
if total == 0:
    print("[]")
    sys.exit(0)

n_verified = sum(1 for v in verdicts if v.get("verdict") == "verified")
n_contradicted = sum(1 for v in verdicts if v.get("verdict") == "contradicted")
n_contradicted_with_correction = sum(
    1 for v in verdicts
    if v.get("verdict") == "contradicted" and (v.get("correction") or "").strip()
)

factual_precision = n_verified / total
audit_contradiction_rate = n_contradicted / total
# falsifier_quality: 1.0 if no contradictions (nothing to score, vacuously good);
# else fraction of contradictions that carry a non-trivial correction.
if n_contradicted == 0:
    falsifier_quality = 1.0
else:
    falsifier_quality = n_contradicted_with_correction / n_contradicted

producer_template_id = resolved.get("producer_role") or "unknown"
producer_template_version = resolved.get("producer_template_version") or "unknown"
artifact_id = resolved.get("artifact_id")
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# calibration_state: pre-calibration until task-15 marks the gate calibrated.
calibration_state = "pre-calibration"

row_base = {
    "schema_version": "1",
    "kind": "scored",
    "tier": "reusable",
    "calibration_state": calibration_state,
    "template_id": producer_template_id,
    "template_version": producer_template_version,
    "sample_size": total,
    "window_start": now,
    "window_end": now,
    "source_artifact_ids": [artifact_id] if artifact_id else [],
    "granularity": "claim-local",
    "verdict_source": "correctness-gate",
    "judge_template_version": gate_template_version,
}

rows = [
    {**row_base, "metric": "factual_precision", "value": factual_precision},
    {**row_base, "metric": "falsifier_quality", "value": falsifier_quality},
    {**row_base, "metric": "audit_contradiction_rate", "value": audit_contradiction_rate},
]
print(json.dumps(rows))
PYEOF
  )

  APPENDED_COUNT=0
  while IFS= read -r row; do
    if [[ -n "$row" ]]; then
      if bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KDIR" --row "$row" >/dev/null 2>&1; then
        APPENDED_COUNT=$((APPENDED_COUNT + 1))
      else
        echo "[audit] warning: scorecard-append rejected a row (see stderr above)" >&2
      fi
    fi
  done < <(printf '%s' "$ROWS_JSON" | jq -c '.[]?')
else
  APPENDED_COUNT=0
fi

# --- Judge 2: curator (task #17) ---
# Runs only when the correctness-gate produced ≥1 verified survivor. The
# curator selects top-k (k ∈ [1,3]) from those survivors and emits per-drop
# trivial_reason rationale. Uses the same two-mode integration model as the
# gate: --curator-output-file for orchestrator/test injection, claude -p
# fallback when neither flag nor file is supplied.
CURATOR_STAGE_RAN=0
CURATOR_APPENDED_COUNT=0
CURATOR_TEMPLATE_VERSION=""
CURATOR_RAW_FILE=""
N_SELECTED=0
N_DROPPED=0

N_VERIFIED_COUNT=$(python3 -c 'import json,sys; print(sum(1 for v in json.load(open(sys.argv[1])).get("verdicts",[]) if v.get("verdict")=="verified"))' "$GATE_RAW_FILE")

if [[ "$N_VERIFIED_COUNT" -gt 0 ]]; then
  # Decide whether the curator stage runs:
  #   - explicit --curator-output-file: yes, inject from file
  #   - no curator flag AND gate was claude-p (no --gate-output-file): yes, invoke claude -p
  #   - no curator flag AND gate was injected (--gate-output-file): no, orchestrator
  #     didn't spawn curator either — skip gracefully. Tests and orchestrators
  #     that want curator coverage must pass --curator-output-file.
  if [[ -z "$CURATOR_OUTPUT_FILE" && -n "$GATE_OUTPUT_FILE" ]]; then
    echo "[audit] curator: skipped (gate was injected but no --curator-output-file supplied)" >&2
    CURATOR_TEMPLATE=""
  elif ! CURATOR_TEMPLATE=$(resolve_agent_template curator 2>/dev/null); then
    echo "[audit] warning: curator agent template not resolvable via resolve_agent_template — skipping curator stage" >&2
    CURATOR_TEMPLATE=""
  fi

  if [[ -z "$CURATOR_TEMPLATE" ]]; then
    :  # curator skipped, fall through to report
  else
    CURATOR_TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "$CURATOR_TEMPLATE")

    if [[ -n "$CURATOR_OUTPUT_FILE" ]]; then
      if [[ ! -f "$CURATOR_OUTPUT_FILE" ]]; then
        echo "[audit] Error: --curator-output-file not found: $CURATOR_OUTPUT_FILE" >&2
        exit 1
      fi
      CURATOR_RAW_FILE="$CURATOR_OUTPUT_FILE"
      echo "[audit] curator: reading pre-computed output from $CURATOR_OUTPUT_FILE" >&2
    else
      if [[ -z "$JUDGE_MODEL" ]]; then
        echo "[audit] warning: neither --curator-output-file nor 'judge' role binding available — skipping curator stage" >&2
      else
        CURATOR_RAW_TMP=$(mktemp "${TMPDIR:-/tmp}/audit-curator-output-XXXXXX.json")
        CURATOR_RAW_FILE="$CURATOR_RAW_TMP"
        # Compose curator input: verified survivors + the original resolved input.
        CURATOR_INPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/audit-curator-input-XXXXXX.json")
        python3 - "$GATE_RAW_FILE" "$RESOLVED_INPUT_FILE" "$CURATOR_INPUT_FILE" << 'PYEOF'
import json, sys
gate_file, resolved_file, out_file = sys.argv[1:4]
with open(gate_file) as fh:
    gate = json.load(fh)
with open(resolved_file) as fh:
    resolved = json.load(fh)
verified_claim_ids = {v["claim_id"] for v in gate.get("verdicts", []) if v.get("verdict") == "verified"}
verified_claims = [c for c in resolved.get("claim_payload", []) if c.get("claim_id") in verified_claim_ids]
payload = {
    "artifact_id": resolved.get("artifact_id"),
    "artifact_type": resolved.get("artifact_type"),
    "work_item": resolved.get("work_item"),
    "verified_candidate_set": verified_claims,
    "change_context": resolved.get("change_context"),
}
with open(out_file, "w") as fh:
    json.dump(payload, fh, indent=2)
PYEOF
        CURATOR_USER_PROMPT="Curator input object (verified survivors + change context per contract.md):

$(cat "$CURATOR_INPUT_FILE")

Emit exactly one JSON object matching the Curator output shape. No markdown fences. No prose outside the JSON."
        echo "[audit] curator: invoking headless runner (template-version: $CURATOR_TEMPLATE_VERSION, model: $JUDGE_MODEL)" >&2
        if ! headless_runner_invoke "$CURATOR_TEMPLATE" "$CURATOR_USER_PROMPT" "$CURATOR_RAW_FILE"; then
          echo "[audit] warning: headless runner invocation failed for curator — skipping curator stage" >&2
          CURATOR_RAW_FILE=""
        elif [[ ! -s "$CURATOR_RAW_FILE" ]]; then
          echo "[audit] warning: headless runner produced no curator output — skipping curator stage" >&2
          CURATOR_RAW_FILE=""
        elif ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CURATOR_RAW_FILE" 2>/dev/null; then
          echo "[audit] warning: curator output is not valid JSON — skipping curator stage" >&2
          CURATOR_RAW_FILE=""
        fi
        rm -f "$CURATOR_INPUT_FILE" 2>/dev/null || true
      fi
    fi

    if [[ -n "$CURATOR_RAW_FILE" ]]; then
      # Validate curator output shape per contract.md:
      #   judge == "curator"
      #   judge_template_version non-empty
      #   selected is an array; every entry has claim_id + selection_rationale
      #   dropped is an array; every entry has claim_id + drop_rationale (non-empty)
      #   selected.length ∈ [1, 3] if verified_candidate_set was non-empty
      CURATOR_SHAPE_OK=$(python3 - "$CURATOR_RAW_FILE" "$N_VERIFIED_COUNT" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        obj = json.load(fh)
except Exception as e:
    print(f"parse-error: {type(e).__name__}: {e}")
    sys.exit(0)
n_verified = int(sys.argv[2])

errs = []
if not isinstance(obj, dict):
    errs.append("output is not a JSON object")
else:
    if obj.get("judge") != "curator":
        errs.append(f"judge != 'curator' (got {obj.get('judge')!r})")
    if not obj.get("judge_template_version"):
        errs.append("judge_template_version missing or empty")
    selected = obj.get("selected")
    dropped = obj.get("dropped")
    if not isinstance(selected, list):
        errs.append("selected is not an array")
    else:
        for i, s in enumerate(selected):
            if not isinstance(s, dict):
                errs.append(f"selected[{i}] is not an object")
                continue
            if not s.get("claim_id"):
                errs.append(f"selected[{i}].claim_id missing")
            if not s.get("selection_rationale"):
                errs.append(f"selected[{i}].selection_rationale missing/empty")
        if n_verified > 0 and len(selected) == 0:
            errs.append("selected is empty but verified_candidate_set was non-empty")
        if len(selected) > 3:
            errs.append(f"selected has {len(selected)} entries; curator contract caps at 3")
    if not isinstance(dropped, list):
        errs.append("dropped is not an array")
    else:
        for i, d in enumerate(dropped):
            if not isinstance(d, dict):
                errs.append(f"dropped[{i}] is not an object")
                continue
            if not d.get("claim_id"):
                errs.append(f"dropped[{i}].claim_id missing")
            if not d.get("drop_rationale"):
                errs.append(f"dropped[{i}].drop_rationale missing/empty")

if errs:
    print("invalid: " + "; ".join(errs))
else:
    print("ok")
PYEOF
)

      if [[ "$CURATOR_SHAPE_OK" != "ok" ]]; then
        echo "[audit] contract violation: curator output failed shape validator" >&2
        echo "[audit]   reason: $CURATOR_SHAPE_OK" >&2
        echo "[audit]   raw output: $CURATOR_RAW_FILE" >&2
        exit 2
      fi

      # Persist curator verdict alongside the gate verdicts (append-only).
      python3 - "$CURATOR_RAW_FILE" "$ARTIFACT_ID" "$VERDICTS_FILE" << 'PYEOF'
import json, sys, datetime
cur_file, artifact_id, verdicts_file = sys.argv[1:4]
with open(cur_file) as fh:
    obj = json.load(fh)
wrapped = {
    "artifact_id": artifact_id,
    "judge_run_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    **obj,
}
with open(verdicts_file, "a") as fh:
    fh.write(json.dumps(wrapped) + "\n")
PYEOF

      N_SELECTED=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("selected",[])))' "$CURATOR_RAW_FILE")
      N_DROPPED=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("dropped",[])))' "$CURATOR_RAW_FILE")
      CURATOR_STAGE_RAN=1

      # Curator scorecard rows per contract.md:
      #   curated_rate    (producer, scored, set-level) = selected / verified
      #   triviality_rate (producer, scored, set-level) = dropped  / verified
      if [[ $SKIP_SCORECARD -eq 0 ]]; then
        CUR_ROWS_JSON=$(python3 - "$CURATOR_RAW_FILE" "$RESOLVED_INPUT_FILE" "$CURATOR_TEMPLATE_VERSION" "$N_VERIFIED_COUNT" << 'PYEOF'
import json, sys, datetime

cur_file, input_file, curator_tv, n_verified = sys.argv[1:5]
n_verified = int(n_verified)
with open(cur_file) as fh:
    cur = json.load(fh)
with open(input_file) as fh:
    resolved = json.load(fh)

selected = cur.get("selected", []) or []
dropped = cur.get("dropped", []) or []

if n_verified == 0:
    print("[]")
    sys.exit(0)

curated_rate = len(selected) / n_verified
triviality_rate = len(dropped) / n_verified

producer_template_id = resolved.get("producer_role") or "unknown"
producer_template_version = resolved.get("producer_template_version") or "unknown"
artifact_id = resolved.get("artifact_id")
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

row_base = {
    "schema_version": "1",
    "kind": "scored",
    "tier": "reusable",
    "calibration_state": "pre-calibration",
    "template_id": producer_template_id,
    "template_version": producer_template_version,
    "sample_size": n_verified,
    "window_start": now,
    "window_end": now,
    "source_artifact_ids": [artifact_id] if artifact_id else [],
    "granularity": "set-level",
    "verdict_source": "curator",
    "judge_template_version": curator_tv,
}

rows = [
    {**row_base, "metric": "curated_rate", "value": curated_rate},
    {**row_base, "metric": "triviality_rate", "value": triviality_rate},
]
print(json.dumps(rows))
PYEOF
)

        while IFS= read -r row; do
          if [[ -n "$row" ]]; then
            if bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KDIR" --row "$row" >/dev/null 2>&1; then
              CURATOR_APPENDED_COUNT=$((CURATOR_APPENDED_COUNT + 1))
            else
              echo "[audit] warning: scorecard-append rejected a curator row" >&2
            fi
          fi
        done < <(printf '%s' "$CUR_ROWS_JSON" | jq -c '.[]?')
      fi
    fi
  fi
fi

# --- Judge 3: reverse-auditor (task #22) ---
# Runs only when the curator produced ≥1 selected survivor. Emits at most one
# grounded omission claim, or explicit silence. The emission is routed
# through scripts/grounding-preflight.py for deterministic anchor
# validation. Passed claims land in audit-candidates.jsonl; failed claims
# land in audit-attempts.jsonl with a reason. Silence short-circuits the
# queue writer. Uses the same two-mode integration model as the gate and
# curator: --reverse-auditor-output-file for orchestrator/test injection,
# claude -p fallback when neither flag nor file is supplied.
REVERSE_AUDITOR_STAGE_RAN=0
REVERSE_AUDITOR_APPENDED_COUNT=0
REVERSE_AUDITOR_TEMPLATE_VERSION=""
REVERSE_AUDITOR_RAW_FILE=""
REVERSE_AUDITOR_VERDICT="none"          # none | omission-claim | silence | preflight-failed
REVERSE_AUDITOR_PREFLIGHT_REASON=""     # silence | ok | file-missing | line-out-of-range | snippet-mismatch | field-missing
REVERSE_AUDITOR_QUEUE_DEST=""           # candidates | attempts | silence
REVERSE_AUDITOR_EXIT_CODE=0             # 0 unless preflight failed (sets to 3)

if [[ "$CURATOR_STAGE_RAN" -eq 1 && "$N_SELECTED" -gt 0 ]]; then
  # Decide whether the reverse-auditor stage runs:
  #   - explicit --reverse-auditor-output-file: inject from file
  #   - no flag AND curator was also fully injected (both gate + curator from
  #     files): skip gracefully — orchestrator didn't spawn reverse-auditor
  #     either. Tests/orchestrators that want reverse-auditor coverage must
  #     pass --reverse-auditor-output-file.
  #   - no flag AND curator ran via claude -p: invoke claude -p for the
  #     reverse-auditor too.
  if [[ -z "$REVERSE_AUDITOR_OUTPUT_FILE" && -n "$CURATOR_OUTPUT_FILE" ]]; then
    echo "[audit] reverse-auditor: skipped (curator was injected but no --reverse-auditor-output-file supplied)" >&2
    REVERSE_AUDITOR_TEMPLATE=""
  elif ! REVERSE_AUDITOR_TEMPLATE=$(resolve_agent_template reverse-auditor 2>/dev/null); then
    echo "[audit] warning: reverse-auditor agent template not resolvable via resolve_agent_template — skipping reverse-auditor stage" >&2
    REVERSE_AUDITOR_TEMPLATE=""
  fi

  if [[ -z "$REVERSE_AUDITOR_TEMPLATE" ]]; then
    :  # reverse-auditor skipped, fall through to report
  else
    REVERSE_AUDITOR_TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "$REVERSE_AUDITOR_TEMPLATE")

    if [[ -n "$REVERSE_AUDITOR_OUTPUT_FILE" ]]; then
      if [[ ! -f "$REVERSE_AUDITOR_OUTPUT_FILE" ]]; then
        echo "[audit] Error: --reverse-auditor-output-file not found: $REVERSE_AUDITOR_OUTPUT_FILE" >&2
        exit 1
      fi
      REVERSE_AUDITOR_RAW_FILE="$REVERSE_AUDITOR_OUTPUT_FILE"
      echo "[audit] reverse-auditor: reading pre-computed output from $REVERSE_AUDITOR_OUTPUT_FILE" >&2
    else
      if [[ -z "$JUDGE_MODEL" ]]; then
        echo "[audit] warning: neither --reverse-auditor-output-file nor 'judge' role binding available — skipping reverse-auditor stage" >&2
      else
        REVERSE_AUDITOR_RAW_TMP=$(mktemp "${TMPDIR:-/tmp}/audit-reverse-auditor-output-XXXXXX.json")
        REVERSE_AUDITOR_RAW_FILE="$REVERSE_AUDITOR_RAW_TMP"
        # Compose reverse-auditor input: curator's selected claims + the
        # original resolved input (artifact_id, work_item, change_context,
        # referenced_files). Per contract.md, reverse-auditor input is the
        # curator-surviving portfolio + original change.
        REVERSE_AUDITOR_INPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/audit-reverse-auditor-input-XXXXXX.json")
        python3 - "$CURATOR_RAW_FILE" "$RESOLVED_INPUT_FILE" "$REVERSE_AUDITOR_INPUT_FILE" << 'PYEOF'
import json, sys
cur_file, resolved_file, out_file = sys.argv[1:4]
with open(cur_file) as fh:
    cur = json.load(fh)
with open(resolved_file) as fh:
    resolved = json.load(fh)
selected_ids = {s["claim_id"] for s in cur.get("selected", []) if s.get("claim_id")}
curated_claims = [c for c in resolved.get("claim_payload", []) if c.get("claim_id") in selected_ids]
payload = {
    "artifact_id": resolved.get("artifact_id"),
    "artifact_type": resolved.get("artifact_type"),
    "artifact_path": resolved.get("artifact_path"),
    "work_item": resolved.get("work_item"),
    "curated_top_k": curated_claims,
    "change_context": resolved.get("change_context"),
    "referenced_files": resolved.get("referenced_files"),
}
with open(out_file, "w") as fh:
    json.dump(payload, fh, indent=2)
PYEOF
        REVERSE_AUDITOR_USER_PROMPT="Reverse-auditor input object (curator-surviving portfolio + change context per contract.md):

$(cat "$REVERSE_AUDITOR_INPUT_FILE")

Emit exactly one JSON object matching the Reverse-auditor output shape (omission_claim object or null). No markdown fences. No prose outside the JSON."
        echo "[audit] reverse-auditor: invoking headless runner (template-version: $REVERSE_AUDITOR_TEMPLATE_VERSION, model: $JUDGE_MODEL)" >&2
        if ! headless_runner_invoke "$REVERSE_AUDITOR_TEMPLATE" "$REVERSE_AUDITOR_USER_PROMPT" "$REVERSE_AUDITOR_RAW_FILE"; then
          echo "[audit] warning: headless runner invocation failed for reverse-auditor — skipping reverse-auditor stage" >&2
          REVERSE_AUDITOR_RAW_FILE=""
        elif [[ ! -s "$REVERSE_AUDITOR_RAW_FILE" ]]; then
          echo "[audit] warning: headless runner produced no reverse-auditor output — skipping reverse-auditor stage" >&2
          REVERSE_AUDITOR_RAW_FILE=""
        elif ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$REVERSE_AUDITOR_RAW_FILE" 2>/dev/null; then
          echo "[audit] warning: reverse-auditor output is not valid JSON — skipping reverse-auditor stage" >&2
          REVERSE_AUDITOR_RAW_FILE=""
        fi
        rm -f "$REVERSE_AUDITOR_INPUT_FILE" 2>/dev/null || true
      fi
    fi

    if [[ -n "$REVERSE_AUDITOR_RAW_FILE" ]]; then
      # Validate reverse-auditor output shape per contract.md:
      #   judge == "reverse-auditor"
      #   judge_template_version non-empty
      #   omission_claim present: either null (silence) or object with all
      #     required fields (file, line_range, exact_snippet,
      #     normalized_snippet_hash, falsifier, why_it_matters).
      # The grounding preflight is a separate deterministic validator that
      # runs AFTER shape validation; shape-ok claims with bad anchors route
      # to audit-attempts.jsonl rather than failing the audit outright.
      RA_SHAPE_OK=$(python3 - "$REVERSE_AUDITOR_RAW_FILE" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        obj = json.load(fh)
except Exception as e:
    print(f"parse-error: {type(e).__name__}: {e}")
    sys.exit(0)

errs = []
if not isinstance(obj, dict):
    errs.append("output is not a JSON object")
else:
    if obj.get("judge") != "reverse-auditor":
        errs.append(f"judge != 'reverse-auditor' (got {obj.get('judge')!r})")
    if not obj.get("judge_template_version"):
        errs.append("judge_template_version missing or empty")
    if "omission_claim" not in obj:
        errs.append("omission_claim field missing (must be object or null)")
    else:
        oc = obj["omission_claim"]
        if oc is not None:
            if not isinstance(oc, dict):
                errs.append("omission_claim must be an object or null")
            else:
                required = ("file", "line_range", "exact_snippet",
                            "normalized_snippet_hash", "falsifier")
                for k in required:
                    if not oc.get(k):
                        errs.append(f"omission_claim.{k} missing or empty")
                if not (oc.get("why_it_matters") or oc.get("why-it-matters")):
                    errs.append("omission_claim.why_it_matters (or why-it-matters) missing or empty")

if errs:
    print("invalid: " + "; ".join(errs))
else:
    print("ok")
PYEOF
)

      if [[ "$RA_SHAPE_OK" != "ok" ]]; then
        echo "[audit] contract violation: reverse-auditor output failed shape validator" >&2
        echo "[audit]   reason: $RA_SHAPE_OK" >&2
        echo "[audit]   raw output: $REVERSE_AUDITOR_RAW_FILE" >&2
        exit 2
      fi

      REVERSE_AUDITOR_STAGE_RAN=1

      # Persist the reverse-auditor emission to the artifact settlement
      # record (append-only), mirroring the gate/curator pattern.
      python3 - "$REVERSE_AUDITOR_RAW_FILE" "$ARTIFACT_ID" "$VERDICTS_FILE" << 'PYEOF'
import json, sys, datetime
ra_file, artifact_id, verdicts_file = sys.argv[1:4]
with open(ra_file) as fh:
    obj = json.load(fh)
wrapped = {
    "artifact_id": artifact_id,
    "judge_run_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    **obj,
}
with open(verdicts_file, "a") as fh:
    fh.write(json.dumps(wrapped) + "\n")
PYEOF

      # Run grounding preflight on the emission. Silence short-circuits
      # with reason=silence (preflight treats it as a no-op pass).
      REVERSE_AUDITOR_PREFLIGHT_TMP=$(mktemp "${TMPDIR:-/tmp}/audit-reverse-auditor-preflight-XXXXXX.json")
      # --repo-root should point at the repo whose files the claim anchors
      # reference. For the audit pipeline that's the lore checkout (where
      # the source files live), not $KDIR. Default preflight to $PWD.
      PREFLIGHT_REPO_ROOT="${LORE_REPO_ROOT:-$(pwd)}"
      if ! python3 "$SCRIPT_DIR/grounding-preflight.py" \
          --claim-file "$REVERSE_AUDITOR_RAW_FILE" \
          --repo-root "$PREFLIGHT_REPO_ROOT" \
          > "$REVERSE_AUDITOR_PREFLIGHT_TMP" 2>/dev/null; then
        echo "[audit] warning: grounding-preflight.py invocation failed — treating as preflight-failed" >&2
        printf '%s\n' '{"pass": false, "reason": "field-missing", "detail": "grounding-preflight.py invocation failed"}' > "$REVERSE_AUDITOR_PREFLIGHT_TMP"
      fi

      REVERSE_AUDITOR_PREFLIGHT_REASON=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("reason","unknown"))' "$REVERSE_AUDITOR_PREFLIGHT_TMP")
      REVERSE_AUDITOR_PREFLIGHT_PASS=$(python3 -c 'import json,sys; print("true" if json.load(open(sys.argv[1])).get("pass") else "false")' "$REVERSE_AUDITOR_PREFLIGHT_TMP")

      # Classify the verdict for rollup + reporting.
      #   silence              → no emission to route; rows reflect
      #                          "nothing surfaced"
      #   pass (ok)            → omission-claim; route to candidates queue
      #   fail (any reason)    → preflight-failed; route to attempts queue
      if [[ "$REVERSE_AUDITOR_PREFLIGHT_REASON" == "silence" ]]; then
        REVERSE_AUDITOR_VERDICT="silence"
        REVERSE_AUDITOR_QUEUE_DEST="silence"
      elif [[ "$REVERSE_AUDITOR_PREFLIGHT_PASS" == "true" ]]; then
        REVERSE_AUDITOR_VERDICT="omission-claim"
        REVERSE_AUDITOR_QUEUE_DEST="candidates"
      else
        REVERSE_AUDITOR_VERDICT="preflight-failed"
        REVERSE_AUDITOR_QUEUE_DEST="attempts"
        # Exit 3 is informational per contract: the audit completed but the
        # omission claim was routed to audit-attempts.jsonl.
        REVERSE_AUDITOR_EXIT_CODE=3
      fi

      # Route the emission to candidates/attempts queue. Prefer
      # audit-queue-route.sh when a work-item slug resolves under
      # $KDIR/_work/<slug>/; otherwise write directly into the owning
      # artifact dir (the followup sidecar case). Silence writes nothing.
      if [[ "$REVERSE_AUDITOR_QUEUE_DEST" != "silence" ]]; then
        # Prefer the work_item field from the resolved input; fall back
        # to the artifact_id when the artifact itself is a work-item slug.
        WORK_ITEM_SLUG=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("work_item") or "")' "$RESOLVED_INPUT_FILE")
        if [[ -z "$WORK_ITEM_SLUG" && "$ARTIFACT_TYPE" == "work-item" ]]; then
          WORK_ITEM_SLUG="$ARTIFACT_ID"
        fi

        if [[ -n "$WORK_ITEM_SLUG" && -d "$KDIR/_work/$WORK_ITEM_SLUG" ]]; then
          # Canonical routing path — audit-queue-route.sh is sole writer
          # of _work/<slug>/audit-{candidates,attempts}.jsonl.
          if ! bash "$SCRIPT_DIR/audit-queue-route.sh" \
              --work-item "$WORK_ITEM_SLUG" \
              --emission "$REVERSE_AUDITOR_RAW_FILE" \
              --preflight "$REVERSE_AUDITOR_PREFLIGHT_TMP" \
              --kdir "$KDIR" \
              --verdict-source "reverse-auditor" >/dev/null 2>&1; then
            echo "[audit] warning: audit-queue-route.sh failed for work-item $WORK_ITEM_SLUG" >&2
          fi
        else
          # Fallback: write directly into the artifact's owning dir
          # (lens-findings followup case, where no _work/<slug> exists).
          # Schema parity with audit-queue-route.sh is preserved.
          if [[ -n "$OWNING_DIR" ]]; then
            QUEUE_DIR="$OWNING_DIR"
          else
            QUEUE_DIR="$KDIR/_audit"
            mkdir -p "$QUEUE_DIR"
          fi
          python3 - "$REVERSE_AUDITOR_RAW_FILE" "$REVERSE_AUDITOR_PREFLIGHT_TMP" "$QUEUE_DIR" "$ARTIFACT_ID" << 'PYEOF'
import json, os, sys, uuid
from datetime import datetime, timezone
ra_file, pf_file, queue_dir, artifact_id = sys.argv[1:5]
with open(ra_file) as fh:
    emission = json.load(fh)
with open(pf_file) as fh:
    pf = json.load(fh)
claim = emission.get("omission_claim") or {}
work_item = emission.get("work_item") or artifact_id
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
if pf.get("pass"):
    row = {
        "candidate_id":   f"cand-{uuid.uuid4().hex[:12]}",
        "verdict_source": "reverse-auditor",
        "work_item":      work_item,
        "file":           claim.get("file"),
        "line_range":     claim.get("line_range"),
        "falsifier":      claim.get("falsifier"),
        "rationale":      claim.get("why_it_matters") or claim.get("why-it-matters") or "",
        "status":         "pending_correctness_gate",
        "created_at":     now,
    }
    target = os.path.join(queue_dir, "audit-candidates.jsonl")
else:
    row = {
        "attempt_id":     f"att-{uuid.uuid4().hex[:12]}",
        "verdict_source": "reverse-auditor",
        "work_item":      work_item,
        "claim_payload":  claim,
        "reason":         pf.get("reason") or "unknown",
        "detail":         pf.get("detail") or "",
        "created_at":     now,
    }
    target = os.path.join(queue_dir, "audit-attempts.jsonl")
with open(target, "a") as fh:
    fh.write(json.dumps(row, sort_keys=True) + "\n")
print(target)
PYEOF
        fi
      fi

      # Scorecard rows per contract.md reverse-auditor row:
      #   omission_rate          (producer,        scored,    portfolio-level)
      #   coverage_quality       (curator,         scored,    portfolio-level)
      #   grounding_failure_rate (reverse-auditor, telemetry, portfolio-level)
      #
      # Per-artifact metric derivation (matches scripts/reverse-auditor-rollup.sh):
      #   verdict                 → omission_rate   coverage_quality   grounding_failure_rate
      #   omission-claim          → 1.0             0.0                0.0
      #   silence                 → 0.0             1.0                0.0
      #   preflight-failed        → 0.0             1.0                1.0
      #
      # Scored reverse-auditor rows must carry claim_anchor per the
      # grounded-or-nothing gate in scorecard-append.sh — the omission_rate
      # row only gets a claim_anchor on an actual omission claim. On silence
      # or preflight-failed, omission_rate = 0 and the row skips the anchor;
      # scorecard-append.sh requires the anchor only when the row actually
      # attributes a grounded concern. To stay on the safe side, when
      # verdict == silence | preflight-failed we skip the omission_rate row
      # (nothing to score) but emit coverage_quality against the curator and
      # grounding_failure_rate as telemetry.
      if [[ $SKIP_SCORECARD -eq 0 ]]; then
        RA_ROWS_JSON=$(python3 - "$REVERSE_AUDITOR_RAW_FILE" "$RESOLVED_INPUT_FILE" \
                                "$REVERSE_AUDITOR_TEMPLATE_VERSION" "$CURATOR_TEMPLATE_VERSION" \
                                "$REVERSE_AUDITOR_VERDICT" << 'PYEOF'
import json, sys, datetime

ra_file, resolved_file, ra_tv, curator_tv, verdict = sys.argv[1:6]
with open(ra_file) as fh:
    ra = json.load(fh)
with open(resolved_file) as fh:
    resolved = json.load(fh)

producer_template_id = resolved.get("producer_role") or "unknown"
producer_template_version = resolved.get("producer_template_version") or "unknown"
curator_template_id = "curator"
artifact_id = resolved.get("artifact_id")
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

claim = ra.get("omission_claim") or {}

# Classify value contributions per verdict.
if verdict == "omission-claim":
    omission_value = 1.0
    coverage_value = 0.0
    grounding_fail = 0.0
elif verdict == "silence":
    omission_value = 0.0
    coverage_value = 1.0
    grounding_fail = 0.0
else:  # preflight-failed
    omission_value = 0.0
    coverage_value = 1.0
    grounding_fail = 1.0

row_common = {
    "schema_version": "1",
    "calibration_state": "pre-calibration",
    "sample_size": 1,
    "window_start": now,
    "window_end": now,
    "source_artifact_ids": [artifact_id] if artifact_id else [],
    "granularity": "portfolio-level",
    "verdict_source": "reverse-auditor",
    "judge_template_version": ra_tv,
    "tier": "reusable",
}

rows = []

# omission_rate — producer template, scored. The scorecard-append.sh
# grounded-or-nothing gate REQUIRES a non-empty claim_anchor on scored
# reverse-auditor rows. Only emit this row when we have a real claim.
if verdict == "omission-claim":
    rows.append({
        **row_common,
        "kind": "scored",
        "template_id": producer_template_id,
        "template_version": producer_template_version,
        "metric": "omission_rate",
        "value": omission_value,
        "claim_anchor": {
            "file": claim.get("file"),
            "line_range": claim.get("line_range"),
            "exact_snippet": claim.get("exact_snippet"),
            "normalized_snippet_hash": claim.get("normalized_snippet_hash"),
        },
    })

# coverage_quality — curator template, scored. Only ships when curator
# template_version is known. The grounded-or-nothing gate also applies
# here because verdict_source=reverse-auditor + kind=scored. We carry the
# same claim_anchor when we have a claim; for silence/preflight-failed we
# emit the row only in the silence case where it is vacuously 1.0 — but
# scorecard-append.sh enforces the anchor regardless. To stay compliant,
# we emit coverage_quality only when we have a claim (omission-claim) OR
# skip it in the silence/failed cases. Silence → no surfaced coverage gap
# so no row is informative; the absence itself is the signal.
if verdict == "omission-claim":
    rows.append({
        **row_common,
        "kind": "scored",
        "template_id": curator_template_id,
        "template_version": curator_tv or "unknown",
        "metric": "coverage_quality",
        "value": coverage_value,
        "claim_anchor": {
            "file": claim.get("file"),
            "line_range": claim.get("line_range"),
            "exact_snippet": claim.get("exact_snippet"),
            "normalized_snippet_hash": claim.get("normalized_snippet_hash"),
        },
    })

# grounding_failure_rate — reverse-auditor template, telemetry. Always
# emit (even on silence) so /retro can track the rate. Telemetry rows
# are exempt from the grounded-or-nothing gate per scorecard-append.sh.
rows.append({
    **row_common,
    "kind": "telemetry",
    "tier": "telemetry",
    "template_id": "reverse-auditor",
    "template_version": ra_tv,
    "metric": "grounding_failure_rate",
    "value": grounding_fail,
})

print(json.dumps(rows))
PYEOF
)

        while IFS= read -r row; do
          if [[ -n "$row" ]]; then
            if bash "$SCRIPT_DIR/scorecard-append.sh" --kdir "$KDIR" --row "$row" >/dev/null 2>&1; then
              REVERSE_AUDITOR_APPENDED_COUNT=$((REVERSE_AUDITOR_APPENDED_COUNT + 1))
            else
              echo "[audit] warning: scorecard-append rejected a reverse-auditor row" >&2
            fi
          fi
        done < <(printf '%s' "$RA_ROWS_JSON" | jq -c '.[]?')
      fi
    fi
  fi
fi

# --- Report ---
N_TOTAL=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("verdicts",[])))' "$GATE_RAW_FILE")
N_VERIFIED=$(python3 -c 'import json,sys; print(sum(1 for v in json.load(open(sys.argv[1])).get("verdicts",[]) if v.get("verdict")=="verified"))' "$GATE_RAW_FILE")
N_UNVERIFIED=$(python3 -c 'import json,sys; print(sum(1 for v in json.load(open(sys.argv[1])).get("verdicts",[]) if v.get("verdict")=="unverified"))' "$GATE_RAW_FILE")
N_CONTRADICTED=$(python3 -c 'import json,sys; print(sum(1 for v in json.load(open(sys.argv[1])).get("verdicts",[]) if v.get("verdict")=="contradicted"))' "$GATE_RAW_FILE")

TOTAL_ROWS_APPENDED=$((APPENDED_COUNT + CURATOR_APPENDED_COUNT + REVERSE_AUDITOR_APPENDED_COUNT))
if [[ $REVERSE_AUDITOR_STAGE_RAN -eq 1 ]]; then
  PIPELINE_STAGE="reverse-auditor-complete"
  NEXT_STAGE="audit pipeline complete"
elif [[ $CURATOR_STAGE_RAN -eq 1 ]]; then
  PIPELINE_STAGE="curator-complete"
  if [[ "$N_SELECTED" == "0" ]]; then
    NEXT_STAGE="reverse-auditor skipped (no selected survivors)"
  else
    NEXT_STAGE="reverse-auditor skipped (template missing, claude unavailable, or curator was injected without --reverse-auditor-output-file)"
  fi
else
  PIPELINE_STAGE="correctness-gate-complete"
  if [[ "$N_VERIFIED" == "0" ]]; then
    NEXT_STAGE="curator skipped (no verified survivors); reverse-auditor skipped (no curated survivors)"
  else
    NEXT_STAGE="curator skipped (template missing or claude unavailable); reverse-auditor skipped"
  fi
fi

if [[ $JSON_MODE -eq 1 ]]; then
  python3 - "$ARTIFACT_ID" "$ARTIFACT_TYPE" "$ARTIFACT_PATH" "$VERDICTS_FILE" \
    "$N_TOTAL" "$N_VERIFIED" "$N_UNVERIFIED" "$N_CONTRADICTED" \
    "$APPENDED_COUNT" "$GATE_TEMPLATE_VERSION" \
    "$CURATOR_STAGE_RAN" "$CURATOR_TEMPLATE_VERSION" \
    "$N_SELECTED" "$N_DROPPED" "$CURATOR_APPENDED_COUNT" \
    "$REVERSE_AUDITOR_STAGE_RAN" "$REVERSE_AUDITOR_TEMPLATE_VERSION" \
    "$REVERSE_AUDITOR_VERDICT" "$REVERSE_AUDITOR_PREFLIGHT_REASON" \
    "$REVERSE_AUDITOR_QUEUE_DEST" "$REVERSE_AUDITOR_APPENDED_COUNT" \
    "$TOTAL_ROWS_APPENDED" "$PIPELINE_STAGE" "$NEXT_STAGE" << 'PYEOF'
import json, sys
(artifact_id, artifact_type, artifact_path, verdicts_file,
 n_total, n_verified, n_unverified, n_contradicted,
 gate_appended, gate_tv,
 curator_ran, curator_tv,
 n_selected, n_dropped, curator_appended,
 ra_ran, ra_tv, ra_verdict, ra_preflight_reason, ra_queue_dest, ra_appended,
 total_appended, pipeline_stage, next_stage) = sys.argv[1:24]

out = {
    "artifact_id": artifact_id,
    "artifact_type": artifact_type,
    "artifact_path": artifact_path,
    "verdicts_file": verdicts_file,
    "correctness_gate": {
        "template_version": gate_tv,
        "verdicts_total": int(n_total),
        "verified": int(n_verified),
        "unverified": int(n_unverified),
        "contradicted": int(n_contradicted),
        "scorecard_rows_appended": int(gate_appended),
    },
    "pipeline_stage": pipeline_stage,
    "scorecard_rows_appended": int(total_appended),
    "next": next_stage,
}
if curator_ran == "1":
    out["curator"] = {
        "template_version": curator_tv,
        "selected": int(n_selected),
        "dropped": int(n_dropped),
        "scorecard_rows_appended": int(curator_appended),
    }
if ra_ran == "1":
    out["reverse_auditor"] = {
        "template_version": ra_tv,
        "verdict": ra_verdict,
        "preflight_reason": ra_preflight_reason,
        "queue_destination": ra_queue_dest,
        "scorecard_rows_appended": int(ra_appended),
    }
print(json.dumps(out, indent=2))
PYEOF
else
  echo "[audit] correctness-gate complete (template-version: $GATE_TEMPLATE_VERSION)"
  echo "[audit]   verdicts: total=$N_TOTAL verified=$N_VERIFIED unverified=$N_UNVERIFIED contradicted=$N_CONTRADICTED"
  echo "[audit]   scorecard rows appended: $APPENDED_COUNT"
  if [[ $CURATOR_STAGE_RAN -eq 1 ]]; then
    echo "[audit] curator complete (template-version: $CURATOR_TEMPLATE_VERSION)"
    echo "[audit]   selected=$N_SELECTED dropped=$N_DROPPED (from $N_VERIFIED verified)"
    echo "[audit]   scorecard rows appended: $CURATOR_APPENDED_COUNT"
  fi
  if [[ $REVERSE_AUDITOR_STAGE_RAN -eq 1 ]]; then
    echo "[audit] reverse-auditor complete (template-version: $REVERSE_AUDITOR_TEMPLATE_VERSION)"
    echo "[audit]   verdict=$REVERSE_AUDITOR_VERDICT preflight=$REVERSE_AUDITOR_PREFLIGHT_REASON queue=$REVERSE_AUDITOR_QUEUE_DEST"
    echo "[audit]   scorecard rows appended: $REVERSE_AUDITOR_APPENDED_COUNT"
  fi
  echo "[audit] verdicts persisted to: $VERDICTS_FILE"
  echo "[audit] total scorecard rows appended: $TOTAL_ROWS_APPENDED"
  echo "[audit] Next: $NEXT_STAGE"
fi

exit $REVERSE_AUDITOR_EXIT_CODE
