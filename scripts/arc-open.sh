#!/usr/bin/env bash
# arc-open.sh — open a coordination arc: create _work/_arcs/<slug>/, instantiate
# the ledger from the coordinate skill's template, and record the arc through
# arc-write-meta.sh.
#
# Usage: bash arc-open.sh --title <t> --anchor <a> [--project <p>] [--slug <s>]
#
# The slug is derived from the title. A slug that collides with an existing arc
# is refused, and so is one the length cap would clip — both name a slug nobody
# chose, in a substrate whose point is that names are findable. --slug is the
# way to choose one deliberately.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  lore arc open --title <title> --anchor <intent> [--project <name>] [--slug <slug>]

Opens a coordination arc as its own directory under _work/_arcs/, holding the
record, the ledger, and whatever documents the arc accumulates.

Options:
  --title <title>    What the arc is about. The slug is derived from it.
  --anchor <intent>  The intent statement, stored verbatim.
  --project <name>   Optional project label. Arcs are not contained by projects;
                     the label is there to filter and to display.
  --slug <slug>      Name the arc directly instead of deriving the name.
  --json             Emit the new record as JSON.
  --kdir <path>      Override the resolved knowledge dir (testing).
  --help, -h         Show this help.
EOF
}

TITLE=""
ANCHOR=""
PROJECT=""; HAS_PROJECT=0
SLUG_OVERRIDE=""
JSON_MODE=0
KDIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) TITLE="${2:-}"; shift 2 ;;
    --anchor) ANCHOR="${2:-}"; shift 2 ;;
    --project) PROJECT="${2:-}"; HAS_PROJECT=1; shift 2 ;;
    --slug) SLUG_OVERRIDE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*)
      if [[ $JSON_MODE -eq 1 ]]; then json_error "Unknown option '$1'"; fi
      echo "[arc] Error: unknown option '$1'" >&2; usage; exit 1 ;;
    *)
      if [[ $JSON_MODE -eq 1 ]]; then json_error "'$1' is unexpected — arc open takes no positional arguments"; fi
      echo "[arc] Error: '$1' is unexpected — arc open takes no positional arguments, the slug comes from --title" >&2
      usage
      exit 1 ;;
  esac
done

fail() {
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$1"
  fi
  echo "[arc] Error: $1" >&2
  exit 1
}

[[ -n "$TITLE" ]] || fail "--title is required"
[[ -n "$ANCHOR" ]] || fail "--anchor is required"
if [[ $HAS_PROJECT -eq 1 && -z "$PROJECT" ]]; then
  fail "--project cannot be empty"
fi

if [[ -n "$SLUG_OVERRIDE" ]]; then
  SLUG="$SLUG_OVERRIDE"
  if [[ ! "$SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    fail "'$SLUG' is not a valid arc slug — use lowercase letters, digits, and hyphens"
  fi
else
  SLUG="$(slugify "$TITLE")"
  [[ -n "$SLUG" ]] || fail "no slug could be derived from '$TITLE' — pass --slug"
  # slugify clips at MAX_SLUG_LENGTH; recomputing without the cap is how a
  # clipped slug is told apart from one the title actually produced.
  UNCLIPPED="$(MAX_SLUG_LENGTH=500; slugify "$TITLE")"
  if [[ "$SLUG" != "$UNCLIPPED" ]]; then
    fail "the title clips to '$SLUG' — pass --slug with a name you have chosen"
  fi
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

ARCS_DIR="$KNOWLEDGE_DIR/_work/_arcs"
RECORD_DIR="$ARCS_DIR/$SLUG"

if [[ -e "$RECORD_DIR" ]]; then
  EXISTING_TITLE=""
  if [[ -f "$RECORD_DIR/_meta.json" ]]; then
    EXISTING_TITLE="$(json_field "title" "$RECORD_DIR/_meta.json")"
  fi
  fail "an arc named '$SLUG' already exists (${EXISTING_TITLE:-untitled}) — pick a more specific topic, or pass --slug to name this one yourself"
fi

TEMPLATE="$LORE_REPO_DIR/skills/coordinate/templates/coordination.md"
[[ -f "$TEMPLATE" ]] || fail "the coordination ledger template is missing at $TEMPLATE"

mkdir -p "$RECORD_DIR"
CREATED_DIR="$RECORD_DIR"

cleanup_on_failure() {
  if [[ -n "$CREATED_DIR" && -d "$CREATED_DIR" ]]; then
    rm -rf "$CREATED_DIR"
  fi
}

if ! ARC_TITLE="$TITLE" ARC_ANCHOR="$ANCHOR" python3 - "$TEMPLATE" "$RECORD_DIR/coordination.md" <<'PYEOF'
import os
import sys

template_path, dest_path = sys.argv[1], sys.argv[2]
title = os.environ["ARC_TITLE"]
anchor = os.environ["ARC_ANCHOR"]

with open(template_path) as handle:
    lines = handle.read().splitlines()

for index, line in enumerate(lines):
    if line.startswith("# Coordination Ledger"):
        lines[index] = "# Coordination Ledger — " + title
    elif line.startswith("**Feature under coordination:**"):
        lines[index] = "**Feature under coordination:** " + anchor

with open(dest_path, "w") as handle:
    handle.write("\n".join(lines) + "\n")
PYEOF
then
  cleanup_on_failure
  fail "the ledger could not be instantiated from $TEMPLATE"
fi

WRITE_ARGS=(--kdir "$KNOWLEDGE_DIR" --slug "$SLUG" --op open --title "$TITLE" --anchor "$ANCHOR")
if [[ $HAS_PROJECT -eq 1 ]]; then
  WRITE_ARGS+=(--project "$PROJECT")
fi

if ! ENVELOPE=$("$SCRIPT_DIR/arc-write-meta.sh" "${WRITE_ARGS[@]}"); then
  cleanup_on_failure
  exit 1
fi

RELATIVE_PATH="_work/_arcs/$SLUG"

if [[ $JSON_MODE -eq 1 ]]; then
  printf '%s' "$ENVELOPE" | python3 -c '
import json, sys
envelope = json.load(sys.stdin)
record = envelope["record"]
record["path"] = sys.argv[1]
print(json.dumps(record, indent=2))
' "$RELATIVE_PATH"
  exit 0
fi

echo "[arc] Opened: $SLUG ($TITLE)"
echo "  path:   $RELATIVE_PATH"
echo "  ledger: $RELATIVE_PATH/coordination.md"
if [[ $HAS_PROJECT -eq 1 ]]; then
  echo "  project: $PROJECT"
fi
