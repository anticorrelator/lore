# Protocol evidence

Reader contract: 2

The reader and the revision, packet, review, and result producers it consumes are all implemented. Everything in this document describes shipped behavior.

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
- **Close bundle.** `impl-close.sh` writes a ten-field, unversioned `retro-bundle.json` (the tenth, `task_attribution`, carries per-task producer attribution). The projection reads it as a declared legacy-v0 snapshot of the last close. It is not revision truth. Where it disagrees with revision-bound results, the disagreement is a timing fact to report. Missing is `absent`, malformed is `unreadable`, and neither says anything about the outcome of the work.
- **Schema-1 packets and outcomes.** Read as unbound: they name no revision, and the projection says so.

## Producers, shipped and planned, and their record contracts

Each producer has exactly one physical writer, reachable only through a `lore` verb. No reader, skill, or adapter appends to these files. Test helpers may construct historical bytes inside isolated fixtures, but they cannot append production records. The revision, packet, and review producers below have shipped, and the work reader's contract 2 carries the derived `packet_summary` described under Packets schema 2 and the derived `review_summary` described under Reviews. The result producer that follows them remains planned; its section describes the contract the reader already accepts through fixtures, so it can land without a reader change.

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

**Close criteria.** A task may declare `**Close criteria:**` as a fenced JSON array. Each criterion has `id`, `intent`, `argv`, `cwd`, `timeout`, `expected_exit`, and an optional `applicability` object with its own `argv`, `cwd`, `timeout`, and distinct `applicable_exit` and `inapplicable_exit`. The generator hashes the complete canonical definition into `criterion_version` and carries the exact command fields into the generated brief, so a changed argv, cwd, timeout, or expected exit changes the version even when the intent text does not. Legacy `**Verification:**` prose is unchanged and stays beside criteria. A task without criteria is a legacy absence of executable evidence, not a passing result. The command that executes criteria is `lore criteria run`, described under Results below.

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

### Reviews

Verb: `lore plan review prepare <slug> --attempt-id <token> --ceremony <spec-design|spec-post-plan> --revision <rid> --purpose <criterion-adequacy|integration> [--execution-worktree <path>]`. Writer: `scripts/plan-review.sh`. Prepare copies the named revision's immutable plan and tasks, together with the original anchor, to `reviews/<attempt-id>/plan.md`, `tasks.json`, and `anchor.md`, and writes `prepared.json` as a schema-1 `review-input` record carrying content hashes, paths, the request, and a frozen source identity. An explicit historical revision is accepted and becomes the revision the outcome binds to. The `integration` purpose requires an execution worktree that can be inspected. Its code digest covers that worktree only: prior review evidence is part of the identity when it lives inside the worktree, and a knowledge store outside it is not code identity. The single exclusion is this attempt's own review directory, listed as `source_exclusions`. The attempt directory is published by a single rename. A prepare interrupted before the rename leaves no accepted attempt and a retry may publish; after the rename the accepted attempt remains and an exact retry verifies it. An exact retry compares the request against the committed record and keeps the frozen source identity even when the worktree has changed since.

Verb: `lore plan review seal <slug> --attempt-id <token> --output <file> --dispositions <file> --evaluator-manifest <file>`. Seal happens once per attempt. The output is UTF-8 reviewer text. The dispositions ledger is strict schema 1: `outcome` (`completed|failed|skipped|needs-decision`), the raw `verdict` string, `reason` (null unless the outcome is skipped or needs-decision), `judgments` of `{purpose, judgment, rationale, result_ids}` with distinct purposes and the prepared purpose present, and `dispositions` of `{finding, disposition, reason}`. An integration review may carry a separate criterion-adequacy judgment. The ledger has no executor state, exit code, argv, or imported result fields, and a judgment never creates a result row. The reviewer owns criterion adequacy and integration against the original anchor and does not accept tasks; the reviewer may read code, run commands, and describe command behavior in prose, but execution evidence the judgment relies on is cited by result ID. Empty `result_ids` states that no execution evidence was cited, not that none was consulted, and the judgment text carries what the citations leave unverified. The lead's normalized outcome sits in the ledger before sealing, so the sealed bytes record the decision together with the review it was made from. The evaluator manifest is exactly `{evaluator_locator, evaluator_template_version, framework, model, final_round}`: a 12-character lowercase hex template version and a positive integer final round.

Seal validates each cited result ID against its canonical `results.jsonl` row through the shared reader; missing, ambiguous, or malformed IDs and wrong output hashes are refused. It freezes the cited rows with their full output envelopes into `cited-results.json`, a schema-1 record whose `execution_evidence` is `cited` or `none` with an explicit absence reason. These copies are review evidence and never result appends, and an exact replay verifies the frozen citations rather than rereading the live ledger. The whole `sealed/` directory (`output.md`, `dispositions.json`, `cited-results.json`, `seal.json`) is published by one rename. Before that rename, failure leaves nothing accepted and a retry may publish; after it, a retry verifies the immutable bytes and refuses a changed output, ledger, or evaluator under the same attempt id. Seal returns the `evidence_manifest` in its JSON result and writes no manifest file under the review. The caller extracts it to a file outside `reviews/` with `jq '.evidence_manifest'` and hand-composes no identity field. The schema-2 manifest carries the evaluator identity fields plus `review_path`, `review_sha256`, `revision_id`, `purpose`, and `source_tasks_sha256`; `source_plan_sha256` and `disposition_ledger_sha256` derive from the sealed bytes.

`spec-outcome.sh` keeps its existing arguments and takes the extracted schema-2 manifest. It revalidates the complete sealed, prepared, and citation bytes, checks that ceremony, attempt, outcome, verdict, and reason match the sealed ledger, and then composes `write-execution-log.sh`, which remains the sole physical writer of the outcome ledger. The recorded revision is the one actually reviewed, never the live head. Exact replay recovers a missing needs-decision auxiliary scorecard row without duplicating the outcome; a conflicting identity fails. Schema-1 outcomes stay legacy and unbound, which covers items with no prepared revision and evaluators that could not run. Design and post-plan ceremonies stay distinct. Filing confers no acceptance, checkoff, or close authority.

**Authored review decisions.** Verb: `lore plan revise <slug> --decision-for <rid> --decision-id <token> --decisions <file>`, appending to the same revisions ledger. A decision carries any subset of `anchor_coverage` (`covered|not-covered|pending`), `review_requirement` (`required|not-required|pending`, with `prior_review_refs`), and `dispatch_decision` (`proceed|wait|reuse`, with `task_ids` and `prior_review_refs`); none of the three is mandatory, each present field carries `by` and `note`, and a field the decision omits is left undecided by that event. A required review records an obligation and gates nothing on its own; pending coverage, a missing dispatch decision, or `wait` still block. An explicit `proceed` may authorize dispatch while a required review is outstanding, and `reuse` must name a prior review and explain why its scope still applies. Every decision is a new immutable event; historical rows are never rewritten. Automatic pending dispositions carry `by: null` and read as pending. Results, outcomes, and review artifacts never change when the head moves. A later review may cite an earlier one; it cannot rewrite its verdict.

**Projection.** Reader contract 2 carries `review_summary`, one entry per attempt: `{attempt_id, state: sealed|unsealed|unreadable|missing, reason, revision_id, purpose, ceremony, binding, result_ids, outcomes, prepared_path}`, with `seal_path`, `outcome`, `verdict`, and `execution_evidence` once sealed. `unsealed` is a prepared attempt with no seal yet. `unreadable` is an attempt whose artifact exists but could not be parsed or validated. `missing` is an attempt derived from a schema-2 outcome whose prepared artifact is absent; such an entry is reported with its reason and never becomes the bound current review. The revision object carries `review_requirement` as `{state, reason, value, revision_id, decision_id, inherited_from_revision}`. Work, retro, the TUI, and the coordinator read this one derivation and keep no folds of their own. Full review bodies travel under store-relative references and survive archive; there is no private fallback. Legacy schema-1 outcomes project as legacy-unbound.

### Results

Verb: `lore criteria run`. Writer: `scripts/criteria-run.sh`. It alone appends `results.jsonl` and creates immutable output and recovery artifacts under `results/<result-id>/`.

**Invocation.**

```
lore criteria run <slug> <task-id> <criterion-id> --execution-worktree <root> --packet-id <id> [--revision <rid>] [--dispatch-attempt-id <id>]
lore criteria run <slug> <task-id> <criterion-id> --execution-worktree <root> --revision <rid> --unbound-reason "<text>"
lore criteria run <slug> [<task-id> <criterion-id>] --recover <result-id>
```

`--json` is accepted. On successful publication or recovery, stdout is one JSON object: `{"schema_version":1,"status":"published"|"recovered","result":<row>}`. Refusals and publication failures emit diagnostic JSON on stderr and may produce no stdout. The allocated result ID and execution-attempt ID are printed as a JSON object on stderr before launch. Exit status is 0 for pass or skipped, 1 for fail, 2 for unavailable, and 3 for refused or a publication error. Platform support is POSIX (Bash and Python, `flock`, process groups, `fsync`); Windows is unsupported, and code identity is unavailable when Git or the source root cannot be inspected.

**No imported results.** The verb accepts identity and placement inputs only. There is no command, output, state, exit, result, or skip override and no generic append or import. Task and criterion resolve from the selected immutable revision. A referenced schema 2 packet fixes work item, task, revision, and dispatch attempt; any optional identity flags supplied alongside must agree with it. Outside dispatch, the caller selects a revision and execution worktree and supplies the unbound reason. An explicitly selected historical revision remains selected; the current head is never substituted. Selection errors are reported before any result ID is allocated.

**Criterion definition.** Stable criterion ID, intent text, exact argv, worktree-relative cwd, timeout, expected exit, and an optional applicability predicate with its own argv, cwd, timeout, and distinct exits for applicable and inapplicable. The criterion version is a hash of the complete canonical definition, covering argv, cwd, timeout, expected exit, and applicability, and excluding generated version metadata. The generator retains the definition and version, and each result row carries the full definition it executed.

**Execution.** Exact argv with no shell; a criterion may name one explicitly. cwd is resolved inside the execution root, including through symlinks. stdin is `/dev/null`. stdout and stderr share a single pipe and are captured as one combined byte stream with no channel labels, retained with a path and SHA-256. Start and end code identities are recorded around the run. The POSIX process group is terminated at timeout or on interruption, followed by a finite 0.5-second pipe drain so escaped descendants cannot hold the supervisor indefinitely; processes that started their own session cannot be killed through the original group. An inaccessible source root records `unavailable`. The applicability predicate runs with its own exact argv, cwd, timeout, and distinct exits and its own retained output: an observed inapplicable exit records `skipped` and the command does not run, an observed applicable exit lets the command run, and every other predicate outcome records `unavailable`.

**Execution sequence.** Each new run allocates an immutable positive integer `execution_sequence` under the results directory lock. The allocated value is one plus the highest sequence retained across both the item's immutable result input journals and its canonical published results ledger, so a missing older result directory cannot cause its published sequence to be reused; invalid history is refused rather than repaired. It is not caller-selectable. The reader validates sequences and selects the latest attempt per criterion by greatest sequence, independent of finish, publication, or recovery order. Legacy rows without a sequence keep ledger order and precede sequenced rows. Recovery keeps the original sequence unchanged. Row references and result history are unchanged by the sequence.

**States at write time.** `pass` only after the process exits as expected with no signal or timeout and durable output. `fail` on nonmatching exit, signal, or timeout. `skipped` only on an observed inapplicable predicate exit. `unavailable` on launch, cwd, or output-persistence failure, on an inaccessible source root, on any undeclared predicate outcome, on supervisor interruption, and for an interrupted attempt with no durable completion. `unavailable` is observed evidence that execution could not provide a usable criterion outcome, not an absence of evidence; retained launch, interruption, and output facts may exist alongside it. At read time `missing` and `unreadable` remain distinct from all four.

**Row fields, schema 1.** `schema_version`, `result_id`, `execution_sequence`, `execution_attempt_id`, `dispatch_attempt_id`, `packet_id`, `unbound_reason`, `task_id`, `criterion_id`, `criterion_version`, `revision_id`, the full criterion definition, `argv`, `cwd`, `resolved_cwd`, `exit`, `signal`, `timed_out`, `duration_ms`, `output_path`, `output_sha256`, `applicability` as `{definition, observation}` or null, `source_start`, `source_end`, `source_head`, `worktree_digest`, `digest_version`, `timestamp`, `completed_at`, `state`, `reason`. `argv` is the selected plan-owned command and `resolved_cwd` is the resolved placement when it was available; neither asserts that a child process launched on unavailable or skipped paths, which `state` and the applicability observation record.

**Recovery.** Each run persists `inputs.json`, `started.json`, process records, and `completion.json` beneath `results/<result-id>/`. Durable completion precedes the ledger append, and an exact publication retry repairs its own torn prefix without rerunning. `--recover <result-id>` replays the persisted inputs and launches nothing; optional identity flags supplied with it must match the immutable inputs, and it refuses conflicting inputs or a changed durable output. It cannot proceed while the supervisor still holds the attempt lock. The recovered row keeps its original `execution_sequence`. An interrupted attempt without completion records `unavailable` and retains the observed start identity when available; a new execution requires a new run, a new result ID, and a new sequence. A ledger failure leaves the completion available for recovery. Per-criterion attempt allocation is locked, no plan publication lock is held during execution, and row and output are immutable after publication.

**Code digest, version 2.** Result code identities use `digest_version` `2`: a canonical SHA-256 over index entries (staged object IDs and modes), tracked working-tree bytes, modes, deletions, and symlink targets, recursive submodule state, and non-ignored untracked files. Git internals are omitted. When the ledger lives inside the execution root, the digest excludes this result's own directory and removes only this result ID's row bytes from `results.jsonl`; an otherwise empty untracked ledger is treated as absent, while older or malformed ledger bytes and tracked index metadata are retained. The writer and the freshness reader use the same algorithm, recursively. Ordinary and review identities retain version 1, and historical version 1 results keep their original algorithm for freshness. There is no arbitrary exclusion flag. Generated files participate and may conservatively make a result stale; they are not excluded to obtain a pass.

**Freshness.** A changed start or end identity, a later source HEAD or worktree digest, or a criterion or revision mismatch is surfaced as stale. An unavailable live root means freshness unknown. Current freshness applies to pass, fail, skipped, and unavailable records alike; only a current pass supports a current passing check, and neither a stale nor an unknown record ever does.

**Boundaries.** Criterion adequacy and combined coverage of the original anchor are authored reviewer judgments recorded with result IDs. No result has acceptance, checkoff, archive, or terminus authority; the verb never checks off tasks, accepts reports, archives work, or declares anchor coverage.

## Invariants across records

- One physical writer per file. Existing writers stay authoritative and are composed, never bypassed.
- Readers never append and never regenerate.
- Records never change when the revision head moves; freshness is derived, not rewritten.
- Every hash boundary is declared and versioned in the record that uses it.
- No producer changes shape before a reader can read it, and each reader change lands in the same commit as its contract prose and behavioral tests.