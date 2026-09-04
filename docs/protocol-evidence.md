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

## Planned producers and their record contracts

Each planned producer has exactly one physical writer, reachable only through a `lore` verb. No reader, skill, or adapter appends to these files. Test helpers may construct historical bytes inside isolated fixtures, but they cannot append production records. The reader already accepts the shapes below through fixtures, so producers can land without a reader change.

### Revisions (planned)

Verb: `lore plan revise <slug>`. Writer: `scripts/plan-revise.sh`. It alone writes `revisions.jsonl`, immutable snapshots under `revisions/<revision_id>/`, and transaction staging beneath that directory. `regen-tasks.sh` remains the sole writer of live `tasks.json`; the revision transaction composes it, including calls made through `lore work regen-tasks`. Authors edit live `plan.md` through existing flows; revise records and publishes that authored state.

**Row fields.** `schema_version` 1; `revision_id` as 12 hex characters; predecessor; old and new plan hashes; old and new generated-task payload hashes; exact finalized tasks-file SHA; source HEAD; author role; timestamp; kind, `semantic` or `progress`; reason; scope delta; changed task IDs; change categories among task, edge, file, constraint, output-contract, criterion; anchor coverage as `{disposition, by, note}`; review requirement as `{disposition, by, note, prior_review_refs}`; item-relative snapshot paths. Generated descriptions and criterion definitions are recorded exactly.

**Deterministic hash boundary.** Revision identity is computed from the plan SHA, the deterministic generated-task payload SHA, and the predecessor. The payload hash excludes only `revision_id`, generation timestamps, and serialization-only metadata. The exact finalized tasks-file SHA is kept separately in the row. The canonical serialization and hash version are named in the contract. Regenerating identical tasks returns the current revision without appending. A progress change permits only checkbox state differences; any other changed plan bytes make the revision semantic. Task IDs stay flat and stable and are never renumbered.

**Recoverable commit.** Under a per-item lock: validate plan, anchor, DAG, and criteria; stage full plan and task snapshots; durably append the commit record; atomically install tasks through their existing writer; refresh the index. Failure before the commit record leaves the prior published generation. After it, no dispatch may use the old generation, and an exact retry repairs only the missing projection from the committed snapshot. A torn tail is incomplete publication, never a silent head; the writer repairs only a provably incomplete final transaction. A competing update against the same predecessor is rejected with a refresh-and-retry diagnostic. Snapshots remain usable after archive.

**Authored decisions.** Absent coverage or review decisions are recorded as `pending`. Nothing infers approval from structural equality. A decision record may later resolve a pending judgment through the same writer. It targets a revision, is a distinct event type, is never a predecessor, and does not alter the historical row. Progress-only revisions inherit the prior decision with explicit provenance. Structural anchor failure still fails validation.

### Packets schema 2 (planned)

`packet-append.sh` remains the sole packet writer. Schema 2 adds revision and source identity and task-attempt identity to the existing template, trust snapshot, entry, and delivery-stage fields. `impl-open.sh` and `impl-next-batch.sh` stamp the committed revision they actually dispatch; already assembled packets are not relabeled. Tasks without a plan revision use schema 1 with an explicit unbound state in the projection. A missing revision on a revised task is an error, not a legacy fallback. Assembly is not receipt; delivery-stage evidence and unknown receipt stay distinct.

The `verify-append.sh` source vocabulary and the `terminus_reached` reasons widen to include investigator, designer, worker, and reviewer beside the legacy names, in the writer, the validator, and the readers together.

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