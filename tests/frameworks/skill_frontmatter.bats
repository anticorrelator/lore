#!/usr/bin/env bats
# skill_frontmatter.bats — Strict-YAML frontmatter validation for shipped skills.
#
# Codex 0.124+ refuses to load skills whose SKILL.md frontmatter fails strict
# YAML parsing; Claude Code's loader is lenient and silently accepts
# malformed-but-recoverable input. The historical regression we are guarding
# against: an unquoted `description:` value containing `Foo: bar` later in the
# string parses as a nested mapping under strict YAML and fails with
# `mapping values are not allowed in this context`. Wrapping such values in
# quotes is the documented fix.
#
# Style: pure bats, mirrors hooks.bats / install.bats pattern. Iterates the
# closed set of `skills/*/SKILL.md` files in the repo and asserts each one
# parses cleanly under `yaml.safe_load` (the strict parser equivalent codex
# uses internally).

REPO_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME:-$0}")/../.." && pwd)"
SKILLS_DIR="$REPO_DIR/skills"

setup() {
  [ -d "$SKILLS_DIR" ] || skip "skills/ missing"
  command -v python3 >/dev/null 2>&1 || skip "python3 required for YAML validation"
  python3 -c "import yaml" 2>/dev/null || skip "PyYAML not installed"
}

# Parse the frontmatter of one SKILL.md and print the parsed dict's keys, or
# print "ERR: <message>" on parse failure. Used by the per-file asserts below.
parse_frontmatter() {
  local skill_md="$1"
  python3 - "$skill_md" <<'PYEOF'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    text = f.read()
parts = text.split("---", 2)
if len(parts) < 3:
    print(f"ERR: missing frontmatter delimiters in {path}")
    sys.exit(1)
try:
    fm = yaml.safe_load(parts[1])
except yaml.YAMLError as e:
    print(f"ERR: {e}")
    sys.exit(1)
if not isinstance(fm, dict):
    print(f"ERR: frontmatter is not a mapping (got {type(fm).__name__})")
    sys.exit(1)
# Print sorted keys so assertions are stable.
print(",".join(sorted(fm.keys())))
PYEOF
}

@test "every shipped SKILL.md has strict-YAML-valid frontmatter" {
  # Closed iteration over the actual on-disk skill set. Any new skill is picked
  # up automatically — no per-skill test maintenance required.
  shopt -s nullglob
  local failed=0
  local report=""
  for skill_md in "$SKILLS_DIR"/*/SKILL.md; do
    local out
    out=$(parse_frontmatter "$skill_md" 2>&1) || {
      failed=$((failed + 1))
      report+="$skill_md: $out"$'\n'
      continue
    }
    if [[ "$out" == ERR:* ]]; then
      failed=$((failed + 1))
      report+="$skill_md: $out"$'\n'
    fi
  done
  if [ "$failed" -gt 0 ]; then
    echo "Strict-YAML frontmatter validation failed for $failed skill(s):"
    echo "$report"
    return 1
  fi
}

@test "every shipped SKILL.md frontmatter declares name + description" {
  # Both keys are load-time required by all three harness adapters
  # (claude-code, opencode, codex). Missing either is a contract violation.
  shopt -s nullglob
  local failed=0
  local report=""
  for skill_md in "$SKILLS_DIR"/*/SKILL.md; do
    local keys
    keys=$(parse_frontmatter "$skill_md") || {
      # Already covered by the previous test — skip without double-reporting.
      continue
    }
    [[ "$keys" == ERR:* ]] && continue
    if [[ ",$keys," != *",name,"* ]] || [[ ",$keys," != *",description,"* ]]; then
      failed=$((failed + 1))
      report+="$skill_md: missing required key(s); got [$keys]"$'\n'
    fi
  done
  if [ "$failed" -gt 0 ]; then
    echo "Required-key check failed for $failed skill(s):"
    echo "$report"
    return 1
  fi
}

@test "regression: skills/memory/SKILL.md description is quoted (codex strict-parser fix)" {
  # Direct anchor for the specific bug that motivated this file: an unquoted
  # description containing `Commands: add, ...` parsed as a nested mapping
  # under codex 0.124+ strict YAML. The fix was to wrap the value in double
  # quotes. This test exists so an unquoted regression fails loudly with the
  # right context, instead of being diagnosed as a generic YAML error.
  local skill_md="$SKILLS_DIR/memory/SKILL.md"
  [ -f "$skill_md" ] || skip "skills/memory/SKILL.md missing"
  local desc_line
  desc_line=$(awk '/^---$/{f=!f; next} f && /^description:/{print; exit}' "$skill_md")
  [ -n "$desc_line" ] || { echo "no description: line found in frontmatter"; return 1; }
  local val="${desc_line#description: }"
  local first="${val:0:1}"
  if [[ "$first" != "\"" && "$first" != "'" ]] && [[ "$val" == *": "* ]]; then
    echo "skills/memory/SKILL.md description is unquoted AND contains ': ' — regresses codex strict-YAML fix"
    echo "    line: $desc_line"
    return 1
  fi
}
