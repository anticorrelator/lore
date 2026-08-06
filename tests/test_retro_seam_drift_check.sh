#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$REPO_ROOT/scripts/check-retro-seam-drift.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

new_repo() {
  local repo="$1"
  mkdir -p "$repo/scripts" "$repo/tests/frameworks" "$repo/tests" "$repo/skills/retro" "$repo/skills/other"
  cp "$CHECKER" "$repo/scripts/check-retro-seam-drift.sh"
  printf 'registry baseline\n' > "$repo/scripts/retro-prepare.sh"
  printf 'reader test baseline\n' > "$repo/tests/frameworks/retro_prepare.bats"
  printf 'session reader baseline\n' > "$repo/scripts/session-events.sh"
  printf 'retro skill baseline\n' > "$repo/skills/retro/SKILL.md"
  printf 'other skill baseline\n' > "$repo/skills/other/SKILL.md"
  printf 'protocol baseline\n' > "$repo/tests/test_retro_evidence_pack_protocol.sh"
  git -C "$repo" init -q
  git -C "$repo" config user.name "Retro Contract Test"
  git -C "$repo" config user.email "retro-contract@example.invalid"
  git -C "$repo" add .
  git -C "$repo" commit -q -m baseline
}

commit_all() {
  local repo="$1" subject="$2"
  git -C "$repo" add .
  git -C "$repo" commit -q -m "$subject"
}

expect_pass() {
  local repo="$1" base="$2"
  (cd "$repo" && bash scripts/check-retro-seam-drift.sh "$base" HEAD) >/dev/null
}

expect_fail() {
  local repo="$1" base="$2"
  if (cd "$repo" && bash scripts/check-retro-seam-drift.sh "$base" HEAD) >/dev/null 2>&1; then
    echo "expected drift check failure in $repo" >&2
    exit 1
  fi
}

repo="$TMP/coupled-reader"
new_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'registry change\n' >> "$repo/scripts/retro-prepare.sh"
printf 'paired contract\n' >> "$repo/tests/frameworks/retro_prepare.bats"
commit_all "$repo" "couple reader and contract"
expect_pass "$repo" "$base"

repo="$TMP/unpaired-reader"
new_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'registry change\n' >> "$repo/scripts/retro-prepare.sh"
commit_all "$repo" "unpaired reader"
expect_fail "$repo" "$base"

repo="$TMP/standalone-skill"
new_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'standalone rewrite\n' >> "$repo/skills/retro/SKILL.md"
commit_all "$repo" "standalone retro prose"
expect_fail "$repo" "$base"

repo="$TMP/two-coupled-skill-commits"
new_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
for n in 1 2; do
  printf 'skill revision %s\n' "$n" >> "$repo/skills/retro/SKILL.md"
  printf 'protocol revision %s\n' "$n" >> "$repo/tests/test_retro_evidence_pack_protocol.sh"
  commit_all "$repo" "coupled retro revision $n"
done
expect_pass "$repo" "$base"

repo="$TMP/other-skill"
new_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'owner calibration\n' >> "$repo/skills/other/SKILL.md"
commit_all "$repo" "other skill prose"
expect_pass "$repo" "$base"

# The pairing must keep firing for every reader still on the protected list,
# not just the one the checker is named after.

repo="$TMP/session-reader-unpaired"
new_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'window projection change\n' >> "$repo/scripts/session-events.sh"
commit_all "$repo" "session reader change with no contract test"
expect_fail "$repo" "$base"

repo="$TMP/session-reader-paired"
new_repo "$repo"
base="$(git -C "$repo" rev-parse HEAD)"
printf 'window projection change\n' >> "$repo/scripts/session-events.sh"
printf 'session projection case\n' >> "$repo/tests/frameworks/retro_prepare.bats"
commit_all "$repo" "session reader change paired with the reader contract"
expect_pass "$repo" "$base"

# A protected path that no longer exists protects nothing: the pattern stops
# matching and the pairing silently stops being enforced. Both the checker and
# the pre-push hook must name only live files.
python3 - "$REPO_ROOT" <<'PY'
import re, sys
from pathlib import Path

root = Path(sys.argv[1])
checker = (root / "scripts/check-retro-seam-drift.sh").read_text()
hook = (root / "githooks/pre-push").read_text()

named = set(re.findall(r"^\s+(scripts/[\w./-]+)$",
                       checker.split("PROTECTED_READERS=(", 1)[1].split(")", 1)[0], re.M))
for extra in ("CONTRACT_TEST", "RETRO_SKILL"):
    named.add(re.search(rf'{extra}="([^"]+)"', checker).group(1))

pattern = re.search(r"PROTECTED_PATTERN='\^\((.*)\)\$'", hook).group(1)
for alternative in pattern.split("|"):
    literal = alternative.replace("\\.", ".")
    if ".*" in literal:
        stem, suffix = literal.split(".*", 1)
        assert list(root.glob(f"{stem}*{suffix}")), f"pre-push pattern matches nothing: {alternative}"
        continue
    named.add(literal)

missing = sorted(path for path in named if not (root / path).exists())
assert not missing, f"protected paths that no longer exist: {missing}"
print(f"protected-path liveness: {len(named)} paths checked")
PY

repo="$TMP/rollout-boundary"
mkdir -p "$repo/scripts" "$repo/tests/frameworks"
printf 'registry baseline\n' > "$repo/scripts/retro-prepare.sh"
printf 'reader test baseline\n' > "$repo/tests/frameworks/retro_prepare.bats"
git -C "$repo" init -q
git -C "$repo" config user.name "Retro Contract Test"
git -C "$repo" config user.email "retro-contract@example.invalid"
git -C "$repo" add .
git -C "$repo" commit -q -m baseline
base="$(git -C "$repo" rev-parse HEAD)"
printf 'pre-checker reader change\n' >> "$repo/scripts/retro-prepare.sh"
commit_all "$repo" "reader change before enforcement"
cp "$CHECKER" "$repo/scripts/check-retro-seam-drift.sh"
commit_all "$repo" "introduce drift checker"
expect_pass "$repo" "$base"

echo "retro seam drift check: PASS"
