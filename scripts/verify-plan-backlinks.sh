#!/usr/bin/env bash
# verify-plan-backlinks.sh — Verify [[knowledge:...]] and [[work:...]] backlinks in a plan.md
# Usage: bash verify-plan-backlinks.sh <plan_file> <knowledge_dir> [--fix]
# Default: report-only JSON. With --fix: apply auto-corrections in-place.
#
# Output JSON format:
#   {
#     "verified": N,
#     "corrected": [{"from": "[[...]]", "to": "[[...]]"}],
#     "unresolved": [{"backlink": "[[...]]", "error": "..."}]
#   }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
PLAN_FILE=""
KNOWLEDGE_DIR=""
FIX=0

for arg in "$@"; do
  case "$arg" in
    --fix) FIX=1 ;;
    *)
      if [[ -z "$PLAN_FILE" ]]; then
        PLAN_FILE="$arg"
      elif [[ -z "$KNOWLEDGE_DIR" ]]; then
        KNOWLEDGE_DIR="$arg"
      fi
      ;;
  esac
done

if [[ -z "$PLAN_FILE" || -z "$KNOWLEDGE_DIR" ]]; then
  json_error "Usage: verify-plan-backlinks.sh <plan_file> <knowledge_dir> [--fix]"
fi

if [[ ! -f "$PLAN_FILE" ]]; then
  json_error "plan file not found: $PLAN_FILE"
fi

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  json_error "knowledge dir not found: $KNOWLEDGE_DIR"
fi

if ! command -v python3 &>/dev/null; then
  json_error "python3 is required but not found"
fi

# --- Extract all [[knowledge:...]] and [[work:...]] backlinks ---
BACKLINKS=$(grep -oE '\[\[(knowledge|work|plan):[^]]+\]\]' "$PLAN_FILE" 2>/dev/null | sort -u || true)

if [[ -z "$BACKLINKS" ]]; then
  printf '{"verified": 0, "corrected": [], "unresolved": []}\n'
  exit 0
fi

# --- Resolve all backlinks in batch via pk_cli.py ---
# Pass each backlink as a separate argument
RESOLVE_ARGS=()
while IFS= read -r bl; do
  [[ -z "$bl" ]] && continue
  RESOLVE_ARGS+=("$bl")
done <<< "$BACKLINKS"

if [[ ${#RESOLVE_ARGS[@]} -eq 0 ]]; then
  printf '{"verified": 0, "corrected": [], "unresolved": []}\n'
  exit 0
fi

RESOLVE_TMP=$(mktemp)
trap 'rm -f "$RESOLVE_TMP"' EXIT

python3 "$SCRIPT_DIR/pk_cli.py" resolve "$KNOWLEDGE_DIR" "${RESOLVE_ARGS[@]}" --json >"$RESOLVE_TMP" 2>/dev/null || {
  json_error "pk_cli.py resolve failed"
}

# --- Process resolution results with Python ---
# For unresolved backlinks, attempt fuzzy search to find correction candidates
RESULT=$(python3 - "$KNOWLEDGE_DIR" "$PLAN_FILE" "$FIX" "$RESOLVE_TMP" "$SCRIPT_DIR" <<'PYEOF'
import json
import os
import re
import subprocess
import sys

knowledge_dir = sys.argv[1]
plan_file = sys.argv[2]
do_fix = sys.argv[3] == "1"
resolve_tmp = sys.argv[4]
script_dir = sys.argv[5]

pk_cli = os.path.join(script_dir, "pk_cli.py")

# Read resolve output from temp file
try:
    with open(resolve_tmp, "r", encoding="utf-8") as f:
        resolve_output_raw = f.read().strip()
except OSError as e:
    print(json.dumps({"error": f"Failed to read resolve output: {e}"}), file=sys.stderr)
    sys.exit(1)

if not resolve_output_raw:
    print(json.dumps({"verified": 0, "corrected": [], "unresolved": []}))
    sys.exit(0)

try:
    resolve_results = json.loads(resolve_output_raw)
except json.JSONDecodeError as e:
    print(json.dumps({"error": f"Failed to parse resolve output: {e}"}), file=sys.stderr)
    sys.exit(1)

verified = 0
corrected = []
unresolved = []

BACKLINK_RE = re.compile(
    r"\[\[(?P<type>knowledge|work|plan|thread):(?P<target>[^\]#]+)(?:#(?P<heading>[^\]]+))?\]\]"
)

for r in resolve_results:
    backlink = r.get("backlink", "")
    resolved = r.get("resolved", False)

    if resolved:
        verified += 1
        continue

    # Unresolved: try fuzzy search for correction candidate
    error = r.get("error", "Unknown error")
    source_type = r.get("source_type", "knowledge")
    target = r.get("target", "")

    # Extract slug fragments for search query
    # e.g. "conventions/skill-design" -> "skill design", "auth-middleware" -> "auth middleware"
    slug_parts = re.split(r"[/\-_]", target)
    search_query = " ".join(p for p in slug_parts if len(p) > 2)

    correction = None
    if search_query and source_type in ("knowledge", "work", "plan"):
        try:
            search_result = subprocess.run(
                ["python3", pk_cli, "search", knowledge_dir, search_query,
                 "--type", "knowledge" if source_type == "knowledge" else "work",
                 "--limit", "1", "--json"],
                capture_output=True, text=True, timeout=10
            )
            if search_result.returncode == 0 and search_result.stdout.strip():
                candidates = json.loads(search_result.stdout)
                if candidates:
                    top = candidates[0]
                    file_path = top.get("file_path", "")
                    # Convert file_path to backlink target
                    # Strip knowledge_dir prefix and .md extension
                    rel_path = file_path
                    if rel_path.endswith(".md"):
                        rel_path = rel_path[:-3]
                    # Remove leading _work/ prefix for work items
                    if source_type in ("work", "plan") and rel_path.startswith("_work/"):
                        parts = rel_path.split("/")
                        # _work/slug/plan or _work/_archive/slug/plan
                        if len(parts) >= 2:
                            slug = parts[1] if parts[1] != "_archive" else (parts[2] if len(parts) > 2 else "")
                            if slug:
                                correction = f"[[work:{slug}]]"
                    else:
                        # knowledge: use relative path as slug
                        correction = f"[[knowledge:{rel_path}]]"
        except (subprocess.TimeoutExpired, json.JSONDecodeError, Exception):
            pass

    if correction and correction != backlink:
        corrected.append({"from": backlink, "to": correction})
    else:
        unresolved.append({"backlink": backlink, "error": error})

# Apply corrections in-place if --fix was requested
if do_fix and corrected:
    try:
        with open(plan_file, "r", encoding="utf-8") as f:
            content = f.read()

        for item in corrected:
            content = content.replace(item["from"], item["to"])

        with open(plan_file, "w", encoding="utf-8") as f:
            f.write(content)
    except OSError as e:
        print(json.dumps({"error": f"Failed to apply fixes: {e}"}), file=sys.stderr)
        sys.exit(1)

result = {
    "verified": verified,
    "corrected": corrected,
    "unresolved": unresolved,
}
print(json.dumps(result, indent=2))
PYEOF
)

printf '%s\n' "$RESULT"
