# Protocol evidence

Reader contract: 2

This document describes how protocol evidence is read from a work item, and what records future producers must write so the same reader can show them beside today's evidence. The reader is implemented. The producers marked **planned** are not. Their sections define the target record contracts that later tasks implement. Interface names given for planned producers are the verbs the design names; their arguments and flags beyond those are not yet chosen and are not listed here.

## Reading a work item

```
python3 -B scripts/work-evidence.py --item-dir PATH --knowledge-dir KDIR
```

`PATH` is the work item directory. `KDIR` is the resolved knowledge store. The command prints the evidence object described below. Adding `--work` prints the complete public work JSON that `lore work show <slug> --json` publishes, with the evidence object embedded in it.

The helper declares `READER_CONTRACT_VERSION="2"`. The `Reader contract: 2` line at the top of this document mirrors that constant so a version change must be made in both places.

The TUI work detail, `lore coordinate status`, and the retrospective all read this one projection. None of them folds ledgers, tasks, or results on its own. A missing or stale record therefore means the same thing in every reader.

## Shape

```
evidence:
  schema_version: 1
  reader_contract_version: "2"
  sources:
    tasks: <envelope>
    revisions: <envelope>
    results: <envelope>
    packets: <envelope>
    outcomes: <envelope>
    reviews: <envelope>
    reports: <envelope>
    claims: <envelope>
    bundle: <envelope>
  revision:
    head: <full committed revision row, or null when no revision ledger exists>
    publication_state: <current | incomplete | legacy-unbound>
    reason: <diagnostic text or null>
  result_summary: [ ... ]
```

### Envelope

Every source is an envelope with the same fields.

| Field | Meaning |
|---|---|
| `state` | `read`, `absent`, `unreadable`, or `unsupported` |
| `reason` | why the state holds; empty when `read` |
| `path` | store-relative path of the source |
| `sha256` | hash of the raw bytes, present whenever bytes exist |
| `content` / `data` / `rows` | parsed content; `rows` for line-delimited ledgers |

Directory-backed sources (reports, reviews, results, revision snapshots) carry one full envelope per entry. Each nested file has its own state, path, hash, and content. A directory source reports one aggregate state when it is unreadable or unsupported, and each entry keeps its own entry-specific state alongside that aggregate.

Report entries carry identifier, declared status or `unknown` when none was declared, size, content hash, and full text. Claims carry a row count together with the canonical rows. Task envelopes carry task bodies and dependency edges, not only IDs. Packet envelopes name their sources and the revision they were assembled against, or an explicit unbound state.

### States

- `read`: the source exists and parses.
- `absent`: nothing exists at the path. Absence establishes only that. It does not say why the source is missing.
- `unreadable`: something exists but fails to parse or validate against the schema it declares.
- `unsupported`: the source declares a schema or contract version this reader does not understand. A work item that predates a producer has no file for that source and is `absent`, not `unsupported`.

No state other than `read` is a pass, and none supplies a zero denominator. A consumer computing a value that requires a source that was not read marks that value unavailable and reports the envelope's state and reason. Values that do not require that source are computed normally. One absent ledger does not invalidate the rest of the projection.

### Freshness

Stale is derived at read time, never stored. A result carries the identities it was produced against, and freshness compares them with the present:

- its revision ID against `revision.head.revision_id`
- its criterion version against the current complete criterion definition
- its recorded source HEAD and worktree digest against the current execution worktree
- its start code identity against its end code identity

Any difference is a stale reason, and the record lists every reason that applies. When the execution worktree cannot be inspected, for example because it was cleaned up, freshness is `unknown` with a reason. Unknown is neither current nor stale. A plan progress change also produces a new revision, so results recorded against the earlier revision become stale; nothing is revalidated or rewritten.

### Revision head

`revision.head` is the latest committed revision. `publication_state` records whether the live task file matches the committed snapshot. When it does not, `reason` explains the mismatch and the projection reports incomplete publication. Readers never regenerate tasks; repair belongs to the revision writer. Items with no revision ledger report no head and state `legacy-unbound`.

### Result summary

One entry per task and criterion: task ID, criterion ID, latest result ID, its state, its freshness, and the reasons behind both. A criterion with no result appears with no result ID. No task-level rollup is computed. A pass on one criterion is shown beside failing, stale, unknown, or missing results on the same task, never in place of them.

## No private fallback

Report bodies, review output, and result output travel in the projection under store-relative references. What the projection could not read, no consumer reads another way. A judgment made from the pack is therefore reproducible from the pack.

## Retrospective pack

The pack schema remains 1. `source_data.cycle_work` carries the semantic work projection at reader contract 2. Other source readers keep their existing versions.

Content identity for `cycle_work` covers every evidence envelope and its substantive content, including each envelope's raw `sha256`, so a source that moves from malformed to valid changes identity even when the parsed shape looks the same. Two things are excluded from identity: the retrospective's own completion atoms in the execution log, and the evidence-pack and filing artifacts the retrospective generates. Nothing else is excluded. The public raw work view delivers the execution log in full. The pack `source_data` semantic view omits prepare-only entries and their associated headers. Parsed `Spec-outcome-record` entries in that log participate in identity on their own terms and are not removed by the completion-atom filter.

## Legacy sources read today

- **Generated tasks.** `regen-tasks.sh` writes `tasks.json`. Readers prefer `tasks[]` and flatten `phases[]` for legacy phase plans. Tasks without structured close criteria are legible as legacy with no executable criteria.
- **Execution log.** Delivered unchanged. Existing reductions and `impl-check-report.sh` behavior are untouched.
- **Close bundle.** `impl-close.sh` writes a nine-field, unversioned `retro-bundle.json`. The projection reads it as a declared legacy-v0 snapshot of the last close. It is not revision truth. Where it disagrees with revision-bound results, the disagreement is a timing fact to report. Missing is `absent`, malformed is `unreadable`, and neither says anything about the outcome of the work.
- **Schema-1 packets and outcomes.** Read as unbound: they name no revision, and the projection says so.

## Producers, shipped and planned, and their record contracts

Each producer has exactly one physical writer, reachable only through a `lore` verb. No reader, skill, or adapter appends to these files. Test helpers may construct historical bytes inside isolated fixtures, but they cannot append production records. The revision and packet producers below have shipped, and the work reader's contract 2 now carries the derived `packet_summary` described under Packets schema 2. The review and result producers that follow them remain planned; their sections describe the contract the reader already accepts through fixtures, so they can land without a reader change.

### Revisions

Verb: `lore plan revise <slug>`. Writer: `scripts/plan-revise.sh`. It alone writes `revisions.jsonl`, immutable snapshots under `revisions/<revision_id>/`, and transaction staging beneath that directory. `regen-tasks.sh` remains the sole writer of live `tasks.json`; the revision transaction composes it, including calls made through `lore work regen-tasks`. Authors edit live `plan.md` through existing flows; revise records and publishes that authored state. The loader that reads `tasks.json` stays read-only, so a reader that observes drift reports it and the composer below resolves it.

**Invocation.**

```bash
lore plan revise <slug> [--reason TEXT] [--author-role ROLE] [--kind auto|semantic|progress] \
  [--expected-predecessor RID|none] [--decisions FILE]
lore plan revise <slug> --decision-for RID --decision-id TOKEN --decisions FILE
lore plan revise <slug> --reconcile
```

The first form publishes the current live plan. `--kind auto` classifies the change from the bytes that differ: checkbox state alone is `progress`, anything else is `semantic`, and a request for `progress` when other bytes changed is refused because progress inherits the semantic decisions of its source, and an inherited decision cannot cover a semantic edit it was never made against. `--expected-predecessor` names the head the author worked from; when the current head differs, the writer refuses with a refresh-and-retry diagnostic rather than publishing decisions made against bytes that are no longer the head. Publishing again with nothing changed is a no-op that returns the current revision without appending. The second form appends a decision record against an existing revision and creates no revision; the same `--decision-id` replays exactly and appends nothing further. The third form is the composer that `open` and `next-batch` call: it completes a provably incomplete final transaction, publishes drift on an item that already has revisions, adopts a legacy item whose plan and tasks disagree, and leaves a legacy item with no drift on its old path. `next-batch` always invokes this pass, and it allows legacy progress only when it can prove the drift is checkbox-only: a legacy item stays on its old path when the current plan checksum matches the recorded original, or when the current bytes with every checkbox normalized to unchecked hash exactly to the recorded original checksum. Other drift is adopted as a revision, or reported as a validation failure or pending authored decision before any dispatch. Because a legacy plan recorded with mixed checked states may not satisfy that proof, such an item is adopted rather than assumed checkbox-only. `open` retains the normal reconcile behavior without this exemption. `lore work regen-tasks` does not use `--reconcile`: on an item that has adopted revisions it runs the first form as a normal revise, and on a legacy item it keeps the direct generator path.

**Row fields.** `schema_version` 1; `revision_id` as 12 hex characters; predecessor; old and new plan hashes, the published plan as `plan_sha256`; old and new generated-task payload hashes; the exact finalized tasks file as `tasks_sha256`; source HEAD; author role; timestamp; kind, `semantic` or `progress`; reason; scope delta; changed task IDs; change categories among task, edge, file, constraint, output-contract, criterion; anchor coverage as `{disposition, by, note}`; review requirement as `{disposition, by, note, prior_review_refs}`; `plan_path` and `tasks_path` as item-relative snapshot paths. Generated descriptions and criterion definitions are recorded exactly. Decision records in the same file carry `record_type` `decision`, are never heads, and reference the revision they settle.

**Deterministic hash boundary.** `hash_version` 1 canonicalizes as compact JSON with sorted keys, encoded as UTF-8 with non-ASCII characters preserved rather than escaped. The payload hash covers the generated tasks with only the top-level `revision_id` and `generated_at` removed, so an identical regeneration hashes identically while the finalized file, which carries those two fields, is recorded separately as `tasks_sha256`. The revision id is the first 12 hex characters of a SHA-256 over the plan hash, the payload hash, and the predecessor in the writer's own serialization. Regenerating identical tasks returns the current revision without appending. A progress change permits only checkbox state differences; any other changed plan bytes make the revision semantic.

**Task identity.** An existing `### Task N` heading is `task-N` and stays `task-N` when its subject is renamed, because results and reviews are keyed to the id. A legacy heading or checklist form may carry an explicit `[id: task-N]` marker; a normal flat heading needs none. When a plan is regenerated against a previous generation, ids that no longer match a heading are preserved as retired rather than freed, and a new task takes the next number above the high watermark, so a deleted task's id is never reused for different work.

**Close criteria.** A task may declare `**Close criteria:**` as a fenced JSON array. Each criterion has `id`, `intent`, `argv`, `cwd`, `timeout`, `expected_exit`, and an optional `applicability` object with its own `argv`, `cwd`, `timeout`, and distinct `applicable_exit` and `inapplicable_exit`. The generator hashes the complete canonical definition into `criterion_version` and carries the exact command fields into the generated brief, so a changed argv, cwd, timeout, or expected exit changes the version even when the intent text does not. Legacy `**Verification:**` prose is unchanged and stays beside criteria. A task without criteria is a legacy absence of executable evidence, not a passing result. The command that executes criteria is described under Results below and has not shipped.

**Recoverable commit.** Under a per-item lock: validate plan, anchor, DAG, and criteria; stage full plan and task snapshots; durably append the commit record; atomically install tasks through their existing writer; refresh the index. Failure before the commit record leaves the prior published generation. After it, no dispatch may use the old generation, and an exact retry repairs only the missing projection from the committed snapshot through the sole tasks writer; it never overwrites author edits to `plan.md`. A torn tail is incomplete publication, never a silent head; the writer repairs only a provably incomplete final transaction. A competing update against the same predecessor is rejected with a refresh-and-retry diagnostic. Snapshot paths are item-relative, so lookup on an archived item resolves the same files.

**Authored decisions.** Absent coverage or review decisions are recorded as `pending`. Nothing infers approval from structural equality. A decision record may later resolve a pending judgment through the same writer. It targets a revision, is a distinct event type, is never a predecessor, and does not alter the historical row. The writer validates that named task ids exist in the target revision. Progress-only revisions inherit the effective decisions with `inherited_from_revision` naming their source; a decision still pending at the source stays pending. Structural anchor failure still fails validation. A `--decisions` file holds any of three keys:

```json
{
  "anchor_coverage": {"disposition": "covered", "by": "designer",
    "note": "Tasks 3 and 6 together cover the publish-under-lock clause; task 6 carries the retry path."},
  "review_requirement": {"disposition": "required", "by": "designer",
    "note": "New physical writer; post-plan review should read the commit ordering.",
    "prior_review_refs": []},
  "dispatch_decision": {"disposition": "proceed", "by": "coordinator",
    "note": "Review is scheduled; the writer is isolated behind its verb and reviewable against the snapshot.",
    "task_ids": ["task-3", "task-6"], "prior_review_refs": []}
}
```

Anchor coverage is `covered`, `not-covered`, or `pending`. Review requirement is `required`, `not-required`, or `pending` and records an obligation; on its own it neither grants nor withholds dispatch. The dispatch decision is `proceed`, `wait`, or `reuse` and belongs to the coordinator. A changed semantic task stays undispatchable while coverage is `pending` or `not-covered`, while no dispatch decision names it, or while the decision is `wait`. Covered anchor plus an explicit `proceed` permits dispatch while a required review is outstanding. `reuse` names the prior review in `prior_review_refs` and says in `note` why its reviewed scope still applies; a reuse without both is refused, because an unnamed prior review cannot be checked later.

Reader contract 2 may additionally carry an optional `revision.dispatch` projection at nested `schema_version` 1, visible to every reader of the contract. It carries a nested `schema_version` of 1; a `tasks` object mapping each task ID to its `coverage`, `coverage_revision_id`, `dispatch`, and `dispatch_revision_id`; and a `blocked` object mapping task IDs to reason strings. The fold carries the predecessor's per-task decisions forward, resets entries only for semantic tasks that changed, and applies a later dispatch decision only to the task IDs it names. A later unrelated edit therefore cannot clear a decision that is missing, and deciding a second task does not erase the first task's decision. `coverage_revision_id` and `dispatch_revision_id` name the authored source of each value; the raw revision and decision records stay unchanged, and progress retains per-task provenance. The projection is derived entirely from those source records.

### Packets schema 2

`packet-append.sh` remains the sole packet writer. Every packet, schema 1 or 2, carries a `packet_id`. Schema 2 adds binding to the existing template, trust snapshot, entry, and delivery-stage fields: `task_id`, `work_item`, `revision_id` as 12 lower-case hex characters, a nonempty `dispatch_attempt_id`, and `source_head`, which is the committed revision's source HEAD as a string or an explicit null. `impl-open.sh` and `impl-next-batch.sh` stamp the committed revision they prepare against. The writer refuses a revised task whose attribution is missing, a revision that is not committed, a task the revision does not know, and a `source_head` that disagrees with the committed row. Existing schema-1 packets are untouched: they keep their `packet_id`, lack `revision_id`, `dispatch_attempt_id`, and `source_head`, and project as legacy-unbound. An item with no revision history still writes schema 1 with the explicit unbound state in the projection. A missing revision on a revised task is an error, not a legacy fallback.

**Attempt identity.** Each preparation allocates a fresh dispatch UUID per task on a revised plan. `open` exposes `packet_id`, `revision_id`, and `dispatch_attempt_id` on each TaskCreate manifest entry and in `packets[]`; TeamCreate and TaskUpdate entries carry no packet identity. `next-batch` exposes the same three fields in `batch[]` and `packets[]`. On legacy items the revision and attempt fields are null. Preparing again is a new candidate attempt, not receipt of an earlier one. The lead carries the selected tuple unchanged into the dispatch brief, keeping the `Packet-id` marker and adding `Revision-id` and `Dispatch-attempt-id` beside it. Manager placement and report attempt labels such as `r1` are a separate namespace; they are recorded as an association with the prepared dispatch id, never in place of it. When the plan moves, attempts already dispatched are never restamped; an ordinary later preparation writes a new packet for the committed current generation.

**Assembly is not receipt.** Retrieval assembly is unchanged. `open` records the existing knowledge delivery snapshot. `next-batch` returns the existing task descriptions and Tier 2 extracts and assembles no knowledge entries, so its packets carry empty `delivered_entries` with an explicit `empty_reason`. That emptiness is not missing receipt proof: every assembly path leaves receipt unknown, and the existing delivered-stage record remains the explicit delivery evidence. Packet assessment keeps its verdict, null, and missing behavior; assessment rows for schema-2 packets carry the added identity fields while staying in the schema-1 assessment vocabulary.

**Packet summary in the work reader.** Work evidence contract 2 adds a `packet_summary` list, derived only by `scripts/work-evidence.py`; no other script computes it. Each entry is `{packet_id, task_id, dispatch_attempt_id, revision_id, binding, receipt}`. `binding` uses the same vocabulary as the full packet records: `current`, `stale` with reason `revision-mismatch`, `legacy-unbound`, `unknown`, or `invalid`. `receipt` reports the receipt state the full record carries, which every assembly path leaves unknown. Legacy schema-1 packets appear with their `packet_id`, null revision and attempt fields, and `legacy-unbound`. The coordinator status exposes exactly this `packet_summary` and nothing more of the packet. Retro and the TUI read the same work evidence and retain the full packet rows and source envelopes, so all three readers observe one derivation of binding rather than each computing its own.

**Source vocabulary.** `verify-append.sh` accepts investigator, designer, worker, reviewer, researcher, spec-lead, and implement-lead as sources. The trust writer accepts those beside all of its legacy sources. `terminus_reached` accepts exactly investigator, designer, worker, reviewer, spec-finalize, and impl-close. The session reader's `vocabulary_version` is 2 while its `reader_contract_version` stays 1, and the work reader stays at contract 2. Terminus IDs and dedup, sampling, close triggers, and the report and execution-log reductions are unchanged. Criterion execution never emits a terminus.

### Reviews (planned)

Verb: `lore plan review prepare <slug>`. Writer: `scripts/plan-review.sh`. It preserves immutable review input under `reviews/<attempt-id>/`. The prepare artifact identifies ceremony, attempt, input revision, plan and task hashes, the input snapshot, and source code identity when the review is integration. A second operation on the same verb seals reviewer output and the authored disposition ledger once, with exact-replay recovery. It accepts review judgments and never command results.

`spec-outcome.sh` validates the sealed artifact hashes and then composes `write-execution-log.sh`, which is the sole physical writer of the outcome ledger. The recorded revision is the one whose snapshot was actually read. Schema-1 outcomes stay legacy and unbound; schema 2 outcomes are bound. Design and post-plan ceremonies stay distinct.

**Authored review decisions.** Each semantic revision declares review disposition `required`, `not-required`, or `pending`, with author and reason. The disposition records an obligation and grants no permission. The coordinator decides to wait, to proceed while review is outstanding, or to reuse a named prior review, and records that decision with its reason and affected task IDs. A prior review satisfies the obligation only when it is named and its continued applicability is explained. Results, outcomes, and review artifacts never change when the head moves. A later review may cite an earlier one; it cannot rewrite its verdict.

### Results (planned)

Verb: `lore criteria run <slug> <task-id> <criterion-id>`. Writer: `scripts/criteria-run.sh`. It alone appends `results.jsonl` and creates immutable output and recovery artifacts under `results/<result-id>/`.

**No imported results.** The verb accepts identity and placement inputs only. There is no result, state, or exit override, no skip flag, and no generic append. Task and criterion resolve from the selected immutable revision; the caller cannot supply a command. For a dispatched run, the referenced packet fixes task, attempt, and revision, and caller-supplied identity must agree. Outside dispatch, the caller selects a revision and execution worktree and supplies the unbound reason. Selection is frozen before execution; a historical revision is never replaced by the current head. Conflicting or missing identity is rejected before any process launches.

**Criterion definition.** Stable criterion ID, intent text, exact argv, worktree-relative cwd, timeout, expected exit, and an optional applicability predicate with its own argv, cwd, timeout, and distinct exits for applicable and inapplicable. The criterion version is a hash of the complete canonical definition, not only the display text. The generator retains the definition and version.

**Row fields, schema 1.** `result_id`; task and dispatch attempt; execution-attempt identity; criterion ID and version; revision ID; source HEAD; worktree digest; start and end code identities; packet reference or explicit unbound reason; argv; cwd; exit; signal; `timed_out`; `duration_ms`; output path and digest; state; machine-derived reason; timestamp.

**States at write time.** `pass` only after the process exits as expected with no signal or timeout and durable output. `fail` on nonmatching exit, signal, or timeout. `skipped` only when the applicability predicate observed its declared inapplicable exit; the criterion command does not run. `unavailable` on launch, placement, or output-persistence failure, on an inaccessible source root, on any predicate outcome other than its two declared exits, and for an interrupted run with no durable completion. At read time `missing` and `unreadable` remain distinct from all four.

**Code digest.** Computed over tracked staged and worktree bytes, deletions, modes, symlink targets, submodule state, and non-ignored untracked files. Excludes only Git internals and this verb's own output and staging. The algorithm version is recorded. Generated build output may produce a conservative stale result and is not excluded to obtain a pass.

**Execution rules.** No implicit shell; a criterion may name one explicitly. cwd resolves inside the declared execution worktree. Dispatch-attempt identity is fixed across reruns; each execution gets a new result ID allocated before launch. Recovery by a named result ID replays its persisted inputs, launches nothing, and rejects conflicting inputs. A new execution after failure or interruption is a new run. Completion rows are immutable, per-criterion attempt allocation is locked, and execution never holds the plan publication lock. The verb never checks off tasks, accepts reports, archives work, or declares anchor coverage.

## Invariants across records

- One physical writer per file. Existing writers stay authoritative and are composed, never bypassed.
- Readers never append and never regenerate.
- Records never change when the revision head moves; freshness is derived, not rewritten.
- Every hash boundary is declared and versioned in the record that uses it.
- No producer changes shape before a reader can read it, and each reader change lands in the same commit as its contract prose and behavioral tests.