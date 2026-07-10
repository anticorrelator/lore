#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO_DIR/skills/evolve/SKILL.md"
PREPARE="$REPO_DIR/scripts/evolve-prepare.sh"
FILE_VERB="$REPO_DIR/scripts/evolve-file.sh"
WRITER="$REPO_DIR/scripts/accepted-cluster-append.sh"

assert_has() {
  local file="$1" literal="$2"
  grep -qF -- "$literal" "$file" || { echo "missing contract in $file: $literal" >&2; exit 1; }
}

assert_not_has() {
  local file="$1" literal="$2"
  ! grep -qF -- "$literal" "$file" || { echo "forbidden stale contract in $file: $literal" >&2; exit 1; }
}

# Authority sequence and doctrine.
assert_has "$SKILL" 'prepare` reconstructs and freezes the review queue'
assert_has "$SKILL" 'Step 6 is the only judgment and edit-authorship seat.'
assert_has "$SKILL" 'lore evolve file'
assert_has "$SKILL" 'Neither verb selects, ranks, synthesizes, or applies a proposal.'

# Closed queue and decision vocabularies.
assert_has "$SKILL" '`eligible`'
assert_has "$SKILL" '`no_op`'
assert_has "$SKILL" '`abstained`'
assert_has "$SKILL" '`not_computable`'
assert_has "$SKILL" '`apply`'
assert_has "$SKILL" '`reject`'
assert_has "$SKILL" '`escalate`'
assert_has "$SKILL" '`destructive-change | high-confidence-drop | abstain`'
assert_has "$SKILL" '`pending | apply | reject | defer`'

# Filing/recovery and physical writer ownership.
assert_has "$SKILL" '`decision_accepted=true`'
assert_has "$SKILL" '`filing_complete=true`'
assert_has "$SKILL" '`created | reused | recovered | partial | refused`'
assert_has "$SKILL" 'The role=`evolve` journal row is last.'
assert_has "$SKILL" 'accepted-cluster-append.sh --append-exact'
assert_has "$SKILL" 'accepted-cluster-append.sh --consume'
assert_has "$SKILL" 'template-registry-register.sh'
assert_has "$SKILL" '`journal:evolve-filing:<filing_id>`'

# Same-run and staged-source boundaries.
assert_has "$SKILL" 'Newly accepted clusters are never consumed in this run.'
assert_has "$SKILL" 'The other 14 staged suggestions remain live and unconsumed'
assert_has "$SKILL" 'leave that row untouched'

# Maintainer branches remain visible but outside v1.
assert_has "$SKILL" 'Mode: `/evolve --pooled <aggregate-path>`'
assert_has "$SKILL" 'Mode: `/evolve --shrink`'
assert_has "$SKILL" 'remain outside the v1 `prepare`/`file` pair'

# Cross-surface vocabulary parity: the prose mirrors the writer and verbs.
assert_has "$PREPARE" 'ELIGIBILITY = {"eligible", "no_op", "abstained", "not_computable"}'
assert_has "$FILE_VERB" '{"apply", "reject", "escalate"}'
assert_has "$FILE_VERB" '{"merge", "edit", "split", "reject", "escalate"}'
assert_has "$WRITER" '--append-exact'
assert_has "$WRITER" '--consume'

# Timestamp-only display plumbing and direct sink recipes no longer govern base flow.
assert_not_has "$SKILL" 'lore journal show --role evolve --limit 1'
assert_not_has "$SKILL" 'lore journal show --role retro-evolution --since'
assert_not_has "$SKILL" 'bash ~/.lore/scripts/template-registry-register.sh \\'

echo "evolve review-queue protocol contract: PASS"
