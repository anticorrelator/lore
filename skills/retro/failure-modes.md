# Retro Failure Mode Reference

Specific failure patterns discovered across retros. Consult when scoring reveals anomalies.

## A. Backlink Resolution Failures

Affects: Dimension 1 (Delivery), Dimension 3 (Gaps)

**Stale backlinks:** Entry moved/renamed by `/renormalize`; slug was valid at plan time. >30% unresolved caps D1 at 2.

**Phantom backlinks:** Plan cited entries that never existed — coverage gap, not infra failure. Affects D3 > D1. Collect phantom slugs as capture candidates. *Severity modulation:* if annotation text is present after the `—` separator, score D1 as annotation-only (not phantom failure); if bare `[[backlink]]` with no annotation, treat as normal phantom. D3: still flag as capture candidate regardless of annotation.

**Misrouted citation (phantom sub-type):** Content exists under a different path than cited. Spec lead guessed the path rather than searching. D1 same as phantom; D3 lower-severity (content exists). Detection: `lore search <slug-fragments>` finds match elsewhere.

**Detection (all backlink types):** Search slug fragments across categories. Different path = stale. No match = phantom. Different category/slug = misrouted.

**Pipeline delivery failure:** Plan has backlinks but task generation drops them silently. Caps D1 at 2.

**Partial resolution:** Some tasks get `## Prior Knowledge`, others don't despite phase-level backlinks. Caps D1 at 3.

**Plan-level context block omission:** `/spec` produces plan with zero `**Knowledge context:**` blocks across all phases — tasks.json has nothing to resolve regardless of store coverage. Upstream of all other backlink failures. Detection: all tasks show "No backlinks found in plan." Caps D1 at 3 (lead prefetch can compensate). Distinct from cold-start (store has entries; plan didn't reference them). When detected, skip backlink/annotation audits and instead check if entries existed via `lore search` on phase objectives.

**Delivery mode mismatch:** Plan specifies `**Knowledge delivery:** full` but tasks.json produces annotation-only with truncated content. Silent pipeline failure. Caps D1 at 3.

**Annotation-only delivery:** `## Prior Knowledge` contains annotations rather than full content. Scoring tiers:
- **D1 = 5**: Full entry prose inlined.
- **D1 = 4**: Annotation-only AND workers demonstrably applied principles correctly.
- **D1 = 3**: Application partial/unverifiable, OR completeness <80%. Default for ambiguous evidence.
- **D1 = 2**: Workers misapplied/diverged, OR no pull fallback (template gap + no resolution instruction).

*Behavioral vs filing-facing:* Behavioral annotations give directives ("do not call X inside Y"). Filing-facing describe the entry ("understand why X was added"). Filing-facing prevents D1=4 when mixed with behavioral phases.

**Compound failures:** When multiple modes co-occur, lowest cap applies. Do not average.

**Cross-cutting backlink redundancy:** All phases share identical backlinks. Does NOT cap D1, but note as spec authoring signal. Exceptions: (1) same backlink with differentiated per-phase annotation text is good authoring; (2) single-file prose rewrite cycles where redundancy is expected.

**Context backlink contamination:** `_work/` references in `**Knowledge context:**` instead of `## Related`. Subtract from annotation completeness denominator.

**Related-section injection:** Task generator injects `## Related` backlinks as bare entries into every task's `## Prior Knowledge`. Expected behavior, not authoring error. Subtract from annotation completeness denominator — use only per-phase `**Knowledge context:**` entries as denominator.

## B. Lead Bypass

Affects: Dimension 1 (Delivery), Dimension 5 (Spec Utility)

**Full bypass** (D1 ≤ 2): TaskCreate descriptions omit `## Prior Knowledge`. Workers start from scratch.

**Pointer bypass** (D1 ≤ 3): Lead references knowledge but doesn't embed content. Push → pull conversion.

**Justified bypass:** Lead writes code-level instructions more actionable than knowledge entries. *Lead-paraphrase* (D1: 3): guidance traceable to entries + code specifics. *Full bypass* (D1 ≤ 2): only code-level instructions. When recurring, knowledge ROI is at spec time, not implementation time.

**Template gap:** `worker.md` absent — ad-hoc prompts, inconsistent reporting. Compounds with annotation-only: removes pull fallback (`lore resolve`), downgrade D1 by 1. Compounds with lead-paraphrase: impossible to evaluate knowledge system independently. *Efficacy signal:* template gap + lead-paraphrase + zero rework across retros = lead-paraphrase sufficient for well-specified work; pipeline value is reporting consistency, not implementation quality.

**Worker over-delivery:** Two coordination patterns producing phantom completion reports:
- *Concurrent task overlap:* Multiple workers edit same file; fast worker finishes first, others report "already done." Coordination artifact, not knowledge failure.
- *Worker scope creep:* Worker implements beyond assigned task scope (completing tasks 2-3 while assigned task 1), crossing task boundaries. Subsequent workers find work done.
Neither caps any dimension. Note when >2 workers report phantom completion.

**Advisor delivery failure:** Advisor spawned but responses arrive after workers finish (idle/wake timing — no intra-turn blocking). Resolution: pre-consultation by lead before workers start. D1 dinged by 1; D5 dinged by 1 for unguided decisions.

**Template/hook field name mismatch:** Template field names don't match hook validation. Causes completion loops. D1 dinged by 1. **Fixed 2026-03-21.**

**Evidence availability:** TaskCreate descriptions are ephemeral. Lead-bypass fully verifiable only in same-session retros. Cross-session: infer from worker observations, notes.md, absence of knowledge-traceable guidance. Cap D1 at 3 without direct evidence.

**Batch execution-log placeholder degradation:** Lead bulk-logs with placeholder text instead of verbatim observations. Reduces evidence quality. Does not cap dimensions.

## C0. Implementation Phase Cold-Start

Affects: Dimension 1, Dimension 3

Phase targets file/subsystem with no knowledge entries. NOT a delivery failure. Score D1 on what was available; D3 on whether discoveries were captured (captured = D3 4, uncaptured = D3 ≤ 3). When mixed with context-rich phases, cross-cutting redundancy is expected. Mitigation: add "unmapped territory — report structural role and constraints" to cold-start phase task descriptions.

## C. Cold-Start and Prefetch Failures

Affects: Dimension 1, Dimension 3

**Cold-start:** No knowledge exists for domain. Researcher prompt should note "No prior knowledge — report patterns for capture." >50% cold-start caps D1 at 3; >75% caps at 2.

**Prefetch silent failure:** Exits 0, returns empty. Caps D1 at 3 unless tasks.json confirms delivery via other means.

**Prefetch query recall failure:** Entries exist but multi-word query misses FTS5 terms. Worse than cold-start — lead should try decomposed queries. Caps D1 at 2 when treated as cold-start without fallback. At implementation time with tasks.json annotations intact, do not cap D1.

**Explore agent shell fallback gap:** Explore agents lack Bash, can't execute `lore search` fallback. Caps D1 at 2. Lead must pre-resolve before dispatching Explore agents.

## C2. Spec Investigation Factual Errors

Affects: Dimension 3, Dimension 4

Investigators produce errors that propagate through plan → tasks → workers. Common patterns: lifecycle misclassification, duplication overestimates, caller count errors, greenfield API name errors, mutation return type errors.

**Scoring:** Single error caught by evaluation: D4 ≥ 3. Error causing rework: D4 ≤ 2. Multiple errors: D4 ≤ 1. Compiler-caught API errors (zero rework): no D4 cap, treat as D3 minor gap.

**Platform-behavior assertions:** Assertions from docs/observed behavior rather than source. Lower confidence — note as reduced-confidence evidence.

## C3. Spec-Investigation-to-Store Gap

Affects: Dimension 3

Insight documented in plan `## Investigations` but never promoted to knowledge store. Workers rediscover via file reads. Scoring: workers applied from investigation = D3 ≤ 4; rediscovered = D3 = 3; hit bugs = D3 ≤ 2. Expected capture rate is 0% unless `/remember` explicitly invoked after `/spec`.

## C4. Post-Spec Capture Without Plan Backfill

Affects: Dimension 1

Entry captured during `/spec` but never added to `**Knowledge context:**` blocks. May reach workers via prefetch but not structured delivery. Prevents D1 = 5 when directly relevant.

## D. Spec Utility Modifiers

Affects: Dimension 5 interpretation — does not cap scores.

**Prototype-cascade:** Knowledge value concentrates on first task in batched similar tasks. Score on full batch including prototype.

**Same-knowledge saturation:** All phases reference same entries. Value front-loaded to first worker.

**Meta/self-referential work:** Implementation IS knowledge work. D5 = 1-2 expected; domain-native workers don't need orientation. With intent-tasks: D5 = 2-3. With prescriptive-tasks: D5 = 1-2 (harder ceiling).

**Intent-vs-prescriptive calibration:** Intent tasks delegate choices — out-of-scope reads for discovery are by-design. Zero escalations + zero divergences = D5 4-5 even with reads outside `**Files:**`.

**Novel domain discount:** No store entries for phase domain. D5 ceiling = 3. Score on non-novel phases.

**Annotation-only + intent-tasks compound:** Workers received framing but no resolved content for design choices. D5 ≤ 3; attribute to delivery mode, not spec quality.

**Removal/deletion ceiling:** >60% deletion phases → D5 ≤ 2. Knowledge ROI on non-deletion phases only. Compounds with zero-delivery when spec omits context blocks for "simple" work — D1 ≤ 2. With `--yes`: auto-approval masks gap detection for embedded replacement phases.

**Failure-recovery amplification:** Work follows failed attempt with post-mortem in store. Value is mistake prevention at spec time, even though implementation D5 is low.

**Micro-fix ceiling:** Single-file fix, no workers, <50 lines. D5 ceiling = 2. ROI is creation (captures), not consumption.

**Sequential same-file phantom work:** Fast worker implements beyond scope on shared file. Later workers report "no changes needed." Over-serialization signal, not knowledge failure.

**Go same-package split constraint:** Go compiler rejects duplicate declarations in same package. Phased removal fails — all removals forced into single pass. Specs should consolidate removal tasks.

**Spec code reference error:** Spec cites code artifact by wrong name (e.g., BASIC_PLAN vs actual MINIMAL_PLAN). Worker must investigate — escalation-equivalent. Mitigation: `/spec` synthesis should grep cited artifacts.

**Task generator parsing bugs:** Three variants: (1) *file_targets from expressions* — code expressions (`X ?? Y`) or Go field access (`msg.Err`) parsed as file targets; (2) *backlink-syntax contamination* — literal `[[knowledge:...]]` in docs examples parsed as real backlinks; (3) *empty phases from bullet lists* — plain bullets vs checkbox syntax produces `"phases": []`, bypassing delivery pipeline (caps D1 at 3). Subtract parser artifacts from annotation completeness denominators.

**Investigation-originated plan without knowledge context:** Investigation findings embedded in prose without `**Knowledge context:**` backlinks. Task generator has nothing to resolve. D1 ≤ 2; D4 = 3.

**Execution-log quality issues:** (1) *Underreporting* — fraction of completions logged; (2) *Discoveries condensation* — bulk-logged one-liners instead of verbatim worker text; (3) *Batch-timestamp collapse* — multiple tasks at same timestamp, losing sequence. None cap dimensions; all degrade cross-session evidence.
