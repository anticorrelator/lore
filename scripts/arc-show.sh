#!/usr/bin/env bash
# arc-show.sh — show one arc: its record joined with the documents in its
# directory, and its ledger rows reproduced exactly as the coordinator wrote them.
# --json adds every file in the arc's directory tree, the ledger's Brief, and the
# digest's decisions, so a reader never has to parse the arc's markdown itself.
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
  --json         Emit the record joined with the document list as JSON, plus
                 files (every file under the arc, recursively), brief (the
                 ledger's Brief as {label, text}) and decisions (digest.md
                 paragraphs as {text, heading}, heading being the nearest
                 heading above the paragraph, or null).
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
ARC_SCRIPT_DIR="$SCRIPT_DIR" \
ARC_SLUG="$SLUG" \
ARC_JSON_MODE="$JSON_MODE" \
python3 - <<'PYEOF'
import json
import os
import re
import stat
import sys
from datetime import datetime, timezone

env = os.environ
sys.path.insert(0, env["ARC_SCRIPT_DIR"])
from extract_section import extract_section

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

HIDDEN = ("_", ".")
COMMENT = re.compile(r"<!--.*?-->", re.S)
HEADING = re.compile(r"^#{1,6}(\s|$)")
RULE = re.compile(r"^([-*_])(\s*\1){2,}$")
CLOSING_HASHES = re.compile(r"\s+#+$")
LIST_ITEM = re.compile(r"^(\d+[.)]|[-*+])\s")
BRIEF_LABEL = re.compile(r"^\*\*(?P<label>[^*]+?)(:\*\*|\*\*:)\s*(?P<text>.*)$")


def arc_files():
    found = []
    for root, dirs, names in os.walk(RECORD_DIR):
        dirs[:] = [name for name in dirs if not name.startswith(HIDDEN)]
        for name in names:
            if name.startswith(HIDDEN):
                continue
            full = os.path.join(root, name)
            info = os.lstat(full)
            if not stat.S_ISREG(info.st_mode):
                continue
            found.append({
                "path": os.path.relpath(full, RECORD_DIR).replace(os.sep, "/"),
                "size": info.st_size,
                "mtime": datetime.fromtimestamp(info.st_mtime, timezone.utc)
                .strftime("%Y-%m-%dT%H:%M:%SZ"),
            })
    return sorted(found, key=lambda entry: entry["path"])


def brief_entries():
    if not has_ledger:
        return []
    section = extract_section(ledger_path, "Brief", exact=True)
    if section is None:
        return []
    body = COMMENT.sub("", section.partition("\n")[2])
    entries = []
    current = None
    for line in body.splitlines():
        line = line.strip()
        if not line or HEADING.match(line):
            current = None
            continue
        match = BRIEF_LABEL.match(line)
        if match:
            current = [match.group("label").strip(), match.group("text")]
            entries.append(current)
        elif current is None:
            current = ["", line]
            entries.append(current)
        else:
            current.append(line)
    out = []
    for entry in entries:
        text = "\n".join(entry[1:]).strip()
        if text.startswith("<") and text.endswith(">"):
            text = ""
        out.append({"label": entry[0], "text": text})
    return out


# A digest is prose for the owner with no fixed shape: numbered items, bold
# leads, bare paragraphs, or a heading per decision. Every paragraph is one
# entry, and a list item starts a new entry even with no blank line before it.
# Each entry carries the nearest heading above it, which is the decision's title
# in a digest written as one heading per decision.
def decision_entries():
    digest_path = os.path.join(RECORD_DIR, "digest.md")
    if not os.path.isfile(digest_path):
        return []
    with open(digest_path, encoding="utf-8") as handle:
        text = COMMENT.sub("", handle.read())
    entries = []
    current = None
    heading = None
    for line in text.splitlines():
        line = line.strip()
        if HEADING.match(line):
            heading = CLOSING_HASHES.sub("", line.lstrip("#")).strip()
            current = None
            continue
        if not line or RULE.match(line):
            current = None
            continue
        if current is None or LIST_ITEM.match(line):
            current = {"lines": [], "heading": heading}
            entries.append(current)
        current["lines"].append(line)
    return [{"text": "\n".join(entry["lines"]), "heading": entry["heading"]}
            for entry in entries]


if JSON_MODE:
    out = dict(record)
    out["path"] = os.path.join("_work", "_arcs", SLUG)
    out["documents"] = documents
    out["has_ledger"] = has_ledger
    out["has_report"] = "report.md" in documents
    out["files"] = arc_files()
    out["brief"] = brief_entries()
    out["decisions"] = decision_entries()
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
