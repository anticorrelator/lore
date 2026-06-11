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
# Per-kind dispatch flags (Phase 1 of the verification-loop work item). When
# --kind and --id are both supplied, the wrapper resolves exactly one source
# row from the per-kind file under _work/<slug>/ and routes only that row
# through the judge pipeline. --work-item disambiguates when the source row's
# work-item cannot be inferred from $ARTIFACT_ID.
KIND_FLAG=""
ID_FLAG=""
WORK_ITEM_FLAG=""
# JUDGE_MODEL stays empty until after arg parsing; resolution from the
# `judge` role runs after we know whether all three judges might be
# spawned via the headless runner. The --model flag (added in T38) lets
# the operator override the role binding for one invocation.
JUDGE_MODEL=""

# headless_runner_invoke <system_prompt_file> <user_prompt_string> <output_file>
#
# Spawn the active harness's headless single-turn agent and capture its
# stdout into <output_file>. The active framework owns the executable surface:
# claude-code uses `claude -p`, codex uses `codex exec`, and unsupported
# frameworks must inject judge output files instead of silently falling through
# to another harness.
#
# Returns 0 on success, non-zero on subprocess failure. Stderr is
# captured and summarized so settlement run records explain the real failure.
#
# Retry contract (post-investigation of the May 17-20 failure cluster):
# the model occasionally returns empty or non-JSON output on a prompt that
# succeeds on retry. _headless_runner_invoke_once classifies the failure
# (rc=64 setup error, rc=65 empty output, rc=66 non-JSON output, rc=* other
# subprocess failure) and headless_runner_invoke wraps it with up to
# LORE_JUDGE_MAX_ATTEMPTS attempts. Setup errors bypass retry; transient
# flakes retry with linear backoff. Both knobs override via env var so
# tests can pin attempts=1.
: "${LORE_JUDGE_MAX_ATTEMPTS:=3}"
: "${LORE_JUDGE_RETRY_BACKOFF_SECS:=2}"

split_codex_model_variant() {
  local binding="$1"
  local model="$binding"
  local effort=""
  case "$binding" in
    *-minimal) model="${binding%-minimal}"; effort="minimal" ;;
    *-low)     model="${binding%-low}";     effort="low" ;;
    *-medium)  model="${binding%-medium}";  effort="medium" ;;
    *-high)    model="${binding%-high}";    effort="high" ;;
    *-xhigh)   model="${binding%-xhigh}";   effort="xhigh" ;;
  esac
  printf '%s\t%s\n' "$model" "$effort"
}

# headless_runner_invoke — public entry point with retry on transient flakes.
# Wraps _headless_runner_invoke_once with up to LORE_JUDGE_MAX_ATTEMPTS attempts.
# Setup errors (rc=64) bypass retry; other non-zero returns retry with linear
# backoff. On exhaustion, returns the last attempt's exit code so the caller
# can still distinguish (e.g. empty-output vs subprocess-failure) for logging.
#
# Optional 4th arg: schema_path. When set, the runner passes a JSON-schema
# constraint to the CLI (claude --json-schema reads inline; codex
# --output-schema reads a file). Opt-in per callsite — only the
# reverse-auditor callsite passes this today (D7).
# Optional 5th arg: max_turns. Per-callsite turn cap (default 15). The
# reverse-auditor passes a low cap because its evidence is inlined — it has
# nothing to fetch — while gate/curator keep the default.
headless_runner_invoke() {
  local system_prompt_file="$1"
  local user_prompt="$2"
  local output_file="$3"
  local schema_path="${4:-}"
  local max_turns="${5:-15}"
  local attempt=1
  local rc=0
  while (( attempt <= LORE_JUDGE_MAX_ATTEMPTS )); do
    rc=0
    _headless_runner_invoke_once "$system_prompt_file" "$user_prompt" "$output_file" "$schema_path" "$max_turns" || rc=$?
    if (( rc == 0 )); then
      if (( attempt > 1 )); then
        echo "[audit] headless runner succeeded on attempt $attempt/$LORE_JUDGE_MAX_ATTEMPTS after retry" >&2
      fi
      return 0
    fi
    # Setup errors (capability gate, CLI missing, unsupported framework) are
    # configuration problems, not transient flakes — retrying is wasted time
    # and noise.
    if (( rc == 64 )); then
      return 64
    fi
    if (( attempt == LORE_JUDGE_MAX_ATTEMPTS )); then
      echo "[audit] headless runner exhausted $LORE_JUDGE_MAX_ATTEMPTS attempts (last rc=$rc)" >&2
      return "$rc"
    fi
    echo "[audit] headless runner attempt $attempt/$LORE_JUDGE_MAX_ATTEMPTS returned rc=$rc; retrying in ${LORE_JUDGE_RETRY_BACKOFF_SECS}s" >&2
    sleep "$LORE_JUDGE_RETRY_BACKOFF_SECS"
    attempt=$((attempt + 1))
  done
  return "$rc"
}

# _headless_runner_invoke_once — internal single-attempt invocation. Callers
# should use headless_runner_invoke instead, which adds retry on transient
# flakes. Exit-code conventions:
#   0  success: output file is non-empty AND parses as JSON
#   64 setup error: capability gate, CLI missing, unsupported framework
#      (NOT retried — these are config problems, not transient flakes)
#   65 empty output (rc=0 but file size 0) — retried by caller
#   66 non-empty output but not parseable as JSON — retried by caller
#   *  any other non-zero subprocess exit — retried by caller
_headless_runner_invoke_once() {
  local system_prompt_file="$1"
  local user_prompt="$2"
  local output_file="$3"
  # Optional 4th arg: a JSON-schema file path. claude --json-schema takes the
  # schema inline (read here); codex --output-schema takes a file path
  # directly. Empty/unset means no schema constraint (existing 3-arg call
  # shape preserved per D7).
  local schema_path="${4:-}"
  # Optional 5th arg: per-callsite turn cap (default 15).
  local max_turns="${5:-15}"

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

  local active
  active=$(resolve_active_framework 2>/dev/null || echo "")
  local harness_args=()
  while IFS= read -r arg; do
    harness_args+=("$arg")
  done < <(load_harness_args "$active")
  local err_file
  err_file=$(mktemp "${TMPDIR:-/tmp}/audit-headless-stderr.XXXXXX")
  local rc=0
  case "$active" in
    claude-code|opencode)
      if ! command -v claude >/dev/null 2>&1; then
        echo "[audit] Error: claude CLI not found on PATH — cannot spawn judges." >&2
        rm -f "$err_file"
        return 64
      fi
      # --max-turns 10 (not 1): the kind-specialized correctness-gate
      # templates instruct the judge to Read the cited file to verify the
      # claim. With --max-turns 1, the first tool use consumes the budget
      # and the judge exits with "Reached max turns" before emitting JSON.
      # 10 turns is generous headroom — typical judges complete in 2-4.
      if [[ -n "$schema_path" ]]; then
        if [[ ! -f "$schema_path" ]]; then
          echo "[audit] Error: --json-schema source file not found: $schema_path" >&2
          rm -f "$err_file"
          return 64
        fi
        # When --json-schema is set, claude internally exposes a
        # StructuredOutput tool whose input_schema is the supplied schema.
        # Under --output-format text, the model invokes that tool but the
        # captured stdout is only the final text turn — often prose
        # narration, sometimes the JSON, sometimes empty — which the
        # downstream :1879 parser sees. To get the schema-enforced payload
        # reliably, switch to --output-format stream-json, capture all
        # events, locate the StructuredOutput tool_use.input, and write
        # that as the result file the rest of the pipeline reads.
        local stream_file
        stream_file=$(mktemp "${TMPDIR:-/tmp}/audit-headless-stream.XXXXXX")
        printf '%s' "$user_prompt" | claude -p \
          "${harness_args[@]}" \
          --append-system-prompt "$(cat "$system_prompt_file")" \
          --model "$JUDGE_MODEL" \
          --output-format stream-json \
          --verbose \
          --max-turns "$max_turns" \
          --json-schema "$(cat "$schema_path")" \
          > "$stream_file" 2>"$err_file"
        rc=$?
        # Extract the LAST StructuredOutput tool_use.input from the stream.
        # Multiple calls can appear if the model self-corrects; take the
        # last as the model's final decision. Surface failures at the
        # runner boundary, not at the upstream :1879 parser.
        python3 - "$stream_file" "$output_file" "$err_file" << 'PYEOF'
import json, sys
stream_path, out_path, err_path = sys.argv[1:4]
last_structured = None
struct_count = 0
saw_result = False
result_subtype = None
try:
    with open(stream_path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(ev, dict) and ev.get("type") == "result":
                saw_result = True
                result_subtype = ev.get("subtype")
            msg = ev.get("message") if isinstance(ev, dict) else None
            if not isinstance(msg, dict):
                continue
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                if (isinstance(block, dict)
                        and block.get("type") == "tool_use"
                        and block.get("name") == "StructuredOutput"
                        and isinstance(block.get("input"), dict)
                        and block.get("input")):
                    last_structured = block["input"]
                    struct_count += 1
except FileNotFoundError:
    pass

err_lines = []
if last_structured is None:
    open(out_path, "w").close()
    err_lines.append(f"[audit] schema-enforcement absent: no StructuredOutput tool_use in stream (result_subtype={result_subtype!r}, saw_result={saw_result})")
else:
    try:
        with open(out_path, "w") as fh:
            json.dump(last_structured, fh)
    except (TypeError, ValueError) as e:
        open(out_path, "w").close()
        err_lines.append(f"[audit] StructuredOutput input not JSON-serializable: {e}")

if struct_count > 1:
    err_lines.append(f"[audit] StructuredOutput tool_use observed {struct_count} times; using the last")

if err_lines:
    try:
        with open(err_path, "a") as fh:
            for ln in err_lines:
                fh.write(ln + "\n")
    except OSError:
        pass
PYEOF
        rm -f "$stream_file"
      else
        printf '%s' "$user_prompt" | claude -p \
          "${harness_args[@]}" \
          --append-system-prompt "$(cat "$system_prompt_file")" \
          --model "$JUDGE_MODEL" \
          --output-format text \
          --max-turns "$max_turns" \
          > "$output_file" 2>"$err_file"
        rc=$?
      fi
      ;;
    codex)
      if ! command -v codex >/dev/null 2>&1; then
        echo "[audit] Error: codex CLI not found on PATH — cannot spawn judges." >&2
        rm -f "$err_file"
        return 64
      fi
      local codex_model codex_effort
      IFS=$'\t' read -r codex_model codex_effort < <(split_codex_model_variant "$JUDGE_MODEL")
      local prompt
      prompt="System instructions:
$(cat "$system_prompt_file")

User prompt:
$user_prompt"
      local has_sandbox_arg=0
      for arg in "${harness_args[@]}"; do
        case "$arg" in
          --sandbox|-s|--dangerously-bypass-approvals-and-sandbox)
            has_sandbox_arg=1
            ;;
        esac
      done
      local cmd=(codex exec "${harness_args[@]}" --ephemeral --skip-git-repo-check -m "$codex_model" -o "$output_file")
      if [[ "$has_sandbox_arg" -eq 0 ]]; then
        cmd+=(--sandbox read-only)
      fi
      if [[ -n "$codex_effort" ]]; then
        cmd+=(-c "model_reasoning_effort=\"$codex_effort\"")
      fi
      if [[ -n "$schema_path" ]]; then
        if [[ ! -f "$schema_path" ]]; then
          echo "[audit] Error: --output-schema file not found: $schema_path" >&2
          rm -f "$err_file"
          return 64
        fi
        cmd+=(--output-schema "$schema_path")
      fi
      printf '%s' "$prompt" | "${cmd[@]}" - >/dev/null 2>"$err_file"
      rc=$?
      ;;
    *)
      echo "[audit] Error: active framework '$active' has no wired headless runner." >&2
      echo "[audit]   Supply --gate-output-file / --curator-output-file / --reverse-auditor-output-file to inject pre-computed judge outputs." >&2
      rm -f "$err_file"
      return 64
      ;;
  esac

  if [[ "$rc" -ne 0 ]]; then
    if [[ -s "$err_file" ]]; then
      echo "[audit] headless runner stderr tail:" >&2
      tail -n 20 "$err_file" >&2
    else
      echo "[audit] headless runner exit=$rc with empty stderr (output_file=$output_file size=$(wc -c < "$output_file" 2>/dev/null || echo 0))" >&2
    fi
    rm -f "$err_file"
    return "$rc"
  fi
  # rc==0 but output may still be empty — surface that explicitly instead of
  # silently returning 1 via the `[[ -s ... ]]` test.
  if [[ ! -s "$output_file" ]]; then
    echo "[audit] headless runner exit=0 but produced empty output_file=$output_file" >&2
    if [[ -s "$err_file" ]]; then
      echo "[audit] stderr tail (may explain empty output):" >&2
      tail -n 20 "$err_file" >&2
    fi
    rm -f "$err_file"
    return 65
  fi
  # rc==0, output non-empty, but the model occasionally wraps the JSON in
  # markdown fences (```json ... ```) or surrounds it with prose ("Here is the
  # verdict: {...}"). A strict json.load() rejects those at the first character,
  # and because the wrapping is *deterministic* for a given model+template the
  # 3-attempt retry layer cannot recover it — every attempt re-fails identically
  # and the run lands as executor_audit_error. So first try to SALVAGE the JSON:
  # strip fences / extract the outermost object, and if that yields valid JSON,
  # rewrite output_file in place (only when salvage was actually needed, so a
  # clean payload stays byte-for-byte) so the downstream shape validators — still
  # the real gate — see clean input. Only a genuinely unparseable payload (no
  # recoverable JSON object) falls through to rc=66.
  if python3 - "$output_file" <<'PYEOF' 2>/dev/null
import json, re, sys
p = sys.argv[1]
s = open(p).read().strip()

def try_load(x):
    try:
        return json.loads(x)
    except Exception:
        return None

obj = try_load(s)
need_rewrite = obj is None
if obj is None:
    m = re.search(r"```(?:json)?\s*(.*?)```", s, re.DOTALL)
    if m:
        obj = try_load(m.group(1).strip())
if obj is None:
    starts = [i for i in (s.find("{"), s.find("[")) if i != -1]
    if starts:
        start = min(starts)
        close = "}" if s[start] == "{" else "]"
        end = s.rfind(close)
        if end > start:
            obj = try_load(s[start:end + 1])
if obj is None:
    sys.exit(1)
if need_rewrite:
    with open(p, "w") as f:
        json.dump(obj, f)
sys.exit(0)
PYEOF
  then
    rm -f "$err_file"
    return 0
  fi
  local sz
  sz=$(wc -c < "$output_file" 2>/dev/null | tr -d ' ' || echo 0)
  echo "[audit] headless runner exit=0 but output is not parseable JSON after fence/prose salvage (size=$sz, file=$output_file)" >&2
  rm -f "$err_file"
  return 66
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
                                [--kind <K> --id <ID> [--work-item <slug>]]

Arguments:
  <artifact-id>    Work-item slug or absolute path to a task-claims.jsonl
                   source file. When --kind/--id are supplied the slug may
                   also be passed via --work-item instead.

Options:
  --kind K --id ID           Dispatch the per-kind, per-source-row audit path.
                             K ∈ {task-claim, omission, consumption-contradiction}.
                             ID is the natural id of the source row
                             (claim_id | candidate_id | contradiction_id).
                             The wrapper resolves exactly one row from the
                             matching file under _work/<slug>/ and routes
                             only that row through the judge pipeline.
                             Returns structured failure for absent,
                             duplicated, malformed, or kind-mismatched rows.
                             --work-item supplies the slug when the
                             positional artifact-id does not.
  --kdir <path>              Override resolved knowledge directory.
  --json                     Emit JSON on stdout (one top-level object).
  --dry-run                  Resolve artifact and enumerate candidates without
                             spawning any judge. Prints the resolved input.
  --gate-output-file P       Read correctness-gate output JSON from P instead
                             of invoking the headless judge runner. Used by
                             test harnesses and by orchestrators that spawn
                             the judge themselves.
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
                             Superseded for the per-kind dispatch path by
                             --kind/--id; retained for legacy callers.
  --model <model>            Override resolve_model_for_role judge for this
                             invocation. All three judges share the same model
                             unless they are injected via the --*-output-file
                             flags above. When absent and no role binding is
                             set, the script attempts the role lookup and
                             refuses to spawn judges if neither resolves.
  -h, --help                 Show this help.

Contract: see \$KDIR/architecture/evidence/audit-pipeline-contract.md for the
canonical input object shape, per-judge output shapes, scorecard-row mapping,
and exit codes.
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
    --kind)
      [[ $# -lt 2 ]] && { echo "[audit] Error: --kind requires a value" >&2; exit 1; }
      KIND_FLAG="$2"
      shift 2
      ;;
    --id)
      [[ $# -lt 2 ]] && { echo "[audit] Error: --id requires a value" >&2; exit 1; }
      ID_FLAG="$2"
      shift 2
      ;;
    --work-item)
      [[ $# -lt 2 ]] && { echo "[audit] Error: --work-item requires a value" >&2; exit 1; }
      WORK_ITEM_FLAG="$2"
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

# --- Validate per-kind dispatch flag pairing ---
# --kind and --id are a pair: either both or neither. --work-item is required
# only when neither $ARTIFACT_ID nor the --kind/--id pair carries enough info
# to resolve the source row's work-item slug. When --kind/--id are present we
# require --work-item too (the per-kind dispatch is most cleanly invoked with
# all three flags explicit; deriving work-item from positional ARTIFACT_ID is
# how legacy callers reach the same code paths).
if [[ -n "$KIND_FLAG" || -n "$ID_FLAG" ]]; then
  if [[ -z "$KIND_FLAG" || -z "$ID_FLAG" ]]; then
    echo "[audit] Error: --kind and --id must both be present (or both absent)" >&2
    exit 1
  fi
  case "$KIND_FLAG" in
    task-claim|omission|consumption-contradiction|commons) : ;;
    *)
      echo "[audit] Error: --kind must be 'task-claim', 'omission', 'consumption-contradiction', or 'commons' (got '$KIND_FLAG')" >&2
      exit 1
      ;;
  esac
  if [[ -z "$WORK_ITEM_FLAG" && -z "$ARTIFACT_ID" ]]; then
    echo "[audit] Error: --kind/--id requires --work-item or a positional <artifact-id> work-item slug" >&2
    exit 1
  fi
fi

# When --kind/--id are supplied without a positional artifact-id, synthesize
# ARTIFACT_ID from the work-item slug so the downstream resolution path runs.
if [[ -n "$KIND_FLAG" && -z "$ARTIFACT_ID" ]]; then
  ARTIFACT_ID="$WORK_ITEM_FLAG"
fi

if [[ -z "$ARTIFACT_ID" ]]; then
  echo "[audit] Error: <artifact-id> is required" >&2
  usage
  exit 1
fi

# Reject the archive root literal — '_archive' is a structural container,
# never a work-item slug. Without this guard, an upstream caller passing
# '_archive' as a slug (e.g. from a path-parser that captured the archive
# directory by accident) would resolve to $KDIR/_work/_archive, then write
# verdicts into $KDIR/_work/_archive/verdicts/ as a phantom stub.
if [[ "$ARTIFACT_ID" == "_archive" ]]; then
  echo "[audit] Error: '_archive' is the archive root, not a work-item slug" >&2
  echo "[audit]   Caller passed --work-item _archive or an equivalent ARTIFACT_ID;" >&2
  echo "[audit]   trace upstream to find the path-parser that lost the real slug." >&2
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

# Model provenance: scorecard-append.sh stamps rows with LORE_MODEL when the
# row carries no model field. Export the resolved judge model so every row
# this pipeline emits records which model generation produced the verdicts
# (pre-computed --*-output-file paths leave it unset → "unrecorded", which is
# honest: the producing model is unknown to this process). Respect a caller's
# own LORE_MODEL if already set.
if [[ -n "$JUDGE_MODEL" && -z "${LORE_MODEL:-}" ]]; then
  export LORE_MODEL="$JUDGE_MODEL"
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

# read_calibration_state — resolve the judge's calibration_state from the
# marker file at $KDIR/_scorecards/calibration-state.json keyed by
# (judge_template_id, judge_template_version). Defaults to "pre-calibration"
# on missing file, missing keyed entry, or unreadable JSON. The reader also
# recognizes `calibration-failed` as a distinct state (a gate template whose
# last run produced calibration-failed; the marker file holds pass-only
# entries, so a present entry with state=calibration-failed only appears when
# the per-gate log is consulted — which the marker reader does not do here).
# audit-artifact.sh is a marker reader only — it never writes either the
# marker or the history sidecar (calibration-history.jsonl). See
# scripts/scorecards-calibrate.sh for the sole-writer contract on those files.
read_calibration_state() {
  local judge_id="$1"
  local judge_version="$2"
  local marker_file="$KDIR/_scorecards/calibration-state.json"
  if [[ ! -f "$marker_file" ]]; then
    echo "pre-calibration"
    return 0
  fi
  JUDGE_ID="$judge_id" JUDGE_VERSION="$judge_version" MARKER_FILE="$marker_file" \
    python3 -c '
import json, os, sys
try:
    with open(os.environ["MARKER_FILE"]) as fh:
        data = json.load(fh)
except (OSError, json.JSONDecodeError):
    print("pre-calibration")
    sys.exit(0)
if not isinstance(data, dict):
    print("pre-calibration")
    sys.exit(0)
key = os.environ["JUDGE_ID"] + ":" + os.environ["JUDGE_VERSION"]
entry = data.get(key)
if not isinstance(entry, dict):
    print("pre-calibration")
    sys.exit(0)
state = entry.get("calibration_state")
if state in ("calibrated", "pre-calibration", "calibration-failed", "unknown"):
    print(state)
else:
    print("pre-calibration")
'
}

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
# Wired artifact types: task-claims (from _work/<slug>/task-claims.jsonl),
# omission (from _work/<slug>/audit-candidates.jsonl), consumption-contradiction
# (from _work/<slug>/consumption-contradictions.jsonl). Other producer
# surfaces (e.g. /pr-review followups) keep their artifacts local without
# routing them through this pipeline.

ARTIFACT_PATH=""
ARTIFACT_TYPE=""

if [[ -f "$ARTIFACT_ID" || -d "$ARTIFACT_ID" ]]; then
  ARTIFACT_PATH="$ARTIFACT_ID"
  ARTIFACT_TYPE="path-provided"
elif [[ -d "$KDIR/_work/$ARTIFACT_ID" ]]; then
  ARTIFACT_PATH="$KDIR/_work/$ARTIFACT_ID"
  ARTIFACT_TYPE="work-item"
elif [[ -d "$KDIR/_work/_archive/$ARTIFACT_ID" ]]; then
  ARTIFACT_PATH="$KDIR/_work/_archive/$ARTIFACT_ID"
  ARTIFACT_TYPE="work-item-archived"
elif [[ -d "$KDIR/_followups/$ARTIFACT_ID" ]]; then
  ARTIFACT_PATH="$KDIR/_followups/$ARTIFACT_ID"
  ARTIFACT_TYPE="followup"
else
  echo "[audit] Error: could not resolve artifact-id '$ARTIFACT_ID'" >&2
  echo "[audit]   Tried: \$ARTIFACT_ID as path, \$KDIR/_work/\$ARTIFACT_ID, \$KDIR/_work/_archive/\$ARTIFACT_ID, \$KDIR/_followups/\$ARTIFACT_ID" >&2
  exit 1
fi

# --- Artifact-type refinement ---
# Path-provided arguments must point at a per-kind source file; directory
# inputs resolve to the first per-kind file present. The dispatch is closed:
# only the three live streams are recognized.
TASK_CLAIMS_PATH=""
AUDIT_CANDIDATES_PATH=""
CONSUMPTION_CONTRADICTIONS_PATH=""

if [[ "$ARTIFACT_TYPE" == "path-provided" ]]; then
  if [[ "$ARTIFACT_PATH" == *"/task-claims.jsonl" && -f "$ARTIFACT_PATH" ]]; then
    TASK_CLAIMS_PATH="$ARTIFACT_PATH"
    ARTIFACT_TYPE="task-claims"
  elif [[ "$ARTIFACT_PATH" == *"/audit-candidates.jsonl" && -f "$ARTIFACT_PATH" ]]; then
    AUDIT_CANDIDATES_PATH="$ARTIFACT_PATH"
    ARTIFACT_TYPE="omission"
  elif [[ "$ARTIFACT_PATH" == *"/consumption-contradictions.jsonl" && -f "$ARTIFACT_PATH" ]]; then
    CONSUMPTION_CONTRADICTIONS_PATH="$ARTIFACT_PATH"
    ARTIFACT_TYPE="consumption-contradiction"
  elif [[ -d "$ARTIFACT_PATH" && -f "$ARTIFACT_PATH/task-claims.jsonl" ]]; then
    TASK_CLAIMS_PATH="$ARTIFACT_PATH/task-claims.jsonl"
    ARTIFACT_TYPE="task-claims"
  elif [[ -d "$ARTIFACT_PATH" && -f "$ARTIFACT_PATH/audit-candidates.jsonl" ]]; then
    AUDIT_CANDIDATES_PATH="$ARTIFACT_PATH/audit-candidates.jsonl"
    ARTIFACT_TYPE="omission"
  elif [[ -d "$ARTIFACT_PATH" && -f "$ARTIFACT_PATH/consumption-contradictions.jsonl" ]]; then
    CONSUMPTION_CONTRADICTIONS_PATH="$ARTIFACT_PATH/consumption-contradictions.jsonl"
    ARTIFACT_TYPE="consumption-contradiction"
  fi
elif [[ "$ARTIFACT_TYPE" == "work-item" || "$ARTIFACT_TYPE" == "work-item-archived" ]]; then
  # Artifact presence, not directory presence, decides the owning dir: an
  # active stub dir can coexist with the archive copy that actually holds the
  # source files (e.g. after `lore work archive` leaves a stub behind). When
  # the active dir holds none of the three auto-discoverable files but the
  # archive sibling holds at least one, re-pin to the archive copy so the
  # source resolves and verdicts land beside it.
  if [[ "$ARTIFACT_TYPE" == "work-item" \
        && ! -f "$ARTIFACT_PATH/task-claims.jsonl" \
        && ! -f "$ARTIFACT_PATH/audit-candidates.jsonl" \
        && ! -f "$ARTIFACT_PATH/consumption-contradictions.jsonl" ]]; then
    _archive_sibling="$KDIR/_work/_archive/$ARTIFACT_ID"
    if [[ -f "$_archive_sibling/task-claims.jsonl" \
          || -f "$_archive_sibling/audit-candidates.jsonl" \
          || -f "$_archive_sibling/consumption-contradictions.jsonl" ]]; then
      echo "[audit] Active work-item dir holds no source artifact; using archive copy: $_archive_sibling" >&2
      ARTIFACT_PATH="$_archive_sibling"
      ARTIFACT_TYPE="work-item-archived"
    fi
  fi
  if [[ -f "$ARTIFACT_PATH/task-claims.jsonl" ]]; then
    TASK_CLAIMS_PATH="$ARTIFACT_PATH/task-claims.jsonl"
    ARTIFACT_TYPE="task-claims"
  elif [[ -f "$ARTIFACT_PATH/audit-candidates.jsonl" ]]; then
    AUDIT_CANDIDATES_PATH="$ARTIFACT_PATH/audit-candidates.jsonl"
    ARTIFACT_TYPE="omission"
  elif [[ -f "$ARTIFACT_PATH/consumption-contradictions.jsonl" ]]; then
    CONSUMPTION_CONTRADICTIONS_PATH="$ARTIFACT_PATH/consumption-contradictions.jsonl"
    ARTIFACT_TYPE="consumption-contradiction"
  fi
fi

# --- Per-kind dispatch override ---
# When --kind/--id are supplied, force the per-kind source file path and emit
# structured errors for absent/duplicated/malformed/kind-mismatched rows. The
# row's natural id must match exactly once in the per-kind file; any other
# count is a hard error.
KIND_DISPATCH_ID=""
KIND_DISPATCH_KIND=""
if [[ -n "$KIND_FLAG" && -n "$ID_FLAG" ]]; then
  KIND_DISPATCH_KIND="$KIND_FLAG"
  KIND_DISPATCH_ID="$ID_FLAG"
  # Resolve the per-kind source file under the already-resolved $ARTIFACT_PATH,
  # which the earlier artifact-id resolver set to either _work/<slug>/ or
  # _work/_archive/<slug>/ as appropriate.
  case "$KIND_FLAG" in
    task-claim)
      kind_basename="task-claims.jsonl"
      kind_id_field="claim_id"
      ;;
    omission)
      kind_basename="audit-candidates.jsonl"
      kind_id_field="candidate_id"
      ;;
    consumption-contradiction)
      kind_basename="consumption-contradictions.jsonl"
      kind_id_field="contradiction_id"
      ;;
    commons)
      kind_basename="promoted-commons.jsonl"
      kind_id_field="claim_id"
      ;;
  esac
  kind_source_file="$ARTIFACT_PATH/$kind_basename"
  # Artifact presence decides the owning dir for the per-kind file too: when
  # the resolved dir lacks it, probe active then archive by slug. Probes match
  # the exact per-kind path at the dir root — verdicts/ subdirs reuse the
  # task-claims.jsonl filename for verdict envelopes and must never match.
  if [[ ! -f "$kind_source_file" ]]; then
    for _kind_dir in "$KDIR/_work/$ARTIFACT_ID" "$KDIR/_work/_archive/$ARTIFACT_ID"; do
      if [[ -f "$_kind_dir/$kind_basename" ]]; then
        echo "[audit] Resolved dir lacks $kind_basename; using copy at: $_kind_dir/$kind_basename" >&2
        ARTIFACT_PATH="$_kind_dir"
        kind_source_file="$_kind_dir/$kind_basename"
        break
      fi
    done
  fi
  if [[ ! -f "$kind_source_file" ]]; then
    echo "[audit] Error: --kind $KIND_FLAG source file not found: $kind_source_file" >&2
    exit 1
  fi
  # Count matching rows.
  match_count=$(KIND_FILE="$kind_source_file" KIND_ID="$ID_FLAG" KIND_ID_FIELD="$kind_id_field" python3 - <<'PYEOF'
import json, os
n = 0
field = os.environ["KIND_ID_FIELD"]
want = os.environ["KIND_ID"]
with open(os.environ["KIND_FILE"], encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(row, dict):
            continue
        if str(row.get(field) or "") == want:
            n += 1
print(n)
PYEOF
)
  if [[ "$match_count" -eq 0 ]]; then
    echo "[audit] Error: --kind $KIND_FLAG --id $ID_FLAG resolved 0 source rows in $kind_source_file" >&2
    exit 1
  fi
  if [[ "$match_count" -gt 1 ]]; then
    echo "[audit] Error: --kind $KIND_FLAG --id $ID_FLAG resolved $match_count source rows in $kind_source_file (expected exactly 1)" >&2
    exit 1
  fi
  # Pin ARTIFACT_PATH/TYPE/KIND_*_PATH to the per-kind file so downstream
  # extractor and pipeline plumbing see exactly that one row.
  case "$KIND_FLAG" in
    task-claim)
      TASK_CLAIMS_PATH="$kind_source_file"
      AUDIT_CANDIDATES_PATH=""
      CONSUMPTION_CONTRADICTIONS_PATH=""
      ARTIFACT_TYPE="task-claims"
      ;;
    omission)
      TASK_CLAIMS_PATH=""
      AUDIT_CANDIDATES_PATH="$kind_source_file"
      CONSUMPTION_CONTRADICTIONS_PATH=""
      ARTIFACT_TYPE="omission"
      ;;
    consumption-contradiction)
      TASK_CLAIMS_PATH=""
      AUDIT_CANDIDATES_PATH=""
      CONSUMPTION_CONTRADICTIONS_PATH="$kind_source_file"
      ARTIFACT_TYPE="consumption-contradiction"
      ;;
    commons)
      # A promoted-commons.jsonl row carries claim_id + claim + falsifier, so the
      # task-claims extractor reads it directly; ARTIFACT_TYPE=commons keeps the
      # provenance legible while the gate dispatch below routes it to the
      # assertion fork (no per-kind extractor or gate template needed).
      TASK_CLAIMS_PATH="$kind_source_file"
      AUDIT_CANDIDATES_PATH=""
      CONSUMPTION_CONTRADICTIONS_PATH=""
      ARTIFACT_TYPE="commons"
      ;;
  esac
  ARTIFACT_PATH="$kind_source_file"
  # Synthesize a priority-claims file from the single resolved id so the
  # downstream filter narrows claim_payload to that one row. The extractor
  # surfaces `claim_id` on each claim — for task-claim/omission that's the
  # natural row id (claim_id|candidate_id), so the dispatch id flows through
  # directly. For consumption-contradiction the row's natural id is
  # `contradiction_id` but the extractor's per-claim id is the wrapped
  # `claim_payload.claim_id`; pull that value out so the priority filter
  # matches what the extractor emits.
  KIND_PRIORITY_TMP=$(mktemp "${TMPDIR:-/tmp}/audit-kind-priority.XXXXXX")
  if [[ "$KIND_FLAG" == "consumption-contradiction" ]]; then
    priority_id=$(KIND_FILE="$kind_source_file" KIND_ID="$ID_FLAG" python3 - <<'PYEOF'
import json, os
want = os.environ["KIND_ID"]
with open(os.environ["KIND_FILE"], encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(row, dict):
            continue
        if str(row.get("contradiction_id") or "") == want:
            payload = row.get("claim_payload") if isinstance(row.get("claim_payload"), dict) else {}
            inner = payload.get("claim_id")
            print(str(inner) if inner else want)
            break
    else:
        print(want)
PYEOF
)
    printf '["%s"]\n' "$priority_id" > "$KIND_PRIORITY_TMP"
  else
    printf '["%s"]\n' "$ID_FLAG" > "$KIND_PRIORITY_TMP"
  fi
  PRIORITY_CLAIMS_FILE="$KIND_PRIORITY_TMP"
fi

# --- Build the resolved input object once (per contract.md) ---
# Used by both the dry-run path and the judge invocation path. Per
# architecture/evidence/audit-pipeline-contract.md the shape is:
#   {artifact_id, artifact_type, artifact_path, kdir,
#    claim_payload[], referenced_files[], change_context, ...}
# Each per-kind source file produces one claim per row; rows with missing
# required fields are skipped with a diagnostic, an empty result is a hard
# error. Branch-aware reconciliation per Appendix B of the plan is future work.
build_resolved_input() {
  local dry_run_flag="$1"  # "true" or "false"
  python3 - "$ARTIFACT_ID" "$ARTIFACT_PATH" "$ARTIFACT_TYPE" "$KDIR" "$TASK_CLAIMS_PATH" "$AUDIT_CANDIDATES_PATH" "$CONSUMPTION_CONTRADICTIONS_PATH" "$dry_run_flag" << 'PYEOF'
import json, re, sys
artifact_id, artifact_path, artifact_type, kdir, task_claims_path, audit_candidates_path, consumption_contradictions_path, dry_run_flag = sys.argv[1:9]

out = {
    "artifact_id": artifact_id,
    "artifact_path": artifact_path,
    "artifact_type": artifact_type,
    "kdir": kdir,
}

def normalize_change_context(row, claim):
    raw = row.get("change_context")
    if isinstance(raw, dict):
        changed_files = [
            str(v)
            for v in raw.get("changed_files", [])
            if isinstance(v, str) and v.strip()
        ] if isinstance(raw.get("changed_files"), list) else []
        summary = raw.get("summary") if isinstance(raw.get("summary"), str) else ""
        diff_ref = raw.get("diff_ref")
        if diff_ref is not None and not isinstance(diff_ref, str):
            diff_ref = None
        if changed_files and summary.strip():
            return {
                "diff_ref": diff_ref,
                "changed_files": list(dict.fromkeys(changed_files)),
                "summary": summary.strip(),
            }
    file_path = claim.get("file")
    summary = row.get("why_this_work_needs_it") or row.get("claim") or row.get("claim_text") or ""
    if isinstance(file_path, str) and file_path.strip() and isinstance(summary, str) and summary.strip():
        return {
            "diff_ref": row.get("captured_at_sha") if isinstance(row.get("captured_at_sha"), str) else None,
            "changed_files": [file_path],
            "summary": summary.strip(),
        }
    return None

def merge_change_context(claims):
    changed_files = []
    summaries = []
    diff_ref = None
    for claim in claims:
        ctx = claim.get("change_context")
        if not isinstance(ctx, dict):
            continue
        if diff_ref is None and isinstance(ctx.get("diff_ref"), str) and ctx.get("diff_ref"):
            diff_ref = ctx.get("diff_ref")
        for file_path in ctx.get("changed_files", []) if isinstance(ctx.get("changed_files"), list) else []:
            if isinstance(file_path, str) and file_path.strip() and file_path not in changed_files:
                changed_files.append(file_path)
        summary = ctx.get("summary")
        if isinstance(summary, str) and summary.strip() and summary.strip() not in summaries:
            summaries.append(summary.strip())
    if not changed_files or not summaries:
        return None
    return {
        "diff_ref": diff_ref,
        "changed_files": changed_files,
        "summary": " | ".join(summaries),
    }

if dry_run_flag == "true":
    out["dry_run"] = True
    out["note"] = "See architecture/evidence/audit-pipeline-contract.md for the full resolved-input object shape."

# Populate work_item from path when artifact lives under $KDIR/_work/<slug>/.
# Required for audit-queue-route.sh canonical routing (vs. direct-write fallback).
# Handles both active (/_work/<slug>/) and archived (/_work/_archive/<slug>/)
# paths. Without the _archive-aware branch, the regex would greedily capture
# '_archive' as the slug for any archived artifact, contaminating downstream
# routing and producing phantom stubs at $KDIR/_work/_archive/verdicts/.
_work_match = re.search(r'/_work/([^/]+)(?:/([^/]+))?(?:/|$)', artifact_path)
if _work_match:
    first, second = _work_match.group(1), _work_match.group(2)
    if first == "_archive" and second:
        out["work_item"] = second
    elif first != "_archive":
        out["work_item"] = first

if task_claims_path:
    claims = []
    skipped = []
    try:
        with open(task_claims_path, encoding="utf-8") as fh:
            for line_no, line in enumerate(fh, start=1):
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError as e:
                    skipped.append(f"line {line_no}: JSONDecodeError: {e}")
                    continue
                if not isinstance(row, dict):
                    skipped.append(f"line {line_no}: row is not an object")
                    continue
                claim_id = str(row.get("claim_id") or "")
                claim_text = str(row.get("claim") or row.get("claim_text") or "")
                if not claim_id:
                    skipped.append(f"line {line_no}: missing claim_id")
                    continue
                if not claim_text:
                    skipped.append(f"{claim_id}: missing claim")
                    continue
                source = row.get("source") if isinstance(row.get("source"), dict) else {}
                file_path = row.get("file") or source.get("file")
                line_range = row.get("line_range") or source.get("line_range")
                # Slow-path routing is explicit via `provenance: "legacy-no-snippet"`.
                # Pre-Phase-2 the routing was implicit-but-correct: snippet/hash
                # absent → gate had no anchor to verify → fell through to slow
                # path naturally. The migration writer (evidence-update.sh) now
                # marks unrecoverable legacy rows with the explicit flag, so we
                # surface it here as a first-class field. The gate templates
                # treat it as the deterministic slow-path signal.
                provenance = row.get("provenance") or None
                claim = {
                    "claim_id": claim_id,
                    "claim_text": claim_text,
                    "file": file_path or None,
                    "line_range": line_range or None,
                    "exact_snippet": row.get("exact_snippet") or None,
                    "normalized_snippet_hash": row.get("normalized_snippet_hash") or None,
                    "provenance": provenance,
                    "falsifier": row.get("falsifier") or row.get("why_this_work_needs_it") or None,
                    "severity_hint": row.get("significance") or row.get("scale") or None,
                    "producer_role": row.get("producer_role") or None,
                    "protocol_slot": row.get("protocol_slot") or None,
                    "task_id": row.get("task_id") or None,
                    "phase_id": row.get("phase_id") or None,
                    "scale": row.get("scale") or None,
                    "evidence_ref": {"path": task_claims_path, "line": line_no},
                }
                claim["change_context"] = normalize_change_context(row, claim)
                claims.append(claim)
    except OSError as e:
        print(f"[audit] extractor: could not read task-claims.jsonl — {e}", file=sys.stderr)
        sys.exit(1)

    if not claims:
        reason = "; ".join(skipped) if skipped else "no task-claim rows found in task-claims.jsonl"
        print(f"[audit] extractor: {reason}", file=sys.stderr)
        sys.exit(1)

    out["task_claims_path"] = task_claims_path
    out["claim_payload"] = claims
    out["claim_count"] = len(claims)
    out["change_context"] = merge_change_context(claims)
    out["producer_role"] = "worker"
    out["producer_template_version"] = "task-claims-jsonl"
    if skipped:
        out["task_claims_skipped"] = skipped

elif audit_candidates_path:
    # Omission claims emitted by the reverse-auditor and routed through
    # grounding-preflight already enforce file/line_range/falsifier. We expose
    # each as a one-claim payload so the correctness-gate can adjudicate.
    claims = []
    skipped = []
    try:
        with open(audit_candidates_path, encoding="utf-8") as fh:
            for line_no, line in enumerate(fh, start=1):
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError as e:
                    skipped.append(f"line {line_no}: JSONDecodeError: {e}")
                    continue
                if not isinstance(row, dict):
                    skipped.append(f"line {line_no}: row is not an object")
                    continue
                candidate_id = str(row.get("candidate_id") or "")
                if not candidate_id:
                    skipped.append(f"line {line_no}: missing candidate_id")
                    continue
                file_path = row.get("file")
                line_range = row.get("line_range")
                falsifier = row.get("falsifier")
                if not (file_path and line_range and falsifier):
                    skipped.append(f"{candidate_id}: missing one of file/line_range/falsifier")
                    continue
                claim = {
                    "claim_id": candidate_id,
                    "claim_text": row.get("rationale") or row.get("why_it_matters") or "",
                    "file": file_path,
                    "line_range": line_range,
                    "exact_snippet": row.get("exact_snippet") or None,
                    "normalized_snippet_hash": row.get("normalized_snippet_hash") or None,
                    "falsifier": falsifier,
                    "evidence_ref": {"path": audit_candidates_path, "line": line_no},
                }
                claims.append(claim)
    except OSError as e:
        print(f"[audit] extractor: could not read audit-candidates.jsonl — {e}", file=sys.stderr)
        sys.exit(1)

    if not claims:
        reason = "; ".join(skipped) if skipped else "no omission rows found in audit-candidates.jsonl"
        print(f"[audit] extractor: {reason}", file=sys.stderr)
        sys.exit(1)

    out["audit_candidates_path"] = audit_candidates_path
    out["claim_payload"] = claims
    out["claim_count"] = len(claims)
    out["producer_role"] = "reverse-auditor"
    out["producer_template_version"] = "audit-candidates-jsonl"
    if skipped:
        out["audit_candidates_skipped"] = skipped

elif consumption_contradictions_path:
    # Consumption-contradiction rows already carry a fully-grounded
    # claim_payload (architecture/consumption-contradictions/sidecar-schema.md).
    # We unwrap that payload as the per-claim input the gate adjudicates.
    claims = []
    skipped = []
    try:
        with open(consumption_contradictions_path, encoding="utf-8") as fh:
            for line_no, line in enumerate(fh, start=1):
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError as e:
                    skipped.append(f"line {line_no}: JSONDecodeError: {e}")
                    continue
                if not isinstance(row, dict):
                    skipped.append(f"line {line_no}: row is not an object")
                    continue
                contradiction_id = str(row.get("contradiction_id") or "")
                if not contradiction_id:
                    skipped.append(f"line {line_no}: missing contradiction_id")
                    continue
                payload = row.get("claim_payload") if isinstance(row.get("claim_payload"), dict) else {}
                if not (payload.get("file") and payload.get("line_range") and payload.get("falsifier")):
                    skipped.append(f"{contradiction_id}: missing one of claim_payload.file/line_range/falsifier")
                    continue
                claim = {
                    "claim_id": payload.get("claim_id") or contradiction_id,
                    "claim_text": payload.get("claim_text") or row.get("contradiction_rationale") or "",
                    "file": payload.get("file"),
                    "line_range": payload.get("line_range"),
                    "exact_snippet": payload.get("exact_snippet") or None,
                    "normalized_snippet_hash": payload.get("normalized_snippet_hash") or None,
                    "falsifier": payload.get("falsifier"),
                    "evidence_ref": {"path": consumption_contradictions_path, "line": line_no, "contradiction_id": contradiction_id},
                }
                claims.append(claim)
    except OSError as e:
        print(f"[audit] extractor: could not read consumption-contradictions.jsonl — {e}", file=sys.stderr)
        sys.exit(1)

    if not claims:
        reason = "; ".join(skipped) if skipped else "no rows found in consumption-contradictions.jsonl"
        print(f"[audit] extractor: {reason}", file=sys.stderr)
        sys.exit(1)

    out["consumption_contradictions_path"] = consumption_contradictions_path
    out["claim_payload"] = claims
    out["claim_count"] = len(claims)
    out["producer_role"] = "consumer-contradiction-channel"
    out["producer_template_version"] = "consumption-contradictions-jsonl"
    if skipped:
        out["consumption_contradictions_skipped"] = skipped

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
    if [[ -n "$TASK_CLAIMS_PATH" ]]; then
      echo "[audit]   task_claims: $TASK_CLAIMS_PATH"
      _claim_count=$(python3 -c '
import json, sys
n = 0
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        continue
    if isinstance(row, dict) and row.get("claim_id"):
        n += 1
print(n)
' "$TASK_CLAIMS_PATH" 2>/dev/null || echo "?")
      echo "[audit]   claim_count:   $_claim_count (per-task-claim → claim_id from row)"
    fi
    if [[ -n "$AUDIT_CANDIDATES_PATH" ]]; then
      echo "[audit]   audit_candidates: $AUDIT_CANDIDATES_PATH"
      _claim_count=$(python3 -c '
import json, sys
n = 0
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        continue
    if isinstance(row, dict) and row.get("candidate_id"):
        n += 1
print(n)
' "$AUDIT_CANDIDATES_PATH" 2>/dev/null || echo "?")
      echo "[audit]   claim_count:   $_claim_count (per-omission → claim_id=candidate_id from row)"
    fi
    if [[ -n "$CONSUMPTION_CONTRADICTIONS_PATH" ]]; then
      echo "[audit]   consumption_contradictions: $CONSUMPTION_CONTRADICTIONS_PATH"
      _claim_count=$(python3 -c '
import json, sys
n = 0
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        continue
    if isinstance(row, dict) and row.get("contradiction_id"):
        n += 1
print(n)
' "$CONSUMPTION_CONTRADICTIONS_PATH" 2>/dev/null || echo "?")
      echo "[audit]   claim_count:   $_claim_count (per-contradiction → claim_id from claim_payload)"
    fi
    echo "[audit] Stub implementation — no judges spawned."
    echo "[audit] See $KDIR/architecture/evidence/audit-pipeline-contract.md for the full pipeline."
  fi
  exit 0
fi

# --- Judge pipeline ---
# Judge 1 (correctness-gate) is wired (task #12). Judge 2 (curator, task #17)
# and Judge 3 (reverse-auditor, task #22) land with their own wiring tasks
# and replace the placeholders below.

# Map the dispatched ARTIFACT_TYPE to the kind-specialized correctness-gate
# fork. Each kind has its own agent template + calibration log:
#   task-claims              → correctness-gate-assertion     (hard-cal)
#   omission                 → correctness-gate-omission      (soft-cal-with-discrimination)
#   consumption-contradiction→ correctness-gate-contradiction (hard-cal)
# The marker file and per-gate logs are keyed by the kind-specialized template
# name; the dispatcher resolves that name once and threads it through the
# scorecard rows + the per-claim verdicts envelope.
case "$ARTIFACT_TYPE" in
  task-claims)
    GATE_TEMPLATE_NAME="correctness-gate-assertion"
    ;;
  omission)
    GATE_TEMPLATE_NAME="correctness-gate-omission"
    ;;
  consumption-contradiction)
    GATE_TEMPLATE_NAME="correctness-gate-contradiction"
    ;;
  commons)
    # Commons-entry claims are assertion-style (claim + falsifier); reuse the
    # assertion gate. Verdict rows stay tier:reusable like every other kind
    # routed through this gate, so /evolve excludes them by construction (D4).
    GATE_TEMPLATE_NAME="correctness-gate-assertion"
    ;;
  *)
    # Path-provided artifacts that did not match any per-kind file still need a
    # gate to adjudicate them; default to the assertion fork because its
    # adjudication discipline is the closest match for free-form task-claim
    # style claims. The dispatcher above narrows ARTIFACT_TYPE to one of the
    # three live kinds whenever a per-kind file is present, so this branch is
    # reached only for unrecognized path inputs (a rare legacy path).
    GATE_TEMPLATE_NAME="correctness-gate-assertion"
    ;;
esac

if ! CORRECTNESS_GATE_TEMPLATE=$(resolve_agent_template "$GATE_TEMPLATE_NAME" 2>/dev/null); then
  echo "[audit] Error: $GATE_TEMPLATE_NAME agent template not resolvable via resolve_agent_template." >&2
  echo "[audit]   Run install.sh to populate the canonical agents/ directory and the active harness's agent install path." >&2
  exit 1
fi

GATE_TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" "$CORRECTNESS_GATE_TEMPLATE")
GATE_TEMPLATE_ID="$GATE_TEMPLATE_NAME"

# Build the resolved input object and stash it in a tmp file.
RESOLVED_INPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/audit-input.XXXXXX")
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
  if [[ -n "${KIND_PRIORITY_TMP:-}" ]]; then
    rm -f "$KIND_PRIORITY_TMP" 2>/dev/null || true
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
  _priority_narrowed=$(mktemp "${TMPDIR:-/tmp}/audit-input-narrowed.XXXXXX")
  if ! jq --slurpfile priority "$PRIORITY_CLAIMS_FILE" '
    ($priority[0]) as $ids
    | (.claim_payload // []) as $orig
    | .claim_payload = [ $orig[] | select(.claim_id as $cid | $ids | index($cid)) ]
    | .claim_count = (.claim_payload | length)
    | .change_context = (
        (.claim_payload // []) as $claims
        | {
            diff_ref: ([ $claims[] | .change_context.diff_ref? // empty | select(type == "string" and length > 0) ] | .[0] // null),
            changed_files: ([ $claims[] | ((.change_context.changed_files[]? // .file? // empty) | select(type == "string" and length > 0)) ] | unique),
            summary: ([ $claims[] | (.change_context.summary? // .claim_text? // empty | select(type == "string" and length > 0)) ] | unique | join(" | "))
          }
      )
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

# Obtain correctness-gate output JSON.
GATE_RAW_FILE=""
if [[ -n "$GATE_OUTPUT_FILE" ]]; then
  # Mode 1: orchestrator/test injection.
  if [[ ! -f "$GATE_OUTPUT_FILE" ]]; then
    echo "[audit] Error: --gate-output-file not found: $GATE_OUTPUT_FILE" >&2
    exit 1
  fi
  GATE_RAW_FILE="$GATE_OUTPUT_FILE"
  echo "[audit] $GATE_TEMPLATE_ID: reading pre-computed output from $GATE_OUTPUT_FILE" >&2
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
    echo "[audit]   or set harnesses.<active>.roles.judge in ~/.lore/config/settings.json (or pass --model <model>)" >&2
    echo "[audit]   to use the \`claude\` headless runner direct-invocation fallback." >&2
    exit 1
  fi
  GATE_RAW_TMP=$(mktemp "${TMPDIR:-/tmp}/audit-gate-output.XXXXXX")
  GATE_RAW_FILE="$GATE_RAW_TMP"
  GATE_SYSTEM_PROMPT_FILE="$CORRECTNESS_GATE_TEMPLATE"
  GATE_USER_PROMPT="Resolved input object (per architecture/evidence/audit-pipeline-contract.md):

$(cat "$RESOLVED_INPUT_FILE")

Use judge: $GATE_TEMPLATE_ID
Use judge_template_version: $GATE_TEMPLATE_VERSION

Emit exactly one JSON object matching the Correctness-gate output shape. No markdown fences. No prose outside the JSON."
  echo "[audit] $GATE_TEMPLATE_ID: invoking headless runner (template-version: $GATE_TEMPLATE_VERSION, model: $JUDGE_MODEL)" >&2
  if ! headless_runner_invoke "$GATE_SYSTEM_PROMPT_FILE" "$GATE_USER_PROMPT" "$GATE_RAW_FILE"; then
    echo "[audit] Error: headless runner invocation failed for $GATE_TEMPLATE_ID" >&2
    exit 1
  fi
fi

# Validate correctness-gate output shape per contract.md. Required:
#   judge ∈ {correctness-gate-assertion, correctness-gate-omission,
#            correctness-gate-contradiction}; the per-claim verdicts shape is
#            identical across the three forks (the kind specialization lives in
#            the template prose + per-gate calibration fixture set, not in the
#            output schema). Legacy "correctness-gate" is accepted as a
#            transitional alias during the Phase 4 cutover.
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

VALID_JUDGES = {
    "correctness-gate-assertion",
    "correctness-gate-omission",
    "correctness-gate-contradiction",
    # Legacy alias kept readable until Phase 4 cutover drains pre-fork verdict files.
    "correctness-gate",
}

errs = []
if not isinstance(obj, dict):
    errs.append("output is not a JSON object")
else:
    if obj.get("judge") not in VALID_JUDGES:
        errs.append(f"judge not in {sorted(VALID_JUDGES)} (got {obj.get('judge')!r})")
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
#   - If the artifact lives under $KDIR/_work/<slug>/ (directory or per-kind
#     source file), verdicts land at $KDIR/_work/<slug>/verdicts/<basename>.jsonl.
#   - If the artifact lives under $KDIR/_followups/<slug>/, verdicts land at
#     $KDIR/_followups/<slug>/verdicts/<basename>.jsonl.
#   - Otherwise, verdicts land at $KDIR/_audit/verdicts/<basename>.jsonl.
# The basename is the resolved artifact path's last segment, stripped of any
# file extension, so repeated audits of the same artifact append to the same
# file.

OWNING_DIR=""
if [[ "$ARTIFACT_PATH" == "$KDIR/_work/"* ]]; then
  # $KDIR/_work/<slug>/ or $KDIR/_work/<slug>/<per-kind source file>
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
# Attribution: producer template_id/version come from the resolved-input
# fields the extractor populated per-kind (producer_role and
# producer_template_version). Missing values fall back to "unknown" +
# calibration_state=pre-calibration, which /retro surfaces but /evolve's
# gate rejects.

if [[ $SKIP_SCORECARD -eq 0 ]]; then
  GATE_CALIBRATION_STATE=$(read_calibration_state "$GATE_TEMPLATE_ID" "$GATE_TEMPLATE_VERSION")
  ROWS_JSON=$(python3 - "$GATE_RAW_FILE" "$RESOLVED_INPUT_FILE" "$GATE_TEMPLATE_VERSION" "$GATE_CALIBRATION_STATE" "$GATE_TEMPLATE_ID" << 'PYEOF'
import json, sys, datetime

gate_file, input_file, gate_template_version, calibration_state, gate_template_id = sys.argv[1:6]
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

# calibration_state: read from $KDIR/_scorecards/calibration-state.json
# keyed by (correctness-gate, gate_template_version) by the bash caller and
# passed in as argv[4]. Defaults to "pre-calibration" on missing file or
# missing keyed entry. audit-artifact.sh is a marker reader only — it never
# writes the marker or the history sidecar.

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
    "verdict_source": gate_template_id,
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
        CURATOR_RAW_TMP=$(mktemp "${TMPDIR:-/tmp}/audit-curator-output.XXXXXX")
        CURATOR_RAW_FILE="$CURATOR_RAW_TMP"
        # Compose curator input: verified survivors + the original resolved input.
        CURATOR_INPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/audit-curator-input.XXXXXX")
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

Use judge_template_version: $CURATOR_TEMPLATE_VERSION

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
        CURATOR_CALIBRATION_STATE=$(read_calibration_state "curator" "$CURATOR_TEMPLATE_VERSION")
        CUR_ROWS_JSON=$(python3 - "$CURATOR_RAW_FILE" "$RESOLVED_INPUT_FILE" "$CURATOR_TEMPLATE_VERSION" "$N_VERIFIED_COUNT" "$CURATOR_CALIBRATION_STATE" << 'PYEOF'
import json, sys, datetime

cur_file, input_file, curator_tv, n_verified, calibration_state = sys.argv[1:6]
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
    "calibration_state": calibration_state,
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
REVERSE_AUDITOR_INLINED_FILE=""        # set only on the claude -p path (injected outputs skip inlining)
REVERSE_AUDITOR_VERDICT="none"          # none | omission-claim | silence | insufficient-evidence | preflight-failed
# Reason enum per architecture/evidence/audit-pipeline-contract.md:
#   silence | ok | verified-with-drift                          (pass-side)
#   file-missing | line-out-of-range | snippet-mismatch |
#   field-missing | provenance-unknown                          (fail-side)
# verified-with-drift is a softened pass (substring fallback hit after
# the line/hash anchor drifted); provenance-unknown is an environment-
# class failure (no clone has the content) distinct from the producer-
# class failures (snippet disagreed).
REVERSE_AUDITOR_PREFLIGHT_REASON=""
REVERSE_AUDITOR_QUEUE_DEST=""           # candidates | attempts | silence | reattempt
REVERSE_AUDITOR_COVERAGE_STATE=""       # covered | insufficient-evidence (read from emission)
REVERSE_AUDITOR_PREFLIGHT_SOFTENED=0    # 1 when reason == verified-with-drift (pass with drift)
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
        REVERSE_AUDITOR_RAW_TMP=$(mktemp "${TMPDIR:-/tmp}/audit-reverse-auditor-output.XXXXXX")
        REVERSE_AUDITOR_RAW_FILE="$REVERSE_AUDITOR_RAW_TMP"
        # Compose reverse-auditor input: curator's selected claims + the
        # original resolved input (artifact_id, work_item, change_context,
        # referenced_files). Per contract.md, reverse-auditor input is the
        # curator-surviving portfolio + original change.
        REVERSE_AUDITOR_INPUT_FILE=$(mktemp "${TMPDIR:-/tmp}/audit-reverse-auditor-input.XXXXXX")
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
        # Resolve the evidence the judge needs (snippet@HEAD + window, the diff
        # hunks for the changed files, content_locate_verdict per file) and
        # inline it, so the adjudicate-only judge has nothing left to fetch.
        # RA-scoped: only this callsite inlines; gate/curator inputs are
        # untouched. The inlined packet is also the verdict-envelope record.
        REVERSE_AUDITOR_INLINED_FILE=$(mktemp "${TMPDIR:-/tmp}/audit-reverse-auditor-inlined.XXXXXX")
        if ! LORE_REPO_ROOT="${LORE_REPO_ROOT:-$(pwd)}" KDIR="$KDIR" \
            python3 "$SCRIPT_DIR/reverse-auditor-inline-evidence.py" \
            "$REVERSE_AUDITOR_INPUT_FILE" "$REVERSE_AUDITOR_INLINED_FILE" \
            --lore-repo "${LORE_REPO_ROOT:-$(pwd)}" --kdir "$KDIR"; then
          echo "[audit] warning: inline-evidence resolution failed — judge will see unresolved packet" >&2
          cp "$REVERSE_AUDITOR_INPUT_FILE" "$REVERSE_AUDITOR_INLINED_FILE" 2>/dev/null || true
        fi
        REVERSE_AUDITOR_USER_PROMPT="Reverse-auditor input object — evidence already resolved and inlined under inlined_evidence (adjudicate from the packet alone; do not read files or run shell commands):

$(cat "$REVERSE_AUDITOR_INLINED_FILE")

Use judge_template_version: $REVERSE_AUDITOR_TEMPLATE_VERSION

Emit exactly one JSON object matching this Reverse-auditor output shape:
{
  \"judge\": \"reverse-auditor\",
  \"judge_template_version\": \"$REVERSE_AUDITOR_TEMPLATE_VERSION\",
  \"work_item\": \"<slug>\",
  \"artifact_id\": \"<id>\",
  \"coverage_state\": \"covered\",
  \"abstention_reason\": null,
  \"insufficient_evidence_refs\": null,
  \"omission_claim\": null,
  \"created_at\": \"<ISO-8601 UTC>\"
}
Set coverage_state to \"insufficient-evidence\" (with abstention_reason + insufficient_evidence_refs, omission_claim null) when the inlined packet is inadequate to adjudicate. If you emit an omission, replace omission_claim null with the omission_claim object required by the template and keep coverage_state \"covered\". Do not emit legacy fields such as verdict_source, verdict, or claim. No markdown fences. No prose outside the JSON."
        echo "[audit] reverse-auditor: invoking headless runner (template-version: $REVERSE_AUDITOR_TEMPLATE_VERSION, model: $JUDGE_MODEL)" >&2
        REVERSE_AUDITOR_SCHEMA_PATH="$SCRIPT_DIR/judge-schemas/reverse-auditor-output.schema.json"
        # --max-turns 3: the adjudicate-only judge has its evidence inlined, so
        # it needs no fetch turns. The cap is RA-scoped; gate/curator default.
        if ! headless_runner_invoke "$REVERSE_AUDITOR_TEMPLATE" "$REVERSE_AUDITOR_USER_PROMPT" "$REVERSE_AUDITOR_RAW_FILE" "$REVERSE_AUDITOR_SCHEMA_PATH" 3; then
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
      #   coverage_state in {covered, insufficient-evidence}
      #   omission_claim present: either null (silence/abstention) or object
      #     with all required fields (file, line_range, exact_snippet,
      #     normalized_snippet_hash, falsifier, why_it_matters).
      #   coverage_state == insufficient-evidence requires omission_claim null
      #     + a non-empty abstention_reason (the visible non-verdict shape).
      # The grounding preflight is a separate deterministic validator that
      # runs AFTER shape validation; shape-ok claims with bad anchors route
      # to audit-attempts.jsonl rather than failing the audit outright.
      RA_SHAPE_OK=$(python3 - "$REVERSE_AUDITOR_RAW_FILE" "$REVERSE_AUDITOR_TEMPLATE_VERSION" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        obj = json.load(fh)
except Exception as e:
    print(f"parse-error: {type(e).__name__}: {e}")
    sys.exit(0)

expected_tv = sys.argv[2]

errs = []
if not isinstance(obj, dict):
    errs.append("output is not a JSON object")
else:
    if obj.get("judge") != "reverse-auditor":
        errs.append(f"judge != 'reverse-auditor' (got {obj.get('judge')!r})")
    if obj.get("judge_template_version") != expected_tv:
        errs.append(f"judge_template_version mismatch: expected {expected_tv!r}, got {obj.get('judge_template_version')!r}")
    coverage_state = obj.get("coverage_state")
    if coverage_state not in ("covered", "insufficient-evidence"):
        errs.append(f"coverage_state must be 'covered' or 'insufficient-evidence' (got {coverage_state!r})")
    if "omission_claim" not in obj:
        errs.append("omission_claim field missing (must be object or null)")
    else:
        oc = obj["omission_claim"]
        if coverage_state == "insufficient-evidence":
            if oc is not None:
                errs.append("coverage_state=insufficient-evidence requires omission_claim null")
            if not obj.get("abstention_reason"):
                errs.append("coverage_state=insufficient-evidence requires non-empty abstention_reason")
        elif oc is not None:
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
      # record (append-only), mirroring the gate/curator pattern. The exact
      # inlined packet the judge adjudicated on (resolved snippet@HEAD +
      # window, the diff hunks, content_locate_verdict per file) is recorded
      # alongside the emission so the judged evidence stays reconstructible.
      python3 - "$REVERSE_AUDITOR_RAW_FILE" "$ARTIFACT_ID" "$VERDICTS_FILE" "$REVERSE_AUDITOR_INLINED_FILE" << 'PYEOF'
import json, sys, datetime
ra_file, artifact_id, verdicts_file, inlined_file = sys.argv[1:5]
with open(ra_file) as fh:
    obj = json.load(fh)
inlined_evidence = None
try:
    with open(inlined_file) as fh:
        inlined_evidence = json.load(fh).get("inlined_evidence")
except (OSError, json.JSONDecodeError, AttributeError):
    inlined_evidence = None
wrapped = {
    "artifact_id": artifact_id,
    "judge_run_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    **obj,
    "inlined_evidence": inlined_evidence,
}
with open(verdicts_file, "a") as fh:
    fh.write(json.dumps(wrapped) + "\n")
PYEOF

      # Repo root for resolving claim file paths — shared by re-anchoring and
      # the grounding preflight below. Points at the lore checkout (where the
      # source files the claim anchors reference live), not $KDIR. Default $PWD.
      PREFLIGHT_REPO_ROOT="${LORE_REPO_ROOT:-$(pwd)}"

      # Deterministic re-anchoring (between emission persistence and preflight).
      # The judge may quote real file content but with a diff-prefixed snippet
      # or a drifted line_range; reanchor-omission-claim.py relocates that same
      # content on disk and rewrites line_range/exact_snippet/normalized_snippet_hash
      # (recording a `reanchor` provenance block) so a strict --no-cascade
      # preflight pass certifies a TRUE anchor. No unique match → claim passes
      # through untouched and fails preflight as before. Tool error (non-zero
      # exit) → warn and keep the ORIGINAL emission, mirroring the preflight
      # invocation-failure guard; the audit never aborts. stdout is captured to
      # a temp file (pure JSON); all reanchor diagnostics go to stderr.
      REVERSE_AUDITOR_REANCHOR_TMP=$(mktemp "${TMPDIR:-/tmp}/audit-reverse-auditor-reanchor.XXXXXX")
      if python3 "$SCRIPT_DIR/reanchor-omission-claim.py" \
          --claim-file "$REVERSE_AUDITOR_RAW_FILE" \
          --repo-root "$PREFLIGHT_REPO_ROOT" \
          > "$REVERSE_AUDITOR_REANCHOR_TMP"; then
        # Re-anchor succeeded or passed through; both write a pure-JSON object.
        # Adopt the (possibly rewritten) emission as the canonical claim file.
        if [[ -s "$REVERSE_AUDITOR_REANCHOR_TMP" ]]; then
          mv "$REVERSE_AUDITOR_REANCHOR_TMP" "$REVERSE_AUDITOR_RAW_FILE"
        else
          rm -f "$REVERSE_AUDITOR_REANCHOR_TMP"
        fi
      else
        echo "[audit] warning: reanchor-omission-claim.py failed — using original emission unchanged" >&2
        rm -f "$REVERSE_AUDITOR_REANCHOR_TMP"
      fi

      REVERSE_AUDITOR_COVERAGE_STATE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("coverage_state") or "")' "$REVERSE_AUDITOR_RAW_FILE")

      REVERSE_AUDITOR_PREFLIGHT_TMP=$(mktemp "${TMPDIR:-/tmp}/audit-reverse-auditor-preflight.XXXXXX")

      # Classify the verdict for rollup + reporting.
      #   insufficient-evidence          → abstention; the inlined packet was
      #                                    inadequate to adjudicate. RA-local
      #                                    re-attempt signal — route to a
      #                                    re-attempt queue (NOT silence, NOT
      #                                    the gate-derived aggregate
      #                                    unverified). No claim to ground, so
      #                                    grounding-preflight is skipped.
      #   silence                        → no emission to route; rows
      #                                    reflect "nothing surfaced"
      #   pass (ok)                      → omission-claim; route to
      #                                    candidates queue
      #   pass (verified-with-drift)     → omission-claim with softened
      #                                    flag; route to candidates
      #                                    queue. Pass status, but
      #                                    /retro counts softened
      #                                    verifications separately.
      #   fail (provenance-unknown)      → preflight-failed; route to
      #                                    attempts. Environment-class
      #                                    failure; grounding_failure_rate
      #                                    telemetry carries
      #                                    failure_reason=provenance-unknown
      #                                    so /retro can distinguish it
      #                                    from producer-class failures.
      #   fail (any other reason)        → preflight-failed; route to
      #                                    attempts. Producer-class
      #                                    failure (file-missing,
      #                                    snippet-mismatch, etc.).
      if [[ "$REVERSE_AUDITOR_COVERAGE_STATE" == "insufficient-evidence" ]]; then
        REVERSE_AUDITOR_VERDICT="insufficient-evidence"
        REVERSE_AUDITOR_QUEUE_DEST="reattempt"
        REVERSE_AUDITOR_PREFLIGHT_REASON="insufficient-evidence"
        # Synthesize a non-pass preflight record so the abstention is
        # captured uniformly downstream without grounding a claim.
        printf '%s\n' '{"pass": false, "reason": "insufficient-evidence", "detail": "reverse-auditor abstained: inlined packet inadequate to adjudicate"}' > "$REVERSE_AUDITOR_PREFLIGHT_TMP"
      else
        # Run grounding preflight on the (possibly re-anchored) emission.
        # Silence short-circuits with reason=silence (preflight treats it as a
        # no-op pass). The RA omission anchors to snippet@HEAD the wrapper
        # inlined, so --no-cascade checks it against the on-disk file at
        # PREFLIGHT_REPO_ROOT (the lore checkout) — the same root re-anchoring
        # used, so a re-anchored claim's rewritten line_range resolves here.
        if ! python3 "$SCRIPT_DIR/grounding-preflight.py" \
            --claim-file "$REVERSE_AUDITOR_RAW_FILE" \
            --repo-root "$PREFLIGHT_REPO_ROOT" \
            --no-cascade \
            > "$REVERSE_AUDITOR_PREFLIGHT_TMP" 2>/dev/null; then
          echo "[audit] warning: grounding-preflight.py invocation failed — treating as preflight-failed" >&2
          printf '%s\n' '{"pass": false, "reason": "field-missing", "detail": "grounding-preflight.py invocation failed"}' > "$REVERSE_AUDITOR_PREFLIGHT_TMP"
        fi

        REVERSE_AUDITOR_PREFLIGHT_REASON=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("reason","unknown"))' "$REVERSE_AUDITOR_PREFLIGHT_TMP")
        REVERSE_AUDITOR_PREFLIGHT_PASS=$(python3 -c 'import json,sys; print("true" if json.load(open(sys.argv[1])).get("pass") else "false")' "$REVERSE_AUDITOR_PREFLIGHT_TMP")

        if [[ "$REVERSE_AUDITOR_PREFLIGHT_REASON" == "silence" ]]; then
          REVERSE_AUDITOR_VERDICT="silence"
          REVERSE_AUDITOR_QUEUE_DEST="silence"
        elif [[ "$REVERSE_AUDITOR_PREFLIGHT_PASS" == "true" ]]; then
          REVERSE_AUDITOR_VERDICT="omission-claim"
          REVERSE_AUDITOR_QUEUE_DEST="candidates"
          if [[ "$REVERSE_AUDITOR_PREFLIGHT_REASON" == "verified-with-drift" ]]; then
            REVERSE_AUDITOR_PREFLIGHT_SOFTENED=1
          fi
        else
          REVERSE_AUDITOR_VERDICT="preflight-failed"
          REVERSE_AUDITOR_QUEUE_DEST="attempts"
          # Exit 3 is informational per contract: the audit completed but the
          # omission claim was routed to audit-attempts.jsonl.
          REVERSE_AUDITOR_EXIT_CODE=3
        fi
      fi

      # Resolve the owning work-item slug once — both the abstention
      # re-attempt route and the candidates/attempts route use it.
      WORK_ITEM_SLUG=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("work_item") or "")' "$RESOLVED_INPUT_FILE")
      if [[ -z "$WORK_ITEM_SLUG" && "$ARTIFACT_TYPE" == "work-item" ]]; then
        WORK_ITEM_SLUG="$ARTIFACT_ID"
      fi

      # Abstention is an RA-local re-attempt signal — it carries no omission
      # claim, so it does NOT flow through the candidates/attempts queue (nor
      # the gate-derived aggregate unverified). Record it in a distinct
      # audit-reattempts.jsonl so a re-drain can pick it up with a better
      # packet. Re-attempt rows live alongside candidates/attempts in the
      # work-item dir, or in the owning/_audit dir for followup-rooted
      # artifacts.
      if [[ "$REVERSE_AUDITOR_QUEUE_DEST" == "reattempt" ]]; then
        if [[ -n "$WORK_ITEM_SLUG" && -d "$KDIR/_work/$WORK_ITEM_SLUG" ]]; then
          REATTEMPT_DIR="$KDIR/_work/$WORK_ITEM_SLUG"
        elif [[ -n "$OWNING_DIR" ]]; then
          REATTEMPT_DIR="$OWNING_DIR"
        else
          REATTEMPT_DIR="$KDIR/_audit"
          mkdir -p "$REATTEMPT_DIR"
        fi
        python3 - "$REVERSE_AUDITOR_RAW_FILE" "$REATTEMPT_DIR" "$ARTIFACT_ID" << 'PYEOF'
import json, os, sys, uuid
from datetime import datetime, timezone
ra_file, queue_dir, artifact_id = sys.argv[1:4]
with open(ra_file) as fh:
    emission = json.load(fh)
work_item = emission.get("work_item") or artifact_id
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
row = {
    "reattempt_id":   f"reatt-{uuid.uuid4().hex[:12]}",
    "verdict_source": "reverse-auditor",
    "work_item":      work_item,
    "artifact_id":    artifact_id,
    "coverage_state": "insufficient-evidence",
    "abstention_reason": emission.get("abstention_reason") or "",
    "insufficient_evidence_refs": emission.get("insufficient_evidence_refs") or [],
    "status":         "pending_reattempt",
    "created_at":     now,
}
target = os.path.join(queue_dir, "audit-reattempts.jsonl")
with open(target, "a") as fh:
    fh.write(json.dumps(row, sort_keys=True) + "\n")
# stderr only — stdout is reserved for the --json report.
print(target, file=sys.stderr)
PYEOF
      fi

      # Route the emission to candidates/attempts queue. Prefer
      # audit-queue-route.sh when a work-item slug resolves under
      # $KDIR/_work/<slug>/; otherwise write directly into the owning
      # artifact dir (the followup sidecar case). Silence and abstention
      # write nothing here (abstention routed to the re-attempt queue above).
      if [[ "$REVERSE_AUDITOR_QUEUE_DEST" == "candidates" || "$REVERSE_AUDITOR_QUEUE_DEST" == "attempts" ]]; then
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
          # (followup-rooted artifact case, where no _work/<slug> exists).
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
    # Preserve pass-side reason (ok | verified-with-drift) and surface
    # softened=true on drift so downstream rollups can count softened
    # verifications. Schema parity with audit-queue-route.sh.
    pass_reason = pf.get("reason") or "ok"
    row = {
        "candidate_id":   f"cand-{uuid.uuid4().hex[:12]}",
        "verdict_source": "reverse-auditor",
        "work_item":      work_item,
        "file":           claim.get("file"),
        "line_range":     claim.get("line_range"),
        "falsifier":      claim.get("falsifier"),
        "rationale":      claim.get("why_it_matters") or claim.get("why-it-matters") or "",
        "reason":         pass_reason,
        "softened":       pass_reason == "verified-with-drift",
        "reanchored":     bool(claim.get("reanchor")),
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
# stderr only — stdout is reserved for the --json report.
print(target, file=sys.stderr)
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
        RA_CALIBRATION_STATE=$(read_calibration_state "reverse-auditor" "$REVERSE_AUDITOR_TEMPLATE_VERSION")
        RA_ROWS_JSON=$(python3 - "$REVERSE_AUDITOR_RAW_FILE" "$RESOLVED_INPUT_FILE" \
                                "$REVERSE_AUDITOR_TEMPLATE_VERSION" "$CURATOR_TEMPLATE_VERSION" \
                                "$REVERSE_AUDITOR_VERDICT" "$RA_CALIBRATION_STATE" \
                                "$REVERSE_AUDITOR_PREFLIGHT_REASON" "$REVERSE_AUDITOR_PREFLIGHT_SOFTENED" << 'PYEOF'
import json, sys, datetime

(ra_file, resolved_file, ra_tv, curator_tv, verdict, calibration_state,
 preflight_reason, preflight_softened) = sys.argv[1:9]
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
softened = preflight_softened == "1"

# Classify value contributions per verdict.
if verdict == "omission-claim":
    omission_value = 1.0
    coverage_value = 0.0
    grounding_fail = 0.0
elif verdict == "silence":
    omission_value = 0.0
    coverage_value = 1.0
    grounding_fail = 0.0
elif verdict == "insufficient-evidence":
    # Abstention is a non-verdict: the judge could not adjudicate from the
    # packet. It scores no omission_rate / coverage_quality (no claim to
    # anchor) and is NOT a grounding failure — the telemetry row carries the
    # coverage_state so the rollup can track abstention separately.
    omission_value = 0.0
    coverage_value = 0.0
    grounding_fail = 0.0
else:  # preflight-failed
    omission_value = 0.0
    coverage_value = 1.0
    grounding_fail = 1.0

row_common = {
    "schema_version": "1",
    "calibration_state": calibration_state,
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
#
# failure_reason: present on preflight-failed verdicts so /retro can
# distinguish environment-class failures (provenance-unknown — no clone
# has the content) from producer-class failures (file-missing,
# snippet-mismatch, line-out-of-range, field-missing). Absent on
# silence (no failure to attribute) and on omission-claim (no failure).
#
# softened: present and true on omission-claim verdicts produced via
# substring fallback (reason=verified-with-drift). Telemetry signal that
# the anchor drifted but the content was still present.
grounding_row = {
    **row_common,
    "kind": "telemetry",
    "tier": "telemetry",
    "template_id": "reverse-auditor",
    "template_version": ra_tv,
    "metric": "grounding_failure_rate",
    "value": grounding_fail,
}
if verdict == "preflight-failed" and preflight_reason:
    grounding_row["failure_reason"] = preflight_reason
if verdict == "omission-claim" and softened:
    grounding_row["softened"] = True
if verdict == "insufficient-evidence":
    grounding_row["coverage_state"] = "insufficient-evidence"
rows.append(grounding_row)

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

      rm -f "$REVERSE_AUDITOR_INLINED_FILE" 2>/dev/null || true
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
    "$REVERSE_AUDITOR_PREFLIGHT_SOFTENED" "$REVERSE_AUDITOR_COVERAGE_STATE" \
    "$TOTAL_ROWS_APPENDED" "$PIPELINE_STAGE" "$NEXT_STAGE" << 'PYEOF'
import json, sys
(artifact_id, artifact_type, artifact_path, verdicts_file,
 n_total, n_verified, n_unverified, n_contradicted,
 gate_appended, gate_tv,
 curator_ran, curator_tv,
 n_selected, n_dropped, curator_appended,
 ra_ran, ra_tv, ra_verdict, ra_preflight_reason, ra_queue_dest, ra_appended,
 ra_softened, ra_coverage_state,
 total_appended, pipeline_stage, next_stage) = sys.argv[1:27]

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
        "coverage_state": ra_coverage_state or None,
        "preflight_reason": ra_preflight_reason,
        "queue_destination": ra_queue_dest,
        "softened": ra_softened == "1",
        "scorecard_rows_appended": int(ra_appended),
    }
print(json.dumps(out, indent=2))
PYEOF
else
  echo "[audit] $GATE_TEMPLATE_ID complete (template-version: $GATE_TEMPLATE_VERSION)"
  echo "[audit]   verdicts: total=$N_TOTAL verified=$N_VERIFIED unverified=$N_UNVERIFIED contradicted=$N_CONTRADICTED"
  echo "[audit]   scorecard rows appended: $APPENDED_COUNT"
  if [[ $CURATOR_STAGE_RAN -eq 1 ]]; then
    echo "[audit] curator complete (template-version: $CURATOR_TEMPLATE_VERSION)"
    echo "[audit]   selected=$N_SELECTED dropped=$N_DROPPED (from $N_VERIFIED verified)"
    echo "[audit]   scorecard rows appended: $CURATOR_APPENDED_COUNT"
  fi
  if [[ $REVERSE_AUDITOR_STAGE_RAN -eq 1 ]]; then
    echo "[audit] reverse-auditor complete (template-version: $REVERSE_AUDITOR_TEMPLATE_VERSION)"
    if [[ "$REVERSE_AUDITOR_PREFLIGHT_SOFTENED" == "1" ]]; then
      echo "[audit]   verdict=$REVERSE_AUDITOR_VERDICT coverage_state=$REVERSE_AUDITOR_COVERAGE_STATE preflight=$REVERSE_AUDITOR_PREFLIGHT_REASON queue=$REVERSE_AUDITOR_QUEUE_DEST softened=true"
    else
      echo "[audit]   verdict=$REVERSE_AUDITOR_VERDICT coverage_state=$REVERSE_AUDITOR_COVERAGE_STATE preflight=$REVERSE_AUDITOR_PREFLIGHT_REASON queue=$REVERSE_AUDITOR_QUEUE_DEST"
    fi
    echo "[audit]   scorecard rows appended: $REVERSE_AUDITOR_APPENDED_COUNT"
  fi
  echo "[audit] verdicts persisted to: $VERDICTS_FILE"
  echo "[audit] total scorecard rows appended: $TOTAL_ROWS_APPENDED"
  echo "[audit] Next: $NEXT_STAGE"
fi

exit $REVERSE_AUDITOR_EXIT_CODE
