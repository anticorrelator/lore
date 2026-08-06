#!/usr/bin/env bats
# settings_retired_key_prune.bats — Guards install.sh's retired-key prune.
#
# The prune strips top-level keys from settings.json that
# adapters/settings.schema.json no longer accepts (the schema is
# additionalProperties:false at root, so an unknown key fails doctor forever).
#
# It previously used a hand-maintained tuple and nothing tested it. The tuple
# drifted out of step with the schema, so installs deleted live configuration
# for a block the schema still declared -- on a FRESH install, a block install.sh
# had seeded from settings.template.json a few hundred lines earlier. One such
# block carried the coordination board's seat ceiling, which fail-closes to 1
# when its key goes missing. The ceiling now lives at
# `coordination.max_concurrency`; the last sections here cover the rehome that
# put it there and the prune ordering that keeps it.
#
# The invariant these tests hold is the derivation, not the instance: the
# retired set comes from the schema, so it cannot disagree with the schema.
#
# `settlement` is now genuinely retired -- absent from the schema and template
# -- so it appears here only as a legacy block injected into a fixture, which
# is the shape a live install still carries.
#
# Falsifiers (each run against this suite, not merely asserted):
#   - Reverting prune-retired-settings.py to a fixed key tuple fails "key
#     present in the schema survives", "surviving key keeps its values", "every
#     shipped template top-level key survives", "pruned set is exactly the
#     schema complement", "no backup is written when there is nothing to
#     prune", and the fresh-install regression.
#   - Making the prune a no-op fails "key absent from the schema is pruned"
#     (and, consequently, the .bak content test).
#   - Dropping the shutil.copy2 backup fails "prune writes a .bak carrying the
#     pre-prune content".
#   - Re-declaring `settlement` in the schema fails "a legacy settlement block
#     is pruned" and the fresh-install regression.

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

# The settlement block as a live install still carries it: retired from the
# schema and template, but present on disk until the next prune runs.
LEGACY_SETTLEMENT='{"enabled": false, "max_concurrency": 10}'

add_legacy_settlement() {
  F="${1:-$SETTINGS}" BLOCK="$LEGACY_SETTLEMENT" python3 - <<'PY'
import json, os
p = os.environ["F"]
with open(p) as f:
    d = json.load(f)
d["settlement"] = json.loads(os.environ["BLOCK"])
with open(p, "w") as f:
    json.dump(d, f, indent=2, sort_keys=True)
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
  # `coordination` is live: schema property, shipped template block, and the
  # board reads it.
  seed_settings
  has_key "$SETTINGS" coordination

  run_prune
  [ "$status" -eq 0 ]

  has_key "$SETTINGS" coordination
}

@test "a legacy settlement block is pruned" {
  # The retirement, stated as an absence: a settings file still carrying the
  # block loses it, because the schema no longer declares it. Re-declaring
  # `settlement` in the schema fails this test.
  seed_settings
  add_legacy_settlement
  has_key "$SETTINGS" settlement

  run_prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"pruned: settlement"* ]]

  ! has_key "$SETTINGS" settlement
}

@test "surviving key keeps its values (max_concurrency is not lost)" {
  # The concrete cost of the old prune: a block the schema still declares must
  # come back with its values, not merely its name.
  seed_settings
  SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os
p = os.environ["SETTINGS"]
with open(p) as f:
    d = json.load(f)
d["coordination"]["max_concurrency"] = 10
with open(p, "w") as f:
    json.dump(d, f, indent=2)
PY

  run_prune
  [ "$status" -eq 0 ]

  run python3 -c "import json;print(json.load(open('$SETTINGS'))['coordination']['max_concurrency'])"
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
  has_key "$SETTINGS" coordination
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
  has_key "$SETTINGS.bak" coordination
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

# --- Coordination ceiling rehome ---------------------------------------------

REHOME="$REPO_DIR/scripts/migrations/rehome-coordination-max-concurrency.py"

# A LORE_DATA_DIR-shaped tree holding a settings.json seeded from the template.
# The argument is python source run with `d` bound to the parsed document.
seed_data_dir() {
  DATA_DIR="$TMP/data"
  DATA_SETTINGS="$DATA_DIR/config/settings.json"
  mkdir -p "$DATA_DIR/config"
  TEMPLATE="$TEMPLATE" OUT="$DATA_SETTINGS" MUTATE="${1:-}" \
    LEGACY="$LEGACY_SETTLEMENT" python3 - <<'PY'
import json, os
with open(os.environ["TEMPLATE"]) as f:
    d = json.load(f)
# The rehome's whole subject is a settings file written before the retirement,
# so the fixture carries the block the template no longer ships.
d["settlement"] = json.loads(os.environ["LEGACY"])
exec(os.environ["MUTATE"])
with open(os.environ["OUT"], "w") as f:
    json.dump(d, f, indent=2, sort_keys=True)
    f.write("\n")
PY
}

run_rehome() {
  run env LORE_DATA_DIR="$TMP/data" python3 "$REHOME" "$@"
}

# Print the value at a dot-separated path, or nothing when the path is absent.
value_at() {
  F="$1" K="$2" python3 - <<'PY'
import json, os
with open(os.environ["F"]) as f:
    node = json.load(f)
for seg in os.environ["K"].split("."):
    node = node.get(seg) if isinstance(node, dict) else None
    if node is None:
        break
print("" if node is None else node)
PY
}

@test "rehome carries a live settlement ceiling onto the coordination key" {
  [ -f "$REHOME" ] || skip "rehome migration missing"
  seed_data_dir 'd.pop("coordination", None); d["settlement"]["max_concurrency"] = 10'

  run_rehome
  [ "$status" -eq 0 ]
  [[ "$output" == *"rehomed"* ]]

  [ "$(value_at "$DATA_SETTINGS" coordination.max_concurrency)" = "10" ]
  # A copy, not a move: removing the source is the prune's job, and it must not
  # happen until the schema stops declaring the block.
  [ "$(value_at "$DATA_SETTINGS" settlement.max_concurrency)" = "10" ]
}

@test "re-running the rehome leaves the file byte-identical" {
  [ -f "$REHOME" ] || skip "rehome migration missing"
  seed_data_dir 'd.pop("coordination", None); d["settlement"]["max_concurrency"] = 10'

  run_rehome
  [ "$status" -eq 0 ]
  after_first="$(cat "$DATA_SETTINGS")"

  run_rehome
  [ "$status" -eq 0 ]
  [[ "$output" == *"already-rehomed"* ]]
  [ "$(cat "$DATA_SETTINGS")" = "$after_first" ]
}

@test "a coordination ceiling already in the file is never overwritten" {
  # The owner's hand-set ceiling outranks whatever the old key still says.
  [ -f "$REHOME" ] || skip "rehome migration missing"
  seed_data_dir 'd["coordination"]["max_concurrency"] = 3; d["settlement"]["max_concurrency"] = 10'

  run_rehome
  [ "$status" -eq 0 ]
  [[ "$output" == *"already-rehomed"* ]]
  [ "$(value_at "$DATA_SETTINGS" coordination.max_concurrency)" = "3" ]
}

@test "rehome writes nothing when there is no ceiling to carry" {
  [ -f "$REHOME" ] || skip "rehome migration missing"
  seed_data_dir 'd.pop("coordination", None); d["settlement"].pop("max_concurrency", None)'
  before="$(cat "$DATA_SETTINGS")"

  run_rehome
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-source"* ]]
  [ "$(cat "$DATA_SETTINGS")" = "$before" ]
}

@test "rehome with no settings file creates none" {
  [ -f "$REHOME" ] || skip "rehome migration missing"
  mkdir -p "$TMP/data/config"

  run_rehome
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-settings"* ]]
  [ ! -f "$TMP/data/config/settings.json" ]
}

@test "the rehomed ceiling survives the prune that retires the settlement block" {
  # The ordering this whole phase exists to establish, run against the real
  # schema now that it has stopped declaring `settlement`. Whether the
  # retirement costs the board its seats is decided entirely by whether the
  # rehome ran first.
  [ -f "$REHOME" ] || skip "rehome migration missing"
  seed_data_dir 'd.pop("coordination", None); d["settlement"]["max_concurrency"] = 10'

  run_rehome
  [ "$status" -eq 0 ]

  run python3 "$PRUNE" --settings "$DATA_SETTINGS" --schema "$SCHEMA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pruned: settlement"* ]]

  ! has_key "$DATA_SETTINGS" settlement
  [ "$(value_at "$DATA_SETTINGS" coordination.max_concurrency)" = "10" ]
}

@test "a prune without the rehome loses the ceiling to the schema default" {
  # The counterfactual that gives the ordering its teeth: skip the rehome and
  # the prune takes the only copy of the ceiling with it.
  seed_data_dir 'd.pop("coordination", None); d["settlement"]["max_concurrency"] = 10'

  run python3 "$PRUNE" --settings "$DATA_SETTINGS" --schema "$SCHEMA"
  [ "$status" -eq 0 ]

  ! has_key "$DATA_SETTINGS" settlement
  [ -z "$(value_at "$DATA_SETTINGS" coordination.max_concurrency)" ]
}

# --- Fresh-install regression ------------------------------------------------

@test "fresh install ships no settlement block and a real coordination ceiling" {
  # End-to-end against the real installer. The original defect was install.sh
  # seeding a block from the template and deleting it in the same run, leaving a
  # brand-new install with its concurrency ceiling already fail-closed. Settlement
  # is retired now, so the assertion inverts: the block must be absent, and the
  # ceiling must still arrive from the template as a real key.
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
  ceiling=""
  if [ "$install_status" -eq 0 ] && [ -f "$settings_file" ]; then
    if has_key "$settings_file" settlement; then key_present=0; else key_present=1; fi
    # Absence, asserted: a fresh install that seeds a settlement block again
    # flips this back to 0 and fails the test.
    # The board's ceiling arrives from the template, not from the reader's
    # fail-closed guard, so a fresh install has real configuration behind it.
    ceiling="$(value_at "$settings_file" coordination.max_concurrency)"
  fi

  # Cleanup must not decide the verdict — a stray read-only file left by any
  # install step would otherwise fail an otherwise-passing test.
  chmod -R u+w "$E2E_DATA" "$E2E_HOME" 2>/dev/null || true
  rm -rf "$E2E_DATA" "$E2E_HOME" 2>/dev/null || true

  [ "$install_status" -eq 0 ] || { echo "$install_output"; false; }
  [ "$key_present" -eq 1 ]
  [ "$ceiling" = "1" ]
}
