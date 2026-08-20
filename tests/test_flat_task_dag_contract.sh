#!/usr/bin/env bash
# test_flat_task_dag_contract.sh — Pin the flat task-DAG plan grammar across the
# spec skill, the plan template, the implement skill, and both worker templates.
#
# Only true protocol constants are pinned: tokens parsed by code or compared
# verbatim across surfaces. Surrounding prose is deliberately NOT pinned —
# wording may drift freely as long as these tokens survive.
#
# Every group pairs presence pins for the flat task-unit vocabulary with
# absence pins for the phase-container vocabulary it replaces. A positive-only
# check passes with BOTH forms present, which is exactly the failure a
# removal-shaped change exists to prevent: a half-migrated surface still
# teaches the phase grammar to whoever reads it next.
#
# All matches run against a whitespace-flattened copy of the file. These
# templates are hard-wrapped, so a phrase that survives an edit intact still
# fails a line-oriented fixed-string assertion.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC_SKILL="$REPO_DIR/skills/spec/SKILL.md"
PLAN_TEMPLATE="$REPO_DIR/skills/spec/templates/plan.md"
IMPLEMENT_SKILL="$REPO_DIR/skills/implement/SKILL.md"
WORKER_MD="$REPO_DIR/agents/worker.md"
CODEX_WORKER_MD="$REPO_DIR/agents/codex-worker.md"

PASS=0
FAIL=0

flatten() {
  tr '\n' ' ' <"$1" | tr -s ' '
}

assert_prose_contains() {
  local label="$1" file="$2" pattern="$3"
  if flatten "$file" | grep -qF -- "$pattern"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    File:    $file"
    echo "    Missing: $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_prose_contains_i() {
  local label="$1" file="$2" pattern="$3"
  if flatten "$file" | grep -qiF -- "$pattern"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    File:    $file"
    echo "    Missing (case-insensitive): $pattern"
    FAIL=$((FAIL + 1))
  fi
}

assert_prose_lacks() {
  local label="$1" file="$2" pattern="$3"
  if flatten "$file" | grep -qF -- "$pattern"; then
    echo "  FAIL: $label"
    echo "    File:               $file"
    echo "    Should not contain: $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

assert_prose_lacks_i() {
  local label="$1" file="$2" pattern="$3"
  if flatten "$file" | grep -qiF -- "$pattern"; then
    echo "  FAIL: $label"
    echo "    File:               $file"
    echo "    Should not contain (case-insensitive): $pattern"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

echo "=== Flat Task DAG Contract Tests ==="
echo ""

echo "Test 1: the plan template authors tasks directly"
# `## Tasks` is the section the flat generator branch scans for. If it drifts,
# a flat plan matches neither branch and generation refuses the whole document.
assert_prose_contains "plan template opens the unit list with '## Tasks'" \
  "$PLAN_TEMPLATE" "## Tasks"
# `### Task N:` is the per-unit heading that discriminates the flat branch from
# the legacy one. Drift here routes a flat plan down the legacy path, which
# then finds no phase headings and emits an empty task list.
assert_prose_contains "plan template shows the '### Task N:' unit heading" \
  "$PLAN_TEMPLATE" "### Task 1:"
# `**Deliverable:**` is a required task block. A template that stops showing it
# produces plans the generator rejects for a missing required block.
assert_prose_contains "plan template shows the required Deliverable block" \
  "$PLAN_TEMPLATE" "**Deliverable:**"
# `**Files:**` is the authoritative owned surface: worker brief, work-item
# matching, and file-overlap chaining all read it. Losing it from the task
# block means a task with no declared file target, which generation refuses.
assert_prose_contains "plan template shows the task-level Files block" \
  "$PLAN_TEMPLATE" "**Files:**"
# `**Scope:**` re-homes to the task, where its do-not-modify declarations
# already belonged. Losing it drops the only place a task fences off files.
assert_prose_contains "plan template shows the task-level Scope block" \
  "$PLAN_TEMPLATE" "**Scope:**"

echo ""
echo "Test 2: the phase container is gone from the authoring template"
# The old section heading. Left in place, plan authors keep writing phase-shaped
# plans that route down the legacy branch and never exercise the flat one.
assert_prose_lacks "plan template no longer heads a '## Phases' section" \
  "$PLAN_TEMPLATE" "## Phases"
# The old unit heading. A template showing both headings teaches a mixed
# document, which generation rejects outright before writing any output.
assert_prose_lacks "plan template no longer shows a '### Phase N:' unit heading" \
  "$PLAN_TEMPLATE" "### Phase 1:"
# `**Objective:**` was the phase's own block; the task block list replaces it
# with `**Deliverable:**`. Keeping both leaves authors guessing which one the
# generator reads, and only one of them is parsed.
assert_prose_lacks "plan template no longer shows the phase Objective block" \
  "$PLAN_TEMPLATE" "**Objective:**"
# `**Split rationale:**` was scoped to a multi-task phase. That scoping is gone
# with the container; the rationale requirement itself is re-pinned in Test 4.
assert_prose_lacks_i "plan template no longer scopes rationale to a multi-task phase" \
  "$PLAN_TEMPLATE" "multi-task phase"
# Backstop for the three pins above and for every remaining phase mention in the
# template — the one-phase-per-plan default, the per-phase Knowledge context
# note, the Applies-to line. The template is the default flat-form surface, so
# any surviving phase vocabulary here is a half-migrated grammar.
assert_prose_lacks_i "plan template names no phase anywhere" \
  "$PLAN_TEMPLATE" "phase"

echo ""
echo "Test 3: the two conjunctive sizing gates are gone from the spec skill"
# Both named rules are deleted outright. A surviving name keeps the two-level
# calculus reachable: the spec author reads a phase rule with no phase to apply
# it to and either invents a container or writes one task by default.
assert_prose_lacks "spec SKILL no longer states the Plan-as-unit rule" \
  "$SPEC_SKILL" "Plan-as-unit rule"
assert_prose_lacks "spec SKILL no longer states the Phase-as-unit rule" \
  "$SPEC_SKILL" "Phase-as-unit rule"
# The two conjunction stems. These are the shape that ratchets toward one unit:
# a gate every split must clear with merge as the free default.
assert_prose_lacks "spec SKILL no longer gates a split on 'only when all three'" \
  "$SPEC_SKILL" "only when all three"
assert_prose_lacks "spec SKILL no longer gates a split on 'only when all four'" \
  "$SPEC_SKILL" "only when all four"
# The two unpriced merge defaults the band replaces. Left in place, the merge
# side still costs nothing to choose and the band is two-sided in name only.
assert_prose_lacks "spec SKILL no longer defaults to merge on a failed condition" \
  "$SPEC_SKILL" "If any condition fails, merge."
assert_prose_lacks "spec SKILL no longer defaults to one task on a failed condition" \
  "$SPEC_SKILL" "If any condition fails, keep one task."
# Deleted split conditions. Cross-phase parallelism has no referent once the
# container is gone; the architectural checkpoint re-homes onto the output
# contract plus the dependency edge pinned in Test 5.
assert_prose_lacks_i "spec SKILL no longer names cross-phase parallelism" \
  "$SPEC_SKILL" "cross-phase parallelism"
assert_prose_lacks_i "spec SKILL no longer names the architectural checkpoint condition" \
  "$SPEC_SKILL" "architectural checkpoint"
# The tuning claim names a loop with no captured dependent variable. Restating
# it sends a later reader looking for a rework-attribution feedback path that
# was never built.
assert_prose_lacks "spec SKILL no longer claims task size is empirically tuned" \
  "$SPEC_SKILL" "empirically tuned via the (class, model, size) rework attribution"

echo ""
echo "Test 4: one two-sided sizing band is stated at task level"
# "design center" is the band's currency — the coined term that decides whether
# a deliverable is one unit or several. Without it the band has no stated
# center and reduces to an unfalsifiable size preference.
assert_prose_contains_i "spec SKILL names the design center as the band's currency" \
  "$SPEC_SKILL" "design center"
# Both directions must be argued in writing. Dropping either side restores the
# asymmetry the band exists to remove: whichever direction goes unpriced becomes
# the free default the author lands on.
assert_prose_contains_i "spec SKILL requires a split rationale" \
  "$SPEC_SKILL" "split rationale"
assert_prose_contains_i "spec SKILL requires a merge rationale" \
  "$SPEC_SKILL" "merge rationale"
# The hard bounds survive the band and are not weighable against it. No residue
# bounds task size from below; the context envelope bounds it from above and is
# the only condition that forces a split on its own.
assert_prose_contains_i "spec SKILL keeps the no-residue floor" \
  "$SPEC_SKILL" "no residue"
assert_prose_contains_i "spec SKILL keeps the context-envelope ceiling" \
  "$SPEC_SKILL" "context-envelope ceiling"
# The task block vocabulary has to reach the spec author, not only the template:
# the skill is what the author reads while decomposing.
assert_prose_contains "spec SKILL names the required Deliverable block" \
  "$SPEC_SKILL" "**Deliverable:**"

echo ""
echo "Test 5: the dependency marker and the output contract are documented"
# `[depends-on: task-N]` is fully implemented in the generator and parsed into
# `blockedBy`, but appears on no authoring surface. Unpinned, the authoring
# surface silently regresses to having no way to express a non-file dependency,
# and ordering that the scheduler could enforce goes back into free prose.
assert_prose_contains "spec SKILL documents the depends-on marker" \
  "$SPEC_SKILL" "[depends-on: task-"
assert_prose_contains "plan template documents the depends-on marker" \
  "$PLAN_TEMPLATE" "[depends-on: task-"
# `- Output contract:` is the producer's acceptance declaration inside `**Scope:**`
# — what this task fixes and later tasks may rely on. It carries the checkpoint
# function that the deleted split condition used to carry, so it has to be
# reachable from the skill and not just the template.
assert_prose_contains "spec SKILL documents the output-contract declaration" \
  "$SPEC_SKILL" "Output contract"
assert_prose_contains "plan template documents the output-contract declaration" \
  "$PLAN_TEMPLATE" "- Output contract:"

echo ""
echo "Test 6: verification is the plan's acceptance bar"
# The block survives; only its altitude changes. Losing it drops the plan's
# acceptance bar entirely.
assert_prose_contains "plan template keeps the Verification block" \
  "$PLAN_TEMPLATE" "**Verification:**"
# The suite-shaped-bar anti-pattern text is preserved through the move. Without
# it, a plan-level bar invites "all tests pass", which pushes suite-level
# certification back onto every worker.
assert_prose_contains "plan template keeps the suite-shaped-bar anti-pattern" \
  "$PLAN_TEMPLATE" "suite-shaped bar"
# The phase-scoped wording of that anti-pattern. Left as-is, the bar still reads
# as a per-unit obligation, which is the per-worker amplification the move
# exists to prevent.
assert_prose_lacks "plan template no longer scopes the bar to THIS phase's surface" \
  "$PLAN_TEMPLATE" "THIS phase's changed surface"
# The spec skill's routing line for invalid units sends "Verify X" to a
# phase-level objective. With no phase level, that route dead-ends.
assert_prose_lacks "spec SKILL no longer routes verification to a phase-level block" \
  "$SPEC_SKILL" "phase-level \`**Verification:**\`"

echo ""
echo "Test 7: required consultations key on the task"
# `**Consultations required:**` is compared verbatim across the template, the
# implement skill's blocking acknowledgement check, and the worker report
# contract. Drift on any one surface silently disables the gate.
assert_prose_contains "plan template keeps the Consultations required block" \
  "$PLAN_TEMPLATE" "**Consultations required:**"
assert_prose_contains "implement SKILL keeps the Consultations required literal" \
  "$IMPLEMENT_SKILL" "**Consultations required:**"
assert_prose_contains "worker.md keeps the Consultations required literal" \
  "$WORKER_MD" "**Consultations required:**"
# The block's phase framing. While the implement skill sources these domains
# from a phase brief, the blocking check has no key for a flat task and every
# required consultation on a flat plan goes unenforced.
assert_prose_lacks_i "implement SKILL no longer sources required domains from a phase brief" \
  "$IMPLEMENT_SKILL" "phase brief"
assert_prose_lacks_i "worker.md no longer calls required consultations a phase-level declaration" \
  "$WORKER_MD" "phase-level declaration"

echo ""
echo "Test 8: the implement lead composes briefs without a phase index"
# The removed verb. Every surface that still names it instructs an agent to run
# a command that no longer exists — an immediate non-zero exit mid-dispatch.
assert_prose_lacks "implement SKILL no longer invokes lore work phase-context" \
  "$IMPLEMENT_SKILL" "lore work phase-context"
# The removed literal-prefix parse. A description that no longer carries this
# line, read by an instruction that still expects it, yields a worker with no
# brief and no error.
assert_prose_lacks "implement SKILL no longer writes the '**Phase:** N' description prefix" \
  "$IMPLEMENT_SKILL" "**Phase:** N"
# The removed positional lookup. Indexing `phases[N-1]` is also where a fully
# checked earlier phase shifts every later brief by one.
assert_prose_lacks "implement SKILL no longer indexes phases[N-1].phase_context" \
  "$IMPLEMENT_SKILL" "phases[N-1].phase_context"
# Prior knowledge is assembled per task, from that task's own files and
# knowledge context. A phase-keyed heading has nothing to group by once the
# container is gone.
assert_prose_lacks "implement SKILL no longer groups prior knowledge under phase headings" \
  "$IMPLEMENT_SKILL" "### Phase N: <phase_name>"

echo ""
echo "Test 9: no flat worker parses a phase prefix or fetches a phase brief"
for pair in "worker:$WORKER_MD" "codex-worker:$CODEX_WORKER_MD"; do
  role="${pair%%:*}"
  file="${pair#*:}"
  # The removed verb, in the two templates that actually run it. A worker
  # following this step gets a non-zero exit and, per its own instructions,
  # stops rather than falling back.
  assert_prose_lacks "$role template no longer invokes lore work phase-context" \
    "$file" "lore work phase-context"
  # The removed literal-prefix parse. Nothing writes this line any more, so a
  # worker deriving a phase number from it derives nothing.
  assert_prose_lacks "$role template no longer parses the '**Phase:** N' prefix" \
    "$file" "**Phase:** N"
  # The argument that parse fed. Left in place it is an unfillable placeholder
  # in a command the worker is told to substitute values into.
  assert_prose_lacks "$role template no longer substitutes a <phase-number>" \
    "$file" "<phase-number>"
  # The variable the fetch bound. A prompt that still interpolates it ships an
  # empty brief to the model with no diagnostic.
  assert_prose_lacks "$role template no longer binds PHASE_BRIEF" \
    "$file" "PHASE_BRIEF"
  # The step itself. There is no separate fetch: the brief arrives composed in
  # the task description.
  assert_prose_lacks_i "$role template no longer has a fetch-phase-context step" \
    "$file" "fetch phase context"
  # The brief's new home, and the token that names it. Without this the removal
  # leaves the worker with no documented source for its brief at all.
  assert_prose_contains_i "$role template sources the brief from the task description" \
    "$file" "task description"
  # Acceptance-bar scoping survives the rewrite of the fetch step: the worker
  # self-checks the bullets its own diff can affect and names the rest.
  assert_prose_contains_i "$role template keeps the acceptance bar" \
    "$file" "acceptance bar"
  assert_prose_contains "$role template keeps the not-self-checked disposition" \
    "$file" "not-self-checked"
  # The bar is owned by the lead at plan close, not at a phase boundary. Left
  # phase-scoped, it collapses into a per-worker obligation once every unit is
  # its own task — the amplification lifting the bar exists to prevent.
  assert_prose_lacks_i "$role template no longer calls the bar a phase acceptance bar" \
    "$file" "phase acceptance bar"
  assert_prose_lacks_i "$role template no longer defers the bar to phase close" \
    "$file" "phase close"
done
# The lone remaining phase field in the shared consultation request shape. A
# worker filling it has no phase number to report, and the lead's matcher keys
# on task id.
assert_prose_lacks "worker.md consultation shape no longer carries a phase number field" \
  "$WORKER_MD" "phase: <your current phase number"

echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi
