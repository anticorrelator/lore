# Plan.md Template

Read this template when emitting `plan.md` in Step 5 (abstract sections) and Step 5b (concrete sections). The fenced block below is the canonical plan structure the designer copies (HTML comments inline are load-bearing enforcement — keep them with the section they govern). Comments reach the plan author only; an obligation a worker must act on travels in a task line and its generated brief.

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
     For legacy or no-anchor work items, omit the section entirely; the Step 5.6 verifier skips with a stderr info message.

     Three fields, in this order:
       1. The anchor body verbatim from `_meta.json.intent_anchor` (no quoting, no prefix label — just the raw text).
       2. `**Scope delta:**` line — default "none — anchor preserved unchanged"; if the spec narrows the capability, name the narrowing here.
       3. `**Tempting narrower implementation:**` heading — the spec author names the tempting narrower implementation that
          would appear successful while violating the anchor.

     Fields 1 and 2 are rendered at the abstract stage (Step 5), because `lore plan revise` runs the anchor verifier on
     every publication and the abstract revision cannot be published without them; the concrete stage (Step 5b item 0)
     preserves them and adds field 3.
     Verifier-enforced fields (load-bearing for every publication and the Step 5.6 gate): anchor body and `**Scope delta:**` line.
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
<!-- Optional, both modes. 3-6 bullets summarizing key files, constraints, and patterns found.
     In short mode this is where the seat's own reading is summarized; the findings themselves
     still go under ## Investigations, because the short reading is an investigation with a
     landed report. Omit the section when the Investigations entries carry everything. -->

## Investigations
<!-- Both modes. One entry per investigation: the dispatched investigators in full mode, and the
     seat's inline investigation in short mode. Findings and Observations are copied verbatim
     from the landed report; the entry is not a paraphrase. -->

### <Topic 1>
**Question:** <what was investigated>
**Findings:**
- Finding 1
- Finding 2
**Key files:** `path/to/file.ts`, `path/to/other.ts`
**Implications:** How this affects the design
**Observations:**
- <mechanism-level pattern, design rationale, or structural footprint signal, preserved verbatim from the investigator report>

<!-- Note: investigator assertions are emitted to task-claims.jsonl (Tier 2)
     via evidence-append.sh — they do not appear in plan.md. See architecture/artifacts/tier2-evidence-schema.md. -->

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
     Size each one by the Step 5b sizing band: one design center per task, and both
     directions of the sizing decision argued in writing below.

     The heading number is the task's id: `### Task 3:` is `task-3`. It stays fixed as
     earlier work is checked off, so `[depends-on: task-3]` keeps naming the same task.

     Task generation refuses the whole document, writing no output, when:
       - a `### Task N:` block carries any number of `- [ ]` lines other than exactly one
       - a backticked path on a task line is absent from that task's `**Files:**` block
       - a task declares no file target in either place
       - two headings share a number
       - the document mixes `### Task N:` headings with any other unit-heading form

     Every task carries the standing premise-wrong exit (Step 5b): a worker report that
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
     Step 5.6 finalize refuses a plan of more than one task that lacks this block. -->
<why this plan splits into N tasks — what the extra worker spawns buy, and against what cost>

**Merge rationale:**
<!-- REQUIRED when this plan carries exactly one task; omit entirely for a multi-task plan.
     One or two sentences naming the single design center the parts share — the one interface,
     mechanism, or subsystem whose shape one worker decides.
     Step 5.6 finalize refuses a one-task plan that lacks this block. -->
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
<!-- Optional — omit when the task has no Knowledge context backlinks and no Files entries.
     Seeds are derived from (a) [[knowledge:...]] backlinks in Knowledge context, resolved to
     title vocabulary, and (b) file paths in Files. Deduplication applied. hop_budget defaults to 1.
     scale_set: REQUIRED — declare the appropriate bucket (abstract | architecture | subsystem | implementation); multi-label form (e.g., architecture,subsystem) is allowed for adjacent pairs. Omitting is an error.
     Consumed at dispatch: `lore impl open` resolves this directive through the shared packet builder
     into the task's knowledge packet, which the implement seat synthesizes before the worker reads it. -->
- seeds: [[knowledge:file#heading]], path/to/file.py
- hop_budget: 1
<!-- scale_set: REQUIRED — declare one bucket: abstract | architecture | subsystem | implementation (multi-label form architecture,subsystem etc. allowed for adjacent pairs) -->
<!-- - filters: type=knowledge, exclude_category=... (optional; omit when not filtering) -->
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
     See Step 5b "Deliverable contract gate" for routing of invalid units.

     Every task line ends with a trailing [class: mechanical | standard | judgment-dense] marker
     (after any [[knowledge:...]] backlinks) declaring the worker tier /implement routes it to.
     Step 5.6 finalize refuses any unannotated task line.

     Append `[depends-on: task-N, task-M]` to declare an ordering no shared file expresses; the ids
     are heading numbers, and the marker seeds `blockedBy` before file-overlap chaining adds to it.
     Tasks that share a file are chained automatically — no marker needed for those.

     Weave the binding subset defined by Step 5b into the constraint clause, name each norm by its stable label,
     and keep the [[knowledge:...]] backlink for provenance.
     The stable label is the identifier the /implement worker's `Convention handling:` report keys on. -->
- [ ] <Verb> <deliverable> in <owned file/surface> — <design or integration constraint>[; honor <stable-label> (<what to do>)] [[knowledge:conventions/<woven-norm-entry>]] [class: mechanical|standard|judgment-dense] [depends-on: task-N]

## Open Questions
- Unresolved decisions or items needing follow-up

## Related
<!-- Cross-cutting references that apply to the whole plan, not a specific task. -->
- [[knowledge:file#heading]] — cross-references to knowledge store
```
