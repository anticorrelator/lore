#!/usr/bin/env bash
# make-epistemic-store.sh — Build a throwaway knowledge store for exercising the
# epistemic lifecycle writers (corroboration, kind_status, expiry).
#
# Usage: make-epistemic-store.sh <dir>
#
# The eight entries are chosen so one covers each branch the expiry sweep can
# take, and they are dated against a fixed reference day rather than "now", so
# day arithmetic in a caller's assertions does not drift with the calendar. Tests
# pass --today 2026-08-09 to match.
#
#   stale-untested-hypothesis         old, unresolved              -> candidate
#   stale-open-question               old, unresolved, other kind  -> candidate
#   fresh-untested-hypothesis         unresolved but recent        -> skipped: fresh
#   recently-corroborated-hypothesis  old `learned`, new corroboration
#                                                                  -> skipped: fresh
#                                     (the declared-timestamps-not-mtime case)
#   stale-supported-hypothesis        old but settled              -> skipped: settled
#   stale-plain-fact                  a kind with no lifecycle     -> skipped
#   legacy-no-kind                    written before the field     -> skipped
#   already-retired-hypothesis        already out of the default set -> skipped
#
# Never point the writers at a real store; build one of these instead.

set -euo pipefail

FIX="${1:?usage: make-epistemic-store.sh <dir>}"

# The reference "today" the dated entries below are positioned against.
REFERENCE_TODAY="2026-08-09"

rm -rf "$FIX"
mkdir -p "$FIX/conventions" "$FIX/gotchas" "$FIX/_trust" "$FIX/_meta"

mk() {
  local path="$1" title="$2" footer="$3"
  mkdir -p "$(dirname "$FIX/$path")"
  printf '# %s\n%s\n%s\n' "$title" "Body prose for $title." "$footer" > "$FIX/$path"
}

mk conventions/stale-untested-hypothesis.md "Stale Untested Hypothesis" \
  '<!-- learned: 2025-06-01 | confidence: medium | source: manual | scale: implementation | kind: hypothesis | kind_status: untested | captured_at_branch: main | captured_at_sha: null | captured_at_merge_base_sha: null | status: current -->'

mk conventions/fresh-untested-hypothesis.md "Fresh Untested Hypothesis" \
  "<!-- learned: $REFERENCE_TODAY | confidence: medium | source: manual | scale: implementation | kind: hypothesis | kind_status: untested | status: current -->"

mk conventions/stale-supported-hypothesis.md "Stale Supported Hypothesis" \
  '<!-- learned: 2025-06-01 | confidence: high | source: manual | scale: implementation | kind: hypothesis | kind_status: supported | status: current -->'

mk gotchas/stale-open-question.md "Stale Open Question" \
  '<!-- learned: 2025-01-15 | confidence: medium | source: manual | scale: subsystem | kind: question | kind_status: open | where_looked: scripts/foo.sh | status: current -->'

mk conventions/stale-plain-fact.md "Stale Plain Fact" \
  '<!-- learned: 2024-11-01 | confidence: high | source: manual | scale: implementation | kind: fact | status: current -->'

mk conventions/legacy-no-kind.md "Legacy No Kind" \
  '<!-- learned: 2024-10-01 | confidence: high | source: manual | scale: implementation | status: current -->'

mk conventions/already-retired-hypothesis.md "Already Retired Hypothesis" \
  '<!-- learned: 2025-02-01 | confidence: medium | source: manual | scale: implementation | kind: hypothesis | kind_status: untested | status: retired | retirements: [{"date": "2026-01-01", "retirement_id": "ret-aaaaaaaaaaaa", "reason": "The queue it describes was removed.", "falsifier": "A live caller still reads it.", "prior_status": "current", "result_status": "retired"}] -->'

# The one that pins recency to declared timestamps: an old `learned` date, but a
# corroboration recorded on the reference day. An mtime-based or learned-only
# sweep would propose this entry; a correct one leaves it alone.
mk conventions/recently-corroborated-hypothesis.md "Recently Corroborated Hypothesis" \
  "<!-- learned: 2025-03-01 | confidence: medium | source: manual | scale: implementation | kind: hypothesis | kind_status: untested | status: current | corroborations: [{\"date\": \"$REFERENCE_TODAY\", \"corroboration_id\": \"corr-bbbbbbbbbbbb\", \"observed_at\": \"$REFERENCE_TODAY\", \"source\": \"worker\", \"direction\": \"supports\", \"note\": \"Held when I read it again.\"}] -->"

python3 - "$FIX" <<'MANIFEST_PY'
import json, os, sys
kdir = sys.argv[1]
entries = []
for root, dirnames, filenames in os.walk(kdir):
    dirnames[:] = [d for d in dirnames if not d.startswith("_")]
    for name in sorted(filenames):
        if name.endswith(".md"):
            entries.append({"path": os.path.relpath(os.path.join(root, name), kdir),
                            "backlinks": []})
manifest = {"format_version": 2, "entries": sorted(entries, key=lambda e: e["path"])}
with open(os.path.join(kdir, "_manifest.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f)
MANIFEST_PY

echo "epistemic fixture store at $FIX ($(find "$FIX" -name '*.md' | wc -l | tr -d ' ') entries)"
