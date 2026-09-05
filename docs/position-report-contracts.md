# Position report contracts

This reference holds the write-back shapes the four position briefs under `agents/positions/` point at. A brief stays short by naming a label and its reader; this file carries the label set, the writer for each artifact, and the legacy vocabulary some writers still require. Every label below has a live reader, so a label that changes spelling, casing, or trailing colon stops being read.

Readers match labels literally. A bold section label is `**Label:**` at the start of a line. The worker report's `Task` label is accepted plain (`Task:`) or bold (`**Task:**`) by the report checker and by both chaperone parseability gates; the other labels are read in the form shown.

## Worker report, schema 1

Header lines, plain, one per line, in this order:

```
Report-schema: 1
Report-id: <assigned at dispatch; the file lands at worker-reports/<report-id>.md>
Work-item: <slug>
Task: <task subject>
Producer-role: worker
Dispatch-path: <harness-subagent | codex-chaperone | worker-session>
Harness: <claude-code | codex | opencode>
Status: <completed | blocked | degraded>
Template-version: <12-hex version of the brief the worker was compiled from>
```

The path is the report's identity; the header restates context for a reader who has only the file. `Status` values stay distinct: `blocked` when Blockers is non-empty, `degraded` when the task shipped with a named capability gap, `completed` otherwise.

| Section | Content | Reader |
|---|---|---|
| `**Artifacts:**` | YAML list, one entry per durable artifact, each with `path`, `kind`, `writer`, `identity`. The typed collector reads the file at `path` and checks `identity` by kind: `kind: source` takes a bare commit hash that holds the file (`git cat-file -e <hash>:<path>` under the execution root) or the exact path itself — a prose composite such as "branch X, commit Y, sha256 Z" is refused; `kind: tier2-claims` names `task-claims.jsonl` with `writer: evidence-append.sh` and a claim ID listed under Tier 2 evidence; `kind: result` (or any identity beginning `result-`) names a `results.jsonl` row with `writer: criteria-run.sh`, and every `result-` ID cited under Checks must appear here. | Coordinator acceptance reads the artifacts the manifest points at, not the manifest; the typed collector refuses a missing file or an identity of the wrong shape. |
| `**Changes:**` | `<file>: <what changed>` per touched file. | Lead's execution-log reduction; retro `cycle_work`. |
| `**Checks:**` | One entry per check: the uncertainty, what was read or run, what it showed. Executed criteria are cited by result ID. `None — <why>` is complete. | Coordinator acceptance; the log reduction's `Test result` line. |
| `**Skills used:**` | Comma-separated skill names or `None`. | Log reduction. |
| `**Observations:**` | YAML list; each entry carries `claim`, `file`, `line_range`, `exact_snippet`, `normalized_snippet_hash`, `falsifier`, `significance`, and optionally `context_before`, `context_after`, `symbol_anchor`, `extends_observation`. `- claim: "None"` is a complete block. | Log reduction; capture selection. Anchors here are unvalidated until a canonical row carries them. |
| `**Tier 2 evidence:**` | A YAML list of claim IDs (`- <claim-id>` per line) or the single word `none`. Rows already live in `task-claims.jsonl`; no row bodies here. The typed collector parses this block as YAML and requires a list of strings, so bare IDs without the `- ` bullet fail typed completion even though the legacy `check-report` reader accepts them. | Report checker joins each ID against the canonical file and refuses a missing one; the typed collector additionally requires each row's `task_id` and `producer_role: worker` to match the attempt. |
| `**Tier 3 candidates:**` | Optional. YAML list of reusable claims with `claim_id`, `tier: reusable`, `claim`, `producer_role`, `protocol_slot`, `scale`, `why_future_agent_cares`, `falsifier`, `related_files`, `source_artifact_ids` (non-empty, each an ID listed under Tier 2 evidence), `work_item`, `captured_at_sha`. | Promotion through `lore promote`; the label is matched literally and no alias is read. |
| `**Narrative:**` | Optional prose for synthesis that fits no field. | Coordinator and retro readers. |
| `**Convention handling:**` | `honored: <label>[ — rationale]` or `diverged: <label> — <why>` per woven norm, or `none in scope` when none was woven. | Report checker completeness; conformance render. |
| `**Surfaced concerns:**` | Off-scale concerns with a path when known, or `None`. | `write-execution-log.sh` forwards a non-`None` payload to the off-scale writer. |
| `**Investigation:**` | Optional: what was expected, what was found, what was done. | Log reduction. |
| `**Consultations:**` | Optional. One entry per consultation sent: `consultation_id`, `handler` (`lead`, `skill`, `agent`), `domain`, `advisor_template_version` when handler is `agent`, `skill_template_version` when handler is `skill`, `query_summary`, `advice_summary`, `was_followed`, `rationale_if_not_followed` when false. | Report checker joins required domains against the consultation ledger; the advisor rollup reads `handler: agent` entries. |
| `**Blockers:**` | `none` or what blocks. | Coordinator; close scans the literal label. |
| `**Spend:**` | Chaperone-relayed only: the closed spend vocabulary as `key=value`, duration-only when degraded. Native workers carry none. | Lead copies it to a `Spend: task=<id>` log line; close joins it to task attribution. |

Observations are a discovery surface, not a quota. A compiled-position report with `- claim: "None"` under Observations and `None` under Surfaced concerns is complete when nothing stood out; a reusable insight goes to `lore capture` at the moment of discovery and is not repeated here. The legacy stamped-report branch of the native completion hook still requires at least one structured observation; that requirement belongs to reports produced from `agents/worker.md`, and the compiled-position completion branch reads the version marker to tell the two apart.

## Investigator report

```
**Question:** <the question as assigned>
Template-version: <12-hex version of the compiled brief>
**Findings:**
- <finding>
**Key files:** <absolute paths>
**Implications:** <how the findings bear on the design>
**Assertions:**
- claim / file / line_range / exact_snippet / normalized_snippet_hash / falsifier / significance, plus optional anchors
**Observations:** <mechanism, rationale, structural footprint; None when nothing stands out>
**Narrative:** <optional>
**Worker leads:** <one-sentence implementation-level items with path:line when known, or None>
**Unknowns:** <what the question left unanswered>
```

Findings are copied verbatim into the plan's Investigations section by the spec collector. Assertions become Tier 2 rows through `evidence-append.sh`; there is no assertion count on the compiled path, and an assertion without a falsifier is an observation. Worker leads route through `write-execution-log.sh` to the off-scale writer. Unknowns are read by whoever plans next.

The typed collector (`scripts/task-completed-capture-check.sh`) reads the landed report at the destination the manifest assigned and applies these constraints before the spec collector accepts anything; each one has refused real reports:

- Every label above except Narrative is present and non-empty. `None` is a complete value for Assertions, Observations and Worker leads.
- **Key files** is parsed as YAML and must be a list of existing **absolute** file paths (one path may be given as a plain string). A `path:line` suffix makes the path not exist and is refused; put line references in Findings or Implications. `None` is accepted when the question touched no file.
- Each grounded assertion is a mapping with non-empty string `claim`, `file`, `line_range`, `exact_snippet`, `normalized_snippet_hash` and `falsifier`, and a `significance` that is exactly `low`, `medium` or `high`. Prose in `significance` is refused; explanatory weight belongs in `implications` or `why_this_work_needs_it`. An entry with no `falsifier` is an observation and is not matched to a row.
- Each grounded assertion must match exactly one canonical row in `task-claims.jsonl` for this attempt: `producer_role: researcher`; `task_id` equal to the bound task when the manifest binds one, otherwise `report_id` and `dispatch_attempt_id` equal to the manifest's; the same `claim`, `line_range`, `exact_snippet`, `normalized_snippet_hash`, `falsifier` and `significance`. The row's `file` is resolved under the execution root, its `captured_at_sha` must be a commit in that root, and `exact_snippet` must occur within `line_range` of that file at that commit — a snippet from an uncommitted edit, or a `file` outside the root, is refused as a source-anchor mismatch.
- Observations, when not `None`, is a YAML list of mappings carrying the same seven fields with the same `significance` enum.
- The optional restated headers (`Report-id`, `Work-item`, `Packet-id`, `Revision-id`, `Dispatch-attempt-id`, `Producer-role: investigator`) must equal the assigned values when present; the three required headers are `Template-version`, `Position-dispatch-manifest` and `Position-dispatch-sha256`.

A report that passes typed completion, in outline:

```
**Question:** Which writer lands compiled reports?
Template-version: 1f2e3d4c5b6a
Position-dispatch-manifest: /store/_work/item/position-dispatch/spec-a1b2/manifest.json
Position-dispatch-sha256: <64 lowercase hex>
**Findings:**
- coordinate-report.sh lands the body at worker-reports/<report-id>.md and refuses an existing path (scripts/coordinate-report.sh lines 40-58).
**Key files:**
- /checkout/scripts/coordinate-report.sh
**Implications:** Retries need a fresh report id.
**Assertions:**
- claim: "coordinate-report.sh refuses an existing report path"
  file: scripts/coordinate-report.sh
  line_range: "52-54"
  exact_snippet: "exit 4"
  normalized_snippet_hash: <sha256 of the normalized snippet>
  falsifier: "the writer overwrites an existing report path"
  significance: medium
**Observations:** None
**Worker leads:** None
**Unknowns:** Whether native transport returns the final message reliably.
```

The same report fails typed completion when `Key files` reads `/checkout/scripts/coordinate-report.sh:52`, when `significance` reads `medium — the retry contract depends on it`, when `Key files` uses a path relative to the checkout, or when the canonical row for the assertion was appended under `producer_role: spec-lead` or with a `task_id` other than the investigation id the pre-plan row must carry.

## Designer outputs

**Planning mode** writes into the work item: the choice, its reason, the assumption it rests on, the alternative rejected, and any explained open question with what would close it. Plan changes publish through `lore plan revise --author-role designer`. Design records stay in the work item as dated history and are indexed by `lore why` and `lore tradeoffs`; no knowledge entry is minted for a decision. A bound planning attempt also lands a short design record at its `report_path` through `lore coordinate report`, so the seat can check which brief produced the design: the header lines `Template-version:`, `Position-dispatch-manifest:` and `Position-dispatch-sha256:` (taken from the envelope and the digest the designer computes, exactly as an investigator does), then `**Revision:**` naming the published revision id, `**Decisions:**`, `**Open questions:**` and `**Tier 2 evidence:**` as a YAML list of claim ids or `none`. The typed collector reads worker and investigator positions only, so a design record is checked by the seat's header comparison against its held reference and by reading the published revision; nothing types a completion row for it.

**Consultation mode** replies to the requesting worker:

```
consultation-id: <verbatim from the worker's ## Consultation request>
handler: agent
advisor_template_version: <12-hex version of the compiled designer brief>
advisor-acknowledged: true
**Domain:** <domain>
**Guidance:** <concrete guidance: files, functions, constraints>
**Key files:**
- <path>
**Cautions:** <domain invariants the approach would meet; omit when none>
```

The four header lines are required. The worker copies `consultation_id`, `handler`, and `advisor_template_version` into its Consultations entry; the lead files the reply through `impl-consult-log.sh` and matches `advisor-acknowledged: true` against the task's required domains; `advisor-impact-rollup.sh` groups the worker's `was_followed` by `advisor_template_version`. That version identifies the answering brief and stays distinct from the reviewed producer's version and from the lead's filing version.

## Reviewer outputs

A review attempt is prepared by `lore plan review prepare` and sealed once by `lore plan review seal`:

- `output.md`: the review in prose.
- `dispositions.json`, schema 1: `outcome` (`completed | failed | skipped | needs-decision`), `verdict`, `reason` (null unless skipped or needs-decision), `judgments` as `{purpose, judgment, rationale, result_ids}` with the prepared purpose present, and `dispositions` as `{finding, disposition, reason}`.
- Evaluator manifest: `{evaluator_locator, evaluator_template_version, framework, model, final_round}`, where the template version is the compiled reviewer brief's 12-hex version.

Seal validates each cited result ID against `results.jsonl` and freezes the rows into `cited-results.json`. Empty `result_ids` records that no execution evidence was cited. The ledger carries no executor state and creates no result row. Filing confers no acceptance, checkoff, archive, or anchor-coverage authority; those are authored decisions recorded with `lore plan revise --decision-for`.

## Writers and identities

| Artifact | Sole writer | Identity a reader checks |
|---|---|---|
| `worker-reports/<report-id>.md` | `scripts/coordinate-report.sh` (`lore coordinate report`) | The path; write-once, a reused id is refused |
| `task-claims.jsonl` | `scripts/evidence-append.sh`, validated by `scripts/validate-tier2.sh` | `claim_id` |
| `results.jsonl` and `results/<result-id>/` | `scripts/criteria-run.sh` (`lore criteria run`) | `result_id`, with revision and criterion version |
| Knowledge entries | `scripts/capture.sh` (`lore capture`) | Entry path |
| Verification and correction events | `scripts/verify-append.sh` (`lore verify`) | Event id on the entry and the trust ledger |
| Corroborations and settlements | `scripts/corroborate-append.sh` (`lore claim`) | Entry `corroborations[]` and `kind_status` |
| `reviews/<attempt-id>/` | `scripts/plan-review.sh` (`lore plan review`) | Attempt id and seal hashes |
| `consultation-transcript.jsonl` | `scripts/impl-consult-log.sh` | `consultation_id` and domain |
| `execution-log.md` | `scripts/write-execution-log.sh` | Entry timestamp, and `Report-key` on legacy paths |
| Promoted commons rows | `scripts/lore-promote.sh` (`lore promote`) | Entry path and `source_artifact_ids` |
| Packets | `scripts/packet-append.sh` | `packet_id`, with `revision_id` and `dispatch_attempt_id` on schema 2 |

A file a position wants to change and does not find here is written through the verb that owns it, or reported as a gap. Snippet hashes for Tier 2 rows come from `scripts/snippet_normalize.py`.

## The dispatch reference on Tier 2 rows

A compiled attempt is identified by its dispatch manifest: the absolute path of the `manifest.json` the binder published for it and that file's sha256. The report carries the pair as the header lines `Position-dispatch-manifest:` and `Position-dispatch-sha256:`; the wrapper for your route says where the two values come from (the envelope's `position_dispatch.manifest_path` and a digest you compute, or the two environment variables on a session). A Tier 2 row from a compiled attempt carries the same pair as one optional object field:

```
"position_dispatch": {"manifest_path": "<the Position-dispatch-manifest value>", "manifest_sha256": "<the Position-dispatch-sha256 value>"}
```

Copy both values from the same place your report headers take them. Do not derive them from the brief you are reading or from any template on disk: the readers resolve the pair against the immutable manifest and check that it binds this work item and, when the manifest binds a plan task, that the row's `task_id` is exactly that task; only when the manifest's producer is the investigator position and it binds neither task nor revision, the pre-plan case, the row keeps its investigation label and must carry the manifest's exact `report_id` and `dispatch_attempt_id`; every other position takes the exact-task test, and a pair that does not resolve or a row that fails its test reads as unknown attribution, never as some current template's version. `validate-tier2.sh` checks only the shape of the field; `evidence-append.sh` resolves it and stores the projection beside the row; a row without the field is a legacy row and is read as before. The `producer_role` on the row keeps the mapping in the next section; a row whose role disagrees with the position the manifest records is stored with unknown attribution and its reason, not refused, so the claim survives and the mismatch stays visible. Every position emits the field the same way: investigator assertions, designer rows in either mode, reviewer rows, worker claims. A consultation reply carries no pair of its own; the lead files the designer's reference from the bound consultation attempt when it logs the reply.

## Legacy producer roles at the writer boundary

`scripts/validate-tier2.sh` accepts `producer_role` values `researcher`, `worker`, `advisor`, `spec-lead`, and `implement-lead`. `lore verify` and the session terminus accept the position names directly. The mapping at the Tier 2 boundary is:

| Position and mode | `producer_role` on Tier 2 rows | `--source` on `lore verify` |
|---|---|---|
| investigator | `researcher` | `investigator` |
| designer, planning mode | `spec-lead` | `designer` |
| designer, consultation mode | `advisor` | `designer` |
| worker | `worker` | `worker` |
| reviewer | `advisor` | `reviewer` |

The mapping changes no canonical vocabulary and gives the legacy names no added authority. It exists because rows written under the old names remain readable and the writer's accepted set was not widened at the prose step.
