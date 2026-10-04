#!/usr/bin/env bash
# test_install_digest.sh — install preflight, post-install digest, and the
# prerequisite checks behind them (scripts/prereqs.sh, doctor.sh --digest).
#
# Strategy: build a PATH holding only the tools lore requires (no go, gh,
# tmux or C compiler, whatever the host has), install into a throwaway HOME,
# and assert on what install.sh and doctor report. LORE_PKG_MANAGER=apt pins
# the fix hints so assertions do not depend on the host's package manager.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

check() {
  local label="$1"; shift
  if "$@"; then
    echo "  PASS: $label"; PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"; FAIL=$((FAIL + 1))
  fi
}
contains() { [[ "$1" == *"$2"* ]]; }
lacks() { [[ "$1" != *"$2"* ]]; }

# Required tools only. Resolved from the host PATH plus the usual system dirs.
TOOLS="$WORK/tools"
mkdir -p "$TOOLS"
for tool in bash sh env cat cp ln mkdir rm mv chmod touch ls sed awk grep find sort uniq \
            tr wc head tail cut date uname id readlink dirname basename mktemp stat tput \
            xargs tee sleep git jq python3 shasum sha256sum diff cmp comm od expr; do
  if path=$(PATH="$PATH:/usr/bin:/bin" command -v "$tool" 2>/dev/null) && [[ -x "$path" ]]; then
    ln -sf "$path" "$TOOLS/$tool"
  fi
done
for tool in git jq python3 grep; do
  [[ -e "$TOOLS/$tool" ]] || { echo "SKIP: host lacks $tool"; exit 0; }
done

SAFE_SUDO="sudo "
[[ "$(id -u)" == 0 ]] && SAFE_SUDO=""

# run_env <home> <path> <cmd...> — a clean environment for lore commands.
run_env() {
  local home="$1" path="$2"; shift 2
  env -i HOME="$home" PATH="$path" SHELL=/bin/bash TERM=dumb LANG="${LANG:-C}" \
    LORE_PKG_MANAGER=apt "$@"
}

echo "=== install preflight and post-install digest ==="

# --- 1. prereqs.sh names a missing required tool with the manager's command ---
echo ""
echo "Test 1: prereqs.sh --records reports jq with an apt fix"
NOJQ="$WORK/nojq"
mkdir -p "$NOJQ"
for f in "$TOOLS"/*; do [[ "$(basename "$f")" == jq ]] || ln -sf "$(readlink "$f")" "$NOJQ/"; done
records=$(run_env "$WORK/h0" "$NOJQ" bash "$REPO_DIR/scripts/prereqs.sh" --records | tr '\037' '|')
check "jq record is required" contains "$records" "required|jq|"
check "jq fix is the apt command" contains "$records" "|jq|${SAFE_SUDO}apt-get install -y jq"
check "go is optional" contains "$records" "optional|go|"

# --- 2. install.sh stops before touching anything when a required tool is missing ---
echo ""
echo "Test 2: install.sh refuses to start without jq and says how to get it"
H2="$WORK/h2"; mkdir -p "$H2"
set +e
out=$(run_env "$H2" "$NOJQ" bash "$REPO_DIR/install.sh" 2>&1)
rc=$?
set -e
check "exit status is non-zero" test "$rc" -ne 0
check "explains what is missing" contains "$out" "can't be installed until these are in place"
check "prints the install command" contains "$out" "apt-get install -y jq"
check "nothing was installed" test ! -e "$H2/.lore/scripts"

# --- 3. a full install ends with the digest; optional-only is not a failure ---
echo ""
echo "Test 3: install ends with next steps listing optional tools only"
H3="$WORK/h3"; mkdir -p "$H3"
set +e
out=$(run_env "$H3" "$TOOLS:$H3/.local/bin" bash "$REPO_DIR/install.sh" 2>&1)
rc=$?
set -e
check "install exits 0" test "$rc" -eq 0
check "digest heading present" contains "$out" "lore: next steps"
check "go listed with apt fix" contains "$out" "apt-get install -y golang-go"
check "batched install line" contains "$out" "All of the above in one command"
check "nothing required" lacks "$out" "Required:"
check "says lore is ready" contains "$out" "Lore is ready"
check "no pip advice anywhere" lacks "$out" "pip install"

# --- 4. optional tools never wake --quiet or fail doctor ---
echo ""
echo "Test 4: doctor --quiet is silent and exits 0 when only optional tools are missing"
set +e
quiet=$(run_env "$H3" "$TOOLS:$H3/.local/bin" bash "$REPO_DIR/scripts/doctor.sh" --quiet 2>&1)
rc=$?
set -e
check "--quiet exits 0" test "$rc" -eq 0
check "--quiet prints nothing" test -z "$quiet"

echo ""
echo "Test 5: doctor --json marks optional prerequisites and carries fixes"
json=$(run_env "$H3" "$TOOLS:$H3/.local/bin" bash "$REPO_DIR/scripts/doctor.sh" --json || true)
status=$(printf '%s' "$json" | jq -r '.status')
gofix=$(printf '%s' "$json" | jq -r '.issues[] | select(.component=="prerequisites" and .artifact=="go") | "\(.type)|\(.fix)"')
check "status is clean" test "$status" = clean
check "go is type optional with its fix" test "$gofix" = "optional|${SAFE_SUDO}apt-get install -y golang-go"

# --- 5. PATH without ~/.local/bin is a required step with a shell-specific fix ---
echo ""
echo "Test 6: missing ~/.local/bin on PATH is required, with the bash profile line"
set +e
digest=$(run_env "$H3" "$TOOLS" bash "$REPO_DIR/scripts/doctor.sh" --digest 2>&1)
rc=$?
set -e
check "--digest exits 1" test "$rc" -eq 1
check "PATH step listed as required" contains "$digest" "~/.local/bin is not on PATH"
check "bash line suggested" contains "$digest" "export PATH=\"\$HOME/.local/bin:\$PATH\""

# --- 6. schema validation needs no jsonschema package ---
echo ""
echo "Test 7: a settings schema violation is reported with a fix, no jsonschema needed"
SETTINGS="$H3/.lore/config/settings.json"
cp "$SETTINGS" "$WORK/settings.bak"
jq '.routes.default = "gpt"' "$WORK/settings.bak" > "$SETTINGS"
json=$(run_env "$H3" "$TOOLS:$H3/.local/bin" bash "$REPO_DIR/scripts/doctor.sh" --json || true)
cp "$WORK/settings.bak" "$SETTINGS"
violation=$(printf '%s' "$json" | jq -r '.issues[] | select(.component=="settings_schema") | "\(.type)|\(.detail)"')
check "violation names the path" contains "$violation" "schema_violation|validation failed at routes/default:"
check "no jsonschema dependency surfaced" lacks "$json" "jsonschema"

echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
echo "All tests passed!"
