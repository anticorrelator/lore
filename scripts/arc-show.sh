#!/usr/bin/env bash
# arc-show.sh — show one arc: its record joined with the documents in its
# directory, and its ledger rows reproduced exactly as the coordinator wrote them.
#
# Usage: bash arc-show.sh <slug> [--json]
#
# Read-only: it never creates or touches anything under the arc directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  lore arc show <slug> [--json]

Shows the arc's recorded state, the documents it holds, and its step ledger.
Ledger rows are printed verbatim — they are coordinator shorthand and reformatting
them loses information.

Options:
  --json         Emit the record joined with the document list as JSON.
  --kdir <path>  Override the resolved knowledge dir (testing).
  --help, -h     Show this help.
EOF
}

SLUG=""
JSON_MODE=0
KDIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
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

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
[[ -d "$KNOWLEDGE_DIR" ]] || fail "knowledge store not found at: $KNOWLEDGE_DIR"

RECORD_DIR="$KNOWLEDGE_DIR/_work/_arcs/$SLUG"
[[ -f "$RECORD_DIR/_meta.json" ]] || fail "no arc named '$SLUG'"

ARC_RECORD_DIR="$RECORD_DIR" \
ARC_SLUG="$SLUG" \
ARC_JSON_MODE="$JSON_MODE" \
python3 - <<'PYEOF'
import json
import os
import sys

env = os.environ
RECORD_DIR = env["ARC_RECORD_DIR"]
SLUG = env["ARC_SLUG"]
JSON_MODE = env["ARC_JSON_MODE"] == "1"

meta_path = os.path.join(RECORD_DIR, "_meta.json")
try:
    with open(meta_path) as handle:
        record = json.load(handle)
except ValueError:
    sys.stderr.write("[arc] Error: the record at %s is not valid JSON\n" % meta_path)
    sys.exit(1)

documents = sorted(
    name for name in os.listdir(RECORD_DIR)
    if not name.startswith("_") and not name.startswith(".")
    and os.path.isfile(os.path.join(RECORD_DIR, name))
)

ledger_path = os.path.join(RECORD_DIR, "coordination.md")
has_ledger = os.path.isfile(ledger_path)

if JSON_MODE:
    out = dict(record)
    out["path"] = os.path.join("_work", "_arcs", SLUG)
    out["documents"] = documents
    out["has_ledger"] = has_ledger
    out["has_report"] = "report.md" in documents
    print(json.dumps(out, indent=2))
    sys.exit(0)

print("=== %s ===" % (record.get("title") or SLUG))
print("  slug:      %s" % (record.get("slug") or SLUG))
print("  status:    %s" % (record.get("status") or "unrecorded"))
print("  project:   %s" % (record.get("project") or "none"))
print("  opened:    %s" % (record.get("opened") or "unrecorded"))
if record.get("closed_at"):
    print("  closed_at: %s" % record["closed_at"])
print("  members:   %s" % (", ".join(record.get("members") or []) or "none"))
print("")
print("Anchor:")
print("  %s" % (record.get("anchor") or "(none recorded)"))
print("")
print("Documents:")
for name in documents:
    print("  %s" % name)
if not documents:
    print("  (none)")

if not has_ledger:
    print("")
    print("Ledger: no coordination.md in this arc.")
    sys.exit(0)

with open(ledger_path) as handle:
    lines = handle.read().splitlines()

ledger_rows = []
in_ledger = False
for line in lines:
    if line.startswith("## "):
        in_ledger = line.strip() == "## Step Ledger"
        continue
    if in_ledger:
        ledger_rows.append(line)

while ledger_rows and not ledger_rows[0].strip():
    ledger_rows.pop(0)
while ledger_rows and not ledger_rows[-1].strip():
    ledger_rows.pop()

print("")
print("Step Ledger:")
if not ledger_rows:
    print("  (no rows yet)")
for line in ledger_rows:
    print(line)
PYEOF
