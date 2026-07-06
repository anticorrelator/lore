#!/usr/bin/env bash
# archive-project.sh — Archive every active member of a project, then mark a
# pre-existing project record archived.
# Usage: bash archive-project.sh <slug> [--yes] [--json]
# Prompts for confirmation unless --yes. Per-member archive failures are
# reported and do not stop the loop, but any failure exits non-zero and leaves
# the record status untouched. Never creates a record just to mark it archived.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

USAGE="Usage: archive-project.sh <slug> [--yes] [--json]"

SLUG=""
YES=0
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      YES=1
      shift
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    *)
      if [[ -z "$SLUG" ]]; then
        SLUG="$1"
      else
        echo "[work] Error: Unknown argument '$1'" >&2
        echo "$USAGE" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$SLUG" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Missing required argument: slug"
  fi
  echo "[work] Error: Missing required argument: slug" >&2
  echo "$USAGE" >&2
  exit 1
fi

INPUT_SLUG="$SLUG"
SLUG=$(slugify "$SLUG")
if [[ -z "$SLUG" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Project label '$INPUT_SLUG' produced an empty slug"
  fi
  echo "[work] Error: Project label '$INPUT_SLUG' produced an empty slug." >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work"

if [[ ! -d "$WORK_DIR" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "No work directory found"
  fi
  echo "[work] Error: No work directory found." >&2
  exit 1
fi

INDEX="$WORK_DIR/_index.json"

# A record exists in either form (directory home or legacy flat file).
RECORD_EXISTS=0
if project_record_exists "$WORK_DIR" "$SLUG"; then
  RECORD_EXISTS=1
fi

# Freshen the index so the member list reflects the current tree.
"$SCRIPT_DIR/update-work-index.sh" >/dev/null 2>/dev/null || true

# Active members from the plans[] projection; archived members need no action.
MEMBERS=$(python3 - "$INDEX" "$SLUG" << 'PYEOF'
import json, sys

index_path, slug = sys.argv[1], sys.argv[2]
try:
    with open(index_path, encoding="utf-8") as f:
        data = json.load(f)
except (OSError, json.JSONDecodeError):
    data = {}
for item in data.get("plans") or []:
    if isinstance(item, dict) and str(item.get("project", "") or "") == slug:
        print(item.get("slug", ""))
PYEOF
)

MEMBER_SLUGS=()
while IFS= read -r member; do
  [[ -n "$member" ]] && MEMBER_SLUGS+=("$member")
done <<<"$MEMBERS"

if [[ $RECORD_EXISTS -eq 0 && ${#MEMBER_SLUGS[@]} -eq 0 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "No project record or active members found for: $SLUG"
  fi
  echo "[work] Error: No project record or active members found for: $SLUG" >&2
  exit 1
fi

if [[ $YES -ne 1 ]]; then
  echo "Archive project '$SLUG': ${#MEMBER_SLUGS[@]} active member(s) will be archived." >&2
  for member in "${MEMBER_SLUGS[@]+"${MEMBER_SLUGS[@]}"}"; do
    echo "  - $member" >&2
  done
  printf "Proceed? [y/N] " >&2
  read -r REPLY
  if [[ "$REPLY" != "y" && "$REPLY" != "Y" ]]; then
    if [[ $JSON_MODE -eq 1 ]]; then
      json_error "Aborted by user"
    fi
    echo "[work] Aborted." >&2
    exit 1
  fi
fi

ARCHIVED_MEMBERS=()
FAILED_MEMBERS=()
for member in "${MEMBER_SLUGS[@]+"${MEMBER_SLUGS[@]}"}"; do
  if bash "$SCRIPT_DIR/archive-work.sh" "$member" >/dev/null; then
    ARCHIVED_MEMBERS+=("$member")
  else
    echo "[work] Warning: failed to archive member '$member' — continuing with remaining members." >&2
    FAILED_MEMBERS+=("$member")
  fi
done

# Record status flips in place only after a clean sweep, and only on a record
# that already exists — archiving never registers a project. A legacy flat
# record migrates to the directory home on this touch.
RECORD_UPDATED=0
if [[ ${#FAILED_MEMBERS[@]} -eq 0 && $RECORD_EXISTS -eq 1 ]]; then
  set_project_record_status "$WORK_DIR" "$SLUG" archived
  RECORD_UPDATED=1
fi

if [[ $JSON_MODE -eq 1 ]]; then
  RESULT=$(python3 - "$SLUG" "$RECORD_UPDATED" \
    "$(printf '%s\n' "${ARCHIVED_MEMBERS[@]+"${ARCHIVED_MEMBERS[@]}"}")" \
    "$(printf '%s\n' "${FAILED_MEMBERS[@]+"${FAILED_MEMBERS[@]}"}")" << 'PYEOF'
import json, sys

slug, record_updated, archived_raw, failed_raw = sys.argv[1:5]
print(json.dumps({
    "slug": slug,
    "archived_members": [s for s in archived_raw.splitlines() if s],
    "failed_members": [s for s in failed_raw.splitlines() if s],
    "record_status_updated": record_updated == "1",
}, indent=2))
PYEOF
)
  if [[ ${#FAILED_MEMBERS[@]} -gt 0 ]]; then
    printf '%s\n' "$RESULT"
    exit 1
  fi
  json_output "$RESULT"
fi

echo "[work] Archived project '$SLUG': ${#ARCHIVED_MEMBERS[@]} member(s) archived"
if [[ "$RECORD_UPDATED" -eq 1 ]]; then
  echo "[work] Project record marked archived: $WORK_DIR/_projects/$SLUG"
elif [[ $RECORD_EXISTS -eq 0 ]]; then
  echo "[work] No project record to update (label-only project)"
fi
if [[ ${#FAILED_MEMBERS[@]} -gt 0 ]]; then
  echo "[work] Error: ${#FAILED_MEMBERS[@]} member(s) failed to archive: ${FAILED_MEMBERS[*]} — record status unchanged." >&2
  exit 1
fi
