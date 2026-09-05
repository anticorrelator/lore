#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/pytest" <<'PYTEST'
#!/usr/bin/env bash
printf '%s\n' "$@"
cat "$1/owner"
PYTEST
  chmod +x "$BATS_TEST_TMPDIR/bin/pytest"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  for owner in alpha beta; do
    candidate="$BATS_TEST_TMPDIR/$owner"
    mkdir -p "$candidate/scripts" "$candidate/cli" "$candidate/tests/protocols"
    cp "$REPO_DIR/scripts/lore-test.sh" "$REPO_DIR/scripts/lib.sh" "$candidate/scripts/"
    cp "$REPO_DIR/cli/lore" "$candidate/cli/"
    echo "$owner" > "$candidate/tests/protocols/owner"
  done
}

@test "each candidate CLI runs its own suite from an unrelated working directory" {
  cd /private/tmp
  for owner in alpha beta; do
    candidate="$BATS_TEST_TMPDIR/$owner"
    run bash "$candidate/cli/lore" test protocols -k sentinel
    [ "$status" -eq 0 ]
    [[ "$output" == *"$candidate/tests/protocols"* ]]
    [[ "$output" == *'-k'* ]]
    [[ "$output" == *'sentinel'* ]]
    [[ "$output" == *"$owner" ]]
  done
}

@test "installed script symlink resolves the owning candidate suite" {
  ln -s "$BATS_TEST_TMPDIR/beta/scripts" "$BATS_TEST_TMPDIR/installed"
  run bash "$BATS_TEST_TMPDIR/installed/lore-test.sh" protocols
  [ "$status" -eq 0 ]
  [[ "$output" == *"$BATS_TEST_TMPDIR/beta/tests/protocols"* ]]
}

@test "missing candidate suite fails instead of using installed tests" {
  rm -r "$BATS_TEST_TMPDIR/alpha/tests"
  run bash "$BATS_TEST_TMPDIR/alpha/cli/lore" test protocols
  [ "$status" -ne 0 ]
  [[ "$output" == *'protocols test directory not found'* ]]
}

@test "two candidate copies execute pytest against distinct local test contents" {
  actual_path="${PATH#*:}"
  command -v pytest >/dev/null || skip "pytest unavailable"
  for owner in alpha beta; do
    candidate="$BATS_TEST_TMPDIR/$owner"
    cat > "$candidate/tests/protocols/test_owner.py" <<'PYTHON'
from pathlib import Path
import os

def test_owning_source():
    assert Path(__file__).with_name('owner').read_text().strip() == os.environ['EXPECTED_OWNER']
PYTHON
    run env PATH="$actual_path" PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 EXPECTED_OWNER="$owner" bash "$candidate/cli/lore" test protocols -q
    [ "$status" -eq 0 ]
    [[ "$output" == *'1 passed'* ]]
  done
}
