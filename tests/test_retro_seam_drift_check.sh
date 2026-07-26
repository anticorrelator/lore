#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$REPO_ROOT/scripts/check-retro-seam-drift.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

new_repo() {
  local repo="$1"
  mkdir -p "$repo/scripts" "$repo/tests/frameworks" "$repo/tests" "$repo/skills/retro" "$repo/skills/other"
  cp "$CHECKER" "$repo/scripts/check-retro-seam-drift.sh"
  printf 'registry baseline\n' > "$repo/scripts/retro-prepare.sh"
  printf 'reader test baseline\n' > "$repo/tests/frameworks/retro_prepare.bats"
  printf 'settlement reader baseline\n' > "$repo/scripts/settlement-processor.py"
  printf 'settlement contract baseline\n' > "$repo/tests/test_settlement_queue.sh"
  printf 'retro skill baseline\n' > "$repo/skills/retro/SKILL.md"
  printf 'other skill baseline\n' > "$repo/skills/other/SKILL.md"
  printf 'protocol baseline\n' > "$repo/tests/test_retro_evidence_pack_protocol.sh"
  git -C "$repo" init -q
  git -C "$repo" config user.name "Retro Contract Test"
  git -C "$repo" config user.email "retro-contract@example.invalid"
  git -C "$repo" add .
  git -C "$repo" commit -q -m baseline
}

commit_all() {
  local repo="$1" subject="$2"
  git -C "$repo" add .
  git -C "$repo" commit -q -m "$subject"
}

expect_pass() {
  local repo="$1" base="$2"
  (cd "$repo" && bash scripts/check-retro-seam-drift.sh "$base" HEAD) >/dev/null
}

expect_fail() {
  local repo="$1" base="$2"
  if (cd "$repo" && bash scripts/check-retro-seam-drift.sh "$base" HEAD) >/dev/null 2>&1; then
    echo "expected drift check failure in $repo" >&2
    exit 1
  fi
}

repo="$TMP/coupled-reader"
new_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'registry change\n' >> "$repo/scripts/retro-prepare.sh"
printf 'paired contract\n' >> "$repo/tests/frameworks/retro_prepare.bats"
commit_all "$repo" "couple reader and contract"
expect_pass "$repo" "$base"

repo="$TMP/unpaired-reader"
new_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'registry change\n' >> "$repo/scripts/retro-prepare.sh"
commit_all "$repo" "unpaired reader"
expect_fail "$repo" "$base"

repo="$TMP/standalone-skill"
new_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'standalone rewrite\n' >> "$repo/skills/retro/SKILL.md"
commit_all "$repo" "standalone retro prose"
expect_fail "$repo" "$base"

repo="$TMP/two-coupled-skill-commits"
new_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
for n in 1 2; do
  printf 'skill revision %s\n' "$n" >> "$repo/skills/retro/SKILL.md"
  printf 'protocol revision %s\n' "$n" >> "$repo/tests/test_retro_evidence_pack_protocol.sh"
  commit_all "$repo" "coupled retro revision $n"
done
expect_pass "$repo" "$base"

repo="$TMP/other-skill"
new_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'owner calibration\n' >> "$repo/skills/other/SKILL.md"
commit_all "$repo" "other skill prose"
expect_pass "$repo" "$base"

# scripts/settlement-processor.py serves the retro projection and the settlement
# queue commands from one file. Which contract test discharges a change depends
# on whether the diff names the retro surface.

repo="$TMP/settlement-non-retro-paired"
new_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'def retry_error_audits(self, limit=None):\n    return []\n' >> "$repo/scripts/settlement-processor.py"
printf 'retry-errors bounds case\n' >> "$repo/tests/test_settlement_queue.sh"
commit_all "$repo" "settlement queue change with its own contract test"
expect_pass "$repo" "$base"

repo="$TMP/settlement-non-retro-unpaired"
new_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'def retry_error_audits(self, limit=None):\n    return []\n' >> "$repo/scripts/settlement-processor.py"
commit_all "$repo" "settlement queue change with no contract test"
expect_fail "$repo" "$base"

repo="$TMP/settlement-retro-surface-unpaired"
new_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'def retro_status_projection(self, queue, start, end):\n    return {}\n' >> "$repo/scripts/settlement-processor.py"
printf 'queue-side case\n' >> "$repo/tests/test_settlement_queue.sh"
commit_all "$repo" "retro projection change paired only with the queue suite"
expect_fail "$repo" "$base"

repo="$TMP/settlement-retro-surface-paired"
new_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'def retro_status_projection(self, queue, start, end):\n    return {}\n' >> "$repo/scripts/settlement-processor.py"
printf 'projection contract case\n' >> "$repo/tests/frameworks/retro_prepare.bats"
commit_all "$repo" "retro projection change paired with the reader contract"
expect_pass "$repo" "$base"

repo="$TMP/rollout-boundary"
mkdir -p "$repo/scripts" "$repo/tests/frameworks"
printf 'registry baseline\n' > "$repo/scripts/retro-prepare.sh"
printf 'reader test baseline\n' > "$repo/tests/frameworks/retro_prepare.bats"
git -C "$repo" init -q
git -C "$repo" config user.name "Retro Contract Test"
git -C "$repo" config user.email "retro-contract@example.invalid"
git -C "$repo" add .
git -C "$repo" commit -q -m baseline
base="$(git -C "$repo" rev-parse HEAD)"
printf 'pre-checker reader change\n' >> "$repo/scripts/retro-prepare.sh"
commit_all "$repo" "reader change before enforcement"
cp "$CHECKER" "$repo/scripts/check-retro-seam-drift.sh"
commit_all "$repo" "introduce drift checker"
expect_pass "$repo" "$base"

echo "retro seam drift check: PASS"
