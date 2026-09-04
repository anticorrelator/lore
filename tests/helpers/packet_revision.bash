# Adopt an isolated task fixture through the production revision writer.
packet_revision_fixture() {
  local fixture_item="$1" fixture_slug="$2"
  mkdir -p "$fixture_item"
  printf '%s\n' '{"title":"Packet fixture","status":"active","intent_anchor":"Preserve packet history."}' > "$fixture_item/_meta.json"
  cat > "$fixture_item/plan.md" <<'EOF'
# Packet fixture

## Intent Anchor
Preserve packet history.

**Scope delta:** none

## Tasks

**Merge rationale:** One packet fixture.

### Task 1: Record history
**Deliverable:** Packet history.
**Files:** `src/history.py`
- [ ] Record history [class: mechanical]
EOF
  cat > "$fixture_item/decisions.json" <<'EOF'
{"anchor_coverage":{"disposition":"covered","by":"designer","note":"The task preserves packet history."},"review_requirement":{"disposition":"not-required","by":"designer","note":"Fixture scope."},"dispatch_decision":{"disposition":"proceed","by":"coordinator","note":"Exercise packet delivery.","task_ids":["task-1"],"prior_review_refs":[]}}
EOF
  bash "$REPO_DIR/scripts/plan-revise.sh" "$fixture_slug" --decisions "$fixture_item/decisions.json" >/dev/null
}
