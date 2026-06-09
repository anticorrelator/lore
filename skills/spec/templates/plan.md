# Plan.md Template

Read this template when emitting `plan.md` in Step 5b. The fenced block below is the canonical plan structure the synthesizer copies (HTML comments inline are load-bearing enforcement — keep them with the section they govern).

```markdown Plan.md Template
# <Work Item Title>

## Goal
<!-- One paragraph: what we're building/changing and why -->

## Narrative
<!-- 1-2 paragraphs synthesizing the goal and key design choices into a readable story.
     Written for a reader who wants the "what, why, and how it fits together" without reading all sections.
     Draw from Goal (the what/why) and Design Decisions (trade-offs chosen).
     Omit file paths and task lists — those belong in Phases. -->

## Intent Anchor
<!-- Conditional — emit this section only when the work item's `_meta.json.intent_anchor` is present.
     For legacy or no-anchor work items, omit the section entirely; the Step 5.5 verifier skips with a stderr info message.

     Three fields, in this order:
       1. The anchor body verbatim from `_meta.json.intent_anchor` (no quoting, no prefix label — just the raw text).
       2. `**Scope delta:**` line — default "none — anchor preserved unchanged"; if the spec narrows the capability, name the narrowing here.
       3. `**Tempting narrower implementation:**` heading — the spec author names the tempting narrower implementation that
          would appear successful while violating the anchor.

     Verifier-enforced fields (load-bearing for Step 5.5 gate): anchor body and `**Scope delta:**` line.
     Template-only field (not verifier-enforced): `**Tempting narrower implementation:**` body. -->
<anchor body verbatim from `_meta.json.intent_anchor`>

**Scope delta:** none — anchor preserved unchanged

**Tempting narrower implementation:** <name the tempting narrower implementation that would appear successful while violating the anchor>

## Strategy
<!-- Optional. Written verbatim from user input at the strategy gate (Step 4).
     Omit this section entirely if the user skips the strategy prompt — absence is the default.
     On continuation runs, this section is read silently and used to shape synthesis.

     Format: free-form text block written as a worker-facing directive.
     Write the user's input as-is — do not summarize, annotate, or interpret.
     If the user provides a list, preserve it as a list. If prose, preserve as prose.

     This content is injected into worker task descriptions alongside design decisions.
     Write it so a worker reading it for the first time understands what to do. -->

## Context
<!-- SHORT BRANCH ONLY: 3-6 bullets summarizing key files, constraints, and patterns found -->
<!-- FULL BRANCH: delete this section and use ## Investigations instead -->

## Investigations
<!-- FULL BRANCH ONLY: findings from team-based exploration -->
<!-- SHORT BRANCH: delete this section and use ## Context instead -->

### <Topic 1>
**Question:** <what was investigated>
**Findings:**
- Finding 1
- Finding 2
**Key files:** `path/to/file.ts`, `path/to/other.ts`
**Implications:** How this affects the design
**Observations:**
- <mechanism-level pattern, design rationale, or structural footprint signal, preserved verbatim from researcher report>

<!-- Note: researcher assertions are emitted to task-claims.jsonl (Tier 2)
     via evidence-append.sh — they do not appear in plan.md. See architecture/artifacts/tier2-evidence-schema.md. -->

## Design Decisions

### D1: <Decision Title>
**Decision:** What was decided — a concrete, actionable statement
**Rationale:** Why this choice over others — the reasoning, constraints, or evidence that led here
**Alternatives considered:** What other approaches were evaluated and why they were rejected
**Applies to:** Phase N (<name>), Phase M (<name>) — which phases/tasks this decision affects

## Architecture Diagram
<!-- Optional — include when the work involves multi-component systems, novel data flows, or module boundaries
     that are not self-evident from the phase list. Omit for single-file or straightforward additive changes.
     Format: plain-text ASCII art inside a fenced code block. Use box-drawing characters (─ │ ┌ ┐ └ ┘ ├ ┤),
     arrows (──►, ──┐, ◄──). Do NOT use Mermaid or other diagram DSLs.
     Label components with actual file/module names. -->

## Phases
<!-- One phase per plan by default. Add a second phase only when all three Plan-as-unit conditions
     hold (Step 5b): cross-phase parallelism, independent deliverable boundary, architectural
     checkpoint. File-overlap-forced sequencing is not a checkpoint — merge into one phase. -->

### Phase 1: <Name>
**Objective:** What this phase accomplishes
**Files:** relevant file paths
**Scope:**
<!-- Optional — list files/components workers must NOT modify and any output contracts. -->
- Do not modify: `path/to/file`
- Output contract: <what the phase must produce without changing>
**Task format:** prescriptive  <!-- optional — omit for default intent+constraints format -->
**Knowledge delivery:** full  <!-- optional — omit for default annotation-only delivery -->
**Retrieval directive:**
<!-- Optional — omit when phase has no Knowledge context backlinks and no Files entries.
     Seeds are derived from (a) [[knowledge:...]] backlinks in Knowledge context, and
     (b) file paths in Files. Deduplication applied. hop_budget defaults to 1.
     scale_set: REQUIRED — declare the appropriate bucket (abstract | architecture | subsystem | implementation); multi-label form (e.g., architecture,subsystem) is allowed for adjacent pairs. Omitting is an error.
     Consumed by /implement Step 3.1 branch (a) via resolve-manifest.sh → {{prior_knowledge}}. -->
- seeds: [[knowledge:file#heading]], path/to/file.py
- hop_budget: 1
<!-- scale_set: REQUIRED — declare one bucket: abstract | architecture | subsystem | implementation (multi-label form architecture,subsystem etc. allowed for adjacent pairs) -->
<!-- - filters: type=knowledge, exclude_category=... (optional; omit when not filtering) -->
**Knowledge context:**
<!-- Each entry MUST include a "— why relevant" annotation after the backlink.
     Annotations are implementation-facing: tell the worker what to DO with the entry.
     GOOD: "— understand the call graph before modifying resolve_backlinks()"
     BAD:  "— provides context for this phase" -->
- [[knowledge:file#heading]] — why this is relevant to this phase
**Advisors:**
<!-- Optional — declare domain-expert advisors. By default (no `mode: persistent` suffix), advisor declarations are
     lead-handled inline on the default `/implement` route: the lead replies to worker consultations using its own
     investigation/plan/code-read tools (and may invoke a skill via the `Skill` tool if the domain is skill-backed) and
     does NOT spawn a separate advisor agent.

     Append `mode: persistent` to opt into the agent route — `/implement` then spawns a persistent advisor agent for the
     domain, concatenates `scripts/agent-protocols/advisory-consultation.md` onto worker prompts, and emits advisor
     scorecard rows on shutdown. Reserve `mode: persistent` for cases where calibration-attribution or parallel-
     consultation throughput earns the ceremony cost. -->
- advisor-name — domain scope. [must-consult|on-demand]
- advisor-name — domain scope. [must-consult|on-demand] mode: persistent  <!-- opt into agent route; omit suffix for default lead-handled -->
**Consultations required:**
<!-- Optional — phase-level declaration listing consultation domains a worker on this phase MUST request before
     starting implementation. Replaces the structural meaning of today's `must-consult` mode on a phase-declared
     advisor: the worker sends a `## Consultation` request (with `consultation-id`, `domain`, `reason`, `question`,
     and task/phase context), ends its turn without implementation work, and resumes when the answering side
     (lead by default, persistent advisor on the opt-in route) replies on the next turn boundary.

     `/implement` lifts this block into `phase_context` (via `lore work phase-context <slug> <phase-number>`) and
     tracks per-worker which required consultations are outstanding. A worker report `**Consultations:**` entry that
     references a required domain without a matching acknowledged lead-side reply is rejected during worker-progress
     collection (the gate's teeth replace the legacy `[must-consult]` structural gate).

     Absence = no consultations required for this phase. -->
- <domain-label>  <!-- e.g. auth-middleware, serialization, security-review -->
- <domain-label>
**Verification:**
<!-- 0–3 observable-behavior criteria. Lives at phase level only — never duplicated into per-task descriptions.
     The phase worker(s) are implicitly held to these objectives; "Verify X" is never its own task.
     Each bullet names a behavior of the changed system a worker can check without reading the diff.
     Anti-patterns — never use:
       "X no longer exists" — recoverable from ls/diff, not a behavior
       grep-for-absence-as-audit — acceptable only when prose is the contract being verified
       task restatement — "refactored Y" is the task, not a verification criterion
     Good example: "`lore prefetch` with no `--scale-set` exits non-zero with a usable error" -->
- <observable behavior — e.g., "`lore search foo` returns ranked results from the updated index">
**Tasks:**
<!-- One - [ ] checkbox per phase by default. Multiple only when the four conditions in Step 5b hold:
     disjoint file ownership, independently reviewable deliverables, real parallel execution, no residue.
     Valid primary verbs: Implement / Refactor / Author / Migrate / Add support for / Wire.
     Banned as primary verb: Verify / Check / Inspect / Run / Capture / Append / Cross-link / Note / Document-only.
     See Step 5b "Deliverable contract gate" for routing of invalid units.

     Weave binding norms into the constraint clause (Step 5b "Deliverable contract gate"): when a surfaced
     preference/convention is BOTH scope-overlapping AND judgment-class, render it as an imperative constraint
     clause in the task line naming the norm by its stable label (the entry slug/title the backlink resolves to),
     and keep the [[knowledge:...]] backlink for provenance. Strict weave — mechanical/lint-class norms are never
     woven (they route to the enforcement-class hook arm); only the binding judgment-class subset becomes a clause.
     The stable label is the identifier the /implement worker's `Convention handling:` report keys on. -->
- [ ] <Verb> <deliverable> in <owned file/surface> — <design or integration constraint>[; honor <stable-label> (<what to do>)] [[knowledge:conventions/<woven-norm-entry>]]

## Open Questions
- Unresolved decisions or items needing follow-up

## Related
<!-- Cross-cutting references that apply to the whole plan, not a specific phase. -->
- [[knowledge:file#heading]] — cross-references to knowledge store
```
