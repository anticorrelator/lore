#!/usr/bin/env bash
# retro-backfill.sh — Cluster historical retro-evolution journal entries into candidate-cluster records
#
# Usage:
#   lore retro backfill --since <date> [--until <date>] [--min-cluster K] \
#                       [--emit-mode stdout|journal] [--include-backfill-rows] \
#                       [--json] [--kdir <path>]
#
# Streams `$KDIR/_meta/effectiveness-journal.jsonl` rows where role=="retro-evolution"
# inside the [since, until] window, parses pipe-delimited Target / Change type
# substrings from the observation prose, buckets by (target, change_type), collects
# distinct work_item slugs, and emits clusters whose distinct-work-item count is
# at least K (default 3).
#
# Output:
#   --emit-mode stdout (default): a human-readable cluster table with cluster_id,
#     target, change_type, count, work_items.  --json toggles structured JSON.
#   --emit-mode journal: appends NEW rows to the journal — one per cluster — with
#     role=="retro-evolution", context=="retro-backfill: <since>..<until>", and
#     a stable cluster_id derived from
#       sha256("retro-backfill" | target | change_type | sorted(work_items)).
#     A cluster whose cluster_id is already present in the journal is skipped
#     (re-run dedupe).
#
# Loop-amplification guard: rows whose context starts with "retro-backfill:" are
# excluded from clustering by default.  --include-backfill-rows opts in to
# composing over prior backfill outputs (deliberate, advanced).
#
# Double-count guard: backfill emits one row per cluster, NOT one row per
# constituent observation — clusters are pre-aggregated so /evolve cannot count
# the same evidence twice.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SINCE=""
UNTIL=""
MIN_CLUSTER=3
EMIT_MODE="stdout"
INCLUDE_BACKFILL_ROWS=0
JSON_MODE=0
KDIR_ARG=""

usage() {
  cat >&2 <<EOF
Usage: lore retro backfill --since <date> [--until <date>] [--min-cluster K]
                           [--emit-mode stdout|journal] [--include-backfill-rows]
                           [--json] [--kdir <path>]

Options:
  --since <date>            Lower bound (ISO 8601, e.g. 2025-01-01) — required
  --until <date>            Upper bound (ISO 8601) — defaults to "now"
  --min-cluster K           Minimum distinct work_items per cluster (default: 3)
  --emit-mode <mode>        stdout (default) or journal
  --include-backfill-rows   Compose over prior backfill rows (default: exclude them)
  --json                    Stdout mode: emit JSON instead of a table
  --kdir <path>             Override knowledge-store directory
  --help, -h                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      SINCE="$2"
      shift 2
      ;;
    --until)
      UNTIL="$2"
      shift 2
      ;;
    --min-cluster)
      MIN_CLUSTER="$2"
      shift 2
      ;;
    --emit-mode)
      EMIT_MODE="$2"
      shift 2
      ;;
    --include-backfill-rows)
      INCLUDE_BACKFILL_ROWS=1
      shift
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --kdir)
      KDIR_ARG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[retro-backfill] Error: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$msg"
  fi
  echo "[retro-backfill] Error: $msg" >&2
  exit 1
}

[[ -z "$SINCE" ]] && fail "--since <date> is required"
[[ "$EMIT_MODE" != "stdout" && "$EMIT_MODE" != "journal" ]] && \
  fail "--emit-mode must be stdout or journal (got: $EMIT_MODE)"
[[ "$MIN_CLUSTER" =~ ^[0-9]+$ ]] || fail "--min-cluster must be a non-negative integer"

command -v python3 &>/dev/null || fail "python3 is required but not found on PATH"

# --- Resolve knowledge dir + journal ---
KDIR="${KDIR_ARG:-$(resolve_knowledge_dir)}"
[[ -z "$KDIR" || ! -d "$KDIR" ]] && fail "knowledge directory not found (kdir=$KDIR)"

JOURNAL="$KDIR/_meta/effectiveness-journal.jsonl"
[[ ! -f "$JOURNAL" ]] && fail "journal not found at $JOURNAL"

# --- Compute clusters ---
CLUSTERS_JSON=$(SINCE="$SINCE" UNTIL="$UNTIL" MIN_CLUSTER="$MIN_CLUSTER" \
  INCLUDE_BACKFILL_ROWS="$INCLUDE_BACKFILL_ROWS" JOURNAL="$JOURNAL" \
  python3 <<'PY'
import hashlib
import json
import os
import re
import sys

journal = os.environ["JOURNAL"]
since = os.environ["SINCE"]
until = os.environ["UNTIL"]
min_cluster = int(os.environ["MIN_CLUSTER"])
include_backfill = os.environ["INCLUDE_BACKFILL_ROWS"] == "1"

target_re = re.compile(r"Target\s*:\s*([^|]+?)(?:\s*\||$)", re.IGNORECASE)
ctype_re = re.compile(r"Change\s*type\s*:\s*([^|]+?)(?:\s*\||$)", re.IGNORECASE)

# Bucket: (target, change_type) -> {work_items: set, journal_row_refs: list, sample_observations: list}
buckets = {}

with open(journal) as fh:
    for line_no, line in enumerate(fh, 1):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            # Skip malformed lines silently — same posture as journal show
            continue
        if row.get("role") != "retro-evolution":
            continue

        ctx = row.get("context", "") or ""
        if not include_backfill and ctx.startswith("retro-backfill:"):
            continue

        ts = row.get("timestamp", "") or ""
        if since and ts < since:
            continue
        if until and ts > until:
            continue

        obs = row.get("observation", "") or ""
        wi = row.get("work_item", "") or ""
        if not wi:
            # No work_item slug — cannot count toward distinct-work-items quorum
            continue

        m_t = target_re.search(obs)
        m_c = ctype_re.search(obs)
        if not (m_t and m_c):
            continue
        target = m_t.group(1).strip()
        change_type = m_c.group(1).strip()
        if not target or not change_type:
            continue

        key = (target, change_type)
        if key not in buckets:
            buckets[key] = {
                "work_items": set(),
                "journal_row_refs": [],
            }
        buckets[key]["work_items"].add(wi)
        # Stable row reference: timestamp + work_item is sufficient
        # (the journal has no synthetic primary key).
        buckets[key]["journal_row_refs"].append({
            "timestamp": ts,
            "work_item": wi,
        })

clusters = []
for (target, change_type), bucket in buckets.items():
    work_items = sorted(bucket["work_items"])
    if len(work_items) < min_cluster:
        continue
    cluster_id_input = "retro-backfill" + "|" + target + "|" + change_type + "|" + ",".join(work_items)
    cluster_id = hashlib.sha256(cluster_id_input.encode("utf-8")).hexdigest()
    clusters.append({
        "cluster_id": cluster_id,
        "target": target,
        "change_type": change_type,
        "work_items": work_items,
        "count": len(work_items),
        "journal_row_refs": bucket["journal_row_refs"],
    })

# Stable order: descending by count, then target, then change_type
clusters.sort(key=lambda c: (-c["count"], c["target"], c["change_type"]))

print(json.dumps({"clusters": clusters}))
PY
)

CLUSTER_COUNT=$(printf '%s' "$CLUSTERS_JSON" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["clusters"]))')

# --- Emit ---
if [[ "$EMIT_MODE" == "stdout" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_output "$CLUSTERS_JSON"
  fi

  WINDOW_DESC="$SINCE..${UNTIL:-now}"
  echo "[retro-backfill] window=$WINDOW_DESC min-cluster=$MIN_CLUSTER include-backfill-rows=$INCLUDE_BACKFILL_ROWS"
  echo "[retro-backfill] clusters: $CLUSTER_COUNT"
  echo ""
  if [[ "$CLUSTER_COUNT" -eq 0 ]]; then
    echo "(no clusters of size >= $MIN_CLUSTER)"
    exit 0
  fi

  printf '%-12s  %-6s  %-30s  %-25s  %s\n' "CLUSTER_ID" "COUNT" "TARGET" "CHANGE_TYPE" "WORK_ITEMS"
  printf '%-12s  %-6s  %-30s  %-25s  %s\n' "------------" "-----" "------------------------------" "-------------------------" "------------------------------"
  CLUSTERS_JSON="$CLUSTERS_JSON" python3 <<'PY'
import json, os
data = json.loads(os.environ["CLUSTERS_JSON"])
for c in data["clusters"]:
    cid = c["cluster_id"][:12]
    target = c["target"][:30]
    change_type = c["change_type"][:25]
    work_items = ", ".join(c["work_items"])
    print(f'{cid:<12}  {c["count"]:<6}  {target:<30}  {change_type:<25}  {work_items}')
PY
  exit 0
fi

# --- emit-mode journal ---
# Stream existing journal once to collect already-present cluster_ids.
EXISTING_IDS=$(JOURNAL="$JOURNAL" python3 <<'PY'
import json, os
journal = os.environ["JOURNAL"]
ids = set()
with open(journal) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if row.get("role") != "retro-evolution":
            continue
        ctx = row.get("context", "") or ""
        if not ctx.startswith("retro-backfill:"):
            continue
        cid = row.get("cluster_id")
        if cid:
            ids.add(cid)
print("\n".join(sorted(ids)))
PY
)

WINDOW_DESC="$SINCE..${UNTIL:-now}"
TIMESTAMP=$(timestamp_iso)
BRANCH=$(get_git_branch)

APPENDED=0
SKIPPED=0
APPENDED_IDS=()

# Iterate clusters via python -> bash loop so we can call timestamp_iso once
# but build the journal row body in Python where JSON escaping is correct.
while IFS= read -r row_json; do
  [[ -z "$row_json" ]] && continue
  cluster_id=$(printf '%s' "$row_json" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["cluster_id"])')
  if grep -Fxq "$cluster_id" <<<"$EXISTING_IDS"; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  # Build the journal row
  ROW=$(WINDOW_DESC="$WINDOW_DESC" TIMESTAMP="$TIMESTAMP" BRANCH="$BRANCH" \
        ROW_JSON="$row_json" python3 <<'PY'
import json, os
src = json.loads(os.environ["ROW_JSON"])
out = {
    "timestamp": os.environ["TIMESTAMP"],
    "role": "retro-evolution",
    "context": f'retro-backfill: {os.environ["WINDOW_DESC"]}',
    "observation": (
        f'Target: {src["target"]} | Change type: {src["change_type"]} | '
        f'Source: retro-backfill | cluster_id: {src["cluster_id"]}'
    ),
    "git_branch": os.environ["BRANCH"],
    "work_item": "(backfill)",
    "cluster_id": src["cluster_id"],
    "journal_row_refs": src["journal_row_refs"],
}
print(json.dumps(out, ensure_ascii=False))
PY
)
  echo "$ROW" >> "$JOURNAL"
  APPENDED=$((APPENDED + 1))
  APPENDED_IDS+=("$cluster_id")
done < <(CLUSTERS_JSON="$CLUSTERS_JSON" python3 -c '
import json, os
data = json.loads(os.environ["CLUSTERS_JSON"])
for c in data["clusters"]:
    print(json.dumps(c))
')

if [[ $JSON_MODE -eq 1 ]]; then
  python3 -c '
import json, sys
print(json.dumps({
    "clusters_total": int(sys.argv[1]),
    "appended": int(sys.argv[2]),
    "skipped_dedupe": int(sys.argv[3]),
    "appended_cluster_ids": sys.argv[4].split(",") if sys.argv[4] else [],
}))
' "$CLUSTER_COUNT" "$APPENDED" "$SKIPPED" "$(IFS=,; echo "${APPENDED_IDS[*]:-}")"
  exit 0
fi

echo "[retro-backfill] window=$WINDOW_DESC clusters=$CLUSTER_COUNT appended=$APPENDED skipped(dedupe)=$SKIPPED"
echo "[retro-backfill] journal: $JOURNAL"
