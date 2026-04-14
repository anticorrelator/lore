#!/usr/bin/env bash
# followup-archive.sh — One-shot migration: move terminal-status followups
# from each knowledge store's active tier (_followups/<id>) into the archive
# tier (_followups/_archive/<id>). Idempotent on re-run.
#
# Usage: bash scripts/migrations/followup-archive.sh [--yes] [--base-dir <path>]
#
# Scans every knowledge store under ~/.lore/repos/*/*/*/ (override with
# --base-dir), prints a dry-run summary of what would move, prompts for
# confirmation, then performs the moves and rebuilds each repo's index.
# --yes skips the prompt.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_SCRIPTS_DIR/lib.sh"
source "$REPO_SCRIPTS_DIR/config.sh"

# --- Parse arguments ---
ASSUME_YES=false
BASE_DIR="${LORE_DATA_DIR}/repos"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)
      ASSUME_YES=true
      shift
      ;;
    --base-dir)
      BASE_DIR="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "[migration] Error: unknown argument '$1'" >&2
      echo "Usage: bash scripts/migrations/followup-archive.sh [--yes] [--base-dir <path>]" >&2
      exit 1
      ;;
  esac
done

if [[ ! -d "$BASE_DIR" ]]; then
  echo "[migration] No knowledge stores found at $BASE_DIR."
  exit 0
fi

# --- Enumerate knowledge stores ---
# Layout: <base>/<host>/<org>/<repo>/  (e.g. ~/.lore/repos/github.com/anticorrelator/lore/)
# Plus: <base>/local/<repo>/           (git repos without a remote)
# Walk both 3-level and 2-level paths; skip anything without a _followups dir.
declare -a KNOWLEDGE_DIRS=()
while IFS= read -r candidate; do
  [[ -d "$candidate/_followups" ]] || continue
  KNOWLEDGE_DIRS+=("$candidate")
done < <(
  { find "$BASE_DIR" -mindepth 3 -maxdepth 3 -type d 2>/dev/null;
    find "$BASE_DIR/local" -mindepth 1 -maxdepth 1 -type d 2>/dev/null; } | sort -u
)

if [[ ${#KNOWLEDGE_DIRS[@]} -eq 0 ]]; then
  echo "[migration] No knowledge stores with a _followups directory under $BASE_DIR."
  exit 0
fi

# --- Build plan ---
# For each knowledge dir, emit lines: "<kdir>\t<id>\t<status>" for every
# active-dir followup whose status is terminal. The python helper is used
# because json_field is regex-based and would misread multi-line metas.
collect_plan() {
  python3 - "$@" <<'PYEOF'
import json, os, sys

for kdir in sys.argv[1:]:
    followups_dir = os.path.join(kdir, "_followups")
    if not os.path.isdir(followups_dir):
        continue
    for entry in sorted(os.listdir(followups_dir)):
        if entry == "_archive":
            continue
        item_dir = os.path.join(followups_dir, entry)
        meta_path = os.path.join(item_dir, "_meta.json")
        if not os.path.isdir(item_dir) or not os.path.isfile(meta_path):
            continue
        try:
            with open(meta_path) as f:
                meta = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        status = str(meta.get("status", "")).strip()
        if status in ("reviewed", "promoted", "dismissed"):
            print(f"{kdir}\t{entry}\t{status}")
PYEOF
}

PLAN=$(collect_plan "${KNOWLEDGE_DIRS[@]}")

# --- Dry-run summary ---
TOTAL=0
if [[ -n "$PLAN" ]]; then
  TOTAL=$(printf '%s\n' "$PLAN" | grep -c '')
fi

echo "[migration] Scanning ${#KNOWLEDGE_DIRS[@]} knowledge store(s) under $BASE_DIR"
for kdir in "${KNOWLEDGE_DIRS[@]}"; do
  count=0
  if [[ -n "$PLAN" ]]; then
    count=$(printf '%s\n' "$PLAN" | awk -F'\t' -v k="$kdir" '$1==k' | wc -l | tr -d '[:space:]')
  fi
  rel="${kdir#$BASE_DIR/}"
  if [[ "$count" == "0" ]]; then
    echo "  $rel: no terminal items to migrate"
  else
    echo "  $rel: would migrate $count item(s)"
    printf '%s\n' "$PLAN" | awk -F'\t' -v k="$kdir" '$1==k { printf "    - %s (%s)\n", $2, $3 }'
  fi
done
echo "[migration] Total items to migrate: $TOTAL"

if [[ "$TOTAL" -eq 0 ]]; then
  echo "[migration] Nothing to do."
  exit 0
fi

# --- Confirm ---
if [[ "$ASSUME_YES" != true ]]; then
  printf "Proceed with migration? [y/N] "
  read -r REPLY || REPLY=""
  case "$REPLY" in
    y|Y|yes|YES) ;;
    *)
      echo "[migration] Aborted — no changes made."
      exit 0
      ;;
  esac
fi

# --- Execute moves ---
FAILURES=0
declare -a MIGRATED_REPOS=()

while IFS=$'\t' read -r kdir id status; do
  [[ -z "$kdir" ]] && continue
  src="$kdir/_followups/$id"
  archive_dir="$kdir/_followups/_archive"
  dst="$archive_dir/$id"

  if [[ ! -d "$src" ]]; then
    echo "[migration] Warning: expected source no longer exists, skipping: $src" >&2
    continue
  fi

  if [[ -d "$dst" ]]; then
    echo "[migration] Error: archive collision for $kdir/$id — skipping" >&2
    FAILURES=$((FAILURES + 1))
    continue
  fi

  mkdir -p "$archive_dir"
  if ! mv "$src" "$dst"; then
    echo "[migration] Error: mv failed for $src -> $dst" >&2
    FAILURES=$((FAILURES + 1))
    continue
  fi

  # Track which repos saw a successful move so we only rebuild those indices.
  already_tracked=false
  for r in "${MIGRATED_REPOS[@]:-}"; do
    if [[ "$r" == "$kdir" ]]; then
      already_tracked=true
      break
    fi
  done
  if [[ "$already_tracked" == false ]]; then
    MIGRATED_REPOS+=("$kdir")
  fi
done <<< "$PLAN"

# --- Rebuild per-repo indices ---
for kdir in "${MIGRATED_REPOS[@]:-}"; do
  [[ -z "$kdir" ]] && continue
  if ! LORE_KNOWLEDGE_DIR="$kdir" bash "$REPO_SCRIPTS_DIR/update-followup-index.sh" >/dev/null; then
    echo "[migration] Error: index rebuild failed for $kdir" >&2
    FAILURES=$((FAILURES + 1))
  fi
done

# --- Per-repo summary ---
echo
for kdir in "${KNOWLEDGE_DIRS[@]}"; do
  rel="${kdir#$BASE_DIR/}"
  count=0
  if [[ -n "$PLAN" ]]; then
    count=$(printf '%s\n' "$PLAN" | awk -F'\t' -v k="$kdir" '$1==k' | wc -l | tr -d '[:space:]')
  fi
  if [[ "$count" == "0" ]]; then
    echo "$rel: no terminal items to migrate"
  else
    echo "$rel: migrated $count item(s)"
  fi
done

if [[ "$FAILURES" -gt 0 ]]; then
  echo >&2
  echo "[migration] Completed with $FAILURES failure(s)." >&2
  exit 1
fi

echo
echo "[migration] Done."
