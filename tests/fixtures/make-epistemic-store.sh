#!/usr/bin/env bash
# make-epistemic-store.sh — Build a throwaway knowledge store for exercising the
# epistemic lifecycle writers (corroboration, kind_status, expiry).
#
# Usage: make-epistemic-store.sh <dir> [--scaled]
#
# --scaled adds a second arm of entries all matching the token "quillon": more
# facts than a default result page holds, four theories across two subsystems,
# and questions and hypotheses in each kind_status. It exists so the delivery
# tests can watch an unsectioned ranked list actually starve the non-fact kinds
# rather than assert that it would. The base arm is unchanged without it.
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

FIX="${1:?usage: make-epistemic-store.sh <dir> [--scaled]}"
SCALED="${2:-}"

# The reference "today" the dated entries below are positioned against.
REFERENCE_TODAY="2026-08-09"

rm -rf "$FIX"
mkdir -p "$FIX/conventions" "$FIX/gotchas" "$FIX/_trust" "$FIX/_meta"

mk() {
  local path="$1" title="$2" footer="$3"
  mkdir -p "$(dirname "$FIX/$path")"
  printf '# %s\n%s\n%s\n' "$title" "Body prose for $title." "$footer" > "$FIX/$path"
}

# Same as mk, with the body supplied instead of generated.
mk_body() {
  local path="$1" title="$2" body="$3" footer="$4"
  mkdir -p "$(dirname "$FIX/$path")"
  printf '# %s\n%s\n%s\n' "$title" "$body" "$footer" > "$FIX/$path"
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

if [[ "$SCALED" == "--scaled" ]]; then
  # Twelve facts, each repeating the query token in a short body, so BM25 ranks
  # every one of them above the longer single-mention non-fact entries below.
  # A default page of ten results is all fact — which is the starvation the
  # sections exist to answer, observed rather than assumed.
  for n in $(seq -w 1 12); do
    mk_body "conventions/quillon/quillon-fact-$n.md" "Quillon Fact $n" \
      "The quillon drains the quillon buffer, so quillon batch $n leaves the quillon queue empty." \
      '<!-- learned: 2026-07-01 | confidence: high | source: manual | scale: subsystem | kind: fact | status: current -->'
  done

  # Three theories about one subsystem and one about another. All four match;
  # the theory section may deliver at most one per distinct subsystem.
  # Bodies run well past the snippet cap so a section budget exists at which a
  # snippet fits and a full block does not — the middle rung of the full ->
  # snippet -> backlink ladder is only reachable on entries this long.
  LONG_PROSE="It covers the path end to end, naming the components, the order they run in, and the reason the design settled where it did rather than on the alternatives considered and set aside. Each component is described by what it is responsible for, what it hands to the next one, and the failure it is positioned to prevent."
  THEORY_BODY="An account of what this area is and how its parts fit together, written to orient a reader arriving with no context at all. $LONG_PROSE $LONG_PROSE $LONG_PROSE"
  mk_body conventions/quillon/quillon-router-theory-a.md "Quillon Router Theory A" \
    "$THEORY_BODY" \
    '<!-- learned: 2026-07-02 | confidence: high | source: manual | scale: subsystem | kind: theory | subsystem: quillon-router | status: current -->'
  mk_body conventions/quillon/quillon-router-theory-b.md "Quillon Router Theory B" \
    "$THEORY_BODY" \
    '<!-- learned: 2026-07-03 | confidence: high | source: manual | scale: subsystem | kind: theory | subsystem: quillon-router | status: current -->'
  mk_body conventions/quillon/quillon-router-theory-c.md "Quillon Router Theory C" \
    "$THEORY_BODY" \
    '<!-- learned: 2026-07-04 | confidence: high | source: manual | scale: subsystem | kind: theory | subsystem: quillon-router | status: current -->'
  mk_body conventions/quillon/quillon-cache-theory.md "Quillon Cache Theory" \
    "$THEORY_BODY" \
    '<!-- learned: 2026-07-05 | confidence: high | source: manual | scale: subsystem | kind: theory | subsystem: quillon-cache | status: current -->'

  # One question per kind_status the registry allows. Only the open one is
  # deliverable; the other two stay findable by a kind-filtered search.
  QUESTION_BODY="A question left open by a reader of the quillon path, recorded with where it was already looked for so the next reader does not repeat that ground. $LONG_PROSE $LONG_PROSE"
  mk_body gotchas/quillon/quillon-question-open.md "Quillon Question Open" \
    "$QUESTION_BODY" \
    '<!-- learned: 2026-07-06 | confidence: medium | source: manual | scale: subsystem | kind: question | kind_status: open | where_looked: scripts/quillon.sh | status: current -->'
  mk_body gotchas/quillon/quillon-question-answered.md "Quillon Question Answered" \
    "$QUESTION_BODY" \
    '<!-- learned: 2026-07-07 | confidence: medium | source: manual | scale: subsystem | kind: question | kind_status: answered | answered_by: conventions/quillon/quillon-fact-01.md | status: current -->'
  mk_body gotchas/quillon/quillon-question-dissolved.md "Quillon Question Dissolved" \
    "$QUESTION_BODY" \
    '<!-- learned: 2026-07-08 | confidence: medium | source: manual | scale: subsystem | kind: question | kind_status: dissolved | status: current -->'

  # One hypothesis per kind_status. The refuted one is a kept negative result:
  # undelivered by the section, still returned by a direct kind-filtered search.
  HYPOTHESIS_BODY="A claim about the quillon path that has not been settled, phrased so a later reader can tell what evidence would settle it. $LONG_PROSE $LONG_PROSE"
  mk_body conventions/quillon/quillon-hypothesis-untested.md "Quillon Hypothesis Untested" \
    "$HYPOTHESIS_BODY" \
    '<!-- learned: 2026-07-09 | confidence: medium | source: manual | scale: subsystem | kind: hypothesis | kind_status: untested | status: current -->'
  mk_body conventions/quillon/quillon-hypothesis-supported.md "Quillon Hypothesis Supported" \
    "$HYPOTHESIS_BODY" \
    '<!-- learned: 2026-07-10 | confidence: medium | source: manual | scale: subsystem | kind: hypothesis | kind_status: supported | status: current -->'
  mk_body conventions/quillon/quillon-hypothesis-refuted.md "Quillon Hypothesis Refuted" \
    "$HYPOTHESIS_BODY" \
    '<!-- learned: 2026-07-11 | confidence: medium | source: manual | scale: subsystem | kind: hypothesis | kind_status: refuted | status: current -->'
fi

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
