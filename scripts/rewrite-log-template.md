# Rewrite Log: <skill>

<!--
Phase 2 workers copy this template to
$KDIR/_work/<cycle-slug>/rewrite-logs/<skill>.md
and replace the placeholder rows below. Workers MUST NOT edit the schema
itself — column names, header text, and the two top-level sections are part
of the verifier contract enforced by check-skill-rewrite.sh.

Filling out the template:
  * Preserve-trace header: one bullet per cat-2 stance phrase that survives
    in the rewritten SKILL.md. Include the audit row_id, the verbatim
    phrase (in straight quotes), and the new heading anchor where it lives
    after the rewrite.
  * Disposition log: one row per audit row_id, exactly once. The columns
    are checked by the verifier — see legend below.

Column legend:
  row_id                            — verbatim from the audit table
  applied_disposition               — one of:
                                        preserve_verbatim
                                        preserve_or_tighten
                                        collapse_to_canonical
                                        delete_candidate
                                        handoff_review
                                        moved_to_sidecar
  new_anchor_or_DELETED_or_MERGED   — one of:
                                        `## Heading::¶N`            (preserved/tightened in place)
                                        DELETED                       (delete_candidate)
                                        MERGED:<file:line_range>      (collapse_to_canonical — use the audit row's
                                                                       canonical_site value verbatim, e.g.
                                                                       MERGED:skills/<skill>/SKILL.md:401)
                                        `## Heading::¶N` (preserved in place)   (handoff_review)
                                        SIDECAR:<relative-path>       (moved_to_sidecar — path is relative to the
                                                                       SKILL.md's parent directory, e.g.
                                                                       SIDECAR:templates/report-shape.md. The
                                                                       verifier resolves the path and routes
                                                                       check (a) substring matches for this row
                                                                       to that file instead of the rewritten
                                                                       SKILL.md; a missing sidecar file is a
                                                                       hard check (a) failure)
  note                              — `none` is acceptable EXCEPT when:
                                        * applied_disposition == handoff_review
                                        * applied_disposition == moved_to_sidecar — the note MUST name the
                                          on-demand load condition (the SKILL.md prose pointer or workflow
                                          step that instructs an agent to read the sidecar)
                                        * applied_disposition differs from the default the routing rules
                                          assign to this row's (primary_category, flags,
                                          failure_vocab_role, canonical_site) combination — the verifier
                                          computes the default and compares against your applied value
                                        * the row's audit excerpt is a path:line_range reference only
                                          (no inline prose to grep), so check (a) emits a warning for it;
                                          the note records how the reviewer should sample the rewritten
                                          anchor
                                      In those cases the verifier requires non-empty text — name the
                                      pattern, explain why the divergence is justified, or describe the
                                      reviewer-sampling target.
-->

## Preserve-trace header

- Stance phrase 1 (cat-2 verbatim from `<skill>-RNNN`): "<verbatim phrase>" — present at `## Heading::¶N`
- Stance phrase 2 (cat-2 verbatim from `<skill>-RNNN`): "<verbatim phrase>" — present at `## Heading::¶N`

## Disposition log

| row_id | applied_disposition | new_anchor_or_DELETED_or_MERGED | note |
|---|---|---|---|
| <skill>-R001 | preserve_verbatim | `## Heading::¶1` | none |
| <skill>-R002 | delete_candidate | DELETED | none |
| <skill>-R003 | collapse_to_canonical | MERGED:skills/<skill>/SKILL.md:401 | none |
| <skill>-R007 | handoff_review | `## Heading::¶3` (preserved in place) | Pattern B — cross-skill canonical to [[knowledge:...]] |
| <skill>-R012 | moved_to_sidecar | SIDECAR:templates/report-shape.md | on-demand load — Step 6 instructs worker to "Read templates/report-shape.md before emitting the completion report" |
