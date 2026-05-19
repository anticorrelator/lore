# Step 6 — Report templates

Read this file when emitting the Step 6 retro report. Two output shapes branch
on `window_state` from Step 3.8.

## Pipeline-degraded variant

When `window_state == "pipeline-degraded"`:

```
[retro] <slug> — PIPELINE-DEGRADED
  Tripped: <check-name-1>, <check-name-2>, ...
  <per-tripped-check block from Step 3.8's tripped-output templates>

  Dimension scores (recorded but non-headline):
    Delivery: X/5 | Quality: X/5 | Gaps: X/5 | Alignment: X/5 | Spec Utility: X/5

  /evolve will refuse to cite this window's scorecard cells. Fix the
  tripped pipeline stage(s), then re-run /retro on the next window.
  Evolution suggestions logged: N (will NOT be applied from this window)
```

## Normal-window variant

When `window_state != "pipeline-degraded"` — scorecard-first shape: delta
surface + headline first, dimension scores relegated to narrative coda.

```
[retro] <slug>
  # Primary: scorecard deltas (Step 3.0), partitioned by tier
  Scorecard deltas — window <current-window-id> vs <previous-window-id>
    --- tier: template ---
    <template_id>@<version-prefix-12>:
      <metric>: <prev> → <curr>  (<direction> <signed delta>, n=<N>)  [<classification change>]
      ...
    Suppressed: <N> (below-sample / below-magnitude / unregistered)
    --- tier: correction ---
    <template_id>@<version-prefix-12>:
      <metric>: <prev> → <curr>  ...
    --- tier: reusable ---       (informational)
    --- tier: task-evidence ---  (informational)

  # Headline: non-compensatory pass|weak|fail per template-version (Step 3.9, tier:template only)
  Scorecard headline (non-compensatory, worst-dimension-wins, tier:template):
    <template_id>@<version-prefix-12>  HEADLINE=<pass|weak|fail>
      worst metric: <metric>
    <template_id-2>@<version-prefix-12>  HEADLINE=<pass|weak|fail>
      worst metric: <metric>

  # Narrative coda: dimension scores (Step 3)
  Narrative coda (dimension scores, not headline):
    Delivery: X/5 | Quality: X/5 | Gaps: X/5 | Alignment: X/5 | Spec Utility: X/5
    Key finding: <one sentence on the knowledge-system behavior this cycle>
    Disagreement with scorecard headline? <none | brief note>

  ## Memory System Telemetry (Step 3.5 — observability only, does not feed /evolve)
  retention_after_renormalize:
    median cycles_survived: <N>  |  entries with ≥3 cycles: <K>/<total>
    top survivors: <entry_id> cycles=<N> | ...
  downstream_adoption_rate:
    mean rate: <val>  |  entries >50%: <K>/<total>
    top adopters: <entry_id> rate=<val> status=<status> | ...
  route_precision:
    <role>: <accepted>/<total> (<pct>%)  |  ...
  supersession_quality:
    improved: <K>/<total>  |  neutral: <N>  |  regressed: <M>
    notable (non-improved): ...  (or "all improved")
  scale_drift_rate: <role>: drift=<val> [ABOVE-THRESHOLD if >0.20]  |  ...
  scale signals (Step 2.9):
    declaration_coverage: <N>/<total> (<PCT>)
    redeclare_rate: <N>/<total> (<PCT>)
    off_scale_routes_emitted: <N>
    verifier_disagreements: <N>
    off_altitude_skipped: <N>  [agent self-report]
    counterfactual_better: <better|same|worse>  — <one-line rationale>
    abstraction: <right-sized|too-coarse|too-fine>  — <one-line rationale>
    better-than-no-scale: routes>0=<yes|no> | counterfactual=<yes|no> | redeclare=<yes|no>
  channel-contract flags: <none | one line per flag>

  # Channel-contract flags (Step 2b.6) — omit when no flags fired
  Channel-contract drift detected:
    <role>/<slot>  signal=<signal_type>  rate=<pct> over <N> cycles
      Remedy: <one-line targeting workflow contract, not individual producers>

  # Behavioral-health coda (Step 3.7)
  <4 selected checks + answers — 1-3 sentences each>

  Evolution suggestions logged: N (run /evolve to apply)
```
