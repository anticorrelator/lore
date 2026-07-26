#!/usr/bin/env bash
# Reject retro reader and protocol changes that leave their contract companion behind.

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
  scripts/settlement-queue.sh
  scripts/scorecard-read.sh
  scripts/session-events.sh
  scripts/consumption-contradiction-read.sh
)

# Handled apart from PROTECTED_READERS: see settlement_retro_surface_changed.
SETTLEMENT_READER="scripts/settlement-processor.py"
SETTLEMENT_CONTRACT_TEST="tests/test_settlement_queue.sh"

contains_path() {
  local needle="$1" path
  shift
  for path in "$@"; do
    [[ "$path" == "$needle" ]] && return 0
  done
  return 1
}

cli_reader_changed() {
  local commit="$1"
  git show --format= --unified=0 "$commit" -- cli/lore \
    | grep -Eq '^[+-].*(scorecard-read\.sh|consumption-contradiction-read\.sh|current\|rows|consumption-contradiction\))'
}

# scripts/settlement-processor.py runs thirteen commands across ~4200 lines; the
# retro evidence pack consumes about ninety of them — retro_status_projection and
# the status window response that carries it (scripts/retro-prepare.sh reads only
# `settlement status --json` and only its retro_projection object). Whole-file
# protection therefore charged every retry-errors, archive, or GC edit with a
# retro contract it never touched. Discriminate on diff content instead, the way
# cli_reader_changed already does for cli/lore: name the retro surface and the
# retro contract test is required; edit anywhere else in the file and the
# settlement queue's own contract suite discharges the pairing.
#
# Known limitation: census_runs feeds the projection its rows, and a change to
# that row set does not have to name any token below. That gap is covered rather
# than ignored — githooks/pre-push runs the full reader contract suite for every
# range touching this file, so a change that actually moves the projection fails
# there instead of passing unnoticed.
settlement_retro_surface_changed() {
  local commit="$1"
  git show --format= --unified=0 "$commit" -- "$SETTLEMENT_READER" \
    | grep -Eq '^[+-].*(retro_status_projection|retro_projection|reader_contract_version|queue_transitions|completed_envelopes|grounding_outcomes|def status\()'
}

skill_has_companion() {
  local commit="$1"
  shift
  local path
  for path in "$@"; do
    case "$path" in
      scripts/retro-*.sh|scripts/settlement-queue.sh|scripts/settlement-processor.py|scripts/scorecard-read.sh|scripts/session-events.sh|scripts/consumption-contradiction-read.sh|tests/frameworks/retro_prepare.bats|scripts/check-retro-seam-drift.sh|tests/test_retro_seam_drift_check.sh|tests/test_retro_evidence_pack_protocol.sh)
        return 0
        ;;
    esac
  done
  cli_reader_changed "$commit"
}

failures=0
while IFS= read -r commit; do
  [[ -n "$commit" ]] || continue
  # The checker establishes the enforcement boundary. Commits made before it
  # existed cannot have complied with a rule the repository had not published.
  if ! git cat-file -e "$commit^:scripts/check-retro-seam-drift.sh" 2>/dev/null; then
    continue
  fi
  paths=()
  while IFS= read -r path; do
    paths+=("$path")
  done < <(git diff-tree --no-commit-id --name-only -r "$commit")
  # Merge commits yield no paths from diff-tree (their changes arrive via the
  # walked parent commits); an empty array also trips `set -u` under bash < 4.4.
  [[ ${#paths[@]} -eq 0 ]] && continue
  reader_change=0
  for protected in "${PROTECTED_READERS[@]}"; do
    if contains_path "$protected" "${paths[@]}"; then
      reader_change=1
      break
    fi
  done
  if [[ $reader_change -eq 0 ]] && contains_path cli/lore "${paths[@]}" && cli_reader_changed "$commit"; then
    reader_change=1
  fi

  # A settlement-processor edit that names the retro surface is a protected
  # reader change; one that does not answers to the settlement contract suite.
  settlement_change=0
  if contains_path "$SETTLEMENT_READER" "${paths[@]}"; then
    if settlement_retro_surface_changed "$commit"; then
      reader_change=1
    else
      settlement_change=1
    fi
  fi

  if [[ $reader_change -eq 1 ]] && ! contains_path "$CONTRACT_TEST" "${paths[@]}"; then
    echo "retro seam drift: $commit changes a protected reader without $CONTRACT_TEST" >&2
    failures=$((failures + 1))
  elif [[ $settlement_change -eq 1 ]] \
    && ! contains_path "$CONTRACT_TEST" "${paths[@]}" \
    && ! contains_path "$SETTLEMENT_CONTRACT_TEST" "${paths[@]}"; then
    echo "retro seam drift: $commit changes $SETTLEMENT_READER without $CONTRACT_TEST or $SETTLEMENT_CONTRACT_TEST" >&2
    failures=$((failures + 1))
  fi

  if contains_path "$RETRO_SKILL" "${paths[@]}" && ! skill_has_companion "$commit" "${paths[@]}"; then
    echo "retro seam drift: $commit changes $RETRO_SKILL without retro behavior, contract-test, or protocol-check changes" >&2
    failures=$((failures + 1))
  fi
done < <(git rev-list --reverse "$BASE..$HEAD")

[[ $failures -eq 0 ]] || exit 1
echo "retro seam drift: PASS"
