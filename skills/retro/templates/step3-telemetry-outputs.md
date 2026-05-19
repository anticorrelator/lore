# Step 3.0e / 3.5 / 3.9 output templates

Read this file when emitting any of the Step 3.0e delta surface, Step 3.5
memory-system telemetry blocks, or Step 3.9 non-compensatory scorecard
headline. The blocks below are pure output shapes — gates, thresholds, and
classification rules live inline in SKILL.md and are consulted there at
decision time.

## Step 3.0f — scorecard_deltas journal-persistence JSON

The delta surface is persisted to the retro journal entry (Step 4) under a `scorecard_deltas` field keyed by tier:

```json
{
  "scorecard_deltas": {
    "template": {
      "<template_id>@<version>": {
        "factual_precision": {"prev": 0.72, "curr": 0.81, "delta": 0.09, "n_curr": 24, "surfaced": true},
        "contradiction_verification_rate": {"prev": 0.08, "curr": 0.17, "delta": 0.09, "n_curr": 12, "surfaced": true},
        ...
      }
    },
    "correction": { ... },
    "reusable": { ... },
    "task-evidence": { ... }
  }
}
```

`surfaced: true` iff the delta passed all three filters (Step 3.0d).

## Step 3.0e — Delta surface report shape (per tier)

The delta surface is the first block of the Step 6 report output:

```
[retro] Scorecard deltas — primary surface

  Window: <current-window-id>  vs  <previous-window-id>

  --- tier: template ---
  Eligible templates with deltas: <N> surfaced, <M> suppressed

  <template_id>@<version-prefix-12>:
    factual_precision:             0.72 → 0.81  (↑ +0.09, n=24)     [delta-pass → regressing]
    curated_rate:                  0.48 → 0.41  (↓ -0.07, n=18)     [regressing]
    omission_rate:                 0.22 → 0.14  (↓ -0.08, n=32)     [inverted: ↓ is improving]
    contradiction_verification_rate: 0.08 → 0.17 (↑ +0.09, n=12)     [inverted: ↑ is regressing]
    (other metrics: unchanged or below threshold)

  Suppressed: 12 (7 below-sample, 3 unregistered, 2 below-magnitude)

  --- tier: correction ---
  <template_id>@<version-prefix-12>:
    factual_precision (correction): 0.82 → 0.88  (↑ +0.06, n=11)     [improving]

  --- tier: reusable ---
  (informational — no deltas meet the 3-filter gate)

  --- tier: task-evidence ---
  (informational — no deltas meet the 3-filter gate)
```

## Step 3.5 — Memory-system telemetry per-metric output blocks

### retention_after_renormalize

```
retention_after_renormalize:
  median cycles_survived: <N>  |  entries with ≥3 cycles: <K>/<total>
  top survivors:
    <entry_id>  cycles=<N>  producer=<template_id>
    <entry_id>  cycles=<N>  producer=<template_id>
    <entry_id>  cycles=<N>  producer=<template_id>
```

### downstream_adoption_rate

```
downstream_adoption_rate:
  mean rate: <val>  |  entries >50%: <K>/<total>
  top adopters:
    <entry_id>  rate=<val>  status=<status>
    <entry_id>  rate=<val>  status=<status>
    <entry_id>  rate=<val>  status=<status>
```

### route_precision

```
route_precision:
  <role>: <accepted>/<total> routes accepted (<pct>%)
  <role>: <accepted>/<total> routes accepted (<pct>%)
  <role>: <accepted>/<total> routes accepted (<pct>%)
```

### supersession_quality

```
supersession_quality:
  improved: <K>/<total> (<pct>%)  |  neutral: <N>  |  regressed: <M>
  notable (non-improved):
    <superseded_entry_id> → <successor_entry_id>  quality=<neutral|regressed>
    ...
```

### scale_drift_rate

```
scale_drift_rate:
  <producer_role>: drift=<val>  [ABOVE-THRESHOLD]
  <producer_role>: drift=<val>
  <producer_role>: drift=<val>
```

### scale signals (sidecar)

```
scale signals (Step 2.9):
  declaration_coverage:     <N>/<total> (<PCT>)
  redeclare_rate:           <N>/<total> (<PCT>)
  off_scale_routes_emitted: <N>
  verifier_disagreements:   <N>
  off_altitude_skipped:     <N>  [agent self-report]
  counterfactual_better:    <better|same|worse>  — <one-line rationale>
  abstraction:              <right-sized|too-coarse|too-fine>  — <one-line rationale>

  Better-than-no-scale derivations:
    off_scale_routes_emitted > 0:                yes|no
    counterfactual_better dominantly same/worse: yes|no
    redeclare_rate stable/decreasing:            yes|no
```

### channel-contract flags (sidecar)

```
channel-contract flags:
  <role>/<slot>  signal=<signal_type>  rate=<pct>  over <N> cycles
    remedy: <remedy_hint or "see Step 2b.6 guidance">
```

## Step 3.9 — Scorecard headline per template-version

```
[retro] Scorecard headline — per template-version (non-compensatory, tier:template only)

  <template_id>@<version-prefix-12>        HEADLINE=<pass|weak|fail>
    factual_precision:            <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    curated_rate:                 <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    triviality_rate:              <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    omission_rate:                <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    observation_promotion_rate:   <val>    [<pass|weak|fail|insufficient:<N>>]  n=<N>
    worst: <metric-that-set-headline>
    unregistered/pre-calibration/degraded-window/wrong-tier rows excluded: <count>
```

One block per distinct registered `template_version` with tier:template rows in the window. If the filter produces zero eligible rows for every template, render `[retro] Scorecard headline: no eligible rows (all-filtered)` — adjacent to `pipeline-degraded`.

If the `tier: template` row count is below the 10-sample floor on every metric:

```
[retro] Scorecard headline: warmup — awaiting-template-tier-rows
  tier:template rows in window: <N> (below n≥10 minimum for all metrics)
  /evolve runs proceed; individual metrics show insufficient:<N> until sample accumulates.
```
