#!/usr/bin/env bats
# settings_schema_consumer_coherence.bats — top-level settings authority checks.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
BACKFILL="$REPO_DIR/scripts/backfill-settings.py"
SETTINGS_SH="$REPO_DIR/scripts/settings.sh"
SCHEMA="$REPO_DIR/adapters/settings.schema.json"
TEMPLATE="$REPO_DIR/adapters/settings.template.json"

setup() {
  [ -f "$BACKFILL" ] || skip "scripts/backfill-settings.py missing"
  [ -f "$SETTINGS_SH" ] || skip "scripts/settings.sh missing"
  [ -f "$SCHEMA" ] || skip "adapters/settings.schema.json missing"
  [ -f "$TEMPLATE" ] || skip "adapters/settings.template.json missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 unavailable"
  command -v jq >/dev/null 2>&1 || skip "jq unavailable"

  TMP="$(mktemp -d)"
  SETTINGS="$TMP/settings.json"
  DATA_DIR="$TMP/data"
  mkdir -p "$DATA_DIR/config"
}

teardown() {
  if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
    rm -rf "$TMP"
  fi
}

seed_without_sampling() {
  TEMPLATE="$TEMPLATE" SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os
with open(os.environ["TEMPLATE"], encoding="utf-8") as handle:
    doc = json.load(handle)
doc.pop("retro_sampling", None)
doc.pop("conformance_sampling", None)
with open(os.environ["SETTINGS"], "w", encoding="utf-8") as handle:
    json.dump(doc, handle, indent=2)
    handle.write("\n")
PY
}

run_backfill() {
  run python3 "$BACKFILL" --settings "$SETTINGS" \
    --schema "${1:-$SCHEMA}" --template "${2:-$TEMPLATE}"
}

value_at() {
  jq -c ".$2" "$1"
}

@test "sampling schema blocks are closed and constrain both rates to zero through one" {
  run python3 - "$SCHEMA" <<'PY'
import json, sys
schema = json.load(open(sys.argv[1], encoding="utf-8"))
properties = schema["properties"]
defs = schema["$defs"]
assert properties["retro_sampling"]["$ref"] == "#/$defs/retro_sampling_config"
assert properties["conformance_sampling"]["$ref"] == "#/$defs/conformance_sampling_config"
for block, key in (("retro_sampling_config", "routine_rate"),
                   ("conformance_sampling_config", "render_rate")):
    definition = defs[block]
    rate = definition["properties"][key]
    assert definition["additionalProperties"] is False
    assert rate["type"] == "number"
    assert rate["minimum"] == 0
    assert rate["maximum"] == 1
print("ok")
PY
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "every top-level settings key read by shell call sites is schema-declared" {
  run python3 - "$REPO_DIR" "$SCHEMA" <<'PY'
import json, re, sys
from pathlib import Path

root = Path(sys.argv[1])
schema = json.load(open(sys.argv[2], encoding="utf-8"))
declared = set(schema["properties"])
paths = [root / "install.sh"]
for dirname in ("scripts", "cli"):
    paths.extend(path for path in (root / dirname).rglob("*") if path.is_file())

reads = []
get_arg = re.compile(r"\sget\s+[\"']?([A-Za-z0-9_-]+)")
lore_get = re.compile(r"\blore\s+settings\s+get\s+[\"']?([A-Za-z0-9_-]+)")
for path in paths:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (UnicodeDecodeError, OSError):
        continue
    for number, line in enumerate(lines, 1):
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        match = lore_get.search(line)
        if match:
            reads.append((match.group(1), path.relative_to(root), number))
            continue
        if re.search(r"\bbash\b", line) and ("settings.sh" in line or "$settings_sh" in line):
            match = get_arg.search(line)
            if match:
                reads.append((match.group(1), path.relative_to(root), number))

# Liveness for the scanner: these are the current independently implemented
# consumer families. If one is intentionally removed, update this set with the
# same review that removes its call sites.
expected = {"harnesses", "capability_overrides", "coordination",
            "retro_sampling", "conformance_sampling"}
found = {key for key, _, _ in reads}
assert expected <= found, f"settings consumer scan lost live families: {sorted(expected - found)}"

unknown = [(key, str(path), line) for key, path, line in reads if key not in declared]
assert not unknown, "settings consumers read undeclared top-level keys: " + repr(unknown)
print(f"settings consumer coherence: {len(reads)} call sites, {len(found)} top-level keys")
PY
  [ "$status" -eq 0 ]
  [[ "$output" == settings\ consumer\ coherence:* ]]
}

@test "backfill adds missing sampling blocks from the template at 0.25" {
  seed_without_sampling

  run_backfill
  [ "$status" -eq 0 ]
  [[ "$output" == *"backfilled: retro_sampling, conformance_sampling"* ]]
  [ "$(value_at "$SETTINGS" retro_sampling.routine_rate)" = "0.25" ]
  [ "$(value_at "$SETTINGS" conformance_sampling.render_rate)" = "0.25" ]
}

@test "backfill never merges inside an existing top-level key" {
  printf '{\n  "version": 1,\n  "retro_sampling" : { "routine_rate" : 0.7500 }\n}\n' > "$SETTINGS"
  CUSTOM_TEMPLATE="$TMP/template.json"
  TEMPLATE="$TEMPLATE" OUT="$CUSTOM_TEMPLATE" python3 - <<'PY'
import json, os
doc = json.load(open(os.environ["TEMPLATE"], encoding="utf-8"))
doc["retro_sampling"]["future_nested_default"] = {"enabled": True}
with open(os.environ["OUT"], "w", encoding="utf-8") as handle:
    json.dump(doc, handle)
PY
  before="$(value_at "$SETTINGS" retro_sampling)"
  raw_before='  "retro_sampling" : { "routine_rate" : 0.7500 }'

  run_backfill "$SCHEMA" "$CUSTOM_TEMPLATE"
  [ "$status" -eq 0 ]
  [ "$(value_at "$SETTINGS" retro_sampling)" = "$before" ]
  grep -Fq "$raw_before" "$SETTINGS"
  [ "$(value_at "$SETTINGS" conformance_sampling.render_rate)" = "0.25" ]
}

@test "backfill is byte-idempotent after missing keys are added" {
  seed_without_sampling
  run_backfill
  [ "$status" -eq 0 ]
  after_first="$(cat "$SETTINGS")"

  run_backfill
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$SETTINGS")" = "$after_first" ]
}

@test "backfill refuses a missing schema and leaves settings untouched" {
  seed_without_sampling
  before="$(cat "$SETTINGS")"

  run_backfill "$TMP/missing-schema.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema unreadable"* ]]
  [ "$(cat "$SETTINGS")" = "$before" ]
}

@test "backfill refuses malformed schema JSON and leaves settings untouched" {
  seed_without_sampling
  BAD_SCHEMA="$TMP/bad-schema.json"
  printf '{broken\n' > "$BAD_SCHEMA"
  before="$(cat "$SETTINGS")"

  run_backfill "$BAD_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"schema is not valid JSON"* ]]
  [ "$(cat "$SETTINGS")" = "$before" ]
}

@test "backfill refuses an open schema and leaves settings untouched" {
  seed_without_sampling
  OPEN_SCHEMA="$TMP/open-schema.json"
  SCHEMA="$SCHEMA" OUT="$OPEN_SCHEMA" python3 - <<'PY'
import json, os
doc = json.load(open(os.environ["SCHEMA"], encoding="utf-8"))
doc["additionalProperties"] = True
json.dump(doc, open(os.environ["OUT"], "w", encoding="utf-8"))
PY
  before="$(cat "$SETTINGS")"

  run_backfill "$OPEN_SCHEMA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"additionalProperties:false"* ]]
  [ "$(cat "$SETTINGS")" = "$before" ]
}

@test "backfill refuses malformed template JSON and leaves settings untouched" {
  seed_without_sampling
  BAD_TEMPLATE="$TMP/bad-template.json"
  printf '{broken\n' > "$BAD_TEMPLATE"
  before="$(cat "$SETTINGS")"

  run_backfill "$SCHEMA" "$BAD_TEMPLATE"
  [ "$status" -ne 0 ]
  [[ "$output" == *"template is not valid JSON"* ]]
  [ "$(cat "$SETTINGS")" = "$before" ]
}

@test "backfill refuses a missing template and leaves settings untouched" {
  seed_without_sampling
  before="$(cat "$SETTINGS")"

  run_backfill "$SCHEMA" "$TMP/missing-template.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"template unreadable"* ]]
  [ "$(cat "$SETTINGS")" = "$before" ]
}

@test "backfill refuses malformed settings JSON without replacing it" {
  printf '{broken\n' > "$SETTINGS"
  before="$(cat "$SETTINGS")"

  run_backfill
  [ "$status" -ne 0 ]
  [[ "$output" == *"settings is not valid JSON"* ]]
  [ "$(cat "$SETTINGS")" = "$before" ]
}

@test "settings patch refuses to create an undeclared top-level key" {
  printf '{}\n' > "$DATA_DIR/config/settings.json"
  before="$(cat "$DATA_DIR/config/settings.json")"

  run env LORE_DATA_DIR="$DATA_DIR" bash "$SETTINGS_SH" patch phantom.value 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"authoritative schema at $SCHEMA"* ]]
  [ "$(cat "$DATA_DIR/config/settings.json")" = "$before" ]
}

@test "settings patch permits declared-key creation and existing unknown-key writes" {
  printf '{"legacy_block":{"value":1}}\n' > "$DATA_DIR/config/settings.json"

  run env LORE_DATA_DIR="$DATA_DIR" bash "$SETTINGS_SH" patch conformance_sampling.render_rate 0.5
  [ "$status" -eq 0 ]
  [ "$(value_at "$DATA_DIR/config/settings.json" conformance_sampling.render_rate)" = "0.5" ]

  run env LORE_DATA_DIR="$DATA_DIR" bash "$SETTINGS_SH" patch legacy_block.value 2
  [ "$status" -eq 0 ]
  [ "$(value_at "$DATA_DIR/config/settings.json" legacy_block.value)" = "2" ]
}

@test "settings patch keeps prior behavior when the schema is missing" {
  STANDALONE="$TMP/standalone/scripts"
  mkdir -p "$STANDALONE"
  cp "$SETTINGS_SH" "$STANDALONE/settings.sh"
  printf '{}\n' > "$DATA_DIR/config/settings.json"

  run env LORE_DATA_DIR="$DATA_DIR" bash "$STANDALONE/settings.sh" patch phantom.value 1
  [ "$status" -eq 0 ]
  [ "$(value_at "$DATA_DIR/config/settings.json" phantom.value)" = "1" ]
}
