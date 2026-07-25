#!/usr/bin/env bats
# settings_retired_key_prune.bats — Guards install.sh's retired-key prune.
#
# The prune strips top-level keys from settings.json that
# adapters/settings.schema.json no longer accepts (the schema is
# additionalProperties:false at root, so an unknown key fails doctor forever).
#
# It previously used a hand-maintained tuple, `("settlement", "capture")`, and
# nothing tested it. The tuple drifted: 884c20b re-introduced `settlement` to
# the schema in 2026-05 and the tuple carried it forward unexamined, so every
# install deleted live settlement config -- on a FRESH install, the very block
# install.sh had seeded from settings.template.json a few hundred lines
# earlier. `settlement.max_concurrency` going missing fail-closes the
# coordination concurrency ceiling to 1.
#
# The invariant these tests hold is the derivation, not the instance: the
# retired set comes from the schema, so it cannot disagree with the schema.
#
# Falsifiers (each run against this suite, not merely asserted):
#   - Reverting prune-retired-settings.py to the ("settlement", "capture")
#     tuple fails 6 tests: "key present in the schema survives", "surviving key
#     keeps its values", "every shipped template top-level key survives",
#     "pruned set is exactly the schema complement", "no backup is written when
#     there is nothing to prune", and the fresh-install regression.
#   - Making the prune a no-op fails "key absent from the schema is pruned"
#     (and, consequently, the .bak content test).
#   - Dropping the shutil.copy2 backup fails "prune writes a .bak carrying the
#     pre-prune content".

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
PRUNE="$REPO_DIR/scripts/prune-retired-settings.py"
SCHEMA="$REPO_DIR/adapters/settings.schema.json"
TEMPLATE="$REPO_DIR/adapters/settings.template.json"
INSTALL_SH="$REPO_DIR/install.sh"

setup() {
  [ -f "$PRUNE" ]    || skip "scripts/prune-retired-settings.py missing"
  [ -f "$SCHEMA" ]   || skip "adapters/settings.schema.json missing"
  [ -f "$TEMPLATE" ] || skip "adapters/settings.template.json missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"

  TMP="$(mktemp -d)"
  SETTINGS="$TMP/settings.json"
}

teardown() {
  if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
    rm -rf "$TMP"
  fi
}

# --- Helpers -----------------------------------------------------------------

run_prune() {
  run python3 "$PRUNE" --settings "$SETTINGS" --schema "${1:-$SCHEMA}"
}

# Print sorted top-level keys of a JSON document, one per line.
top_keys() {
  F="$1" python3 - <<'PY'
import json, os
with open(os.environ["F"]) as f:
    d = json.load(f)
for k in sorted(d):
    print(k)
PY
}

has_key() {
  F="$1" K="$2" python3 - <<'PY'
import json, os, sys
with open(os.environ["F"]) as f:
    d = json.load(f)
sys.exit(0 if os.environ["K"] in d else 1)
PY
}

# A settings doc carrying the schema's required keys plus whatever extra
# top-level blocks the caller names, so the fixture is realistic rather than
# a bare pair of keys.
seed_settings() {
  SETTINGS="$SETTINGS" TEMPLATE="$TEMPLATE" python3 - "$@" <<'PY'
import json, os, sys
with open(os.environ["TEMPLATE"]) as f:
    doc = json.load(f)
for extra in sys.argv[1:]:
    doc[extra] = {"stale": True}
with open(os.environ["SETTINGS"], "w") as f:
    json.dump(doc, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

# --- The two required cases --------------------------------------------------

@test "key absent from the schema is pruned" {
  # `capture` is legitimately retired -- absent from the schema, and must
  # still be removed. A prune that became a no-op fails here.
  seed_settings capture
  has_key "$SETTINGS" capture

  run_prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"pruned: capture"* ]]

  ! has_key "$SETTINGS" capture
}

@test "key present in the schema survives" {
  # `settlement` is live: schema property, shipped template block, six readers.
  seed_settings
  has_key "$SETTINGS" settlement

  run_prune
  [ "$status" -eq 0 ]

  has_key "$SETTINGS" settlement
}

@test "surviving key keeps its values (max_concurrency is not lost)" {
  # The concrete cost of the old prune: coordinate-status.sh fail-closes the
  # concurrency ceiling to 1 when settlement.max_concurrency is absent.
  seed_settings
  SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os
p = os.environ["SETTINGS"]
with open(p) as f:
    d = json.load(f)
d["settlement"]["max_concurrency"] = 10
with open(p, "w") as f:
    json.dump(d, f, indent=2)
PY

  run_prune
  [ "$status" -eq 0 ]

  run python3 -c "import json;print(json.load(open('$SETTINGS'))['settlement']['max_concurrency'])"
  [ "$status" -eq 0 ]
  [ "$output" = "10" ]
}

# --- The derivation, not the instance ----------------------------------------

@test "every shipped template top-level key survives the prune" {
  # Generalizes the settlement case: install.sh seeds from the template and
  # then prunes in the same run, so any template key the derivation rejects is
  # a key fresh installs silently lose.
  seed_settings

  before="$(top_keys "$SETTINGS")"
  run_prune
  [ "$status" -eq 0 ]
  after="$(top_keys "$SETTINGS")"

  [ "$before" = "$after" ]
}

@test "pruned set is exactly the schema complement, not a fixed list" {
  seed_settings capture phantom_block another_stale_block

  run_prune
  [ "$status" -eq 0 ]
  # Keys the schema never heard of go, regardless of whether anyone
  # remembered to list them.
  ! has_key "$SETTINGS" capture
  ! has_key "$SETTINGS" phantom_block
  ! has_key "$SETTINGS" another_stale_block
  has_key "$SETTINGS" settlement
  has_key "$SETTINGS" harnesses
}

@test "install.sh carries no hand-maintained retired-key list" {
  # The defect was the list existing at all. If one comes back, so does drift.
  run grep -n "retired_keys" "$INSTALL_SH"
  [ "$status" -ne 0 ]
}

# --- Backup ------------------------------------------------------------------

@test "prune writes a .bak carrying the pre-prune content" {
  seed_settings capture

  run_prune
  [ "$status" -eq 0 ]
  [ -f "$SETTINGS.bak" ]
  # The backup is the file the user actually had -- pruned key included.
  has_key "$SETTINGS.bak" capture
  has_key "$SETTINGS.bak" settlement
}

@test "no backup is written when there is nothing to prune" {
  seed_settings

  run_prune
  [ "$status" -eq 0 ]
  [ ! -f "$SETTINGS.bak" ]
  [ -z "$output" ]
}

# --- Refusal beats guessing --------------------------------------------------

@test "missing schema refuses to prune and leaves settings untouched" {
  seed_settings capture
  before="$(cat "$SETTINGS")"

  run_prune "$TMP/nonexistent-schema.json"
  [ "$status" -ne 0 ]

  [ "$(cat "$SETTINGS")" = "$before" ]
  has_key "$SETTINGS" capture
}

@test "schema without additionalProperties:false refuses to prune" {
  # If unknown keys are legal, "absent from properties" no longer means
  # "rejected", so the derivation is unsound and must not run.
  seed_settings capture
  OPEN_SCHEMA="$TMP/open-schema.json"
  SCHEMA="$SCHEMA" OUT="$OPEN_SCHEMA" python3 - <<'PY'
import json, os
with open(os.environ["SCHEMA"]) as f:
    d = json.load(f)
d["additionalProperties"] = True
with open(os.environ["OUT"], "w") as f:
    json.dump(d, f)
PY

  run_prune "$OPEN_SCHEMA"
  [ "$status" -ne 0 ]
  has_key "$SETTINGS" capture
}

@test "absent settings file is a silent no-op" {
  run_prune
  [ "$status" -eq 0 ]
}

# --- Fresh-install regression ------------------------------------------------

@test "fresh install leaves the settlement block intact" {
  # End-to-end against the real installer: this is the reported defect. Before
  # the fix, install.sh seeded settlement from the template and deleted it in
  # the same run, so a brand-new install came up with the concurrency ceiling
  # already fail-closed.
  [ -f "$INSTALL_SH" ] || skip "install.sh missing"

  E2E_DATA="$(mktemp -d)"
  E2E_HOME="$(mktemp -d)"
  mkdir -p "$E2E_DATA/config"
  ln -s "$REPO_DIR/scripts" "$E2E_DATA/scripts"

  # install.sh builds the TUI with `go build`. Resolved against the isolated
  # HOME, Go would re-download its whole module cache into the temp dir (slow,
  # and it lands read-only). Point it at the caches this machine already has;
  # the settings behavior under test does not depend on the build either way.
  go_env=()
  if command -v go >/dev/null 2>&1; then
    go_env=(GOMODCACHE="$(go env GOMODCACHE)" GOCACHE="$(go env GOCACHE)")
  fi

  run env LORE_DATA_DIR="$E2E_DATA" HOME="$E2E_HOME" "${go_env[@]}" \
    bash "$INSTALL_SH" --framework claude-code
  install_status="$status"
  install_output="$output"

  settings_file="$E2E_DATA/config/settings.json"
  key_present=99
  if [ "$install_status" -eq 0 ] && [ -f "$settings_file" ]; then
    if has_key "$settings_file" settlement; then key_present=0; else key_present=1; fi
  fi

  # Cleanup must not decide the verdict — a stray read-only file left by any
  # install step would otherwise fail an otherwise-passing test.
  chmod -R u+w "$E2E_DATA" "$E2E_HOME" 2>/dev/null || true
  rm -rf "$E2E_DATA" "$E2E_HOME" 2>/dev/null || true

  [ "$install_status" -eq 0 ] || { echo "$install_output"; false; }
  [ "$key_present" -eq 0 ]
}
