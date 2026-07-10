#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE="$REPO_DIR/cli/lore"

setup() {
  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"
  export LORE_FRAMEWORK=codex
  mkdir -p "$TEST_KDIR/_work/discover-item" "$TEST_KDIR/preferences" "$TEST_KDIR/conventions/nested"
  printf '%s\n' '{"title":"Discover Item","status":"active"}' > "$TEST_KDIR/_work/discover-item/_meta.json"
  printf '%s\n' '# Discover Item' '## Phases' '- [ ] Build [class: standard]' > "$TEST_KDIR/_work/discover-item/plan.md"
  printf '%s\n' '# Preference One' 'Keep the preference visible.' > "$TEST_KDIR/preferences/one.md"
  printf '%s\n' '# Convention Two' 'Keep nested enumeration visible.' > "$TEST_KDIR/conventions/nested/two.md"
}

teardown() { rm -rf "$TEST_KDIR"; unset LORE_KNOWLEDGE_DIR LORE_FRAMEWORK; }

@test "discover returns coverage and raw source-native candidates without applicability fields" {
  run bash "$LORE" spec discover discover-item --json
  [ "$status" -eq 0 ]
  echo "$output" | grep '"schema_version"' | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert set(d)=={"schema_version","coverage","candidates","provenance"}
assert d["schema_version"]==1
assert d["provenance"]["ordering"]=="source-native"
assert d["provenance"]["applicability_decided"] is False
ids={r["source_id"] for r in d["coverage"]}
assert {"harness-skills-root","harness-skills-system","harness-skills-plugins","harness-agents","preferences-tree","conventions-tree","cross-cutting-conventions-tree","bm25-subsystem-implementation","bm25-abstract-architecture"} <= ids
paths=[r["path"] for r in d["candidates"]]
assert "preferences/one.md" in paths and "conventions/nested/two.md" in paths
for row in d["candidates"]:
    assert set(row)=={"source_id","kind","path","query","source_rank","source_score","metadata"}
    assert not ({"applicability","matched","binding","combined_rank"} & set(row))
'
  [ ! -e "$TEST_KDIR/_work/discover-item/execution-log.md" ]
}

@test "discover exposes missing strata instead of silently dropping them" {
  run bash "$LORE" spec discover discover-item --json
  [ "$status" -eq 0 ]
  echo "$output" | grep '"schema_version"' | python3 -c '
import json,sys
d=json.load(sys.stdin)
row=next(r for r in d["coverage"] if r["source_id"]=="cross-cutting-conventions-tree")
assert row["status"]=="missing" and row["candidate_count"]==0 and row["gap_reason"]
'
}

@test "discover requires a work reference and rejects unknown flags" {
  run bash "$LORE" spec discover --json
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "missing required argument"
  run bash "$LORE" spec discover discover-item --rank
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "unknown flag"
}
