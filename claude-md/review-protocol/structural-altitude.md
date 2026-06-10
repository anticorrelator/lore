### Structural Read Lens

Canonical methodology for the Structural Read lens. This is referenced by the `/pr-review` orchestrator when spawning a structural lens agent, the same way the security lens reads `security-methodology.md`. There is no standalone `/pr-structure` skill — the lens consumes the orchestrator-produced PR Narrative and Implementation Diagram, so it runs only inside the orchestrator that builds them.

The Structural Read lens judges the PR **as a designed solution**: is the logical flow sound and not over-complicated, is the approach idiomatic to this codebase, and are the PR-level abstractions and contracts sensible. It is the one whole-PR lens — every other lens scans changed lines and emits `{file, line}` findings from the diff. The structural lens reads the diagram (when present), the narrative, and the diff *as a whole* and judges solution-shape.

#### Altitude Boundary

Three lenses can each sound like they review "design." They do not overlap — each owns a distinct altitude. State the boundary so the structural lens stays in its lane and does not re-file what another lens already owns:

- **interface-clarity = local.** *Can a caller use this signature?* Naming, parameter shape, abstraction coherence at a single boundary. Diff-local.
- **thematic = scope.** *Does this change belong in this PR?* Coherence of what was changed against the PR's stated intent. Diff-local.
- **structural = solution-shape.** *Is this the natural way to build this here?* Whether the PR's overall logical flow, its fit to codebase idiom, and its PR-level abstractions and contracts are the shape the problem calls for. Whole-PR.

A finding that turns on one changed signature is interface-clarity, not structural. A finding that turns on whether a file belongs in the PR is thematic, not structural. The structural lens speaks only when the observation is about the *shape of the whole solution* — a concern no diff-local lens can reach, because it requires reading the PR end to end rather than line by line.

#### Methodology

The lens reads **diagram (when present) + narrative + diff** and assesses three things. The diagram is an *enriching* substrate, not a precondition: on a single-module PR no diagram is drawn (`followup-template.md` gates it to 2+ modules), so diagram-dependent checks simply have nothing to bind to and are skipped — the rest run from narrative + diff alone.

**a. Logical-flow soundness and parsimony.** Trace the path the PR builds, end to end. Is the flow sound — does the control/data path actually accomplish the narrative's stated goal? Is it parsimonious — is anything unnecessary, redundant, or more complicated than the problem warrants? This is `codex-design-review`'s "lean and legible — is anything unnecessary, ambiguous, or over-engineered?" altitude, applied at review time rather than design time. Over-complication is a structural observation only when the simpler shape is genuinely available here; "I'd have written it differently" is not.

**b. Codebase-idiom fit.** Does the approach match how this codebase already does this kind of thing? A PR that hand-rolls a mechanism the codebase already has a convention for, or that introduces a parallel pattern where an established one fits, is a structural observation — the cost is a maintainer who now has two patterns to hold instead of one. Idiom fit is judged against observed codebase patterns, not against a personal preference.

**c. PR-level abstraction and contract sensibility.** Are the abstractions the PR introduces at the right boundaries, and are the contracts between its parts coherent? This reads the diagram's module/flow structure (when present) against the narrative's intent: a contract that drifts from what callers expect, an abstraction drawn at a boundary that forces unnatural coupling, or a missing seam the solution-shape needs are structural observations.

**Evidence precedence.** The Narrative and Diagram are *non-authoritative derived context* — the orchestrator generated them; they are not ground truth. A structural observation must be grounded in the diff or source, not in the brief alone. The brief orients the read; it can never be the sole basis for a claim.

#### Observation Schema

On success the lens returns one reviewer-facing assessment: a `verdict`, a brief rationale, and `observations[]`. Zero observations means "no structural issue found beyond the assessment," not failure. Missing or malformed lens output is recorded in the Structural Assessment section and never fabricates posted comments.

Each observation carries:

- **summary** — short declarative statement of the structural observation.
- **evidence** — what in the diff/source/narrative grounds it, including any free-text scope explanation. Routing reads `scope`, not this field.
- **scope** — the altitude the observation lives at, in a machine-readable shape so the orchestrator can route on it without parsing prose:
  - **changed-line anchor(s)** — explicit `file` + `line` pairs, each on a changed line. Use only when the observation honestly attaches to specific changed lines.
  - **affected file(s)** — an explicit string array of file paths.
  - **affected module(s)** — an explicit string array of module names.
  - **`whole-PR`** — a literal scope kind, for an observation about the solution as a whole with no narrower honest anchor.
- **downstream_cost** — present **only when** the observation clears the materiality bar below. It names the concrete cost in the conditional-stake form (see the bar). Its absence means the observation is cockpit-only.

`scope` drives two downstream behaviors, both owned by `/pr-review`, not by the lens:

- **Routing (materiality, D4):** the orchestrator computes whether an observation crosses to a posted form from `scope` + `downstream_cost`. The lens does not decide posting.
- **Correlation eligibility (synthesis):** synthesis correlates a structural observation against clusters of diff-local findings **only when it has changed-line or file anchors** — the existing file/line proximity mechanics need concrete anchors. A `whole-PR` or module-only observation is simply not correlated; absence of an anchor means "no cluster check," never lower confidence. Do not invent fake line anchors to become eligible — an honest `whole-PR` scope is correct when that is the real altitude.

#### Structural Materiality Bar

The structural bar **specializes `severity.md`'s Materiality Gate for whole-PR observations — it does not restate or fork it.** `severity.md` is the single source of truth for severity and materiality; the same articulation→materiality move applies one altitude up. Any structural observation's consequence can be *articulated* — "this is more complex than it needs to be" always reads as a stake — so the test is **magnitude, not expressibility**: would the author change the code over this?

Two surfaces, split exactly as `pr-review-separates-two-surfaces-reviewer-cockpit` describes:

- **Cockpit — always.** The reviewer-facing **Structural Assessment** report section is populated on every run and is never posted. It keeps the full reasoning, the verdict, and every observation regardless of whether it clears the bar. This is the reviewer's own triage view.
- **Posted — only on a concrete downstream cost.** A structural observation crosses to a posted form (the top-level PR comment, or an inline comment when honestly anchored) **only when it names a concrete downstream cost** — a likelier future bug, contract drift, or a convention break a maintainer would reject. When nothing clears the bar, no top-level comment is proposed and `review_body` is not selected.

What clears and what drops:

- **Clears (material):** the observation names a cost a reader can situate — *when* it bites in ordinary maintenance or use, and *what it costs* the person who hits it. Stated as a conditional stake (`X happens when Y`), the same `**Grounding:**` form `findings-format.md` and `severity.md` already define — reuse that vocabulary, do not coin a parallel "structural stake" term.
- **Drops (immaterial):** "cleaner my way," reads-better, pure-taste preference. If, once you spell out the realistic situation, the cost appears only in a contrived scenario or is a matter of taste, drop it — do not dress it up as a code-state to sound worse. Dropped observations stay in the cockpit assessment; they are never posted.

**Posted form.** When a structural observation does cross the wall, its posted form honors `preference-scoped-to-pr-review-skills-posted` exactly as every other posted comment does: it **names the material impact** in usage terms, is **neutral** (no severity word, no verdict — the conditional stake hands the criticality call to the reader), and is **digestible — one line where possible**, never an internal-reasoning essay. A fix, if non-obvious, is framed softly as a question. The distill rule in `findings-format.md` → External Output Formatting governs the wording; nothing here overrides it.
