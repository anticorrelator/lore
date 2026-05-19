# Step 2.9 — Signal computation scripts

Read this file when computing the six per-cycle scale signals in Step 2.9.
Four scripts (factual signals 1–4) + two self-report prompts (eval signals
5–6). Run each script with `KDIR=$(lore resolve)` already set.

## Factual signal 1 — `declaration_coverage`

Fraction of retrieval opportunities in this cycle where `scale_declared=true` in `retrieval-log.jsonl`.

```bash
KDIR=$(lore resolve)
python3 -c "
import json, sys
rows = [json.loads(l) for l in open('$KDIR/_meta/retrieval-log.jsonl') if l.strip()]
total = len(rows)
declared = sum(1 for r in rows if r.get('scale_declared') is True)
print(f'declaration_coverage: {declared}/{total} ({declared/total:.0%})' if total else 'declaration_coverage: no retrieval events')
"
```

If `retrieval-log.jsonl` is absent: emit `declaration_coverage: no retrieval log this cycle`.

## Factual signal 2 — `redeclare_rate`

Fraction of session retrievals that re-issued at a different scale set from the previous call in the same session. Measures rubric ↔ agent reality drift — a climbing rate means agents are correcting scale mid-session, indicating the rubric isn't landing on first read.

```bash
python3 -c "
import json
rows = [json.loads(l) for l in open('$KDIR/_meta/retrieval-log.jsonl') if l.strip()]
session_rows = [r for r in rows if r.get('scale_declared') is True]
redeclares = sum(
    1 for i in range(1, len(session_rows))
    if session_rows[i].get('scale_set') != session_rows[i-1].get('scale_set')
       and session_rows[i].get('session_id') == session_rows[i-1].get('session_id')
)
total = max(len(session_rows) - 1, 0)
print(f'redeclare_rate: {redeclares}/{total} ({redeclares/total:.0%})' if total else 'redeclare_rate: insufficient data')
"
```

## Factual signal 3 — `off_scale_routes_emitted`

Count of worker-surfaced concerns routed off-scale this cycle. Read from `_work/<slug>/off_scale_routes.jsonl`.

```bash
SLUG="<current work item slug>"
ROUTES="$KDIR/_work/$SLUG/off_scale_routes.jsonl"
COUNT=0
[ -f "$ROUTES" ] && COUNT=$(wc -l < "$ROUTES" | tr -d ' ')
echo "off_scale_routes_emitted: $COUNT"
```

## Factual signal 4 — `verifier_disagreements`

Count of classifier disagreements from the most recent `/renormalize` run. Read from `$KDIR/_meta/classification-report.json`'s `disagreements` array (or from telemetry rows where `metric == "scale_drift_rate"`).

```bash
REPORT="$KDIR/_meta/classification-report.json"
if [ -f "$REPORT" ]; then
  python3 -c "import json; d=json.load(open('$REPORT')); print(f'verifier_disagreements: {len(d.get(\"disagreements\", []))}\')"
else
  # Fall back to telemetry rows
  python3 -c "
import json
rows = [json.loads(l) for l in open('$KDIR/_scorecards/rows.jsonl') if l.strip()]
drift_rows = [r for r in rows if r.get('metric') == 'scale_drift_rate']
total_disagreements = sum(int(r.get('disagreements', 0)) for r in drift_rows[-1:])
print(f'verifier_disagreements: {total_disagreements} (from scale_drift_rate telemetry)')
  " 2>/dev/null || echo 'verifier_disagreements: no data'
fi
```

## Eval signal 5 — `off_altitude_skipped` (agent self-report)

How many retrieved entries did you (the agent) judge as wrong-altitude and skip during this cycle?

> "During this cycle, did you receive any retrieved knowledge entries that were at the wrong altitude for your task and consciously skip them rather than read them in full? Estimate the count."

Record the count. Zero is a valid answer.

## Eval signal 6 — `counterfactual_better` (agent self-report)

Would retrieval without declared scale have produced better, the same, or worse results?

> "If you had retrieved without declaring a scale set — pulling from the full knowledge store without altitude filtering — do you think the results would have been: better (more relevant context delivered), same (no meaningful difference), or worse (more noise, less signal)?"

Grade: `better | same | worse`

One-line rationale.

## Emission

```bash
KDIR=$(lore resolve)
bash ~/.lore/scripts/retro-scale-access-append.sh \
  --cycle-id "<slug>" \
  --abstraction-grade "<right-sized|too-coarse|too-fine>" \
  --abstraction-rationale "<one-line citing retrieval calls>" \
  --counterfactual-better "<better|same|worse>" \
  --counterfactual-rationale "<one-line>"
```

The script writes to `$KDIR/_scorecards/retro-scale-access.jsonl` (schema_version: 2, created on first use). It validates grades against the closed enum before appending.
