#!/usr/bin/env bash
# verify-plan-intent-anchor.sh — Verify a work item's plan.md preserves the
# neutral `intent_anchor` captured at intake.
#
# Contract (D3 of work item `capability-anchor-protocol`):
#   Args:
#     <slug>                Required positional. Work-item slug.
#     --work-dir <path>     Optional. Treat <path> as the work root, so the
#                           script reads <path>/<slug>/_meta.json and
#                           <path>/<slug>/plan.md. Defaults to
#                           "$(lore resolve)/_work".
#
#   Behavior:
#     - When `_meta.json.intent_anchor` is absent / null / blank-after-trim:
#       exit 0 and emit a one-line stderr info message documenting the skip
#       (legacy back-compat — absence is legible, not silent).
#     - Otherwise extract the `## Intent Anchor` section body from plan.md
#       (lines after `^## Intent Anchor$` up to but not including the first
#       `^\*\*Scope delta:\*\*` line) and compare against the meta value,
#       both stripped of leading/trailing whitespace (internal whitespace and
#       line breaks compared exactly). Also require that a `**Scope delta:**`
#       line appears before the next top-level `^## ` heading or EOF.
#
#   Exit codes:
#     0  pass — anchor matches AND scope-delta line present, OR
#               anchor absent in _meta.json (with stderr skip message).
#     1  usage error (missing slug, unreadable inputs, malformed JSON).
#     2  `## Intent Anchor` section missing from plan.md.
#     3  anchor body diverges from _meta.json.intent_anchor.
#     4  `**Scope delta:**` line missing inside the section.
#
#   Stderr format on failure (per script-output-formatting convention):
#     [verify-plan-intent-anchor] <slug>: <one-line reason> — <remediation>

set -euo pipefail

SCRIPT_NAME="verify-plan-intent-anchor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<EOF
Usage: bash verify-plan-intent-anchor.sh <slug> [--work-dir <path>]

Verifies that the work item's plan.md preserves _meta.json.intent_anchor
in a structured \`## Intent Anchor\` section followed by a \`**Scope delta:**\`
line.
EOF
  exit 1
}

# --- Parse arguments ---
SLUG=""
WORK_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir)
      [[ $# -ge 2 ]] || { echo "[$SCRIPT_NAME] error: --work-dir requires a path" >&2; exit 1; }
      WORK_DIR="$2"
      shift 2
      ;;
    --work-dir=*)
      WORK_DIR="${1#--work-dir=}"
      shift
      ;;
    -h|--help)
      usage
      ;;
    --*)
      echo "[$SCRIPT_NAME] error: unknown flag: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$SLUG" ]]; then
        SLUG="$1"
      else
        echo "[$SCRIPT_NAME] error: unexpected positional argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$SLUG" ]]; then
  usage
fi

# --- Resolve work directory ---
if [[ -z "$WORK_DIR" ]]; then
  KDIR=$(resolve_knowledge_dir) || {
    echo "[$SCRIPT_NAME] $SLUG: failed to resolve knowledge dir via lore resolve — ensure lore is installed." >&2
    exit 1
  }
  WORK_DIR="$KDIR/_work"
fi

ITEM_DIR="$WORK_DIR/$SLUG"
META_FILE="$ITEM_DIR/_meta.json"
PLAN_FILE="$ITEM_DIR/plan.md"

if [[ ! -f "$META_FILE" ]]; then
  echo "[$SCRIPT_NAME] $SLUG: _meta.json not found at $META_FILE — verify slug and --work-dir." >&2
  exit 1
fi

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "[$SCRIPT_NAME] $SLUG: plan.md not found at $PLAN_FILE — run /spec to produce a plan before verifying." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[$SCRIPT_NAME] $SLUG: python3 not found on PATH — required for JSON parse and section extraction." >&2
  exit 1
fi

# --- Run extraction + comparison in Python ---
# Exit codes propagated from python: 0/2/3/4 as documented above. Python's
# stdout is reserved for diagnostic detail; stderr carries the human-readable
# one-liner. We pass paths + slug as argv so the heredoc body has no
# interpolation surprises.
set +e
python3 - "$SCRIPT_NAME" "$SLUG" "$META_FILE" "$PLAN_FILE" <<'PYEOF'
import json
import re
import sys

script_name = sys.argv[1]
slug = sys.argv[2]
meta_path = sys.argv[3]
plan_path = sys.argv[4]


def emit(reason, remediation):
    sys.stderr.write(
        "[{name}] {slug}: {reason} — {rem}\n".format(
            name=script_name, slug=slug, reason=reason, rem=remediation
        )
    )


try:
    with open(meta_path, "r", encoding="utf-8") as fh:
        meta = json.load(fh)
except (OSError, json.JSONDecodeError) as exc:
    emit(
        "failed to read _meta.json ({})".format(exc),
        "ensure the file is valid JSON and readable",
    )
    sys.exit(1)

raw_anchor = meta.get("intent_anchor")
if raw_anchor is None or not isinstance(raw_anchor, str) or raw_anchor.strip() == "":
    sys.stderr.write(
        "[{name}] {slug}: no intent_anchor in _meta.json — skipping\n".format(
            name=script_name, slug=slug
        )
    )
    sys.exit(0)

anchor_expected = raw_anchor.strip()

try:
    with open(plan_path, "r", encoding="utf-8") as fh:
        plan = fh.read()
except OSError as exc:
    emit(
        "failed to read plan.md ({})".format(exc),
        "ensure the file exists and is readable",
    )
    sys.exit(1)

lines = plan.splitlines()

# Locate the `^## Intent Anchor$` heading (case-sensitive, exact).
heading_idx = None
for i, line in enumerate(lines):
    if line == "## Intent Anchor":
        heading_idx = i
        break

if heading_idx is None:
    emit(
        "section missing",
        "add a `## Intent Anchor` section to plan.md immediately after `## Narrative` "
        "with the anchor body verbatim from `_meta.json.intent_anchor`",
    )
    sys.exit(2)

# Walk forward from heading_idx + 1, collecting body lines until we hit either:
#   - a `**Scope delta:**` line (extraction boundary; body extraction succeeds)
#   - the next top-level `## ` heading or EOF (scope-delta line missing)
scope_delta_re = re.compile(r"^\*\*Scope delta:\*\*")
next_heading_re = re.compile(r"^## ")

body_lines = []
scope_delta_found = False
for j in range(heading_idx + 1, len(lines)):
    line = lines[j]
    if scope_delta_re.match(line):
        scope_delta_found = True
        break
    if next_heading_re.match(line):
        # Next top-level heading encountered without ever seeing scope-delta.
        break
    body_lines.append(line)

if not scope_delta_found:
    emit(
        "scope-delta line missing",
        "add a `**Scope delta:**` line immediately after the anchor body "
        "(default \"none — anchor preserved unchanged\")",
    )
    sys.exit(4)

# Trim leading/trailing blank lines from the extracted body. Internal
# whitespace and blank lines are preserved exactly.
start = 0
while start < len(body_lines) and body_lines[start].strip() == "":
    start += 1
end = len(body_lines)
while end > start and body_lines[end - 1].strip() == "":
    end -= 1
body_trimmed_lines = body_lines[start:end]
body_extracted = "\n".join(body_trimmed_lines).strip()

if body_extracted != anchor_expected:
    emit(
        "body diverges from _meta.json.intent_anchor",
        "rewrite the section body verbatim from "
        "`lore work load <slug> --json | jq -r .meta.intent_anchor`",
    )
    sys.exit(3)

sys.exit(0)
PYEOF
rc=$?
set -e
exit $rc
