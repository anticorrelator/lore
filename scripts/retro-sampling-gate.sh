#!/usr/bin/env bash
# retro-sampling-gate.sh — Decide, at a protocol terminus, whether a work cycle
#                          surfaces a retro now or defers to the batch queue.
#
# Consulted by spec-finalize.sh and impl-close.sh as a post-telemetry, best-effort
# side effect (the terminus never changes its exit code or verdict on this gate).
# The decision is a two-stage evaluation:
#
#   1. Deterministic ALWAYS-STRATA (exempt from any sampling rate). Each is a
#      pure read of committed substrate — no RNG, no agent judgment:
#        new_template_version   the producing template's 12-char version hash
#                               appears in NO prior scorecard row (rows.jsonl).
#                               A never-before-scored template always gets a retro.
#        first_k_routing_pair   some (judgment_class, worker_model) pair in this
#                               cycle's task_attribution has fewer than FIRST_K
#                               prior occurrences across scorecard history. The
#                               opening uses of a routing pair always get a retro.
#                               (impl-close only — spec-finalize carries no
#                               per-task routing attribution.)
#        degraded_closure       the closure verdict is 'partial' or 'none' — a
#                               degraded/contested outcome always gets a retro.
#                               (impl-close only.)
#      If any stratum fires, the cycle is DUE regardless of routine_rate.
#
#   2. Mechanical COIN for routine cycles (no stratum fired). A hash of
#      slug + calendar-date — checkable and RNG-free, so the same slug on the
#      same date always yields the same coin — is compared against
#      retro_sampling.routine_rate (settings.json; default 0). coin < rate → DUE;
#      else → DEFERRED.
#
# Outcome is RECORDED either way; an unattended terminal is never the only trace:
#   DUE      → one outcome=due, disposition=unhandled row appended via the
#              queue's sole writer, plus the existing operator prompt (stderr).
#   DEFERRED → one outcome=deferred row appended through the same writer.
#
# The queue outcome vocabulary (done | deferred | skipped | due) extends the
# coordinate ledger's retro-outcome grammar, reused verbatim — not reinvented.
#
# stdout: a machine-readable decision line (or --json object) for callers/tests.
# stderr: the operator-facing prompt/note. Terminus callers discard stdout and
# keep stderr, so the human sees the decision without the terminus's --json
# payload being corrupted.
#
# Usage:
#   retro-sampling-gate.sh --terminus <spec-finalize|impl-close> --slug <slug>
#       --template-version <hash>
#       [--verdict <full|partial|none>]         (impl-close closure verdict)
#       [--task-attribution <json-array>]        (impl-close routing attribution)
#       [--routine-rate <float>]                 (test override; default: settings)
#       [--first-k <int>]                        (default: 3)
#       [--date <YYYY-MM-DD>]                    (test override; default: today UTC)
#       [--kdir <path>] [--json]
#
# Exit codes:
#   0  decision reached (DUE or DEFERRED). This is the normal path — the gate is
#      best-effort and never signals due/deferred through the exit code.
#   1  usage error (bad flag, missing required arg, bad rate).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

FIRST_K_DEFAULT=3

TERMINUS=""
SLUG=""
TEMPLATE_VERSION=""
VERDICT=""
TASK_ATTRIBUTION=""
ROUTINE_RATE=""
FIRST_K=""
DATE=""
KDIR_OVERRIDE=""
JSON_MODE=0

usage() {
  sed -n '2,60p' "$0" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --terminus)          TERMINUS="$2";          shift 2 ;;
    --slug)              SLUG="$2";              shift 2 ;;
    --template-version)  TEMPLATE_VERSION="$2";  shift 2 ;;
    --verdict)           VERDICT="$2";           shift 2 ;;
    --task-attribution)  TASK_ATTRIBUTION="$2";  shift 2 ;;
    --routine-rate)      ROUTINE_RATE="$2";      shift 2 ;;
    --first-k)           FIRST_K="$2";           shift 2 ;;
    --date)              DATE="$2";              shift 2 ;;
    --kdir)              KDIR_OVERRIDE="$2";     shift 2 ;;
    --json)              JSON_MODE=1;            shift ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[retro] Error: unknown flag '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

# --- Required args ---
if [[ -z "$SLUG" ]]; then
  echo "[retro] Error: --slug is required" >&2
  exit 1
fi
case "$TERMINUS" in
  spec-finalize|impl-close) ;;
  "")
    echo "[retro] Error: --terminus is required (spec-finalize|impl-close)" >&2
    exit 1
    ;;
  *)
    echo "[retro] Error: --terminus must be 'spec-finalize' or 'impl-close' (got '$TERMINUS')" >&2
    exit 1
    ;;
esac

[[ -z "$FIRST_K" ]] && FIRST_K="$FIRST_K_DEFAULT"
if ! [[ "$FIRST_K" =~ ^[0-9]+$ ]]; then
  echo "[retro] Error: --first-k must be a non-negative integer (got '$FIRST_K')" >&2
  exit 1
fi

# --- Resolve knowledge directory ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi
if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  echo "[retro] Error: knowledge store not found at: $KNOWLEDGE_DIR" >&2
  exit 1
fi
ROWS_FILE="$KNOWLEDGE_DIR/_scorecards/rows.jsonl"

# --- Resolve routine_rate: flag override > settings.json > 0 ---
if [[ -z "$ROUTINE_RATE" ]]; then
  ROUTINE_RATE=$(bash "$SCRIPT_DIR/settings.sh" get retro_sampling.routine_rate 2>/dev/null || true)
  [[ -z "$ROUTINE_RATE" || "$ROUTINE_RATE" == "null" ]] && ROUTINE_RATE="0"
fi
if ! python3 -c "
import sys
try:
    v = float(sys.argv[1])
    sys.exit(0 if 0.0 <= v <= 1.0 else 1)
except ValueError:
    sys.exit(1)
" "$ROUTINE_RATE" 2>/dev/null; then
  echo "[retro] Error: routine_rate must be a float in [0.0, 1.0] (got '$ROUTINE_RATE')" >&2
  exit 1
fi

# --- Date for the mechanical coin (test-pinnable) ---
[[ -z "$DATE" ]] && DATE=$(date -u +%Y-%m-%d)

# --- Deterministic decision core -------------------------------------------
# Pure function of (rows.jsonl history, this cycle's inputs). Emits a JSON
# decision object to stdout. task_attribution is passed via env to avoid argv
# quoting hazards on the (potentially large) JSON array.
DECISION=$(_LORE_TASK_ATTR="$TASK_ATTRIBUTION" python3 - \
  "$ROWS_FILE" "$SLUG" "$TERMINUS" "$TEMPLATE_VERSION" "$VERDICT" \
  "$ROUTINE_RATE" "$FIRST_K" "$DATE" <<'PYEOF'
import hashlib, json, os, sys

rows_file, slug, terminus, template_version, verdict, rate_str, first_k_str, date = sys.argv[1:9]
routine_rate = float(rate_str)
first_k = int(first_k_str)
task_attr_raw = os.environ.get("_LORE_TASK_ATTR", "")

def is_hex12(s):
    return bool(s) and len(s) == 12 and all(c in "0123456789abcdef" for c in s)

# This cycle's distinct routing pairs (judgment_class, worker_model).
current_pairs = set()
if task_attr_raw.strip():
    try:
        for e in json.loads(task_attr_raw):
            if isinstance(e, dict):
                current_pairs.add((e.get("judgment_class"), e.get("worker_model")))
    except ValueError:
        pass  # malformed attribution degrades to no routing-pair stratum

# Read scorecard history: has this template_version been scored before, and how
# many times has each routing pair appeared. The current cycle's telemetry row
# is ALREADY in rows.jsonl by the time this gate runs (it rides the terminus
# after the telemetry append), so rows belonging to this work item are excluded
# — the strata ask whether the REST of the corpus already calibrates this
# template / routing pair, and the cycle's own just-written row is the thing
# being decided about, not prior calibration. (Re-finalizing the sole user of a
# brand-new template re-asks the question and re-triggers, a safe over-trigger.)
tv_hex = is_hex12(template_version)
tv_seen = False
pair_counts = {}
if os.path.isfile(rows_file):
    with open(rows_file, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("work_item") == slug:
                continue  # exclude this cycle's own rows from prior-calibration reads
            if tv_hex and r.get("template_version") == template_version:
                tv_seen = True
            attr = r.get("task_attribution")
            if isinstance(attr, list):
                for e in attr:
                    if isinstance(e, dict):
                        key = (e.get("judgment_class"), e.get("worker_model"))
                        pair_counts[key] = pair_counts.get(key, 0) + 1

# Deterministic always-strata (exempt from routine_rate).
strata = []
if tv_hex and not tv_seen:
    strata.append("new_template_version")
first_k_pairs = [p for p in sorted(current_pairs, key=lambda p: (str(p[0]), str(p[1])))
                 if pair_counts.get(p, 0) < first_k]
if first_k_pairs:
    strata.append("first_k_routing_pair")
if verdict in ("partial", "none"):
    strata.append("degraded_closure")

# Mechanical coin: checkable hash of slug + date, RNG-free. Same slug + date
# always yields the same coin.
digest = hashlib.sha256(f"{slug}|{date}".encode("utf-8")).hexdigest()
coin = int(digest[:8], 16) / 0x100000000  # [0, 1)

if strata:
    outcome = "due"
    reason = "always-stratum"
    stratum = strata[0]
elif coin < routine_rate:
    outcome = "due"
    reason = "coin"
    stratum = "routine"
else:
    outcome = "deferred"
    reason = "sampled-out"
    stratum = "routine"

print(json.dumps({
    "outcome": outcome,
    "reason": reason,
    "stratum": stratum,
    "strata": strata,
    "cycle_id": slug,
    "event_type": terminus,
    "template_version": template_version or None,
    "verdict": verdict or None,
    "rate": routine_rate,
    "coin": coin,
    "date": date,
    "first_k_pairs": ["/".join(str(x) for x in p) for p in first_k_pairs],
}, ensure_ascii=False))
PYEOF
)

# --- Extract fields for the bash side ---
read -r OUTCOME REASON STRATUM COIN <<<"$(printf '%s' "$DECISION" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["outcome"], d["reason"], d["stratum"], d["coin"])
')"

# --- Act on the decision: durably record, then surface -----------------------
COIN_FMT=$(printf '%s' "$DECISION" | python3 -c 'import json,sys; print("%.4f" % json.load(sys.stdin)["coin"])')
RATE_FMT=$(printf '%s' "$DECISION" | python3 -c 'import json,sys; print("%.4f" % json.load(sys.stdin)["rate"])')

if [[ "$OUTCOME" == "due" ]]; then
  APPEND_ARGS=(--cycle-id "$SLUG" --event-type "$TERMINUS" --outcome due
               --disposition unhandled --reason "$REASON"
               --rate "$ROUTINE_RATE" --stratum "$STRATUM" --coin "$COIN")
  [[ -n "$TEMPLATE_VERSION" ]] && APPEND_ARGS+=(--template-version "$TEMPLATE_VERSION")
  [[ -n "$VERDICT" ]] && APPEND_ARGS+=(--verdict "$VERDICT")
  [[ -n "$KDIR_OVERRIDE" ]] && APPEND_ARGS+=(--kdir "$KDIR_OVERRIDE")
  if ! bash "$SCRIPT_DIR/retro-deferred-append.sh" "${APPEND_ARGS[@]}" >/dev/null; then
    echo "[retro] Warning: DUE outcome recording failed for cycle '$SLUG'; the terminus remains complete and the retro decision remains DUE." >&2
  fi
  if [[ "$REASON" == "always-stratum" ]]; then
    STRATA_LIST=$(printf '%s' "$DECISION" | python3 -c 'import json,sys; print(", ".join(json.load(sys.stdin)["strata"]))')
    echo "[retro] Retro is DUE for cycle '$SLUG' ($TERMINUS) — always-strata: $STRATA_LIST (rate-exempt)." >&2
  else
    echo "[retro] Retro is DUE for cycle '$SLUG' ($TERMINUS) — routine sample hit (coin $COIN_FMT < rate $RATE_FMT)." >&2
  fi
  echo "[retro]   Run /retro on this cycle now, or ledger an explicit deferral/skip." >&2
else
  # DEFERRED: append one debt row to the batch queue via the sole writer.
  APPEND_ARGS=(--cycle-id "$SLUG" --event-type "$TERMINUS" --outcome deferred
               --rate "$ROUTINE_RATE" --stratum "$STRATUM" --coin "$COIN")
  [[ -n "$TEMPLATE_VERSION" ]] && APPEND_ARGS+=(--template-version "$TEMPLATE_VERSION")
  [[ -n "$VERDICT" ]] && APPEND_ARGS+=(--verdict "$VERDICT")
  [[ -n "$KDIR_OVERRIDE" ]] && APPEND_ARGS+=(--kdir "$KDIR_OVERRIDE")
  if bash "$SCRIPT_DIR/retro-deferred-append.sh" "${APPEND_ARGS[@]}" >/dev/null; then
    echo "[retro] Retro DEFERRED for cycle '$SLUG' ($TERMINUS) — routine, sampled out (coin $COIN_FMT >= rate $RATE_FMT). Queued to _scorecards/retro-deferred-queue.jsonl." >&2
  else
    echo "[retro] Warning: deferred-queue append failed for cycle '$SLUG'; retro decision was DEFERRED but not recorded." >&2
  fi
fi

# --- stdout: machine-readable decision for callers/tests ---
if [[ $JSON_MODE -eq 1 ]]; then
  printf '%s\n' "$DECISION"
else
  echo "outcome=$OUTCOME reason=$REASON stratum=$STRATUM coin=$COIN_FMT rate=$RATE_FMT"
fi
