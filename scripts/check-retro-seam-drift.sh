#!/usr/bin/env bash
# Reject retro reader and protocol changes that leave their contract companion behind.
#
# Granularity: the pushed range, not the individual commit. A protected-reader
# change anywhere in BASE..HEAD is paired when the contract test also changes
# anywhere in that range. Merge-stream workflows routinely land a reader change
# and its contract-test update in sibling commits of one push; the guarantee
# that matters at the push seam is that the pushed tree's readers and their
# contract moved together, not that every commit carried both halves.

set -euo pipefail

usage() {
  echo "Usage: check-retro-seam-drift.sh <base-revision> [head-revision]" >&2
}

[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 2; }
BASE="$1"
HEAD="${2:-HEAD}"

git rev-parse --verify "$BASE^{commit}" >/dev/null 2>&1 || { echo "retro seam drift: unknown base revision '$BASE'" >&2; exit 2; }
git rev-parse --verify "$HEAD^{commit}" >/dev/null 2>&1 || { echo "retro seam drift: unknown head revision '$HEAD'" >&2; exit 2; }

CONTRACT_TEST="tests/frameworks/retro_prepare.bats"
RETRO_SKILL="skills/retro/SKILL.md"
PROTECTED_READERS=(
  scripts/retro-prepare.sh
  scripts/retro-queue.sh
  scripts/scorecard-read.sh
  scripts/session-events.sh
)
# Companion surfaces for the retro SKILL pairing beyond the readers: the retro
# judge scores delivery straight from tasks.json, so the task-DAG generator,
# loader, and their contract test are part of the same mutation chain as the
# SKILL prose that describes how to read them.
SKILL_COMPANIONS=(
  scripts/generate-tasks.py
  scripts/load-tasks.sh
  tests/test_flat_task_dag_contract.sh
)

# Enforcement boundary: the checker establishes the rule. If the base predates
# the checker, advance the base to the commit that introduced it — changes made
# before the repository published the rule cannot have complied with it.
if ! git cat-file -e "$BASE:scripts/check-retro-seam-drift.sh" 2>/dev/null; then
  intro=""
  while IFS= read -r commit; do
    if git cat-file -e "$commit:scripts/check-retro-seam-drift.sh" 2>/dev/null; then
      intro="$commit"
      break
    fi
  done < <(git rev-list --reverse "$BASE..$HEAD")
  if [[ -z "$intro" ]]; then
    echo "retro seam drift: PASS"
    exit 0
  fi
  BASE="$intro"
fi

contains_path() {
  local needle="$1" path
  shift
  for path in "$@"; do
    [[ "$path" == "$needle" ]] && return 0
  done
  return 1
}

cli_reader_changed() {
  git diff --unified=0 "$BASE" "$HEAD" -- cli/lore \
    | grep -Eq '^[+-].*(scorecard-read\.sh|current\|rows)'
}

range_has_companion() {
  local path
  for path in "$@"; do
    case "$path" in
      scripts/retro-*.sh|scripts/scorecard-read.sh|scripts/session-events.sh|tests/frameworks/retro_prepare.bats|scripts/check-retro-seam-drift.sh|tests/test_retro_seam_drift_check.sh|tests/test_retro_evidence_pack_protocol.sh)
        return 0
        ;;
    esac
    if contains_path "$path" "${SKILL_COMPANIONS[@]}"; then
      return 0
    fi
  done
  cli_reader_changed
}

# Net tree diff over the range: a change reverted within the range is not drift.
paths=()
while IFS= read -r path; do
  paths+=("$path")
done < <(git diff --name-only "$BASE" "$HEAD")

failures=0
if [[ ${#paths[@]} -gt 0 ]]; then
  reader_change=0
  for protected in "${PROTECTED_READERS[@]}"; do
    if contains_path "$protected" "${paths[@]}"; then
      reader_change=1
      break
    fi
  done
  if [[ $reader_change -eq 0 ]] && contains_path cli/lore "${paths[@]}" && cli_reader_changed; then
    reader_change=1
  fi

  if [[ $reader_change -eq 1 ]] && ! contains_path "$CONTRACT_TEST" "${paths[@]}"; then
    echo "retro seam drift: range $BASE..$HEAD changes a protected reader without $CONTRACT_TEST" >&2
    failures=$((failures + 1))
  fi

  if contains_path "$RETRO_SKILL" "${paths[@]}" && ! range_has_companion "${paths[@]}"; then
    echo "retro seam drift: range $BASE..$HEAD changes $RETRO_SKILL without retro behavior, contract-test, or protocol-check changes" >&2
    failures=$((failures + 1))
  fi
fi

[[ $failures -eq 0 ]] || exit 1
echo "retro seam drift: PASS"
