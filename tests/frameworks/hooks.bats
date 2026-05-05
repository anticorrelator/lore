#!/usr/bin/env bats
# hooks.bats — Smoke coverage for the per-harness hook adapters
# (Phase 3, T30).
#
# Verifies the two assertions named in adapters/hooks/README.md
# "Adapter implementor's checklist":
#   item 5: each adapter exposes a smoke subcommand that prints, for the
#           active framework, every Lore lifecycle event paired with its
#           support level (and, where applicable, the native harness hook
#           it routes through).
#   item 6: every hook command string emitted by the adapter uses the
#           stable `~/.lore/scripts/<name>` form, never `$(pwd)`-relative
#           or repo-absolute paths.
#
# What gets exercised:
#   - The closed Lore lifecycle event set declared in adapters/hooks/README.md
#     matches the keys each adapter's smoke output advertises (drift detector
#     for the closed-set invariant).
#   - Every adapter prints exactly the nine Lore events + their support
#     levels + a description of what the cell binds to.
#   - For each adapter, each event's support level matches the
#     capabilities.json cell (no adapter-side drift from the registry).
#   - Adapter source files use stable `~/.lore/scripts/<name>` paths in
#     every emitted hook command (grep-based; covers the install path and
#     the smoke summary).
#
# Coverage matrix:
#   - claude-code adapter: required (T25 ships the reference impl).
#   - opencode adapter:    required (T26 ships in the same phase).
#   - codex adapter:       optional — skips with a clear reason if
#                          adapters/codex/hooks.sh has not landed yet.
#
# Style: pure bats. Skips cleanly when prerequisites (python3, bats, the
# adapter binary itself) are missing.

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
CAPS="$REPO_DIR/adapters/capabilities.json"
HOOKS_README="$REPO_DIR/adapters/hooks/README.md"
CC_ADAPTER="$REPO_DIR/adapters/hooks/claude-code.sh"
OC_ADAPTER="$REPO_DIR/adapters/opencode/lore-hooks.ts"
CODEX_ADAPTER="$REPO_DIR/adapters/codex/hooks.sh"

# Closed Lore event set per adapters/hooks/README.md "Lifecycle Events".
# Tests assert each adapter advertises exactly these tokens.
LORE_EVENTS=(
  session_start
  user_prompt
  pre_tool
  post_tool
  permission_request
  pre_compact
  stop
  session_end
  task_completed
)

setup() {
  [ -f "$CAPS" ] || skip "adapters/capabilities.json missing"
  [ -f "$HOOKS_README" ] || skip "adapters/hooks/README.md missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required for capability cell lookup"

  # Stage an isolated LORE_DATA_DIR so adapter smoke commands resolve
  # framework.json without touching the user's real config. The Go and
  # bash sides both walk the LORE_DATA_DIR/scripts symlink to find the
  # repo, so we replicate that here.
  TEST_LORE_DATA_DIR="$(mktemp -d)"
  mkdir -p "$TEST_LORE_DATA_DIR/config"
  ln -s "$REPO_DIR/scripts" "$TEST_LORE_DATA_DIR/scripts"
  export LORE_DATA_DIR="$TEST_LORE_DATA_DIR"
  unset LORE_FRAMEWORK
}

teardown() {
  if [ -n "${TEST_LORE_DATA_DIR:-}" ] && [ -d "$TEST_LORE_DATA_DIR" ]; then
    rm -rf "$TEST_LORE_DATA_DIR"
  fi
}

# --- Helpers ---

set_framework() {
  cat > "$TEST_LORE_DATA_DIR/config/framework.json" <<EOF
{"version":1,"framework":"$1","capability_overrides":{},"roles":{}}
EOF
}

# Look up frameworks.<fw>.capabilities.<cap>.support from capabilities.json.
# Prints the support level (full|partial|fallback|none) on stdout, exits 0;
# exits non-zero if the cell is missing.
cap_support() {
  local fw="$1" cap="$2"
  CAPS="$CAPS" FW="$fw" CAP="$cap" python3 - <<'PYEOF'
import json, os, sys
d = json.load(open(os.environ["CAPS"]))
fw = d["frameworks"].get(os.environ["FW"], {})
cell = (fw.get("capabilities") or {}).get(os.environ["CAP"])
if not cell or "support" not in cell:
    sys.exit(2)
print(cell["support"])
PYEOF
}

# Closed map — Lore event -> capabilities.json key — must mirror the
# table in adapters/hooks/README.md "Lifecycle Events" + the adapter
# CAPABILITY_KEY constants. Drift here means drift in the contract; the
# closed-set assertion test (below) catches it.
event_to_capability() {
  case "$1" in
    session_start)      echo session_start_hook ;;
    user_prompt)        echo tool_hooks ;;
    pre_tool)           echo tool_hooks ;;
    post_tool)          echo tool_hooks ;;
    permission_request) echo permission_hooks ;;
    pre_compact)        echo pre_compact_hook ;;
    stop)               echo stop_hook ;;
    session_end)        echo stop_hook ;;
    task_completed)     echo task_completed_hook ;;
    *) return 1 ;;
  esac
}

# ============================================================
# Closed-set invariant — README is the source of truth
# ============================================================

@test "README declares exactly the nine Lore lifecycle events" {
  # Pull the event names from the README's "Lifecycle Events (Closed Set)"
  # table, then compare to the LORE_EVENTS array. Any drift is a contract
  # violation (the README is the source of truth per T24).
  EXPECTED_EVENTS="${LORE_EVENTS[*]}" \
  README_PATH="$HOOKS_README" \
  run python3 - <<'PYEOF'
import os, re, sys
text = open(os.environ["README_PATH"]).read()
m = re.search(r"## Lifecycle Events \(Closed Set\)(.*?)## Dispatch Contract", text, re.S)
if not m:
    print("could not locate Lifecycle Events section in README"); sys.exit(2)
section = m.group(1)
events = re.findall(r"^\| `([a-z_]+)`\s*\|", section, re.M)
expected = sorted(os.environ["EXPECTED_EVENTS"].split())
got = sorted(set(events))
if got != expected:
    print("README events:", got)
    print("expected:    ", expected)
    sys.exit(1)
PYEOF
  [ "$status" -eq 0 ]
}

# ============================================================
# claude-code adapter (T25 reference impl)
# ============================================================

@test "claude-code adapter exposes a smoke subcommand" {
  [ -f "$CC_ADAPTER" ] || skip "adapters/hooks/claude-code.sh missing"
  set_framework claude-code
  run bash "$CC_ADAPTER" smoke
  [ "$status" -eq 0 ]
  # Header line + at least one event row should be present.
  [[ "$output" =~ "claude-code" ]]
}

@test "claude-code smoke advertises every Lore lifecycle event" {
  [ -f "$CC_ADAPTER" ] || skip "adapters/hooks/claude-code.sh missing"
  set_framework claude-code
  run bash "$CC_ADAPTER" smoke
  [ "$status" -eq 0 ]
  for event in "${LORE_EVENTS[@]}"; do
    if ! grep -qE "(^|[[:space:]])${event}([[:space:]]|$)" <<<"$output"; then
      echo "claude-code smoke missing event: $event"
      echo "smoke output:"
      echo "$output"
      return 1
    fi
  done
}

@test "claude-code smoke support levels match capabilities.json" {
  [ -f "$CC_ADAPTER" ] || skip "adapters/hooks/claude-code.sh missing"
  set_framework claude-code
  run bash "$CC_ADAPTER" smoke
  [ "$status" -eq 0 ]
  for event in "${LORE_EVENTS[@]}"; do
    cap=$(event_to_capability "$event")
    expected=$(cap_support claude-code "$cap")
    # Each smoke row begins with two leading spaces, the event name padded
    # to 20, then the support level. Match the (event, level) pair via a
    # whitespace-tolerant regex so we don't pin column counts.
    if ! grep -qE "(^|[[:space:]])${event}[[:space:]]+${expected}([[:space:]]|$)" <<<"$output"; then
      echo "claude-code smoke event=$event expected support=$expected"
      echo "smoke output:"
      echo "$output"
      return 1
    fi
  done
}

@test "claude-code adapter source uses ~/.lore/scripts/ for every hook command" {
  [ -f "$CC_ADAPTER" ] || skip "adapters/hooks/claude-code.sh missing"
  # Every line in claude-code.sh that mentions a script under .lore/scripts/
  # MUST use the stable `~/.lore/scripts/<name>` form (T24 checklist item
  # 6). Any reference to a different lore script root (e.g. the literal
  # repo path, $LORE_DATA_DIR/scripts hard-coded into a hook command, or
  # a `lore/scripts/` legacy path *outside* the is_lore_hook detector) is
  # a regression. Allow the legacy-detection literals because they only
  # match user-installed entries during uninstall scrubbing.
  bad_lines=$(grep -nE '(\$\(pwd\)/scripts/|\$LORE_DATA_DIR/scripts/[a-z_-]+\.(sh|py)|/work/.*/scripts/[a-z_-]+\.(sh|py))' "$CC_ADAPTER" || true)
  if [ -n "$bad_lines" ]; then
    echo "claude-code adapter contains hook command paths that are not ~/.lore/scripts/:"
    echo "$bad_lines"
    return 1
  fi

  # Positive assertion — at least one ~/.lore/scripts/ reference exists.
  run grep -cE '~/\.lore/scripts/[a-z_-]+\.(sh|py)' "$CC_ADAPTER"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "claude-code smoke fails fast when active framework is not claude-code" {
  [ -f "$CC_ADAPTER" ] || skip "adapters/hooks/claude-code.sh missing"
  set_framework opencode
  run bash "$CC_ADAPTER" smoke
  # Adapter MUST refuse to smoke when active framework != claude-code,
  # per the require_claude_code() guard. Either non-zero exit OR an
  # explicit error message is acceptable; we assert both for clarity.
  [ "$status" -ne 0 ]
  [[ "$output" =~ claude-code ]]
}

# ============================================================
# opencode adapter (T26)
# ============================================================

@test "opencode adapter exposes a --smoke entrypoint" {
  [ -f "$OC_ADAPTER" ] || skip "adapters/opencode/lore-hooks.ts missing"
  # Smoke is gated on a runtime that can execute the .ts file. Skip
  # cleanly if neither tsx nor bun nor node-with-loader is available.
  if command -v tsx >/dev/null 2>&1; then
    runtime=(tsx)
  elif command -v bun >/dev/null 2>&1; then
    runtime=(bun)
  else
    skip "no TypeScript runtime available (need tsx or bun) to run lore-hooks.ts --smoke"
  fi
  set_framework opencode
  run "${runtime[@]}" "$OC_ADAPTER" --smoke
  [ "$status" -eq 0 ]
  [[ "$output" =~ opencode ]]
}

@test "opencode smoke advertises every Lore lifecycle event" {
  [ -f "$OC_ADAPTER" ] || skip "adapters/opencode/lore-hooks.ts missing"
  if command -v tsx >/dev/null 2>&1; then
    runtime=(tsx)
  elif command -v bun >/dev/null 2>&1; then
    runtime=(bun)
  else
    skip "no TypeScript runtime available to run lore-hooks.ts --smoke"
  fi
  set_framework opencode
  run "${runtime[@]}" "$OC_ADAPTER" --smoke
  [ "$status" -eq 0 ]
  for event in "${LORE_EVENTS[@]}"; do
    if ! grep -qE "(^|[[:space:]])${event}([[:space:]]|$)" <<<"$output"; then
      echo "opencode smoke missing event: $event"
      echo "smoke output:"
      echo "$output"
      return 1
    fi
  done
}

@test "opencode adapter source uses ~/.lore/scripts/ paths or LORE_DATA_DIR" {
  [ -f "$OC_ADAPTER" ] || skip "adapters/opencode/lore-hooks.ts missing"
  # OpenCode adapter spawns Lore handler scripts via path.join with
  # LORE_DATA_DIR fallback to ~/.lore. Any literal `/work/` or
  # `git rev-parse`-derived absolute path is a regression — the plugin
  # runtime resolves $LORE_DATA_DIR/scripts/<name> at spawn time.
  bad=$(grep -nE '(/work/[^"]*scripts/[a-z_-]+\.(sh|py)|\$\(pwd\)/scripts/)' "$OC_ADAPTER" || true)
  if [ -n "$bad" ]; then
    echo "opencode adapter contains absolute repo paths in script invocations:"
    echo "$bad"
    return 1
  fi

  # Positive assertion — adapter mentions LORE_DATA_DIR or ~/.lore/scripts
  # somewhere (script path resolution).
  run grep -cE '(LORE_DATA_DIR|\.lore[/"\047]scripts)' "$OC_ADAPTER"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "opencode adapter declares the same closed event set as the README" {
  [ -f "$OC_ADAPTER" ] || skip "adapters/opencode/lore-hooks.ts missing"
  # The TS LoreEvent type literal union must list exactly the nine Lore
  # events. Drift between the union and the README closed set is a
  # contract violation regardless of whether a TS runtime is installed.
  EXPECTED_EVENTS="${LORE_EVENTS[*]}" \
  OC_ADAPTER="$OC_ADAPTER" \
  run python3 - <<'PYEOF'
import os, re, sys
text = open(os.environ["OC_ADAPTER"]).read()
m = re.search(r"export type LoreEvent\s*=\s*([^;]+);", text)
if not m:
    print("could not locate LoreEvent type alias in opencode adapter"); sys.exit(2)
union = m.group(1)
got = sorted(set(re.findall(r'"([a-z_]+)"', union)))
expected = sorted(os.environ["EXPECTED_EVENTS"].split())
if got != expected:
    print("opencode LoreEvent union:", got)
    print("expected:                ", expected)
    sys.exit(1)
PYEOF
  [ "$status" -eq 0 ]
}

# ============================================================
# codex adapter (T27 — optional until adapter lands)
# ============================================================

@test "codex adapter exposes a smoke subcommand" {
  [ -f "$CODEX_ADAPTER" ] || skip "adapters/codex/hooks.sh missing (T27 not landed yet)"
  set_framework codex
  run bash "$CODEX_ADAPTER" smoke
  [ "$status" -eq 0 ]
  [[ "$output" =~ codex ]]
}

@test "codex smoke advertises every Lore lifecycle event" {
  [ -f "$CODEX_ADAPTER" ] || skip "adapters/codex/hooks.sh missing (T27 not landed yet)"
  set_framework codex
  run bash "$CODEX_ADAPTER" smoke
  [ "$status" -eq 0 ]
  for event in "${LORE_EVENTS[@]}"; do
    if ! grep -qE "(^|[[:space:]])${event}([[:space:]]|$)" <<<"$output"; then
      echo "codex smoke missing event: $event"
      echo "smoke output:"
      echo "$output"
      return 1
    fi
  done
}

@test "codex smoke support levels match capabilities.json" {
  [ -f "$CODEX_ADAPTER" ] || skip "adapters/codex/hooks.sh missing (T27 not landed yet)"
  set_framework codex
  run bash "$CODEX_ADAPTER" smoke
  [ "$status" -eq 0 ]
  for event in "${LORE_EVENTS[@]}"; do
    cap=$(event_to_capability "$event")
    expected=$(cap_support codex "$cap")
    if ! grep -qE "(^|[[:space:]])${event}[[:space:]]+${expected}([[:space:]]|$)" <<<"$output"; then
      echo "codex smoke event=$event expected support=$expected"
      echo "smoke output:"
      echo "$output"
      return 1
    fi
  done
}

@test "codex adapter source uses ~/.lore/scripts/ for every hook command" {
  [ -f "$CODEX_ADAPTER" ] || skip "adapters/codex/hooks.sh missing (T27 not landed yet)"
  bad_lines=$(grep -nE '(\$\(pwd\)/scripts/|/work/.*/scripts/[a-z_-]+\.(sh|py))' "$CODEX_ADAPTER" || true)
  if [ -n "$bad_lines" ]; then
    echo "codex adapter contains hook command paths that are not ~/.lore/scripts/:"
    echo "$bad_lines"
    return 1
  fi
  run grep -cE '(~/\.lore/scripts/|LORE_DATA_DIR.*scripts)' "$CODEX_ADAPTER"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}
