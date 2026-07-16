#!/usr/bin/env bats

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE="$REPO_DIR/cli/lore"

setup() {
  command -v git >/dev/null 2>&1 || skip "git required"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"

  TEST_ROOT="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_ROOT/knowledge"
  export LORE_FRAMEWORK=codex
  PROJECT="$TEST_ROOT/project"
  ITEM_DIR="$LORE_KNOWLEDGE_DIR/_work/render-item"
  DEGRADED_DIR="$LORE_KNOWLEDGE_DIR/_work/degraded-item"
  mkdir -p "$PROJECT/scripts" "$ITEM_DIR" "$DEGRADED_DIR" \
    "$LORE_KNOWLEDGE_DIR/conventions/scripting"

  git -C "$PROJECT" init -q -b main
  git -C "$PROJECT" config user.email tests@example.com
  git -C "$PROJECT" config user.name "Lore Tests"
  printf '%s\n' '#!/usr/bin/env bash' 'echo base' > "$PROJECT/scripts/widget.sh"
  git -C "$PROJECT" add scripts/widget.sh
  git -C "$PROJECT" commit -qm "base"
  printf '%s\n' 'echo changed' >> "$PROJECT/scripts/widget.sh"
  printf '%s\n' '# widget helper' > "$PROJECT/scripts/helper.md"
  git -C "$PROJECT" add scripts/widget.sh scripts/helper.md
  git -C "$PROJECT" commit -qm "change widget"
  BASE_SHA="$(git -C "$PROJECT" rev-parse HEAD~1)"

  python3 - "$ITEM_DIR/_meta.json" "$DEGRADED_DIR/_meta.json" <<'PY'
import json, sys
for path, slug in zip(sys.argv[1:], ("render-item", "degraded-item")):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump({"slug": slug, "title": slug.replace("-", " ").title(),
                   "status": "active"}, handle)
PY
  cat > "$ITEM_DIR/plan.md" <<'EOF'
# Render Item

## Phases

### Phase 1: Build
- [x] Build the widget

**Related preferences/conventions:**
- [[knowledge:conventions/scripting/safe-widget-edits]] — keep widget changes safe
EOF
  cat > "$ITEM_DIR/tasks.json" <<'EOF'
{"phases":[{"tasks":[{"id":"task-1","woven_norms":["safe-widget-edits"]}]}]}
EOF
  cat > "$ITEM_DIR/execution-log.md" <<'EOF'
Convention handling: clean; missing=[]; duplicated=[]; unrecognized=[]; diverged=[{"label": "safe-widget-edits", "rationale": "the fixture has no deployment step"}]
EOF
  printf '%s\n' '# Safe Widget Edits' > \
    "$LORE_KNOWLEDGE_DIR/conventions/scripting/safe-widget-edits.md"
}

teardown() {
  rm -rf "$TEST_ROOT"
  unset LORE_KNOWLEDGE_DIR LORE_FRAMEWORK
}

run_conformance() {
  run bash -c 'cd "$1" && exec "$2" work conformance "$3" --diff-base "$4" --json' \
    _ "$PROJECT" "$LORE" "$1" "$BASE_SHA"
}

@test "full render writes five panels, a cross-tab, and schema version 1 without judgment fields" {
  run_conformance render-item
  [ "$status" -eq 0 ]
  [ -f "$ITEM_DIR/closure-conformance.md" ]
  for panel in \
    "Panel A — Spec-Time Discovery" \
    "Panel B — Woven Norms" \
    "Panel C — Recorded Dispositions" \
    "Panel D — Shipped Diff" \
    "Panel E — Closure-Time Diff-Seeded Discovery" \
    "Label Cross-Tabulation"; do
    grep -Fq "$panel" "$ITEM_DIR/closure-conformance.md"
  done
  ! grep -Eqi 'verdict|"verdict"' "$ITEM_DIR/closure-conformance.md"
  python3 - "$ITEM_DIR/closure-conformance.md" "$BASE_SHA" <<'PY'
import json, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
payload = json.loads(re.search(r"```json\n(.*?)\n```", text, re.S).group(1))
assert payload["schema_version"] == 1
assert payload["diff"]["base_sha"] == sys.argv[2]
assert {row["path"] for row in payload["diff"]["files"]} == {
    "scripts/helper.md", "scripts/widget.sh"}
assert payload["spec_discovery"][0]["label"] == "safe-widget-edits"
assert payload["woven_norms"] == [{"label": "safe-widget-edits", "task_ids": ["task-1"]}]
assert payload["recorded_dispositions"][0]["rationale"] == "the fixture has no deployment step"
assert set(payload["panel_coverage"]) == {
    "spec_discovery", "woven_norms", "recorded_dispositions",
    "shipped_diff", "closure_discovery"}
PY
}

@test "degraded render names unavailable panels while retaining the diff" {
  run_conformance degraded-item
  [ "$status" -eq 0 ]
  artifact="$DEGRADED_DIR/closure-conformance.md"
  [ -f "$artifact" ]
  grep -Fq "Spec Discovery: absent" "$artifact"
  grep -Fq "Woven Norms: absent" "$artifact"
  grep -Fq "Recorded Dispositions: absent" "$artifact"
  grep -Fq "Shipped Diff: present" "$artifact"
  grep -Fq '`scripts/widget.sh`' "$artifact"
}

@test "unknown work references preserve resolver exit codes" {
  run bash -c 'cd "$1" && exec "$2" work conformance no-such-item --diff-base HEAD~1' \
    _ "$PROJECT" "$LORE"
  [ "$status" -eq 1 ]
}
