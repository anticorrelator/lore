#!/usr/bin/env bats
# impl_consult_log.bats — Coverage for `lore impl consult-log` (impl-consult-log.sh)
#
# Asserts:
#   - consultation metadata and the lead's answer are required flags;
#     missing any exits non-zero BEFORE any write
#   - --handler is enum-validated (lead|skill|agent)
#   - per-handler field contract (--skill-template-version / --advisor-template-version)
#   - transcript record appended to consultation-transcript.jsonl with
#     provenance (template_version, captured_at_sha, replied_at)
#   - execution-log entry via write-execution-log.sh, source impl-verb,
#     Step 4.0 line format with JSON-string encoded question/answer
#   - exactly one transcript record + one log entry per invocation
#   - tri-state reference resolution passthrough; --json output shape
#
# All tests use an isolated knowledge directory via LORE_KNOWLEDGE_DIR.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE_CLI="$REPO_DIR/cli/lore"
CONSULT_SH="$REPO_DIR/scripts/impl-consult-log.sh"

setup() {
  [ -x "$LORE_CLI" ] || skip "cli/lore missing"
  [ -f "$CONSULT_SH" ] || skip "impl-consult-log.sh missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"

  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"

  WORK_DIR="$TEST_KDIR/_work"
  mkdir -p "$WORK_DIR/active-item" "$WORK_DIR/second-item"
  printf '{"title": "Active Item", "intent_anchor": "Ship it."}\n' > "$WORK_DIR/active-item/_meta.json"
  printf '{"title": "Second Item"}\n' > "$WORK_DIR/second-item/_meta.json"
}

teardown() {
  if [ -n "${TEST_KDIR:-}" ] && [ -d "$TEST_KDIR" ]; then
    rm -rf "$TEST_KDIR"
  fi
  unset LORE_KNOWLEDGE_DIR
}

transcript_file() { echo "$WORK_DIR/active-item/consultation-transcript.jsonl"; }
log_file() { echo "$WORK_DIR/active-item/execution-log.md"; }

# Filed-with-all-required-flags invocation; extra args override/append.
file_lead_consultation() {
  run bash "$LORE_CLI" impl consult-log active-item \
    --consultation-id q-1 --worker worker-2 --domain testing --handler lead \
    --question "which fixture applies?" --answer "use the temp kdir" "$@"
}

# bats `run` merges stderr into $output — take the last JSON object line.
json_payload() {
  echo "$output" | python3 -c '
import json, sys
last = None
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        last = json.loads(line)
    except ValueError:
        continue
print(json.dumps(last))
'
}

assert_no_writes() {
  [ ! -f "$(transcript_file)" ]
  [ ! -f "$(log_file)" ]
}

# --- Required metadata and answer (error before any write) -----------------

@test "missing --consultation-id exits 1 naming the flag, no writes" {
  run bash "$LORE_CLI" impl consult-log active-item \
    --worker worker-2 --domain testing --handler lead --question "q" --answer "a"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--consultation-id is required"
  assert_no_writes
}

@test "missing --worker exits 1 naming the flag, no writes" {
  run bash "$LORE_CLI" impl consult-log active-item \
    --consultation-id q-1 --domain testing --handler lead --question "q" --answer "a"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--worker is required"
  assert_no_writes
}

@test "missing --domain exits 1 naming the flag, no writes" {
  run bash "$LORE_CLI" impl consult-log active-item \
    --consultation-id q-1 --worker worker-2 --handler lead --question "q" --answer "a"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--domain is required"
  assert_no_writes
}

@test "missing --handler exits 1 naming the flag, no writes" {
  run bash "$LORE_CLI" impl consult-log active-item \
    --consultation-id q-1 --worker worker-2 --domain testing --question "q" --answer "a"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--handler is required"
  assert_no_writes
}

@test "missing --question exits 1 naming the flag, no writes" {
  run bash "$LORE_CLI" impl consult-log active-item \
    --consultation-id q-1 --worker worker-2 --domain testing --handler lead --answer "a"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--question is required"
  assert_no_writes
}

@test "missing --answer exits 1 naming the flag, no writes" {
  run bash "$LORE_CLI" impl consult-log active-item \
    --consultation-id q-1 --worker worker-2 --domain testing --handler lead --question "q"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q -- "--answer is required"
  assert_no_writes
}

@test "invalid handler exits 1 listing the enum" {
  file_lead_consultation --handler sideways
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "lead|skill|agent"
  assert_no_writes
}

# --- Per-handler field contract ---------------------------------------------

@test "handler lead with --skill-template-version is rejected" {
  file_lead_consultation --skill-template-version abcdef123456
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "does not take --skill-template-version"
  assert_no_writes
}

@test "handler lead with --advisor-template-version is rejected" {
  file_lead_consultation --advisor-template-version abcdef123456
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "does not take --advisor-template-version"
  assert_no_writes
}

@test "handler skill without --skill-template-version is rejected" {
  file_lead_consultation --handler skill
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "requires --skill-template-version"
  assert_no_writes
}

@test "handler skill with --advisor-template-version is rejected" {
  file_lead_consultation --handler skill --skill-template-version abcdef123456 \
    --advisor-template-version fedcba654321
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "does not take --advisor-template-version"
  assert_no_writes
}

@test "handler agent without --advisor-template-version is rejected" {
  file_lead_consultation --handler agent
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "requires --advisor-template-version"
  assert_no_writes
}

@test "handler agent with --skill-template-version is rejected" {
  file_lead_consultation --handler agent --advisor-template-version fedcba654321 \
    --skill-template-version abcdef123456
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "does not take --skill-template-version"
  assert_no_writes
}

# --- Lead handler: transcript record + log entry ------------------------------

@test "lead consultation appends one transcript record with full fields" {
  file_lead_consultation
  [ "$status" -eq 0 ]
  [ -f "$(transcript_file)" ]
  [ "$(grep -c '[^[:space:]]' "$(transcript_file)")" -eq 1 ]
  python3 - "$(transcript_file)" <<'PYEOF'
import json, sys
row = json.loads(open(sys.argv[1]).read().strip())
assert row["consultation_id"] == "q-1"
assert row["worker"] == "worker-2"
assert row["domain"] == "testing"
assert row["handler"] == "lead"
assert row["skill_template_version"] is None
assert row["advisor_template_version"] is None
assert row["question"] == "which fixture applies?"
assert row["answer"] == "use the temp kdir"
assert row["replied_at"]
PYEOF
}

@test "transcript record carries provenance (template_version + captured_at_sha keys)" {
  file_lead_consultation
  [ "$status" -eq 0 ]
  python3 - "$(transcript_file)" <<'PYEOF'
import json, sys
row = json.loads(open(sys.argv[1]).read().strip())
assert "template_version" in row
assert "captured_at_sha" in row
PYEOF
}

@test "lead consultation appends exactly one execution-log entry with source impl-verb" {
  file_lead_consultation
  [ "$status" -eq 0 ]
  [ "$(grep -c '^## ' "$(log_file)")" -eq 1 ]
  grep -q "source: impl-verb" "$(log_file)"
}

@test "log entry carries the Step 4.0 labeled lines in order" {
  file_lead_consultation
  [ "$status" -eq 0 ]
  python3 - "$(log_file)" <<'PYEOF'
import sys
lines = [l for l in open(sys.argv[1]).read().splitlines() if l.strip()]
labels = [
    "Consultation: q-1",
    "Worker: worker-2",
    "Domain: testing",
    "Consultation-handler: lead",
    "Question: ",
    "Answer summary: ",
]
idx = [next(i for i, l in enumerate(lines) if l.startswith(p)) for p in labels]
assert idx == sorted(idx), f"labels out of order: {idx}"
PYEOF
}

@test "multi-line answer is JSON-string encoded on a single log line" {
  file_lead_consultation --answer $'first line\nsecond line'
  [ "$status" -eq 0 ]
  answer_line=$(grep "^Answer summary: " "$(log_file)")
  echo "$answer_line" | python3 -c '
import json, sys
raw = sys.stdin.read().removeprefix("Answer summary: ").strip()
assert json.loads(raw) == "first line\nsecond line"
'
}

@test "log entry stamps a 12-hex Template-version header" {
  file_lead_consultation
  [ "$status" -eq 0 ]
  grep -qE '^Template-version: [0-9a-f]{12}$' "$(log_file)"
}

@test "--template-version override is used verbatim on the log header and transcript" {
  file_lead_consultation --template-version abcdef123456
  [ "$status" -eq 0 ]
  grep -q '^Template-version: abcdef123456$' "$(log_file)"
  python3 - "$(transcript_file)" <<'PYEOF'
import json, sys
row = json.loads(open(sys.argv[1]).read().strip())
assert row["template_version"] == "abcdef123456"
PYEOF
}

# --- Skill and agent handlers --------------------------------------------------

@test "skill handler files Skill template-version between handler and Question" {
  file_lead_consultation --handler skill --skill-template-version abcdef123456
  [ "$status" -eq 0 ]
  python3 - "$(log_file)" <<'PYEOF'
import sys
lines = [l for l in open(sys.argv[1]).read().splitlines() if l.strip()]
h = next(i for i, l in enumerate(lines) if l.startswith("Consultation-handler: skill"))
tv = next(i for i, l in enumerate(lines) if l == "Skill template-version: abcdef123456")
q = next(i for i, l in enumerate(lines) if l.startswith("Question: "))
assert h < tv < q, (h, tv, q)
PYEOF
  python3 - "$(transcript_file)" <<'PYEOF'
import json, sys
row = json.loads(open(sys.argv[1]).read().strip())
assert row["handler"] == "skill"
assert row["skill_template_version"] == "abcdef123456"
assert row["advisor_template_version"] is None
PYEOF
}

@test "agent handler files Advisor template-version line and transcript field" {
  file_lead_consultation --handler agent --advisor-template-version fedcba654321
  [ "$status" -eq 0 ]
  grep -q '^Advisor template-version: fedcba654321$' "$(log_file)"
  python3 - "$(transcript_file)" <<'PYEOF'
import json, sys
row = json.loads(open(sys.argv[1]).read().strip())
assert row["handler"] == "agent"
assert row["advisor_template_version"] == "fedcba654321"
assert row["skill_template_version"] is None
PYEOF
}

# --- Accumulation ---------------------------------------------------------------

@test "second consultation appends a second transcript record and log entry" {
  file_lead_consultation
  [ "$status" -eq 0 ]
  run bash "$LORE_CLI" impl consult-log active-item \
    --consultation-id q-2 --worker worker-3 --domain schema --handler lead \
    --question "second q" --answer "second a"
  [ "$status" -eq 0 ]
  [ "$(grep -c '[^[:space:]]' "$(transcript_file)")" -eq 2 ]
  [ "$(grep -c '^## ' "$(log_file)")" -eq 2 ]
  echo "$output" | grep -q "record 2"
}

# --- Reference resolution: tri-state passthrough --------------------------------

@test "no-match reference exits 1" {
  run bash "$LORE_CLI" impl consult-log no-such-item-zzz \
    --consultation-id q-1 --worker w --domain d --handler lead --question "q" --answer "a"
  [ "$status" -eq 1 ]
}

@test "ambiguous reference exits 2" {
  cat > "$WORK_DIR/_index.json" <<'EOF'
{
  "version": 1,
  "plans": [
    {"slug": "active-item", "title": "Active Item", "tags": ["shared-tag"], "branches": []},
    {"slug": "second-item", "title": "Second Item", "tags": ["shared-tag"], "branches": []}
  ],
  "archived": []
}
EOF
  run bash "$LORE_CLI" impl consult-log shared-tag \
    --consultation-id q-1 --worker w --domain d --handler lead --question "q" --answer "a"
  [ "$status" -eq 2 ]
}

@test "archived work item is rejected" {
  mkdir -p "$WORK_DIR/_archive/done-item"
  printf '{"title": "Done Item"}\n' > "$WORK_DIR/_archive/done-item/_meta.json"
  run bash "$LORE_CLI" impl consult-log done-item \
    --consultation-id q-1 --worker w --domain d --handler lead --question "q" --answer "a"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "archived"
}

# --- JSON output -----------------------------------------------------------------

@test "--json returns transcript/log identifiers" {
  file_lead_consultation --json
  [ "$status" -eq 0 ]
  json_payload | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert d["slug"] == "active-item"
assert d["consultation_id"] == "q-1"
assert d["handler"] == "lead"
assert d["transcript_record"] == 1
assert d["transcript_path"].endswith("consultation-transcript.jsonl")
assert d["log_path"].endswith("execution-log.md")
assert d["replied_at"]
'
}

@test "--json on validation error returns error object with exit 1" {
  run bash "$LORE_CLI" impl consult-log active-item --json
  [ "$status" -eq 1 ]
  json_payload | python3 -c 'import json, sys; d = json.loads(sys.stdin.read()); assert "error" in d'
}
