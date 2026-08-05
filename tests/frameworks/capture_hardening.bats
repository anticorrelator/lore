#!/usr/bin/env bats
# capture_hardening.bats — Two capture defects observed 2026-08-05, both of the
# silent-wrong-answer kind: capture succeeded and reported success while the
# result was not what the caller asked for.
#
#   1. Sibling-store misfile. `lore capture` run with cwd inside one knowledge
#      store resolved (via the data dir's own git remote) to a DIFFERENT store
#      under the same repos/ tree and filed there, reporting success. Contract:
#      when the store containing cwd and the store resolution picked disagree,
#      capture refuses, names both candidates, and points at --kdir. Silent
#      selection is the defect; a warning would not be enough, because the
#      caller has already been told the capture succeeded.
#
#   2. Phantom headings. derive_entry_title() is line-oriented awk, so a
#      multi-line insight yielded a multi-line "title" — every section's first
#      eight words, title-cased, stacked above the body, with only the first
#      line carrying the `#`. The body was then written again in full below.
#      Contract: an H1 is one line. Normalize the insight to a single title
#      line; never promote later lines.
#
# Both suites are hermetic: suite 1 builds a throwaway LORE_DATA_DIR holding two
# stores and a real git remote, suite 2 uses LORE_KNOWLEDGE_DIR. Neither touches
# the user's ~/.lore store.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
CAPTURE_SH="$REPO_DIR/scripts/capture.sh"

setup() {
  [ -f "$CAPTURE_SH" ] || skip "scripts/capture.sh missing"
  command -v git >/dev/null 2>&1 || skip "git required"

  TEST_ROOT="$(mktemp -d)"
  # macOS mktemp hands back /var/... which is a symlink to /private/var. Pin the
  # resolved form so path comparisons in the assertions match what the scripts
  # compute.
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"

  DATA_DIR="$TEST_ROOT/data"
  PROJECT_STORE="$DATA_DIR/repos/github.com/owner/project"
  SIBLING_STORE="$DATA_DIR/repos/github.com/owner/.lore"
  mkdir -p "$PROJECT_STORE" "$SIBLING_STORE"
  printf '{"entries":[]}\n' > "$PROJECT_STORE/_manifest.json"
  printf '{"entries":[]}\n' > "$SIBLING_STORE/_manifest.json"

  # The data dir is itself a git repo — this is the real-world shape that caused
  # the misfile: every path under it inherits the data dir's own remote.
  git init --quiet "$DATA_DIR"
  git -C "$DATA_DIR" config user.email "test@example.com"
  git -C "$DATA_DIR" config user.name "Test"

  export LORE_DATA_DIR="$DATA_DIR"
  unset LORE_KNOWLEDGE_DIR
}

teardown() {
  [ -n "${TEST_ROOT:-}" ] && [ -d "$TEST_ROOT" ] && rm -rf "$TEST_ROOT"
  unset LORE_DATA_DIR LORE_KNOWLEDGE_DIR
}

# Point the data dir's remote at <owner/name>, which is what resolve-repo.sh
# turns into a store path under repos/.
aim_remote_at() {
  git -C "$DATA_DIR" remote remove origin 2>/dev/null || true
  git -C "$DATA_DIR" remote add origin "git@github.com:$1.git"
}

entry_count() {
  find "$1" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' '
}

# --- 1. Sibling-store resolution ------------------------------------------

@test "refuses when cwd's store and the resolved store disagree" {
  aim_remote_at "owner/.lore"

  cd "$PROJECT_STORE"
  run bash "$CAPTURE_SH" --insight "queues drain oldest-first" \
    --scale implementation --skip-manifest
  [ "$status" -ne 0 ]

  # Both candidates are named, so the caller can tell which one they meant.
  [[ "$output" == *"$PROJECT_STORE"* ]]
  [[ "$output" == *"$SIBLING_STORE"* ]]
  # And the way forward is stated, not implied.
  [[ "$output" == *"--kdir"* ]]
}

@test "a refused capture writes nothing to either store" {
  aim_remote_at "owner/.lore"

  cd "$PROJECT_STORE"
  run bash "$CAPTURE_SH" --insight "queues drain oldest-first" \
    --scale implementation --skip-manifest
  [ "$status" -ne 0 ]

  [ "$(entry_count "$PROJECT_STORE")" -eq 0 ]
  [ "$(entry_count "$SIBLING_STORE")" -eq 0 ]
  [ ! -f "$PROJECT_STORE/_capture_log.csv" ]
  [ ! -f "$SIBLING_STORE/_capture_log.csv" ]
}

@test "--json refusal is a machine-readable error, not a success envelope" {
  aim_remote_at "owner/.lore"

  cd "$PROJECT_STORE"
  run bash "$CAPTURE_SH" --insight "queues drain oldest-first" \
    --scale implementation --skip-manifest --json
  [ "$status" -ne 0 ]
  [[ "$output" == *"error"* ]]
  [[ "$output" != *'"path"'* ]]
}

@test "--kdir settles the ambiguity and files into the named store" {
  aim_remote_at "owner/.lore"

  cd "$PROJECT_STORE"
  run bash "$CAPTURE_SH" --insight "queues drain oldest-first" \
    --scale implementation --skip-manifest --kdir "$PROJECT_STORE"
  [ "$status" -eq 0 ]

  [ "$(entry_count "$PROJECT_STORE")" -eq 1 ]
  [ "$(entry_count "$SIBLING_STORE")" -eq 0 ]
}

@test "agreement between cwd's store and resolution captures without complaint" {
  aim_remote_at "owner/project"

  cd "$PROJECT_STORE"
  run bash "$CAPTURE_SH" --insight "queues drain oldest-first" \
    --scale implementation --skip-manifest
  [ "$status" -eq 0 ]

  [ "$(entry_count "$PROJECT_STORE")" -eq 1 ]
  [ "$(entry_count "$SIBLING_STORE")" -eq 0 ]
}

@test "LORE_KNOWLEDGE_DIR names the store outright and is not second-guessed" {
  # The env-var form of --kdir. Resolution infers nothing when it is set, so
  # there is no second candidate — the guard must stay out of the way, including
  # when cwd happens to sit inside some other store.
  aim_remote_at "owner/.lore"
  export LORE_KNOWLEDGE_DIR="$SIBLING_STORE"

  cd "$PROJECT_STORE"
  run bash "$CAPTURE_SH" --insight "queues drain oldest-first" \
    --scale implementation --skip-manifest
  [ "$status" -eq 0 ]
  [ "$(entry_count "$SIBLING_STORE")" -eq 1 ]
  [ "$(entry_count "$PROJECT_STORE")" -eq 0 ]
}

@test "a subdirectory of a store resolves to that store, not its neighbour" {
  # Session worktrees and _work/ live below the store root; walking up must find
  # the enclosing store rather than declaring an ambiguity.
  aim_remote_at "owner/project"
  mkdir -p "$PROJECT_STORE/_sessions/worktrees/abc123"

  cd "$PROJECT_STORE/_sessions/worktrees/abc123"
  run bash "$CAPTURE_SH" --insight "queues drain oldest-first" \
    --scale implementation --skip-manifest
  [ "$status" -eq 0 ]
  [ "$(entry_count "$PROJECT_STORE")" -eq 1 ]
}

# --- 2. Phantom headings ---------------------------------------------------

MULTI_SECTION_INSIGHT='SCOPE: the settlement pipeline was removed on 2026-08-05.

EVIDENCE: the trust ledger recorded 643 peer verification events over four weeks.

FALSIFIER: correction yield falls materially and does not recover.'

captured_entry() {
  find "$1/conventions" -name '*.md' -type f 2>/dev/null | head -1
}

@test "a multi-section insight produces exactly one heading" {
  export LORE_KNOWLEDGE_DIR="$PROJECT_STORE"

  run bash "$CAPTURE_SH" --insight "$MULTI_SECTION_INSIGHT" \
    --scale architecture --skip-manifest
  [ "$status" -eq 0 ]

  local file
  file="$(captured_entry "$PROJECT_STORE")"
  [ -n "$file" ]

  # One `#` line, and it is the first line.
  [ "$(grep -c '^#' "$file")" -eq 1 ]
  head -1 "$file" | grep -q '^# '
  # The heading occupies exactly one line: line 2 is already the body. The
  # defect put a blank line and two title-cased section fragments here first.
  [ "$(sed -n '2p' "$file")" = "SCOPE: the settlement pipeline was removed on 2026-08-05." ]
}

@test "later sections are not promoted above the body" {
  export LORE_KNOWLEDGE_DIR="$PROJECT_STORE"

  run bash "$CAPTURE_SH" --insight "$MULTI_SECTION_INSIGHT" \
    --scale architecture --skip-manifest
  [ "$status" -eq 0 ]

  local file
  file="$(captured_entry "$PROJECT_STORE")"

  # Each section label appears once — in the body. The defect emitted a
  # title-cased, eight-word-truncated copy of every line above the body too.
  [ "$(grep -c 'EVIDENCE:' "$file")" -eq 1 ]
  [ "$(grep -c 'FALSIFIER:' "$file")" -eq 1 ]
  ! grep -q 'EVIDENCE: The Trust Ledger' "$file"
  ! grep -q 'FALSIFIER: Correction Yield' "$file"
}

@test "the body survives verbatim under the single heading" {
  export LORE_KNOWLEDGE_DIR="$PROJECT_STORE"

  run bash "$CAPTURE_SH" --insight "$MULTI_SECTION_INSIGHT" \
    --scale architecture --skip-manifest
  [ "$status" -eq 0 ]

  local file
  file="$(captured_entry "$PROJECT_STORE")"

  grep -qF 'EVIDENCE: the trust ledger recorded 643 peer verification events over four weeks.' "$file"
  grep -qF 'FALSIFIER: correction yield falls materially and does not recover.' "$file"
  # The title is derived from the first line only.
  head -1 "$file" | grep -qF 'Settlement Pipeline'
}

@test "single-line insights keep their existing title" {
  export LORE_KNOWLEDGE_DIR="$PROJECT_STORE"

  run bash "$CAPTURE_SH" \
    --insight "the token bucket refills at a constant rate regardless of load" \
    --scale implementation --skip-manifest
  [ "$status" -eq 0 ]

  local file
  file="$(captured_entry "$PROJECT_STORE")"
  [ "$(head -1 "$file")" = "# The Token Bucket Refills At A Constant Rate" ]
}
