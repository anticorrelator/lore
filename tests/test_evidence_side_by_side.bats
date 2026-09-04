#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  FIXTURE_ROOT="${LORE_EVIDENCE_FIXTURE_ROOT:-$(mktemp -d)}"
}

teardown() {
  if [[ -z "${LORE_EVIDENCE_FIXTURE_ROOT:-}" ]]; then
    rm -rf "$FIXTURE_ROOT"
  fi
}

@test "authentic legacy and revision N plus N+1 evidence joins every reader and survives archive" {
  run python3 "$REPO_DIR/tests/helpers/evidence_side_by_side.py" build "$REPO_DIR" "$FIXTURE_ROOT"
  [ "$status" -eq 0 ]
  run env LORE_EVIDENCE_FIXTURE_ROOT="$FIXTURE_ROOT" \
    PKG_CONFIG="$REPO_DIR/tui/internal/work/libghostty/pkg-config-shim.sh" \
    GOCACHE=/private/tmp/lore-go-cache \
    bash -c 'cd "$1/tui" && go test ./internal/work -run "^TestRetainedMixedEvidence$" -count=1 -v' bash "$REPO_DIR"
  printf '%s\n' "$output" > "$FIXTURE_ROOT/tui-test-output.txt"
  [ "$status" -eq 0 ]
  python3 "$REPO_DIR/tests/helpers/evidence_side_by_side.py" refresh "$REPO_DIR" "$FIXTURE_ROOT"
}
