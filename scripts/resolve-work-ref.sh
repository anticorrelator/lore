#!/usr/bin/env bash
# resolve-work-ref.sh — Resolve a fuzzy work-item reference to (slug, archived)
# Usage: bash resolve-work-ref.sh <ref> [--branch <name>] [--include-archived] [--json]
#
# Implements the 7-tier resolution algorithm previously duplicated in
# /work, /implement, /spec, /retro SKILL.md prose:
#
#   Fast path: exact-slug filesystem probe (_work/<ref>/_meta.json,
#              then _work/_archive/<ref>/_meta.json).
#   Tier 1: exact slug match in _index.json plans.
#   Tier 2: substring match on title.
#   Tier 3: substring match on slug.
#   Tier 4: tag match.
#   Tier 5: branch match (only when --branch <name> given).
#   Tier 6: recency — most recently updated active.
#   Tier 7: archive fallback — re-apply tiers 1–3 against archived entries.
#
# Exit codes:
#   0  unique resolution; prints "<slug>\n<archived>\n" (or JSON object)
#   1  no match; stderr error line, JSON {"error":...}
#   2  ambiguous; stderr candidate list, JSON {"error":..., "candidates":[...]}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REF=""
BRANCH=""
INCLUDE_ARCHIVED=0
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      BRANCH="${2:-}"
      shift 2
      ;;
    --branch=*)
      BRANCH="${1#--branch=}"
      shift
      ;;
    --include-archived)
      INCLUDE_ARCHIVED=1
      shift
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --help|-h)
      cat >&2 <<EOF
Usage: lore work resolve <ref> [--branch <name>] [--include-archived] [--json]

Resolve a fuzzy work-item reference to a canonical slug.

Output (text mode, default): two lines on stdout — "<slug>\n<archived>\n"
                             where <archived> is the literal "true" or "false".
Output (--json):              {"slug":"...","archived":true|false}

Exit codes:
  0  unique resolution
  1  no match (error line on stderr)
  2  ambiguous (candidate list on stderr; "candidates":[...] in JSON)
EOF
      exit 0
      ;;
    --*)
      if [[ $JSON_MODE -eq 1 ]]; then
        json_error "Unknown flag: $1"
      fi
      echo "[work resolve] Error: Unknown flag: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$REF" ]]; then
        REF="$1"
      else
        if [[ $JSON_MODE -eq 1 ]]; then
          json_error "Unexpected extra argument: $1"
        fi
        echo "[work resolve] Error: Unexpected extra argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$REF" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "Missing required argument: <ref>"
  fi
  echo "[work resolve] Error: Missing required argument: <ref>" >&2
  echo "Usage: lore work resolve <ref> [--branch <name>] [--include-archived] [--json]" >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work"
ARCHIVE_DIR="$WORK_DIR/_archive"
INDEX="$WORK_DIR/_index.json"

if [[ ! -d "$WORK_DIR" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "No work directory found at $WORK_DIR"
  fi
  echo "[work resolve] Error: No work directory found at $WORK_DIR" >&2
  exit 1
fi

# --- Emit helpers ---------------------------------------------------------
emit_resolved() {
  local slug="$1"
  local archived="$2"  # "true" | "false"
  if [[ $JSON_MODE -eq 1 ]]; then
    local archived_literal="false"
    [[ "$archived" == "true" ]] && archived_literal="true"
    json_output "$(printf '{"slug":"%s","archived":%s}' "$slug" "$archived_literal")"
  fi
  printf '%s\n%s\n' "$slug" "$archived"
  exit 0
}

emit_ambiguous() {
  # $1: newline-separated list of candidate slugs (deduped, sorted by relevance)
  local candidates="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    local arr
    arr=$(printf '%s\n' "$candidates" | python3 -c '
import json, sys
slugs = [line.strip() for line in sys.stdin if line.strip()]
print(json.dumps(slugs))
')
    local payload
    payload=$(python3 -c '
import json, sys
arr_raw = sys.argv[1]
print(json.dumps({"error": "ambiguous reference", "candidates": json.loads(arr_raw)}))
' "$arr")
    printf '%s\n' "$payload"
    exit 2
  fi
  echo "[work resolve] Ambiguous reference '$REF' — candidates:" >&2
  printf '  %s\n' $(printf '%s\n' "$candidates" | sed '/^$/d') >&2
  exit 2
}

emit_no_match() {
  if [[ $JSON_MODE -eq 1 ]]; then
    local payload
    payload=$(python3 -c '
import json, sys
print(json.dumps({"error": "no match for reference: " + sys.argv[1]}))
' "$REF")
    printf '%s\n' "$payload"
    exit 1
  fi
  echo "[work resolve] Error: No match for reference '$REF'" >&2
  exit 1
}

# --- Fast path: exact-slug filesystem probe -------------------------------
# This avoids reading _index.json for the common case where the caller
# already knows the canonical slug. Per D3 of the design.
if [[ -f "$WORK_DIR/$REF/_meta.json" ]]; then
  emit_resolved "$REF" "false"
fi
if [[ -f "$ARCHIVE_DIR/$REF/_meta.json" ]]; then
  emit_resolved "$REF" "true"
fi

# --- Self-heal: regenerate _index.json if missing -------------------------
if [[ ! -f "$INDEX" ]]; then
  "$SCRIPT_DIR/update-work-index.sh" 2>/dev/null || true
fi
if [[ ! -f "$INDEX" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "No work index found and could not regenerate at $INDEX"
  fi
  echo "[work resolve] Error: No work index found and could not regenerate at $INDEX" >&2
  exit 1
fi

# --- Index-based tiers (Python) -------------------------------------------
# Delegated to python3 for robust JSON parsing. Returns one of:
#   RESOLVED <slug> <archived>
#   AMBIGUOUS <slug>\n<slug>\n...
#   NONE
RESULT=$(python3 - "$INDEX" "$REF" "$BRANCH" "$INCLUDE_ARCHIVED" <<'PYEOF'
import json
import sys
from datetime import datetime, timezone


def parse_epoch(value):
    if not value:
        return 0
    raw = str(value)
    candidates = [raw]
    if raw.endswith("Z"):
        candidates.append(raw[:-1] + "+00:00")
        candidates.append(raw[:-1])
    for candidate in candidates:
        try:
            dt = datetime.fromisoformat(candidate)
        except ValueError:
            continue
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    return 0


index_path, ref, branch, include_archived_flag = sys.argv[1:]
include_archived = include_archived_flag == "1"
ref_lower = ref.lower()

with open(index_path) as f:
    data = json.load(f)

plans = data.get("plans", []) or []
archived_raw = data.get("archived", []) or []

# Normalize archived entries — some legacy rows may be plain strings.
archived = []
for item in archived_raw:
    if isinstance(item, str):
        archived.append({"slug": item, "title": item, "tags": [], "branches": []})
    else:
        archived.append(item)


def emit(line):
    print(line)


def candidates_unique_ordered(seq):
    seen = set()
    out = []
    for slug in seq:
        if slug and slug not in seen:
            seen.add(slug)
            out.append(slug)
    return out


def tier_matches(items, tier, ref_lower, branch):
    """Return list of slugs matching `tier` against `items`."""
    matches = []
    for item in items:
        slug = str(item.get("slug", "") or "")
        title = str(item.get("title", "") or "")
        tags = item.get("tags", []) or []
        branches = item.get("branches", []) or []
        if tier == "exact_slug":
            if slug == ref_lower or slug.lower() == ref_lower:
                matches.append(slug)
        elif tier == "title_substring":
            if ref_lower and ref_lower in title.lower():
                matches.append(slug)
        elif tier == "slug_substring":
            if ref_lower and ref_lower in slug.lower():
                matches.append(slug)
        elif tier == "tag":
            for tag in tags:
                if ref_lower == str(tag).lower():
                    matches.append(slug)
                    break
        elif tier == "branch":
            if branch:
                for b in branches:
                    if str(b) == branch:
                        matches.append(slug)
                        break
    return candidates_unique_ordered(matches)


def try_tiers(items, tiers, ref_lower, branch):
    """Walk the given tiers in order against `items`. Return (slugs, tier_name)
    for the first tier producing matches. If a tier produces multiple, return
    them (caller decides ambiguity)."""
    for tier in tiers:
        matches = tier_matches(items, tier, ref_lower, branch)
        if matches:
            return matches, tier
    return [], None


# --- Active pass: tiers 1–6 (5 only if branch given; 6 recency only when ref
# matches *something* loosely, otherwise recency would resolve any garbage ref
# to "most recent active" which is surprising). Per the algorithm, recency
# acts as a *tie-breaker* / last-resort within an already-narrowed candidate
# set. We treat recency as a deterministic fallback only when prior tiers
# produced no match AND the ref is the literal sentinel "recent" or empty.
# For arbitrary refs, fall through to archive instead.
tiers_active = ["exact_slug", "title_substring", "slug_substring", "tag"]
if branch:
    tiers_active.append("branch")

slugs, tier = try_tiers(plans, tiers_active, ref_lower, branch)

if slugs:
    if len(slugs) == 1:
        emit(f"RESOLVED {slugs[0]} false")
        sys.exit(0)
    # Multiple matches at this tier — ambiguous. Surface candidates.
    emit("AMBIGUOUS")
    for s in slugs:
        emit(s)
    sys.exit(0)

# Recency tier (tier 6): only fires when ref is the explicit sentinel "recent"
# OR the caller explicitly asked for include_archived=0 with an empty-like ref.
# Per D2/D3 of the design, recency is a soft fallback — applied only when the
# ref is the empty/"recent" sentinel (an unambiguous "give me the most recent
# active item" request).
if ref_lower == "recent":
    sorted_plans = sorted(
        plans,
        key=lambda p: parse_epoch(p.get("updated", "")),
        reverse=True,
    )
    if sorted_plans:
        slug = str(sorted_plans[0].get("slug", "") or "")
        if slug:
            emit(f"RESOLVED {slug} false")
            sys.exit(0)

# --- Archive fallback (tier 7) -------------------------------------------
# Re-apply tiers 1–3 against archived entries. Branch/tag tiers usually do
# not apply to archived rows (legacy archived rows lack those fields), so
# we restrict to slug/title.
tiers_archive = ["exact_slug", "title_substring", "slug_substring"]
slugs_a, _ = try_tiers(archived, tiers_archive, ref_lower, branch)
if slugs_a:
    if len(slugs_a) == 1:
        emit(f"RESOLVED {slugs_a[0]} true")
        sys.exit(0)
    emit("AMBIGUOUS")
    for s in slugs_a:
        emit(s)
    sys.exit(0)

emit("NONE")
PYEOF
)

# Parse python output and dispatch.
FIRST_LINE=$(printf '%s\n' "$RESULT" | head -1)
case "$FIRST_LINE" in
  "RESOLVED "*)
    SLUG=$(printf '%s' "$FIRST_LINE" | awk '{print $2}')
    ARCHIVED=$(printf '%s' "$FIRST_LINE" | awk '{print $3}')
    emit_resolved "$SLUG" "$ARCHIVED"
    ;;
  "AMBIGUOUS")
    CANDIDATES=$(printf '%s\n' "$RESULT" | tail -n +2)
    emit_ambiguous "$CANDIDATES"
    ;;
  "NONE"|"")
    emit_no_match
    ;;
  *)
    if [[ $JSON_MODE -eq 1 ]]; then
      json_error "internal resolver error: unexpected output"
    fi
    echo "[work resolve] Internal error: unexpected resolver output:" >&2
    printf '%s\n' "$RESULT" >&2
    exit 1
    ;;
esac
