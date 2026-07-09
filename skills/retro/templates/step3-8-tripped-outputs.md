# Step 3.8 — Tripped-check output templates

Read this file when a Step 3.8 health check trips and the report needs its
tripped-output block. Each block below corresponds to one check. The
healthy-case silence invariant still applies — these blocks emit ONLY when
the named check has tripped.

## Audit coverage

```
[retro] pipeline-degraded: audit coverage
  lag: median <days> (threshold 7 days)
  routing_realization: <ratio> (threshold 0.50 @ n≥10, or ≥3 completed runs @ n<10)
    enqueued_old_enough=<N>  runs_completed=<M>
  see: $KDIR/_settlement/queue.json and $KDIR/_settlement/runs/*.json
```

If only one sub-check tripped, omit the healthy sub-check's detail line.

## Trigger realization rate

One block per tripped ceremony:

```
[retro] pipeline-degraded: trigger realization rate
  source=<type> observed=<rate> configured=<p> (band ±50%, min 10 samples)
  rolls=<total> fires=<fires> divergence=<pct>
  see: future trigger-roll telemetry and probabilistic-audit config
```

## Grounding failure rate

```
[retro] pipeline-degraded: grounding failure rate
  aggregate=<pct> (threshold 30%, N=<total>)
  per_reason: file-missing=<pct>  line-out-of-range=<pct>
              snippet-mismatch=<pct>  field-missing=<pct>
  dominant=<reason> (concentration=<pct>, threshold 50%)
  see: $KDIR/_work/<slug>/audit-attempts.jsonl (per-work-item breakdown)
```

## Candidate-queue backlog

One block per tripped kind plus a cluster-aggregate line when the aggregate trips:

```
[retro] pipeline-degraded: candidate-queue backlog
  kind=<K> added=<N> resolved=<M> growth_ratio=<ratio> (threshold 2.0, min N=10)
                  pending=<K> (threshold 25 per-kind)
  cluster pending_total=<K> (threshold 50, summed across kinds)
  see: $KDIR/_settlement/queue.json
```

## Judge liveness

One block per tripped gate × signature combination:

```
[retro] pipeline-degraded: judge liveness (<signature>)
  gate=<gate-name> <metric>=<value> (threshold <pct>)
  sample=<N> window=<start>..<end>
  see: $KDIR/_settlement/runs/*.json (and $KDIR/_settlement/queue.json for zero-rows case)
```

<!-- "Calibration state surface" tripped-block removed: that check is demoted to a silent per-row
     filter and no longer sets pipeline-degraded. See skills/retro/SKILL.md § Check: Calibration
     state surface. pre-calibration (soft-cal steady state) is not a degradation. -->

## Consumer-contradiction routing

```
[retro] pipeline-degraded: consumer-contradiction routing
  produced=<N>  verdicts_landed=<M>  realization=<pct> (threshold 10% at N≥10)
  see: $KDIR/_work/*/consumption-contradictions.jsonl and rows.jsonl
```
