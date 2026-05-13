#!/usr/bin/env bats
# work_resolve.bats — Coverage for `lore work resolve` and resolve-work-ref.sh
#
# Asserts the 7-tier resolution algorithm plus the filesystem fast path:
#   - exact slug (fast path, active)
#   - exact slug (fast path, archived)
#   - exact slug (index, active)
#   - unique title substring
#   - unique slug substring
#   - tag match
#   - branch match (only when --branch given)
#   - archive fallback (substring against archived entries)
#   - ambiguous match → exit 2 + candidate list
#   - no match → exit 1 + stderr error
#   - JSON output shape for each terminal outcome
#
# All tests use an isolated knowledge directory via LORE_KNOWLEDGE_DIR so they
# never touch the user's real ~/.lore store.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
LORE_CLI="$REPO_DIR/cli/lore"
RESOLVE_SH="$REPO_DIR/scripts/resolve-work-ref.sh"

setup() {
  [ -x "$LORE_CLI" ]    || skip "cli/lore missing"
  [ -x "$RESOLVE_SH" ]  || skip "resolve-work-ref.sh missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required for resolver"

  TEST_KDIR="$(mktemp -d)"
  export LORE_KNOWLEDGE_DIR="$TEST_KDIR"

  WORK_DIR="$TEST_KDIR/_work"
  ARCHIVE_DIR="$WORK_DIR/_archive"
  mkdir -p "$WORK_DIR" "$ARCHIVE_DIR"

  # Active work items — varied titles, slugs, tags, branches.
  mkdir -p \
    "$WORK_DIR/auth-refactor-token-storage" \
    "$WORK_DIR/billing-pipeline-rebuild" \
    "$WORK_DIR/observability-dashboard" \
    "$WORK_DIR/zeta-feature-rollout"
  printf '{"title":"Auth Refactor — Token Storage"}\n'    > "$WORK_DIR/auth-refactor-token-storage/_meta.json"
  printf '{"title":"Billing Pipeline Rebuild"}\n'         > "$WORK_DIR/billing-pipeline-rebuild/_meta.json"
  printf '{"title":"Observability Dashboard"}\n'          > "$WORK_DIR/observability-dashboard/_meta.json"
  printf '{"title":"Zeta Feature Rollout"}\n'             > "$WORK_DIR/zeta-feature-rollout/_meta.json"

  # Archived items.
  mkdir -p \
    "$ARCHIVE_DIR/legacy-auth-migration" \
    "$ARCHIVE_DIR/old-billing-cleanup"
  printf '{"title":"Legacy Auth Migration"}\n' > "$ARCHIVE_DIR/legacy-auth-migration/_meta.json"
  printf '{"title":"Old Billing Cleanup"}\n'   > "$ARCHIVE_DIR/old-billing-cleanup/_meta.json"

  # _index.json — covers all tier fields the resolver consults.
  cat > "$WORK_DIR/_index.json" <<'EOF'
{
  "version": 1,
  "repo": "test-repo",
  "last_updated": "2026-05-13T10:00:00Z",
  "plans": [
    {
      "slug": "auth-refactor-token-storage",
      "title": "Auth Refactor — Token Storage",
      "status": "active",
      "branches": ["feature/auth-refactor"],
      "tags": ["security", "compliance"],
      "updated": "2026-05-10T12:00:00Z"
    },
    {
      "slug": "billing-pipeline-rebuild",
      "title": "Billing Pipeline Rebuild",
      "status": "active",
      "branches": ["feature/billing"],
      "tags": ["payments"],
      "updated": "2026-05-11T12:00:00Z"
    },
    {
      "slug": "observability-dashboard",
      "title": "Observability Dashboard",
      "status": "active",
      "branches": ["main"],
      "tags": ["infra"],
      "updated": "2026-05-12T12:00:00Z"
    },
    {
      "slug": "zeta-feature-rollout",
      "title": "Zeta Feature Rollout",
      "status": "active",
      "branches": ["main"],
      "tags": ["rollout"],
      "updated": "2026-05-13T12:00:00Z"
    }
  ],
  "archived": [
    {
      "slug": "legacy-auth-migration",
      "title": "Legacy Auth Migration",
      "status": "archived"
    },
    {
      "slug": "old-billing-cleanup",
      "title": "Old Billing Cleanup",
      "status": "archived"
    }
  ]
}
EOF
}

teardown() {
  if [ -n "${TEST_KDIR:-}" ] && [ -d "$TEST_KDIR" ]; then
    rm -rf "$TEST_KDIR"
  fi
  unset LORE_KNOWLEDGE_DIR
}

# --- Fast path (filesystem) ---------------------------------------------

@test "exact-slug fast path resolves an active item without reading the index" {
  # Delete the index so this test only passes if the fast path skipped reading it.
  rm -f "$WORK_DIR/_index.json"
  run bash "$LORE_CLI" work resolve auth-refactor-token-storage
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "auth-refactor-token-storage" ]
  [ "${lines[1]}" = "false" ]
}

@test "exact-slug fast path resolves an archived item without reading the index" {
  rm -f "$WORK_DIR/_index.json"
  run bash "$LORE_CLI" work resolve legacy-auth-migration
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "legacy-auth-migration" ]
  [ "${lines[1]}" = "true" ]
}

# --- Tier 1: exact-slug in index ---------------------------------------

@test "exact slug in index resolves to archived=false" {
  # Remove the on-disk dir so the fast path misses; index must serve the answer.
  rm -rf "$WORK_DIR/auth-refactor-token-storage"
  run bash "$LORE_CLI" work resolve auth-refactor-token-storage
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "auth-refactor-token-storage" ]
  [ "${lines[1]}" = "false" ]
}

# --- Tier 2: substring on title ---------------------------------------

@test "unique title substring resolves to canonical slug" {
  run bash "$LORE_CLI" work resolve "token storage"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "auth-refactor-token-storage" ]
  [ "${lines[1]}" = "false" ]
}

# --- Tier 3: substring on slug ----------------------------------------

@test "unique slug substring resolves to canonical slug" {
  # "zeta" appears only in slug, not in any title (besides the title that
  # contains it). Make this test slug-only by querying a substring of the
  # slug that does NOT appear in the title — "rollout" appears in both;
  # "zeta-feature" appears in slug only (title has spaces).
  run bash "$LORE_CLI" work resolve "zeta-feature"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "zeta-feature-rollout" ]
  [ "${lines[1]}" = "false" ]
}

# --- Tier 4: tag match -------------------------------------------------

@test "tag match resolves to the tagged work item" {
  run bash "$LORE_CLI" work resolve "compliance"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "auth-refactor-token-storage" ]
  [ "${lines[1]}" = "false" ]
}

# --- Tier 5: branch (only with --branch) ------------------------------

@test "branch tier fires only when --branch is given" {
  # "infra" tag would match observability-dashboard via tier 4. Use a ref
  # that doesn't match any title/slug/tag — only the branch.
  run bash "$LORE_CLI" work resolve "no-such-ref-zzz" --branch "feature/billing"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "billing-pipeline-rebuild" ]
  [ "${lines[1]}" = "false" ]
}

@test "without --branch, branch tier is skipped" {
  # Same ref as above, no --branch: should be no-match (exit 1).
  run bash "$LORE_CLI" work resolve "no-such-ref-zzz"
  [ "$status" -eq 1 ]
}

# --- Tier 7: archive fallback -----------------------------------------

@test "archive fallback resolves a substring-only match in archived entries" {
  # "legacy" appears only in an archived title. Active tiers find nothing,
  # archive fallback finds the unique match.
  run bash "$LORE_CLI" work resolve "legacy"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "legacy-auth-migration" ]
  [ "${lines[1]}" = "true" ]
}

# --- Ambiguous --------------------------------------------------------

@test "ambiguous substring returns exit 2 with candidate list on stderr" {
  # "billing" matches billing-pipeline-rebuild (active) AND would match
  # old-billing-cleanup only on archive fallback. Active is unambiguous —
  # so use a substring that matches multiple active items.
  # "main" doesn't help (no title contains it). Use a substring shared
  # across multiple active titles: "Rebuild" only one item. We need a
  # shared term. Add a custom case via index manipulation: the substring
  # "feature" doesn't appear in any title here. Use "rollout" — only one.
  # Force ambiguity by querying a tag shared across multiple items?
  # Simplest: query a slug substring that two slugs share. Both
  # "billing-pipeline-rebuild" and the archived "old-billing-cleanup"
  # share "billing" — but archived is tier 7. Two ACTIVE slugs sharing
  # a substring: only one has "billing". So use a query that matches
  # both billing-pipeline-rebuild AND observability via tags? No.
  # Best: add a temporary common tag by editing the index for this test.
  python3 - "$WORK_DIR/_index.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
for item in d["plans"]:
    if item["slug"] in ("auth-refactor-token-storage", "billing-pipeline-rebuild"):
        item["tags"] = item.get("tags", []) + ["shared-tag"]
with open(p, "w") as f: json.dump(d, f)
PYEOF
  run bash "$LORE_CLI" work resolve "shared-tag"
  [ "$status" -eq 2 ]
  # Stderr-via-`run` is interleaved into $output for bats unless 2>/dev/null.
  # Just check the exit code and that candidates are mentioned somewhere.
  echo "$output" | grep -q "auth-refactor-token-storage"
  echo "$output" | grep -q "billing-pipeline-rebuild"
}

# --- No match ---------------------------------------------------------

@test "no match returns exit 1 with stderr error line" {
  run bash "$LORE_CLI" work resolve "absolutely-no-such-thing-9999"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "No match for reference"
}

# --- JSON output shapes -----------------------------------------------

@test "--json on resolved produces single-line JSON object" {
  run bash "$LORE_CLI" work resolve auth-refactor-token-storage --json
  [ "$status" -eq 0 ]
  # Validate it's parseable JSON with the right keys.
  echo "$output" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["slug"]=="auth-refactor-token-storage"; assert d["archived"] is False'
}

@test "--json on archived fast path returns archived=true" {
  run bash "$LORE_CLI" work resolve legacy-auth-migration --json
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["slug"]=="legacy-auth-migration"; assert d["archived"] is True'
}

@test "--json on no-match returns error object with exit 1" {
  run bash "$LORE_CLI" work resolve "absolutely-no-such-thing-9999" --json
  [ "$status" -eq 1 ]
  echo "$output" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert "error" in d'
}

@test "--json on ambiguous returns candidates array with exit 2" {
  # Reuse the same setup-trick: shared tag forcing ambiguity.
  python3 - "$WORK_DIR/_index.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
with open(p) as f: d = json.load(f)
for item in d["plans"]:
    if item["slug"] in ("auth-refactor-token-storage", "billing-pipeline-rebuild"):
        item["tags"] = item.get("tags", []) + ["shared-tag"]
with open(p, "w") as f: json.dump(d, f)
PYEOF
  run bash "$LORE_CLI" work resolve "shared-tag" --json
  [ "$status" -eq 2 ]
  echo "$output" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
assert "error" in d
assert isinstance(d.get("candidates"), list)
assert "auth-refactor-token-storage" in d["candidates"]
assert "billing-pipeline-rebuild" in d["candidates"]
'
}

# --- CLI surface ------------------------------------------------------

@test "lore work usage mentions the resolve subcommand" {
  run bash "$LORE_CLI" work --help
  # work_usage writes to stderr; bats `run` merges to $output.
  echo "$output" | grep -q "resolve"
}

@test "missing ref argument returns a usage error" {
  run bash "$LORE_CLI" work resolve
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "missing required argument"
}

@test "unknown flag returns an error" {
  run bash "$LORE_CLI" work resolve some-ref --no-such-flag
  [ "$status" -eq 1 ]
}
