#!/usr/bin/env bash
# arc-set.sh — update an arc's descriptive fields (title, anchor, project).
#
# Usage: bash arc-set.sh <slug> [--title <t>] [--anchor <a>] [--project <p> | --clear-project]
#
# Status and timestamps belong to the lifecycle verbs; this one only touches the
# fields that describe the arc. Omitted flags leave their fields alone.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  lore arc set <slug> [--title <title>] [--anchor <intent>]
                      [--project <name> | --clear-project]

Updates an arc's descriptive fields. At least one field flag is required.

Options:
  --title <title>    Replace the title. The slug never changes with it.
  --anchor <intent>  Replace the intent statement, stored verbatim.
  --project <name>   Set the project label. An empty value is refused — pass
                     --clear-project to remove the label.
  --clear-project    Remove the project label.
  --json             Emit the updated record as JSON.
  --kdir <path>      Override the resolved knowledge dir (testing).
  --help, -h         Show this help.
EOF
}

SLUG=""
TITLE=""; HAS_TITLE=0
ANCHOR=""; HAS_ANCHOR=0
PROJECT=""; HAS_PROJECT=0
CLEAR_PROJECT=0
JSON_MODE=0
KDIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="${2:-}"; HAS_TITLE=1; shift 2 ;;
    --anchor) ANCHOR="${2:-}"; HAS_ANCHOR=1; shift 2 ;;
    --project) PROJECT="${2:-}"; HAS_PROJECT=1; shift 2 ;;
    --clear-project) CLEAR_PROJECT=1; shift ;;
    --json) JSON_MODE=1; shift ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*)
      if [[ $JSON_MODE -eq 1 ]]; then json_error "Unknown option '$1'"; fi
      echo "[arc] Error: unknown option '$1'" >&2; usage; exit 1 ;;
    *)
      if [[ -n "$SLUG" ]]; then
        echo "[arc] Error: unexpected argument '$1'" >&2; usage; exit 1
      fi
      SLUG="$1"; shift ;;
  esac
done

fail() {
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$1"
  fi
  echo "[arc] Error: $1" >&2
  exit 1
}

[[ -n "$SLUG" ]] || fail "a slug is required"

if [[ $HAS_TITLE -eq 0 && $HAS_ANCHOR -eq 0 && $HAS_PROJECT -eq 0 && $CLEAR_PROJECT -eq 0 ]]; then
  fail "nothing to set — pass at least one of --title, --anchor, --project, --clear-project"
fi
if [[ $HAS_PROJECT -eq 1 && $CLEAR_PROJECT -eq 1 ]]; then
  fail "--project and --clear-project are mutually exclusive"
fi
if [[ $HAS_PROJECT -eq 1 && -z "$PROJECT" ]]; then
  fail "--project cannot be empty — pass --clear-project to remove the label"
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

RECORD_DIR="$KNOWLEDGE_DIR/_work/_arcs/$SLUG"
[[ -f "$RECORD_DIR/_meta.json" ]] || fail "no arc named '$SLUG'"

WRITE_ARGS=(--kdir "$KNOWLEDGE_DIR" --slug "$SLUG" --op set)
[[ $HAS_TITLE -eq 1 ]] && WRITE_ARGS+=(--title "$TITLE")
[[ $HAS_ANCHOR -eq 1 ]] && WRITE_ARGS+=(--anchor "$ANCHOR")
[[ $HAS_PROJECT -eq 1 ]] && WRITE_ARGS+=(--project "$PROJECT")
[[ $CLEAR_PROJECT -eq 1 ]] && WRITE_ARGS+=(--clear-project)

ENVELOPE=$("$SCRIPT_DIR/arc-write-meta.sh" "${WRITE_ARGS[@]}") || exit 1

if [[ $JSON_MODE -eq 1 ]]; then
  printf '%s' "$ENVELOPE" | python3 -c '
import json, sys
print(json.dumps(json.load(sys.stdin)["record"], indent=2))
'
  exit 0
fi

printf '%s' "$ENVELOPE" | python3 -c '
import json, sys
envelope = json.load(sys.stdin)
record = envelope["record"]
title = record.get("title") or "untitled"
if envelope["changed"]:
    print("[arc] Updated: %s (%s)" % (record["slug"], title))
    print("  project: %s" % (record.get("project") or "none"))
else:
    print("[arc] No change: %s (%s) already carries those values" % (record["slug"], title))
'
