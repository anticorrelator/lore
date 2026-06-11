#!/usr/bin/env bash
# test_scale_set_contract.sh — Regression guard for the --scale-set declaration contract.
#
# The lore CLI errors on a `lore search`/`lore prefetch`/`lore query` invocation
# that omits --scale-set. A doc-only sweep of that contract misses the surfaces
# that break hardest: compiled/subprocess callers (the TUI's exec.Command) and
# prompt-emitting scripts that instruct an agent to run the command. Those fail
# completely at runtime rather than degrading, and stay broken silently because
# no markdown grep covers them.
#
# This guard scans three surface classes for an executable invocation of the
# search family that lacks --scale-set:
#   1. Markdown command lines under skills/ and claude-md/
#   2. exec.Command("lore", "search"|"prefetch"|"query", ...) under tui/
#   3. Agent-runnable `lore <subcmd> "<query>"` instructions under scripts/
#
# `lore work search` is a distinct subcommand that does not enforce --scale-set
# (it routes to search-work.sh, bypassing the declaration gate), so every scan
# excludes it. Prose mentions — inline-code in a sentence, capability tables,
# error-message fragments — are not executable lines and are not flagged.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

assert_empty() {
  local label="$1" output="$2"
  if [[ -z "$output" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Unscoped invocation(s) found:"
    echo "$output" | sed 's/^/      /'
    FAIL=$((FAIL + 1))
  fi
}

assert_nonempty() {
  local label="$1" output="$2"
  if [[ -n "$output" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected the scanner to flag a known-bad line, got nothing)"
    FAIL=$((FAIL + 1))
  fi
}

# --- Scanners -----------------------------------------------------------------
#
# Each scanner takes a root directory and prints `file:line:text` for every
# offending line. Empty output means the tree is clean.

# Markdown command lines: a line that, after optional leading whitespace and an
# optional `VAR=$(` / `$(` shell-capture prefix, BEGINS with the search family.
# This is what distinguishes an executable line (agent runs it verbatim) from a
# prose mention, where `lore search` appears mid-sentence or inside backticks.
scan_markdown_surfaces() {
  local root="$1"
  grep -rEn '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=)?\$?\(?lore (search|prefetch|query)([[:space:]]|$)' \
    "$root" 2>/dev/null \
    | grep -v 'lore work search' \
    | grep -v -- '--scale-set'
}

# TUI subprocess callers: the Go call spans multiple lines, so the --scale-set
# argument may sit on a continuation line. Flag an exec.Command("lore",
# "search"|"prefetch"|"query", ...) only when no --scale-set appears within the
# call window (the matched line plus the next few continuation lines).
scan_tui_subprocess() {
  local root="$1"
  grep -rln --include='*.go' 'exec.Command' "$root" 2>/dev/null | while read -r f; do
    awk -v fname="$f" '
      /exec\.Command\("lore", "(search|prefetch|query)"/ {
        # Accumulate the call window: this line plus continuations until the
        # statement closes (a line containing the call-terminating `)`).
        window = $0; start = NR; depth_line = $0
        # exec.Command("lore", "work", "search") is the excluded subcommand.
        if (window ~ /"lore", "work", "search"/) next
        n = 0
        while (window !~ /\)/ && n < 6) {
          if ((getline nextline) <= 0) break
          window = window "\n" nextline
          n++
        }
        if (window !~ /--scale-set/) {
          # Report the call-site line only.
          print fname ":" start ":" depth_line
        }
      }
    ' "$f"
  done
}

# Prompt-emitting scripts: an agent-runnable instruction carries a real quoted
# query — `lore search "<...>"` with content after the opening quote. A trailing
# `lore prefetch "` that merely closes a string literal (an error-message hint)
# has nothing after the quote and is not matched. Backtick-wrapped mentions
# (`\`lore search\``) are prose, not instructions.
scan_prompt_scripts() {
  local root="$1"
  # Blank out `lore work search` occurrences first so a line carrying BOTH the
  # excluded work-search command and a separate unscoped `lore search` (as
  # work-ai.sh's permitted-actions block does) is still judged on the latter.
  grep -rEn 'lore (search|prefetch|query) "[^"]' "$root" 2>/dev/null \
    | sed 's/lore work search/lore_WORK_search/g' \
    | grep -E 'lore (search|prefetch|query) "[^"]' \
    | grep -v '`lore' \
    | grep -v -- '--scale-set'
}

echo "=== Scale-Set Contract Guard ==="
echo ""

# --- Live tree must be clean --------------------------------------------------

echo "Markdown surfaces (skills/, claude-md/) carry --scale-set"
assert_empty "skills/ has no unscoped command lines" "$(scan_markdown_surfaces "$REPO_DIR/skills")"
assert_empty "claude-md/ has no unscoped command lines" "$(scan_markdown_surfaces "$REPO_DIR/claude-md")"

echo ""
echo "TUI subprocess callers carry --scale-set"
assert_empty "tui/ exec.Command callers are scoped" "$(scan_tui_subprocess "$REPO_DIR/tui")"

echo ""
echo "Prompt-emitting scripts carry --scale-set"
assert_empty "scripts/ agent instructions are scoped" "$(scan_prompt_scripts "$REPO_DIR/scripts")"

# --- Self-check: the scanners must flag known-bad fixtures --------------------
#
# Without this, a scanner that silently matches nothing would pass the
# clean-tree assertions vacuously. Each fixture is a deliberately unscoped
# invocation the corresponding scanner MUST catch.

echo ""
echo "Self-check: scanners flag known-bad fixtures"
FIXTURE_DIR=$(mktemp -d)
trap 'rm -rf "$FIXTURE_DIR"' EXIT

mkdir -p "$FIXTURE_DIR/skills" "$FIXTURE_DIR/tui" "$FIXTURE_DIR/scripts"

cat > "$FIXTURE_DIR/skills/bad.md" <<'EOF'
Run the query:
```bash
lore search "<topic>" --type knowledge --json --limit 3
```
EOF

cat > "$FIXTURE_DIR/tui/bad.go" <<'EOF'
func run(query string) {
	cmd := exec.Command("lore", "search", query, "--type", "knowledge", "--json")
	_ = cmd
}
EOF

cat > "$FIXTURE_DIR/scripts/bad.sh" <<'EOF'
PROMPT=$(cat <<'PEOF'
PERMITTED ACTIONS:
  Read-only information gathering:
    lore work list, lore work search "<query>", lore search "<query>"
PEOF
)
EOF

assert_nonempty "markdown scanner flags an unscoped command line" \
  "$(scan_markdown_surfaces "$FIXTURE_DIR/skills")"
assert_nonempty "tui scanner flags an unscoped exec.Command caller" \
  "$(scan_tui_subprocess "$FIXTURE_DIR/tui")"
assert_nonempty "script scanner flags an unscoped agent instruction" \
  "$(scan_prompt_scripts "$FIXTURE_DIR/scripts")"

# A scoped fixture must NOT be flagged — guards against an over-eager matcher
# that ignores the --scale-set it is supposed to require.
cat > "$FIXTURE_DIR/skills/good.md" <<'EOF'
```bash
lore search "<topic>" --type knowledge --scale-set subsystem,implementation --json --limit 3
```
EOF
cat > "$FIXTURE_DIR/tui/good.go" <<'EOF'
	cmd := exec.Command("lore", "search", query, "--type", "knowledge",
		"--scale-set", "abstract,architecture,subsystem,implementation", "--json")
EOF

mkdir -p "$FIXTURE_DIR/skills_good" "$FIXTURE_DIR/tui_good"
mv "$FIXTURE_DIR/skills/good.md" "$FIXTURE_DIR/skills_good/good.md"
mv "$FIXTURE_DIR/tui/good.go" "$FIXTURE_DIR/tui_good/good.go"

assert_empty "markdown scanner ignores a scoped command line" \
  "$(scan_markdown_surfaces "$FIXTURE_DIR/skills_good")"
assert_empty "tui scanner ignores a scoped exec.Command caller" \
  "$(scan_tui_subprocess "$FIXTURE_DIR/tui_good")"

# `lore work search` must never be flagged in any surface (D4).
mkdir -p "$FIXTURE_DIR/worksearch"
cat > "$FIXTURE_DIR/worksearch/work.go" <<'EOF'
	cmd := exec.Command("lore", "work", "search", query, "--json")
EOF
cat > "$FIXTURE_DIR/worksearch/work.md" <<'EOF'
```bash
lore work search "<query>"
```
EOF
assert_empty "tui scanner ignores lore work search" \
  "$(scan_tui_subprocess "$FIXTURE_DIR/worksearch")"
assert_empty "markdown scanner ignores lore work search" \
  "$(scan_markdown_surfaces "$FIXTURE_DIR/worksearch")"

# --- Summary ------------------------------------------------------------------

echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
