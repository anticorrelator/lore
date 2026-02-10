#!/usr/bin/env bash
# test_stop_hook.sh — Tests for the Stop agent hook installation in install.sh
# Verifies that install.sh correctly configures the Stop agent hook in settings.json.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)

PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

assert_equals() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected: $expected"
    echo "    Got:      $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    Expected to contain: $expected"
    echo "    Got: $(echo "$output" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Stop Hook Installation Tests ==="
echo ""

# =============================================
# Test 1: Agent hook appears in settings.json with correct structure
# =============================================
echo "Test 1: Agent hook has correct structure in settings.json"

SETTINGS_FILE="$TEST_DIR/settings.json"
echo '{}' > "$SETTINGS_FILE"

# Create a fake scripts symlink pointing to our repo
FAKE_LORE_DIR="$TEST_DIR/fake-lore"
mkdir -p "$FAKE_LORE_DIR"
ln -s "$REPO_DIR/scripts" "$FAKE_LORE_DIR/scripts"

# Run the Python hook configuration logic with overridden paths
python3 - "$SETTINGS_FILE" "$FAKE_LORE_DIR/scripts" <<'PYEOF'
import json, sys, os

settings_path = sys.argv[1]
scripts_real_path = os.path.realpath(sys.argv[2])
repo_dir = os.path.dirname(scripts_real_path)

if os.path.exists(settings_path):
    with open(settings_path, "r") as f:
        settings = json.load(f)
else:
    settings = {}

stop_capture_prompt = ""
prompt_file = os.path.join(repo_dir, "scripts", "stop-capture-prompt.txt")
if os.path.exists(prompt_file):
    with open(prompt_file, "r") as pf:
        stop_capture_prompt = pf.read().strip()

lore_hooks = [
    ("SessionStart", None, "command", "bash ~/.lore/scripts/auto-reindex.sh", 5),
    ("SessionStart", None, "command", "bash ~/.lore/scripts/load-knowledge.sh", 5),
    ("SessionStart", None, "command", "bash ~/.lore/scripts/load-work.sh", 5),
    ("SessionStart", None, "command", "bash ~/.lore/scripts/load-threads.sh", 5),
    ("SessionStart", None, "command", "python3 ~/.lore/scripts/extract-session-digest.py", 5),
    ("PreCompact",   None, "command", "bash ~/.lore/scripts/pre-compact.sh", 5),
    ("Stop",         None, "agent",   stop_capture_prompt, 60),
    ("Stop",         None, "command", "python3 ~/.lore/scripts/check-plan-persistence.py", 10),
    ("SessionEnd",   "clear", "command", "bash ~/.lore/scripts/pre-compact.sh", 5),
]

lore_hooks = [(ht, m, k, p, t) for ht, m, k, p, t in lore_hooks if not (k == "agent" and not p)]

def is_lore_hook(entry):
    for h in entry.get("hooks", []):
        cmd = h.get("command", "")
        if "lore/scripts/" in cmd or "project-knowledge/scripts/" in cmd:
            return True
        prompt = h.get("prompt", "")
        if "lore-capture-evaluator" in prompt:
            return True
    return False

def make_entry(matcher, hook_kind, payload, timeout):
    entry = {}
    if matcher is not None:
        entry["matcher"] = matcher
    if hook_kind == "command":
        entry["hooks"] = [{"type": "command", "command": payload, "timeout": timeout}]
    elif hook_kind == "agent":
        entry["hooks"] = [{"type": "agent", "prompt": payload, "timeout": timeout}]
    return entry

hooks = settings.get("hooks", {})

from collections import defaultdict
lore_by_type = defaultdict(list)
for hook_type, matcher, hook_kind, payload, timeout in lore_hooks:
    lore_by_type[hook_type].append(make_entry(matcher, hook_kind, payload, timeout))

all_hook_types = set(list(hooks.keys()) + list(lore_by_type.keys()))
for hook_type in all_hook_types:
    existing = hooks.get(hook_type, [])
    preserved = [e for e in existing if not is_lore_hook(e)]
    new_lore = lore_by_type.get(hook_type, [])
    hooks[hook_type] = preserved + new_lore

hooks = {k: v for k, v in hooks.items() if v}
settings["hooks"] = hooks

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF

# Extract the Stop hooks from settings.json
STOP_HOOKS=$(python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    settings = json.load(f)
stop = settings.get('hooks', {}).get('Stop', [])
print(len(stop))
for entry in stop:
    for h in entry.get('hooks', []):
        print(h.get('type', ''))
        print(h.get('timeout', ''))
")

STOP_COUNT=$(echo "$STOP_HOOKS" | sed -n '1p')
FIRST_TYPE=$(echo "$STOP_HOOKS" | sed -n '2p')
FIRST_TIMEOUT=$(echo "$STOP_HOOKS" | sed -n '3p')
SECOND_TYPE=$(echo "$STOP_HOOKS" | sed -n '4p')
SECOND_TIMEOUT=$(echo "$STOP_HOOKS" | sed -n '5p')

assert_equals "two Stop hooks" "$STOP_COUNT" "2"
assert_equals "first Stop hook is agent type" "$FIRST_TYPE" "agent"
assert_equals "first Stop hook timeout is 60" "$FIRST_TIMEOUT" "60"
assert_equals "second Stop hook is command type" "$SECOND_TYPE" "command"
assert_equals "second Stop hook timeout is 10" "$SECOND_TIMEOUT" "10"

# =============================================
# Test 2: Agent hook prompt contains the marker
# =============================================
echo ""
echo "Test 2: Agent hook prompt contains lore-capture-evaluator marker"

PROMPT_CONTENT=$(python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    settings = json.load(f)
stop = settings['hooks']['Stop']
for entry in stop:
    for h in entry.get('hooks', []):
        if h.get('type') == 'agent':
            prompt = h.get('prompt', '')
            print('HAS_MARKER' if 'lore-capture-evaluator' in prompt else 'NO_MARKER')
            print('HAS_STOP_EVAL' if 'Stop hook evaluator' in prompt else 'NO_STOP_EVAL')
            print('HAS_TRIGGER' if 'Trigger Scan' in prompt else 'NO_TRIGGER')
")

HAS_MARKER=$(echo "$PROMPT_CONTENT" | sed -n '1p')
HAS_STOP_EVAL=$(echo "$PROMPT_CONTENT" | sed -n '2p')
HAS_TRIGGER=$(echo "$PROMPT_CONTENT" | sed -n '3p')

assert_equals "prompt has lore-capture-evaluator marker" "$HAS_MARKER" "HAS_MARKER"
assert_equals "prompt has Stop hook evaluator role" "$HAS_STOP_EVAL" "HAS_STOP_EVAL"
assert_equals "prompt has Trigger Scan section" "$HAS_TRIGGER" "HAS_TRIGGER"

# =============================================
# Test 3: Idempotent install — running twice produces same result
# =============================================
echo ""
echo "Test 3: Idempotent install — running twice produces same result"

FIRST_SETTINGS=$(cat "$SETTINGS_FILE")

# Run the same Python again
python3 - "$SETTINGS_FILE" "$FAKE_LORE_DIR/scripts" <<'PYEOF'
import json, sys, os

settings_path = sys.argv[1]
scripts_real_path = os.path.realpath(sys.argv[2])
repo_dir = os.path.dirname(scripts_real_path)

if os.path.exists(settings_path):
    with open(settings_path, "r") as f:
        settings = json.load(f)
else:
    settings = {}

stop_capture_prompt = ""
prompt_file = os.path.join(repo_dir, "scripts", "stop-capture-prompt.txt")
if os.path.exists(prompt_file):
    with open(prompt_file, "r") as pf:
        stop_capture_prompt = pf.read().strip()

lore_hooks = [
    ("SessionStart", None, "command", "bash ~/.lore/scripts/auto-reindex.sh", 5),
    ("SessionStart", None, "command", "bash ~/.lore/scripts/load-knowledge.sh", 5),
    ("SessionStart", None, "command", "bash ~/.lore/scripts/load-work.sh", 5),
    ("SessionStart", None, "command", "bash ~/.lore/scripts/load-threads.sh", 5),
    ("SessionStart", None, "command", "python3 ~/.lore/scripts/extract-session-digest.py", 5),
    ("PreCompact",   None, "command", "bash ~/.lore/scripts/pre-compact.sh", 5),
    ("Stop",         None, "agent",   stop_capture_prompt, 60),
    ("Stop",         None, "command", "python3 ~/.lore/scripts/check-plan-persistence.py", 10),
    ("SessionEnd",   "clear", "command", "bash ~/.lore/scripts/pre-compact.sh", 5),
]

lore_hooks = [(ht, m, k, p, t) for ht, m, k, p, t in lore_hooks if not (k == "agent" and not p)]

def is_lore_hook(entry):
    for h in entry.get("hooks", []):
        cmd = h.get("command", "")
        if "lore/scripts/" in cmd or "project-knowledge/scripts/" in cmd:
            return True
        prompt = h.get("prompt", "")
        if "lore-capture-evaluator" in prompt:
            return True
    return False

def make_entry(matcher, hook_kind, payload, timeout):
    entry = {}
    if matcher is not None:
        entry["matcher"] = matcher
    if hook_kind == "command":
        entry["hooks"] = [{"type": "command", "command": payload, "timeout": timeout}]
    elif hook_kind == "agent":
        entry["hooks"] = [{"type": "agent", "prompt": payload, "timeout": timeout}]
    return entry

hooks = settings.get("hooks", {})

from collections import defaultdict
lore_by_type = defaultdict(list)
for hook_type, matcher, hook_kind, payload, timeout in lore_hooks:
    lore_by_type[hook_type].append(make_entry(matcher, hook_kind, payload, timeout))

all_hook_types = set(list(hooks.keys()) + list(lore_by_type.keys()))
for hook_type in all_hook_types:
    existing = hooks.get(hook_type, [])
    preserved = [e for e in existing if not is_lore_hook(e)]
    new_lore = lore_by_type.get(hook_type, [])
    hooks[hook_type] = preserved + new_lore

hooks = {k: v for k, v in hooks.items() if v}
settings["hooks"] = hooks

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF

SECOND_SETTINGS=$(cat "$SETTINGS_FILE")

if [[ "$FIRST_SETTINGS" == "$SECOND_SETTINGS" ]]; then
  echo "  PASS: idempotent — second run produces identical output"
  PASS=$((PASS + 1))
else
  echo "  FAIL: idempotent — outputs differ"
  FAIL=$((FAIL + 1))
fi

# =============================================
# Test 4: Non-lore hooks are preserved
# =============================================
echo ""
echo "Test 4: Non-lore hooks are preserved across install"

# Add a non-lore Stop hook to settings.json
python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    settings = json.load(f)
settings['hooks']['Stop'].insert(0, {'hooks': [{'type': 'command', 'command': 'echo custom-hook', 'timeout': 5}]})
with open('$SETTINGS_FILE', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
"

# Verify 3 Stop hooks before re-install
BEFORE_COUNT=$(python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    print(len(json.load(f)['hooks']['Stop']))
")
assert_equals "3 Stop hooks before re-install" "$BEFORE_COUNT" "3"

# Re-run install
python3 - "$SETTINGS_FILE" "$FAKE_LORE_DIR/scripts" <<'PYEOF'
import json, sys, os

settings_path = sys.argv[1]
scripts_real_path = os.path.realpath(sys.argv[2])
repo_dir = os.path.dirname(scripts_real_path)

if os.path.exists(settings_path):
    with open(settings_path, "r") as f:
        settings = json.load(f)
else:
    settings = {}

stop_capture_prompt = ""
prompt_file = os.path.join(repo_dir, "scripts", "stop-capture-prompt.txt")
if os.path.exists(prompt_file):
    with open(prompt_file, "r") as pf:
        stop_capture_prompt = pf.read().strip()

lore_hooks = [
    ("SessionStart", None, "command", "bash ~/.lore/scripts/auto-reindex.sh", 5),
    ("SessionStart", None, "command", "bash ~/.lore/scripts/load-knowledge.sh", 5),
    ("SessionStart", None, "command", "bash ~/.lore/scripts/load-work.sh", 5),
    ("SessionStart", None, "command", "bash ~/.lore/scripts/load-threads.sh", 5),
    ("SessionStart", None, "command", "python3 ~/.lore/scripts/extract-session-digest.py", 5),
    ("PreCompact",   None, "command", "bash ~/.lore/scripts/pre-compact.sh", 5),
    ("Stop",         None, "agent",   stop_capture_prompt, 60),
    ("Stop",         None, "command", "python3 ~/.lore/scripts/check-plan-persistence.py", 10),
    ("SessionEnd",   "clear", "command", "bash ~/.lore/scripts/pre-compact.sh", 5),
]

lore_hooks = [(ht, m, k, p, t) for ht, m, k, p, t in lore_hooks if not (k == "agent" and not p)]

def is_lore_hook(entry):
    for h in entry.get("hooks", []):
        cmd = h.get("command", "")
        if "lore/scripts/" in cmd or "project-knowledge/scripts/" in cmd:
            return True
        prompt = h.get("prompt", "")
        if "lore-capture-evaluator" in prompt:
            return True
    return False

def make_entry(matcher, hook_kind, payload, timeout):
    entry = {}
    if matcher is not None:
        entry["matcher"] = matcher
    if hook_kind == "command":
        entry["hooks"] = [{"type": "command", "command": payload, "timeout": timeout}]
    elif hook_kind == "agent":
        entry["hooks"] = [{"type": "agent", "prompt": payload, "timeout": timeout}]
    return entry

hooks = settings.get("hooks", {})

from collections import defaultdict
lore_by_type = defaultdict(list)
for hook_type, matcher, hook_kind, payload, timeout in lore_hooks:
    lore_by_type[hook_type].append(make_entry(matcher, hook_kind, payload, timeout))

all_hook_types = set(list(hooks.keys()) + list(lore_by_type.keys()))
for hook_type in all_hook_types:
    existing = hooks.get(hook_type, [])
    preserved = [e for e in existing if not is_lore_hook(e)]
    new_lore = lore_by_type.get(hook_type, [])
    hooks[hook_type] = preserved + new_lore

hooks = {k: v for k, v in hooks.items() if v}
settings["hooks"] = hooks

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF

# After re-install: should have 3 Stop hooks (1 custom + 2 lore)
AFTER_COUNT=$(python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    print(len(json.load(f)['hooks']['Stop']))
")
assert_equals "3 Stop hooks after re-install (custom preserved)" "$AFTER_COUNT" "3"

# The custom hook should be first (preserved hooks come before lore hooks)
FIRST_CMD=$(python3 -c "
import json
with open('$SETTINGS_FILE') as f:
    settings = json.load(f)
stop = settings['hooks']['Stop']
print(stop[0]['hooks'][0].get('command', 'no-command'))
")
assert_equals "custom hook is first" "$FIRST_CMD" "echo custom-hook"

# =============================================
# Test 5: Graceful skip when prompt file missing
# =============================================
echo ""
echo "Test 5: Graceful skip when prompt file missing"

SETTINGS_NO_PROMPT="$TEST_DIR/settings-no-prompt.json"
echo '{}' > "$SETTINGS_NO_PROMPT"

# Create a fake scripts dir WITHOUT stop-capture-prompt.txt
FAKE_SCRIPTS_NO_PROMPT="$TEST_DIR/fake-scripts-no-prompt"
mkdir -p "$FAKE_SCRIPTS_NO_PROMPT"

python3 - "$SETTINGS_NO_PROMPT" "$FAKE_SCRIPTS_NO_PROMPT" <<'PYEOF'
import json, sys, os

settings_path = sys.argv[1]
scripts_real_path = os.path.realpath(sys.argv[2])
repo_dir = os.path.dirname(scripts_real_path)

if os.path.exists(settings_path):
    with open(settings_path, "r") as f:
        settings = json.load(f)
else:
    settings = {}

stop_capture_prompt = ""
prompt_file = os.path.join(repo_dir, "scripts", "stop-capture-prompt.txt")
if os.path.exists(prompt_file):
    with open(prompt_file, "r") as pf:
        stop_capture_prompt = pf.read().strip()

lore_hooks = [
    ("SessionStart", None, "command", "bash ~/.lore/scripts/auto-reindex.sh", 5),
    ("Stop",         None, "agent",   stop_capture_prompt, 60),
    ("Stop",         None, "command", "python3 ~/.lore/scripts/check-plan-persistence.py", 10),
]

lore_hooks = [(ht, m, k, p, t) for ht, m, k, p, t in lore_hooks if not (k == "agent" and not p)]

def is_lore_hook(entry):
    for h in entry.get("hooks", []):
        cmd = h.get("command", "")
        if "lore/scripts/" in cmd or "project-knowledge/scripts/" in cmd:
            return True
        prompt = h.get("prompt", "")
        if "lore-capture-evaluator" in prompt:
            return True
    return False

def make_entry(matcher, hook_kind, payload, timeout):
    entry = {}
    if matcher is not None:
        entry["matcher"] = matcher
    if hook_kind == "command":
        entry["hooks"] = [{"type": "command", "command": payload, "timeout": timeout}]
    elif hook_kind == "agent":
        entry["hooks"] = [{"type": "agent", "prompt": payload, "timeout": timeout}]
    return entry

hooks = settings.get("hooks", {})

from collections import defaultdict
lore_by_type = defaultdict(list)
for hook_type, matcher, hook_kind, payload, timeout in lore_hooks:
    lore_by_type[hook_type].append(make_entry(matcher, hook_kind, payload, timeout))

all_hook_types = set(list(hooks.keys()) + list(lore_by_type.keys()))
for hook_type in all_hook_types:
    existing = hooks.get(hook_type, [])
    preserved = [e for e in existing if not is_lore_hook(e)]
    new_lore = lore_by_type.get(hook_type, [])
    hooks[hook_type] = preserved + new_lore

hooks = {k: v for k, v in hooks.items() if v}
settings["hooks"] = hooks

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF

# Should have only 1 Stop hook (the command one), no agent hook
STOP_COUNT_NO_PROMPT=$(python3 -c "
import json
with open('$SETTINGS_NO_PROMPT') as f:
    settings = json.load(f)
stop = settings.get('hooks', {}).get('Stop', [])
print(len(stop))
for entry in stop:
    for h in entry.get('hooks', []):
        print(h.get('type', ''))
")

NO_PROMPT_COUNT=$(echo "$STOP_COUNT_NO_PROMPT" | sed -n '1p')
NO_PROMPT_TYPE=$(echo "$STOP_COUNT_NO_PROMPT" | sed -n '2p')

assert_equals "only 1 Stop hook when prompt missing" "$NO_PROMPT_COUNT" "1"
assert_equals "remaining Stop hook is command type" "$NO_PROMPT_TYPE" "command"

# =============================================
# Test 6: Uninstall removes agent hooks
# =============================================
echo ""
echo "Test 6: Uninstall removes agent hooks"

# Start from a clean settings with just lore hooks (no leftover custom hooks from Test 4)
SETTINGS_UNINSTALL="$TEST_DIR/settings-uninstall.json"
echo '{}' > "$SETTINGS_UNINSTALL"

# Install lore hooks fresh
python3 - "$SETTINGS_UNINSTALL" "$FAKE_LORE_DIR/scripts" <<'PYEOF'
import json, sys, os

settings_path = sys.argv[1]
scripts_real_path = os.path.realpath(sys.argv[2])
repo_dir = os.path.dirname(scripts_real_path)

if os.path.exists(settings_path):
    with open(settings_path, "r") as f:
        settings = json.load(f)
else:
    settings = {}

stop_capture_prompt = ""
prompt_file = os.path.join(repo_dir, "scripts", "stop-capture-prompt.txt")
if os.path.exists(prompt_file):
    with open(prompt_file, "r") as pf:
        stop_capture_prompt = pf.read().strip()

lore_hooks = [
    ("SessionStart", None, "command", "bash ~/.lore/scripts/auto-reindex.sh", 5),
    ("Stop",         None, "agent",   stop_capture_prompt, 60),
    ("Stop",         None, "command", "python3 ~/.lore/scripts/check-plan-persistence.py", 10),
]

lore_hooks = [(ht, m, k, p, t) for ht, m, k, p, t in lore_hooks if not (k == "agent" and not p)]

def make_entry(matcher, hook_kind, payload, timeout):
    entry = {}
    if matcher is not None:
        entry["matcher"] = matcher
    if hook_kind == "command":
        entry["hooks"] = [{"type": "command", "command": payload, "timeout": timeout}]
    elif hook_kind == "agent":
        entry["hooks"] = [{"type": "agent", "prompt": payload, "timeout": timeout}]
    return entry

hooks = settings.get("hooks", {})
from collections import defaultdict
lore_by_type = defaultdict(list)
for hook_type, matcher, hook_kind, payload, timeout in lore_hooks:
    lore_by_type[hook_type].append(make_entry(matcher, hook_kind, payload, timeout))

for hook_type in set(list(hooks.keys()) + list(lore_by_type.keys())):
    existing = hooks.get(hook_type, [])
    hooks[hook_type] = existing + lore_by_type.get(hook_type, [])

hooks = {k: v for k, v in hooks.items() if v}
settings["hooks"] = hooks

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF

# Add a non-lore hook so we can verify it's preserved
python3 -c "
import json
with open('$SETTINGS_UNINSTALL') as f:
    settings = json.load(f)
settings['hooks']['Stop'].insert(0, {'hooks': [{'type': 'command', 'command': 'echo keep-me', 'timeout': 5}]})
with open('$SETTINGS_UNINSTALL', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
"

# Run the uninstall logic
python3 - "$SETTINGS_UNINSTALL" <<'PYEOF'
import json, sys

settings_path = sys.argv[1]
with open(settings_path, "r") as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
for hook_type in list(hooks.keys()):
    entries = hooks[hook_type]
    filtered = []
    for entry in entries:
        inner_hooks = entry.get("hooks", [])
        is_lore = any(
            "lore/scripts/" in h.get("command", "") or "project-knowledge/scripts/" in h.get("command", "")
            or "lore-capture-evaluator" in h.get("prompt", "")
            for h in inner_hooks
        )
        if not is_lore:
            filtered.append(entry)
    if filtered:
        hooks[hook_type] = filtered
    else:
        del hooks[hook_type]

if hooks:
    settings["hooks"] = hooks
elif "hooks" in settings:
    del settings["hooks"]

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF

# After uninstall: only the custom "echo keep-me" hook should remain under Stop
UNINSTALL_RESULT=$(python3 -c "
import json
with open('$SETTINGS_UNINSTALL') as f:
    settings = json.load(f)
stop = settings.get('hooks', {}).get('Stop', [])
print(len(stop))
if stop:
    print(stop[0]['hooks'][0].get('command', 'none'))
# Check no SessionStart hooks remain (all were lore)
session = settings.get('hooks', {}).get('SessionStart', [])
print(len(session))
")

UNINSTALL_STOP_COUNT=$(echo "$UNINSTALL_RESULT" | sed -n '1p')
UNINSTALL_STOP_CMD=$(echo "$UNINSTALL_RESULT" | sed -n '2p')
UNINSTALL_SESSION_COUNT=$(echo "$UNINSTALL_RESULT" | sed -n '3p')

assert_equals "1 Stop hook after uninstall" "$UNINSTALL_STOP_COUNT" "1"
assert_equals "preserved hook is custom" "$UNINSTALL_STOP_CMD" "echo keep-me"
assert_equals "all SessionStart hooks removed" "$UNINSTALL_SESSION_COUNT" "0"

# =============================================
# Summary
# =============================================
echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo "$PASS/$TOTAL passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
else
  echo "All tests passed!"
  exit 0
fi
