#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE="$REPO_DIR/cli/lore"

write_manifest() {
  local code_question="${1:-How should the code work?}"
  python3 - "$MANIFEST" "$code_question" <<'PY'
import json,sys
path, question=sys.argv[1:]
json.dump({"schema_version":1,"track":"full","investigations":[
 {"id":"external","kind":"fixed","question":"External skill and agent applicability","complexity":"simple","prefetch":[]},
 {"id":"preferences","kind":"fixed","question":"Preferences and conventions applicability","complexity":"simple","prefetch":[]},
 {"id":"code","kind":"lead-authored","question":question,"complexity":"moderate","prefetch":[]}
]},open(path,"w"),separators=(",",":"))
PY
}

setup() {
  TEST_KDIR="$(mktemp -d)"
  ORIGINAL_HOME="$HOME"
  TEST_HOME="$TEST_KDIR/home"
  mkdir -p "$TEST_HOME/.lore"
  ln -s "$REPO_DIR/scripts" "$TEST_HOME/.lore/scripts"
  export HOME="$TEST_HOME"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"
  export LORE_FRAMEWORK=codex
  export LORE_MODEL_RESEARCHER=test-researcher-model
  mkdir -p "$TEST_KDIR/_work/open-item"
  printf '%s\n' '{"title":"Open Item","status":"active"}' > "$TEST_KDIR/_work/open-item/_meta.json"
  printf '%s\n' '# Open Item' '## Phases' '- [ ] Build [class: standard]' > "$TEST_KDIR/_work/open-item/plan.md"
  MANIFEST="$TEST_KDIR/investigations.json"
  write_manifest
}

teardown() {
  export HOME="$ORIGINAL_HOME"
  rm -rf "$TEST_KDIR"
  unset LORE_KNOWLEDGE_DIR LORE_FRAMEWORK LORE_MODEL_RESEARCHER
}

json_line() { echo "$output" | grep '"schema_version"'; }
atom_count() { grep -c '^Spec-open-atom:' "$TEST_KDIR/_work/open-item/execution-log.md" 2>/dev/null || true; }

@test "open publishes canonical artifact before one completion atom and returns Codex fanout directives" {
  run bash "$LORE" spec open open-item --investigations "$MANIFEST" --json
  [ "$status" -eq 0 ]
  json_line | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["status"]=="created" and d["schema_version"]==1
assert d["source_manifest"]["adapter_capabilities"]["team_messaging"]=="none"
assert d["source_manifest"]["adapter_capabilities"]["subagents"]=="partial"
assert len(d["directives"])==3
assert [r["ordinal"] for r in d["directives"]]==[1,2,3]
assert all(r["action"]=="spawn" and r["teardown_payload"]["action"]=="shutdown" for r in d["directives"])
identity=d["source_manifest"]["dispatch_guidance_identity"]
assert identity["schema_version"]==1 and identity["defaults_digest"].startswith("sha256:")
assert all("<!-- lore-dispatch-guidance:v1:begin -->" in r["payload"]["dispatch_guidance"] for r in d["directives"])
'
  [ -f "$TEST_KDIR/_work/open-item/spec-dispatch.json" ]
  [ "$(atom_count)" -eq 1 ]
  python3 - "$TEST_KDIR/_work/open-item/spec-dispatch.json" "$TEST_KDIR/_work/open-item/execution-log.md" <<'PY'
import hashlib,json,re,sys
artifact,log=sys.argv[1:]
raw=open(artifact,"rb").read()
assert not raw.endswith(b"\n")
d=json.loads(raw)
atom=json.loads(re.findall(r"(?m)^Spec-open-atom: (\{.*\})$",open(log).read())[-1])
assert atom["artifact_sha256"]==hashlib.sha256(raw).hexdigest()
assert atom["input_fingerprint"]==d["input_fingerprint"]
PY
}

@test "every generated researcher directive carries guidance accepted by the canonical validator" {
  run bash "$LORE" spec open open-item --investigations "$MANIFEST" --json
  [ "$status" -eq 0 ]
  local prompt="$TEST_KDIR/researcher-prompt.txt"
  json_line | jq -r '.directives[0].payload.dispatch_guidance + "\nInvestigate the declared question."' > "$prompt"
  run bash "$REPO_DIR/scripts/validate-dispatch-guidance.sh" --prompt-file "$prompt"
  [ "$status" -eq 0 ]
}

@test "exact replay is reused and appends no second atom" {
  run bash "$LORE" spec open open-item --investigations "$MANIFEST" --json
  [ "$status" -eq 0 ]
  run bash "$LORE" spec open open-item --investigations "$MANIFEST" --json
  [ "$status" -eq 0 ]
  json_line | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"]=="reused"'
  [ "$(atom_count)" -eq 1 ]
}

@test "artifact without atom recovers only the missing completion marker" {
  run bash "$LORE" spec open open-item --investigations "$MANIFEST" --json
  [ "$status" -eq 0 ]
  rm "$TEST_KDIR/_work/open-item/execution-log.md"
  before=$(shasum -a 256 "$TEST_KDIR/_work/open-item/spec-dispatch.json" | awk '{print $1}')
  run bash "$LORE" spec open open-item --investigations "$MANIFEST" --json
  [ "$status" -eq 0 ]
  json_line | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"]=="recovered"'
  after=$(shasum -a 256 "$TEST_KDIR/_work/open-item/spec-dispatch.json" | awk '{print $1}')
  [ "$before" = "$after" ]
  [ "$(atom_count)" -eq 1 ]
}

@test "changed declared input replaces the artifact with a new fingerprint and atom" {
  run bash "$LORE" spec open open-item --investigations "$MANIFEST" --json
  [ "$status" -eq 0 ]
  old=$(json_line | python3 -c 'import json,sys; print(json.load(sys.stdin)["input_fingerprint"])')
  write_manifest "Which code path owns publication?"
  run bash "$LORE" spec open open-item --investigations "$MANIFEST" --json
  [ "$status" -eq 0 ]
  json_line | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["status"]=="replaced"'
  new=$(json_line | python3 -c 'import json,sys; print(json.load(sys.stdin)["input_fingerprint"])')
  [ "$old" != "$new" ]
  [ "$(atom_count)" -eq 2 ]
}

@test "open refuses missing declarations and invalid schemas before publication" {
  run bash "$LORE" spec open open-item --json
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "missing required declaration"

  python3 - "$MANIFEST" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); d["track"]="short"; d["mystery"]=1
json.dump(d,open(sys.argv[1],"w"))
PY
  run bash "$LORE" spec open open-item --investigations "$MANIFEST" --json
  [ "$status" -eq 1 ]
  [ ! -e "$TEST_KDIR/_work/open-item/spec-dispatch.json" ]

  printf '%s' '{"schema_version":1,"track":"full","investigations":[]}' > "$MANIFEST"
  run bash "$LORE" spec open open-item --investigations "$MANIFEST" --json
  [ "$status" -eq 1 ]
  [ ! -e "$TEST_KDIR/_work/open-item/spec-dispatch.json" ]
}
