# Plan.md Template

Read this template when writing `plan.md`: the design sections in `/spec` § 3, the tasks in § 4. The fenced block below is the canonical plan structure (HTML comments inline are load-bearing enforcement — keep them with the section they govern). Comments reach the plan author only; an obligation a worker must act on travels in a task line and its generated brief.

```markdown Plan.md Template
# <Work Item Title>

## Goal
<!-- One paragraph: what we're building/changing and why -->

## Narrative
<!-- 1-2 paragraphs synthesizing the goal and key design choices into a readable story.
     Written for a reader who wants the "what, why, and how it fits together" without reading all sections.
     Draw from Goal (the what/why) and Design Decisions (trade-offs chosen).
     Omit file paths and task lists — those belong in Tasks. -->

## Intent Anchor
<!-- Conditional — emit this section only when the work item's `_meta.json.intent_anchor` is present.
     For legacy or no-anchor work items, omit the section entirely; the finalize verifier skips with a stderr info message.

     Three fields, in this order:
       1. The anchor body verbatim from `_meta.json.intent_anchor` (no quoting, no prefix label — just the raw text).
       2. `**Scope delta:**` line — default "none — anchor preserved unchanged"; if the spec narrows the capability, name the narrowing here.
       3. `**Tempting narrower implementation:**` heading — the spec author names the tempting narrower implementation that
          would appear successful while violating the anchor.

     Fields 1 and 2 are written with the design (§ 3), because `lore plan revise` runs the anchor verifier on
     every publication and the design revision cannot be published without them; the tasks (§ 4) add field 3.
     Verifier-enforced fields (every publication and the finalize gate): anchor body and `**Scope delta:**` line.
     Template-only field (not verifier-enforced): `**Tempting narrower implementation:**` body. -->
<anchor body verbatim from `_meta.json.intent_anchor`>

**Scope delta:** none — anchor preserved unchanged

**Tempting narrower implementation:** <name the tempting narrower implementation that would appear successful while violating the anchor>

## Strategy
<!-- Optional. Written verbatim from the owner's answer at the first stop (§ 3).
     Omit this section entirely if the user skips the strategy prompt — absence is the default.
     On continuation runs, this section is read silently and used to shape synthesis.

     Format: free-form text block written as a worker-facing directive.
     Write the user's input as-is — do not summarize, annotate, or interpret.
     If the user provides a list, preserve it as a list. If prose, preserve as prose.

     This content is injected into worker task descriptions alongside design decisions.
     Write it so a worker reading it for the first time understands what to do. -->

## Context
<!-- Optional. 3-6 bullets summarizing key files, constraints, and patterns found. The findings
     themselves go under ## Investigations; omit this section when those entries carry everything. -->

## Investigations
<!-- One entry per question: the seat's own reading, and each commissioned investigator's landed
     report. Findings and Observations are recorded as they stood, not paraphrased. -->

### <Topic 1>
**Question:** <what was investigated>
**Findings:**
- Finding 1
- Finding 2
**Key files:** `path/to/file.ts`, `path/to/other.ts`
**Implications:** How this affects the design
**Observations:**
- <mechanism-level pattern, design rationale, or structural footprint signal, preserved verbatim from the investigator report>

<!-- Grounded assertions go to task-claims.jsonl (Tier 2) through evidence-append.sh, not into
     plan.md; scripts/validate-tier2.sh holds the required fields. -->

## Design Decisions

### D1: <Decision Title>
**Decision:** What was decided — a concrete, actionable statement
**Rationale:** Why this choice over others — cite the specific findings or assertions it rests on, keeping their provenance, rather than restating them in looser words
**Alternatives considered:** What other approaches were evaluated and why they were rejected
**Applies to:** Task N (<name>), Task M (<name>) — which tasks this decision affects

## Architecture Diagram
<!-- Optional — include when the work involves multi-component systems, novel data flows, or module boundaries
     that are not self-evident from the task list. Omit for single-file or straightforward additive changes.
     Format: plain-text ASCII art inside a fenced code block. Use box-drawing characters (─ │ ┌ ┐ └ ┘ ├ ┤),
     arrows (──►, ──┐, ◄──). Do NOT use Mermaid or other diagram DSLs.
     Label components with actual file/module names. -->

## Tasks
<!-- One `### Task N:` block per unit of work — the plan holds its tasks directly.
     Size each one by /spec § 4: one design center per task, and the sizing decision
     recorded below in whichever direction it went.

     The heading number is the task's id: `### Task 3:` is `task-3`. It stays fixed as
     earlier work is checked off, so `[depends-on: task-3]` keeps naming the same task.

     Task generation refuses the whole document, writing no output, when:
       - a `### Task N:` block carries any number of `- [ ]` lines other than exactly one
       - a backticked path on a task line is absent from that task's `**Files:**` block
       - a task declares no file target in either place
       - two headings share a number
       - the document mixes `### Task N:` headings with any other unit-heading form

     Every task carries the standing premise-wrong exit (§ 4): a worker report that
     the task cannot be built as scoped, naming what blocked it, is a sanctioned
     deliverable — never write a task whose only expressible outcome is success. -->

**Verification:**
<!-- 0–3 observable-behavior criteria, owned by the plan. This is the seat's acceptance bar
     at plan close — never duplicated into per-task descriptions, and never its own task.
     Task generation renders these bullets into every worker brief as plan-owned close
     criteria; a worker self-checks only the bullets its own diff can affect.
     Each bullet names a behavior of the changed system a reader can check without reading the diff.
     Anti-patterns — never use:
       "X no longer exists" — recoverable from ls/diff, not a behavior
       grep-for-absence-as-audit — acceptable only when prose is the contract being verified
       task restatement — "refactored Y" is the task, not a verification criterion
       suite-shaped bar — "all tests pass", "full suite green", "both dialects pass": suite-level
         certification happens once, at coordinator integration from the control checkout, against
         the composed tree. A bullet here names a behavior of THIS plan's changed surface,
         checkable in minutes against the worker's own tree.
     Good example: "`lore prefetch` with no `--scale-set` exits non-zero with a usable error" -->
- <observable behavior — e.g., "`lore search foo` returns ranked results from the updated index">

**Split rationale:**
<!-- REQUIRED when this plan carries more than one task; omit entirely for a one-task plan.
     One or two sentences naming what the split buys — parallel wall-time, separate acceptance
     boundaries, fresh context per worker, worker-tier separation, a scoped premise-wrong exit —
     set against what it costs in spawn ceremony, brief duplication, and integration risk.
     Finalize refuses a plan of more than one task that lacks this block. -->
<why this plan splits into N tasks — what the extra worker spawns buy, and against what cost>

**Merge rationale:**
<!-- REQUIRED when this plan carries exactly one task; omit entirely for a multi-task plan.
     One or two sentences naming the single design center the parts share — the one interface,
     mechanism, or subsystem whose shape one worker decides.
     Finalize refuses a one-task plan that lacks this block. -->
<why this deliverable is one task — the design center its parts share>

### Task 1: <Name>
**Deliverable:** What this task produces
**Files:** relevant file paths
<!-- Authoritative owned surface: the worker brief, work-item matching, and file-overlap
     chaining all read this block. Every backticked path on the task line must appear here. -->
**Scope:**
<!-- Optional — files/components workers must NOT modify, plus any output contract.
     `- Output contract:` is the producer's acceptance declaration: what this task fixes that
     later tasks may rely on. Its prose is for the worker and the seat; the scheduler never
     reads it. Ordering comes from the edge — each consuming task ends its line with
     `[depends-on: task-N]`. -->
- Do not modify: `path/to/file`
- Output contract: <what this task fixes and later tasks may rely on>
<!-- optional — executable close criteria for this task; omit the block when the task has none. `lore criteria run` executes the published criterion exactly as written, resolved from the immutable revision: argv is a literal argument list with no implicit shell (name one explicitly if the check needs it), cwd is worktree-relative and must resolve inside the execution root, and any change to argv, cwd, timeout, expected exit, or applicability produces a new criterion version. A check that spans several tasks belongs to a named integration task that owns it. Budget the timeout from a measured development run of the command, with margin. A passing result records only that this command exited as expected against a recorded code identity; whether the criterion is adequate for the task and whether the criteria together cover the original anchor remain the reviewer's judgment. Replace the example argv below with the check this task owns; the sample is an illustration, not a requirement to create scripts/test.sh -->
**Close criteria:**
```json
[
  {
    "id": "unit-tests",
    "intent": "The task's unit tests pass from the execution worktree.",
    "argv": ["bash", "scripts/test.sh"],
    "cwd": ".",
    "timeout": 600,
    "expected_exit": 0
  }
]
```
**Task format:** prescriptive  <!-- optional — omit for default intent+constraints format -->
**Knowledge delivery:** full  <!-- optional — omit for default annotation-only delivery -->
**Retrieval directive:**
<!-- Optional — omit when the task has no Knowledge context backlinks and no Files entries, and leave
     an HTML comment in its place saying there were no backlinks or files to derive seeds from.
     Place it after **Knowledge delivery:** (or after **Files:** when that is absent), before **Knowledge context:**.
     Derived from this task's own content only, never a neighbour's:
       - Exactly one `focal` topic: the task's own subject, default scale [subsystem, implementation], limit 8.
         Seeds are the task's owned **Files:** paths plus the title vocabulary of its Knowledge context entries —
         title words, because a raw `knowledge:` string tokenizes as one literal and misses the index.
       - Up to five `adjacent` topics: subsystems the task touches but does not own, typically
         [architecture, subsystem], limit 4, seeded from the titles of entries about that subsystem.
         Right scale with the wrong entries is the usual failure; re-derive from those entries' titles.
       - `activity_vocab` (optional, per topic): tokens looked up in `$KDIR/_meta/activity-vocab.yaml` by
         matching its path globs against the topic's files; never invented inline.
       - `scale_set` is required on every topic. A topic whose seeds come out empty is dropped.
     A v2 directive with zero or several focal topics is a parse error in generate-tasks.py. When no
     genuine focal topic exists, use the legacy flat form (seeds, hop_budget, scale_set as bullets).
     Consumed at dispatch: `lore impl open` resolves this directive through the shared packet builder
     into the task's knowledge packet, which the implement seat synthesizes before the worker reads it. -->
```yaml
retrieval_directive:
  version: 2
  topics:
    - role: focal
      topic: "<short label>"
      seeds:
        - "<title-vocabulary terms resolved from a Knowledge context backlink>"
        - "path/to/owned/file.py"
      scale_set: [subsystem, implementation]
      activity_vocab: [pytest, fixture]   # optional; from _meta/activity-vocab.yaml
      limit: 8
    - role: adjacent
      topic: "<adjacent subsystem label>"
      seeds:
        - "<title-vocabulary terms from an entry about the adjacent subsystem>"
      scale_set: [architecture, subsystem]
      limit: 4
  hop_budget: 1
```
**Knowledge context:**
<!-- Each entry MUST include a "— why relevant" annotation after the backlink.
     Annotations are implementation-facing: tell the worker what to DO with the entry.
     Carry only the entries this task's surface needs; the full surfaced set stays in the
     top-level **Related preferences/conventions:** manifest, and entries set aside for this
     task are listed with their reasons in the item's norm dispositions record.
     GOOD: "— understand the call graph before modifying resolve_backlinks()"
     BAD:  "— provides context for this task" -->
- [[knowledge:file#heading]] — why this is relevant to this task
**Advisors:**
<!-- Optional — declare domain-expert advisors. By default (no `mode: persistent` suffix), advisor declarations are
     seat-handled inline on the default `/implement` route: the implement seat replies to worker consultations using
     its own investigation/plan/code-read tools (and may invoke a skill via the `Skill` tool if the domain is
     skill-backed) and spawns no separate advisor.

     Append `mode: persistent` to opt into the compiled-designer route — `/implement` then prepares a designer in
     consultation mode for the domain, activates it on the first worker request with its own packet and bound
     attempt, and files each reply through the consultation ledger under the designer's compiled version. Compiled
     worker prompts carry no advisory mixin; the consultation channel is the `## Consultation` request below.
     Reserve `mode: persistent` for cases where calibration-attribution or parallel-consultation throughput earns
     the ceremony cost. -->
- advisor-name — domain scope. [must-consult|on-demand]
- advisor-name — domain scope. [must-consult|on-demand] mode: persistent  <!-- opt into the compiled-designer route; omit suffix for default seat-handled -->
**Consultations required:**
<!-- Optional — task-level declaration listing consultation domains this task's worker MUST request before
     starting implementation. Replaces the structural meaning of today's `must-consult` mode on a
     task-declared advisor: the worker sends a `## Consultation` request (with `consultation-id`, `domain`,
     `reason`, `question`, and its task id and subject), ends its turn without implementation work, and
     resumes when the answering side (seat by default, compiled designer on the opt-in route) replies on
     the next turn boundary.

     `/implement` composes this block into the task's own brief and tracks per-worker which required
     consultations are outstanding, keyed by task id. A worker report `**Consultations:**` entry that
     references a required domain without a matching acknowledged reply in the consultation ledger is
     rejected during worker-progress collection (the gate's teeth replace the legacy `[must-consult]`
     structural gate).

     Absence = no consultations required for this task. -->
- <domain-label>  <!-- e.g. auth-middleware, serialization, security-review -->
- <domain-label>

<!-- Exactly one `- [ ]` line per task block.
     Valid primary verbs: Implement / Refactor / Author / Migrate / Add support for / Wire.
     Banned as primary verb: Verify / Check / Inspect / Run / Capture / Append / Cross-link / Note / Document-only.
     /spec § 4 says where checks, captures and single edits go instead.

     Every task line ends with a trailing [class: mechanical | standard | judgment-dense] marker
     (after any [[knowledge:...]] backlinks) declaring the worker tier /implement routes it to.
     Finalize refuses any unannotated task line.

     Append `[depends-on: task-N, task-M]` to declare an ordering no shared file expresses; the ids
     are heading numbers, and the marker seeds `blockedBy` before file-overlap chaining adds to it.
     Tasks that share a file are chained automatically — no marker needed for those.

     Weave the binding subset defined in /spec § 4 into the constraint clause, name each norm by its stable label,
     and keep the [[knowledge:...]] backlink for provenance.
     The stable label is the identifier the /implement worker's `Convention handling:` report keys on. -->
- [ ] <Verb> <deliverable> in <owned file/surface> — <design or integration constraint>[; honor <stable-label> (<what to do>)] [[knowledge:conventions/<woven-norm-entry>]] [class: mechanical|standard|judgment-dense] [depends-on: task-N]

## Open Questions
- Unresolved decisions or items needing follow-up

## Related
<!-- Cross-cutting references that apply to the whole plan, not a specific task. -->
- [[knowledge:file#heading]] — cross-references to knowledge store
```
