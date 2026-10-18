#!/usr/bin/env bash
# test_frameworks_capabilities.sh — Bash mirror of tests/frameworks/capabilities.bats
#
# Why mirror: the canonical artifact named in the multi-framework-agent-support
# plan (Phase 1, T13) is a `.bats` file, but the existing tests/ directory uses
# `test_*.sh` bash runners and bats is not installed in CI yet. This script
# runs the same validations so coverage works without the bats toolchain;
# both files MUST stay in sync. If a check is added here, mirror it to
# tests/frameworks/capabilities.bats and vice versa.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAPS="$REPO_DIR/adapters/capabilities.json"
EVID="$REPO_DIR/adapters/capabilities-evidence.md"

PASS=0
FAIL=0

assert_ok() {
  local label="$1"
  shift
  if "$@" >/tmp/cap-test-out 2>&1; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    sed 's/^/    /' /tmp/cap-test-out
    FAIL=$((FAIL + 1))
  fi
}

# --- Setup checks ---
if [[ ! -f "$CAPS" ]]; then
  echo "SKIP: $CAPS missing"
  exit 0
fi
if [[ ! -f "$EVID" ]]; then
  echo "SKIP: $EVID missing"
  exit 0
fi

# --- Schema-shape ---

check_json_parses() {
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$CAPS"
}

check_top_level_keys() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
required = ["version", "support_levels", "capabilities", "frameworks"]
missing = [k for k in required if k not in d]
if missing:
    print("missing keys:", missing); sys.exit(1)
' "$CAPS"
}

check_support_levels() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
got = set(d["support_levels"].keys())
want = {"full", "partial", "fallback", "none"}
if got != want:
    print("expected", sorted(want), "got", sorted(got)); sys.exit(1)
' "$CAPS"
}

check_frameworks_present() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
got = set(d["frameworks"].keys())
want = {"claude-code", "opencode", "codex"}
missing = want - got
if missing:
    print("missing frameworks:", sorted(missing)); sys.exit(1)
' "$CAPS"
}

# --- Per-cell schema ---

check_support_level_closed_set() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
allowed = set(d["support_levels"].keys())
bad = []
for fw_id, fw in d["frameworks"].items():
    for cap, cell in (fw.get("capabilities") or {}).items():
        s = cell.get("support")
        if s not in allowed:
            bad.append(f"{fw_id}.{cap}.support={s!r}")
if bad:
    print("invalid support levels:")
    for b in bad: print(" ", b)
    sys.exit(1)
' "$CAPS"
}

check_per_cell_capability_declared() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
declared = set(d["capabilities"].keys())
bad = []
for fw_id, fw in d["frameworks"].items():
    for cap in (fw.get("capabilities") or {}).keys():
        if cap not in declared:
            bad.append(f"{fw_id}.capabilities.{cap}")
if bad:
    print("undeclared capability keys:")
    for b in bad: print(" ", b)
    sys.exit(1)
' "$CAPS"
}

check_no_partial_profiles() {
  # model_routing, interaction, spend_telemetry, and session_lifecycle_hooks live
  # at the framework root (siblings to capabilities) rather than inside the
  # per-framework capabilities map because their shapes are not a plain support
  # cell. Validate routing via check_model_routing, interaction via
  # check_interaction_rows, spend via check_spend_telemetry, and lifecycle hooks
  # via check_lifecycle_hooks_shape and check_lifecycle_hooks_d8.
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
declared = set(d["capabilities"].keys()) - {"model_routing", "interaction", "spend_telemetry", "session_lifecycle_hooks"}
bad = []
for fw_id, fw in d["frameworks"].items():
    have = set((fw.get("capabilities") or {}).keys())
    missing = declared - have
    if missing:
        bad.append((fw_id, sorted(missing)))
if bad:
    for fw_id, m in bad:
        print(f"{fw_id} missing:", m)
    sys.exit(1)
' "$CAPS"
}

check_evidence_present_for_non_none() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
bad = []
for fw_id, fw in d["frameworks"].items():
    for cap, cell in (fw.get("capabilities") or {}).items():
        if cell.get("support") == "none":
            continue
        ev = cell.get("evidence")
        if not isinstance(ev, str) or not ev.strip():
            bad.append(f"{fw_id}.{cap}")
if bad:
    print("non-none cells without evidence pointer:")
    for b in bad: print(" ", b)
    sys.exit(1)
' "$CAPS"
}

check_model_routing() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
allowed = {"single", "multi"}
bad = []
for fw_id, fw in d["frameworks"].items():
    mr = fw.get("model_routing") or {}
    shape = mr.get("shape")
    ev = mr.get("evidence")
    if shape not in allowed:
        bad.append(f"{fw_id}.model_routing.shape={shape!r}")
    if not isinstance(ev, str) or not ev.strip():
        bad.append(f"{fw_id}.model_routing.evidence missing")
if bad:
    for b in bad: print(b)
    sys.exit(1)
' "$CAPS"
}

check_interaction_rows() {
  # Every framework declares the closed interaction row set; each row is an
  # evidence-gated cell (support in the closed set + non-empty evidence) with
  # exactly the typed payload its kind requires. Derived from the JSON, never
  # hard-coded per harness.
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
levels = set(d["support_levels"].keys())
SIG = {"composer_signature", "permission_prompt_signature"}
SEQ = {"submit_sequence", "newline_sequence", "graceful_exit_sequence"}
VAL = {"honors_bracketed_paste", "paste_multiline_semantics", "mid_generation_semantics"}
ROWS = SIG | SEQ | VAL
PASTE_VOCAB = {"held-multiline-needs-submit", "auto-submit-on-close"}
MIDGEN_VOCAB = {"queued-autosubmit", "buffered-draft", "dropped", "interrupts"}
bad = []
for fw_id, fw in d["frameworks"].items():
    ix = fw.get("interaction")
    if not isinstance(ix, dict):
        bad.append(f"{fw_id}: missing interaction block"); continue
    if set(ix.keys()) != ROWS:
        bad.append(f"{fw_id}.interaction rows {sorted(ix.keys())} != {sorted(ROWS)}")
        continue
    for row, cell in ix.items():
        if not isinstance(cell, dict):
            bad.append(f"{fw_id}.interaction.{row} not an object"); continue
        if cell.get("support") not in levels:
            bad.append(f"{fw_id}.interaction.{row} support outside closed set")
        ev = cell.get("evidence")
        if not isinstance(ev, str) or not ev.strip():
            bad.append(f"{fw_id}.interaction.{row} missing evidence")
        if row in SIG and not (isinstance(cell.get("matcher"), str) and cell["matcher"].strip()):
            bad.append(f"{fw_id}.interaction.{row} missing matcher")
        if row in SEQ and not (isinstance(cell.get("sequence"), str) and cell["sequence"]):
            bad.append(f"{fw_id}.interaction.{row} missing non-empty sequence")
        if row == "honors_bracketed_paste" and not isinstance(cell.get("value"), bool):
            bad.append(f"{fw_id}.interaction.{row}.value not a bool")
        if row == "paste_multiline_semantics" and cell.get("value") not in PASTE_VOCAB:
            bad.append(f"{fw_id}.interaction.{row} paste value outside vocab")
        if row == "mid_generation_semantics" and cell.get("value") not in MIDGEN_VOCAB:
            bad.append(f"{fw_id}.interaction.{row} midgen value outside vocab")
if bad:
    for b in bad: print(b)
    sys.exit(1)
' "$CAPS"
}

check_spend_telemetry() {
  # spend_telemetry is a framework-root sibling block (like model_routing and
  # interaction): every framework declares one, evidence-gated, with a closed
  # artifact/binding vocabulary and a fields[] list drawn from the normalized
  # spend token vocabulary. Derived from the JSON, never hard-coded per harness.
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
levels = set(d["support_levels"].keys())
ARTIFACTS = {"transcript", "rollout", "store"}
BINDINGS = {"session-id-flag", "none"}
FIELD_VOCAB = {"input_tokens", "output_tokens", "cache_read_input_tokens",
               "cache_creation_input_tokens", "reasoning_output_tokens",
               "total_tokens", "cost_usd", "model"}
bad = []
for fw_id, fw in d["frameworks"].items():
    st = fw.get("spend_telemetry")
    if not isinstance(st, dict):
        bad.append(f"{fw_id}: missing spend_telemetry block"); continue
    if st.get("support") not in levels:
        bad.append(f"{fw_id}.spend_telemetry.support outside closed set")
    ev = st.get("evidence")
    if not isinstance(ev, str) or not ev.strip():
        bad.append(f"{fw_id}.spend_telemetry missing evidence")
    if st.get("artifact") not in ARTIFACTS:
        bad.append(f"{fw_id}.spend_telemetry.artifact outside {sorted(ARTIFACTS)}")
    if st.get("binding") not in BINDINGS:
        bad.append(f"{fw_id}.spend_telemetry.binding outside {sorted(BINDINGS)}")
    fields = st.get("fields")
    if not isinstance(fields, list) or not fields:
        bad.append(f"{fw_id}.spend_telemetry.fields not a non-empty list")
    else:
        for f in fields:
            if f not in FIELD_VOCAB:
                bad.append(f"{fw_id}.spend_telemetry.fields has unknown field {f!r}")
if bad:
    for b in bad: print(b)
    sys.exit(1)
' "$CAPS"
}

check_lifecycle_hooks_shape() {
  # check_lifecycle_hooks_shape <capabilities.json> — every framework declares a
  # typed session_lifecycle_hooks block whose events map onto the two hook-row
  # events with a consistent activity.
  python3 - "${1:-$CAPS}" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
levels = set(d["support_levels"].keys())
CHANNELS = {"settings-json", "config-override", "plugin-env"}
ACTIVITY = {"needs_input": {"idle", "blocked"}, "resumed": {"working"}}
RESERVED_LINKS = {"authority", "hook_event", "activity", "generation", "fired_at",
                  "framework", "spawn_instance", "observation", "work_item"}
def text(v):
    return isinstance(v, str) and v.strip() != ""
bad = []
for fw_id, fw in d["frameworks"].items():
    where = f"{fw_id}.session_lifecycle_hooks"
    cell = fw.get("session_lifecycle_hooks")
    if not isinstance(cell, dict):
        bad.append(f"{fw_id}: missing session_lifecycle_hooks block"); continue
    extra = set(cell) - {"support", "evidence", "channel", "events", "notes"}
    if extra:
        bad.append(f"{where} has undeclared keys {sorted(extra)}")
    support = cell.get("support")
    if support not in levels:
        bad.append(f"{where}.support={support!r} outside the closed set")
    if cell.get("channel") not in CHANNELS:
        bad.append(f"{where}.channel={cell.get('channel')!r} outside {sorted(CHANNELS)}")
    if "evidence" in cell and not text(cell["evidence"]):
        bad.append(f"{where}.evidence must be a non-empty id when present")
    if support != "none" and not text(cell.get("evidence")):
        bad.append(f"{where} is {support!r} without an evidence pointer")
    if not isinstance(cell.get("notes"), str):
        bad.append(f"{where}.notes is not a string")
    events = cell.get("events")
    if not isinstance(events, list):
        bad.append(f"{where}.events is not a list"); continue
    if support != "none" and not events:
        bad.append(f"{where} is {support!r} but declares no events")
    seen = set()
    for i, e in enumerate(events):
        at = f"{where}.events[{i}]"
        if not isinstance(e, dict):
            bad.append(f"{at} is not an object"); continue
        extra = set(e) - {"hook_event", "matcher", "event", "activity", "payload_links"}
        if extra:
            bad.append(f"{at} has undeclared keys {sorted(extra)}")
        if not text(e.get("hook_event")):
            bad.append(f"{at}.hook_event missing")
        if "matcher" in e and not text(e["matcher"]):
            bad.append(f"{at}.matcher must be a non-empty string when present")
        event = e.get("event")
        if event not in ACTIVITY:
            bad.append(f"{at}.event={event!r} is not needs_input or resumed")
        elif e.get("activity") not in ACTIVITY[event]:
            bad.append(f"{at}.activity={e.get('activity')!r} does not fit {event} ({sorted(ACTIVITY[event])})")
        links = e.get("payload_links", {})
        if not isinstance(links, dict):
            bad.append(f"{at}.payload_links is not an object")
        else:
            for link, field in links.items():
                if not text(link) or not text(field):
                    bad.append(f"{at}.payload_links maps {link!r} to {field!r}; both must be non-empty strings")
                elif link in RESERVED_LINKS:
                    bad.append(f"{at}.payload_links would overwrite the hook row's own link {link!r}")
        key = (e.get("hook_event"), e.get("matcher"))
        if key in seen:
            bad.append(f"{at} repeats hook_event/matcher {key}")
        seen.add(key)
if bad:
    for b in bad: print(b)
    sys.exit(1)
PYEOF
}

check_lifecycle_hooks_d8() {
  # check_lifecycle_hooks_d8 <capabilities.json> <capabilities-evidence.md> <YYYY-MM-DD>
  # D8 for session_lifecycle_hooks cells, judged against the supplied reference
  # date rather than today: full needs a versioned row retrieved no more than 90
  # days before it; partial and fallback need a row of any age; none needs notes.
  python3 - "$1" "$2" "$3" <<'PYEOF'
import datetime, json, re, sys
caps, evid, ref = sys.argv[1], sys.argv[2], sys.argv[3]
ref_date = datetime.date.fromisoformat(ref[:10])
d = json.load(open(caps))
body = open(evid).read().partition("## _index")[0]
rows = {m.group(1): m.group(2) for m in
        re.finditer(r"(?ms)^### ([a-z0-9-]+)[ \t]*\n(.*?)(?=^### |^## |\Z)", body)}
def fields(row):
    out, current = {}, None
    for line in row.splitlines():
        m = re.match(r"^- \*\*(.+?):\*\*\s*(.*)$", line)
        if m:
            current = m.group(1)
            out[current] = m.group(2)
        elif current and line.startswith("  "):
            out[current] += " " + line.strip()
        else:
            current = None
    return out
bad = []
for fw_id, fw in d["frameworks"].items():
    cell = fw.get("session_lifecycle_hooks")
    if not isinstance(cell, dict):
        continue
    where = f"{fw_id}.session_lifecycle_hooks"
    support, ev = cell.get("support"), cell.get("evidence")
    if support == "none":
        if not (isinstance(cell.get("notes"), str) and cell["notes"].strip()):
            bad.append(f"{where} is none but its notes do not name the premise that blocks it")
        continue
    if ev not in rows:
        bad.append(f"{where} is {support} but cites no evidence row in the evidence file ({ev!r})")
        continue
    if support != "full":
        continue
    row = fields(rows[ev])
    dates = re.findall(r"\d{4}-\d{2}-\d{2}", row.get("Retrieved", ""))
    if not dates:
        bad.append(f"{where} is full but evidence row {ev} is undated")
        continue
    latest = max(datetime.date.fromisoformat(x) for x in dates)
    age = (ref_date - latest).days
    if age > 90:
        bad.append(f"{where} is full but evidence row {ev} was retrieved {latest}, {age} days before {ref_date}; D8 allows full only within 90 days")
    version = row.get("Product / version", "")
    if "unversioned" in version.lower() or not re.search(r"\d+\.\d+", version):
        bad.append(f"{where} is full but evidence row {ev} names no product version")
if bad:
    for b in bad: print(b)
    sys.exit(1)
PYEOF
}

capabilities_commit_date() {
  # The committer date of the latest commit touching adapters/capabilities.json,
  # or HEAD's when no commit touches it; empty outside a git checkout.
  local stamp
  stamp=$(git -C "$REPO_DIR" log -1 --format=%cI -- adapters/capabilities.json 2>/dev/null || true)
  [[ -n "$stamp" ]] || stamp=$(git -C "$REPO_DIR" log -1 --format=%cI HEAD 2>/dev/null || true)
  printf '%s' "${stamp:0:10}"
}

check_headless_argument_contract() {
  # Every non-none headless_runner cell declares how its non-interactive
  # surface differs from the interactive one, evidence-gated and CLI-version
  # stamped. `filtered` carries a source_grammar whose entries give each flag
  # spelling an arity and an accepted/rejected policy; `shared_parser` is the
  # positive finding that there is no narrower surface and must not carry one.
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
MODES = {"filtered", "shared_parser"}
POLICY = {"accepted", "rejected"}
bad = []
for fw_id, fw in d["frameworks"].items():
    cell = (fw.get("capabilities") or {}).get("headless_runner") or {}
    if cell.get("support") == "none":
        continue
    ac = cell.get("argument_contract")
    if not isinstance(ac, dict):
        bad.append(f"{fw_id}.headless_runner has no argument_contract block"); continue
    mode = ac.get("mode")
    if mode not in MODES:
        bad.append(f"{fw_id}.headless_runner.argument_contract.mode={mode!r} outside {sorted(MODES)}")
    for field in ("evidence", "cli_version"):
        val = ac.get(field)
        if not isinstance(val, str) or not val.strip():
            bad.append(f"{fw_id}.headless_runner.argument_contract.{field} missing")
    grammar = ac.get("source_grammar")
    if mode == "shared_parser":
        if grammar is not None:
            bad.append(f"{fw_id}.headless_runner.argument_contract declares shared_parser with a source_grammar")
        continue
    if mode != "filtered":
        continue
    if not isinstance(grammar, dict) or not grammar:
        bad.append(f"{fw_id}.headless_runner.argument_contract mode=filtered with empty source_grammar"); continue
    for flag, entry in grammar.items():
        where = f"{fw_id}.headless_runner.argument_contract.source_grammar.{flag}"
        if not flag.startswith("-"):
            bad.append(f"{where} is not a flag spelling")
        if not isinstance(entry, dict):
            bad.append(f"{where} is not an object"); continue
        arity = entry.get("arity")
        if not isinstance(arity, int) or isinstance(arity, bool) or arity < 0:
            bad.append(f"{where}.arity={arity!r} is not a non-negative integer")
        policy = entry.get("headless")
        if policy not in POLICY:
            bad.append(f"{where}.headless={policy!r} outside {sorted(POLICY)}")
if bad:
    for b in bad: print(b)
    sys.exit(1)
' "$CAPS"
}

check_codex_rejects_ask_for_approval() {
  # The flag that took the settlement executor path down: `--ask-for-approval`
  # exists on the codex root parser but not on `codex exec`. Both spellings
  # must be declared rejected AND carry arity 1 — arity is what lets the
  # filter drop the value with the flag instead of leaving it to bind as the
  # subcommand positional prompt.
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
g = d["frameworks"]["codex"]["capabilities"]["headless_runner"]["argument_contract"]["source_grammar"]
bad = []
for flag in ("-a", "--ask-for-approval"):
    entry = g.get(flag)
    if not entry:
        bad.append(f"codex source_grammar missing {flag}"); continue
    if entry.get("headless") != "rejected":
        bad.append(f"codex source_grammar {flag} is not rejected for headless use")
    if entry.get("arity") != 1:
        bad.append(f"codex source_grammar {flag} must declare arity 1 so its value drops with it")
if bad:
    for b in bad: print(b)
    sys.exit(1)
' "$CAPS"
}

# --- Evidence cross-reference ---

evidence_index() {
  EVID="$EVID" python3 - <<'PYEOF'
import os, re, sys
with open(os.environ["EVID"]) as f:
    text = f.read()
m = re.search(r"^## _index\s*\n(.*)$", text, re.M | re.S)
if not m: sys.exit(2)
for line in m.group(1).splitlines():
    line = line.strip()
    if line.startswith("- "):
        print(line[2:].strip())
PYEOF
}

evidence_section_ids() {
  EVID="$EVID" python3 - <<'PYEOF'
import os, re
with open(os.environ["EVID"]) as f:
    text = f.read()
body, _, _ = text.partition("## _index")
for m in re.finditer(r"^###\s+([a-z0-9-]+)\s*$", body, re.M):
    print(m.group(1))
PYEOF
}

consumed_evidence_ids() {
  CAPS="$CAPS" python3 - <<'PYEOF'
import json, os
with open(os.environ["CAPS"]) as f:
    data = json.load(f)
ids = set()
for fw_id, fw in data.get("frameworks", {}).items():
    mr = fw.get("model_routing") or {}
    if mr.get("evidence"): ids.add(mr["evidence"])
    pc = fw.get("position_compilation") or {}
    if pc.get("evidence"): ids.add(pc["evidence"])
    st = fw.get("spend_telemetry") or {}
    if st.get("evidence"): ids.add(st["evidence"])
    lh = fw.get("session_lifecycle_hooks") or {}
    if lh.get("evidence"): ids.add(lh["evidence"])
    for cap, cell in (fw.get("capabilities") or {}).items():
        if cell.get("evidence"): ids.add(cell["evidence"])
        ac = cell.get("argument_contract") or {}
        if ac.get("evidence"): ids.add(ac["evidence"])
    for row, cell in (fw.get("interaction") or {}).items():
        if isinstance(cell, dict) and cell.get("evidence"): ids.add(cell["evidence"])
for cid in sorted(ids): print(cid)
PYEOF
}

check_consumed_resolve_in_index() {
  consumed=$(consumed_evidence_ids)
  index=$(evidence_index)
  missing=""
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    grep -Fxq "$id" <<<"$index" || missing+="${id}"$'\n'
  done <<<"$consumed"
  if [[ -n "$missing" ]]; then
    echo "evidence ids consumed but not present in capabilities-evidence.md _index:"
    echo "$missing"
    return 1
  fi
  return 0
}

check_index_has_body_sections() {
  index=$(evidence_index)
  body=$(evidence_section_ids)
  orphans=""
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    grep -Fxq "$id" <<<"$body" || orphans+="${id}"$'\n'
  done <<<"$index"
  if [[ -n "$orphans" ]]; then
    echo "ids listed in _index without ### body section:"
    echo "$orphans"
    return 1
  fi
  return 0
}

check_body_sections_in_index() {
  body=$(evidence_section_ids)
  index=$(evidence_index)
  orphans=""
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    grep -Fxq "$id" <<<"$index" || orphans+="${id}"$'\n'
  done <<<"$body"
  if [[ -n "$orphans" ]]; then
    echo "ids defined in body but missing from _index:"
    echo "$orphans"
    return 1
  fi
  return 0
}

check_no_unused_evidence() {
  consumed=$(consumed_evidence_ids)
  index=$(evidence_index)
  unused=""
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    grep -Fxq "$id" <<<"$consumed" || unused+="${id}"$'\n'
  done <<<"$index"
  if [[ -n "$unused" ]]; then
    echo "evidence ids defined but not consumed by any capability cell:"
    echo "$unused"
    return 1
  fi
  return 0
}

# --- T41 skills.requires partial-mode gating ---

check_degradation_vocab() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
vocab = d["skills"].get("_degradation_vocab")
if not isinstance(vocab, dict):
    print("missing skills._degradation_vocab"); sys.exit(1)
required = {"partial", "fallback", "none", "no-evidence", "unverified-support"}
have = set(vocab.keys()) - {"_description"}
missing = required - have
extra = have - required
if missing or extra:
    print("missing tokens:", sorted(missing))
    print("unexpected tokens:", sorted(extra))
    sys.exit(1)
' "$CAPS"
}

check_levels_order() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
order = d["skills"].get("_levels_order")
if order != ["full", "partial", "fallback", "none"]:
    print("expected [full, partial, fallback, none], got", order); sys.exit(1)
declared = set(d["support_levels"].keys())
if set(order) != declared:
    print("levels_order set", set(order), "does not match support_levels", declared); sys.exit(1)
' "$CAPS"
}

check_skills_requires_known_ids() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
caps = set(d["capabilities"].keys())
tools = set(d.get("tools", {}).keys())
known = caps | tools
bad = []
for name, spec in d["skills"].items():
    if name.startswith("_"): continue
    for entry in spec.get("requires", []):
        rid = entry if isinstance(entry, str) else entry.get("id")
        if rid not in known:
            bad.append(f"skills.{name}.requires references unknown id {rid!r}")
if bad:
    for b in bad: print(b)
    sys.exit(1)
' "$CAPS"
}

check_skills_requires_levels() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
allowed = set(d["support_levels"].keys())
bad = []
for name, spec in d["skills"].items():
    if name.startswith("_"): continue
    for entry in spec.get("requires", []):
        if isinstance(entry, str): continue
        if not isinstance(entry, dict):
            bad.append(f"skills.{name}.requires entry is neither string nor object: {entry!r}")
            continue
        rid = entry.get("id")
        if not isinstance(rid, str):
            bad.append(f"skills.{name}.requires entry missing string id: {entry!r}")
        ml = entry.get("min_level", "full")
        if ml not in allowed:
            bad.append(f"skills.{name}.requires id={rid!r} has min_level={ml!r} outside {sorted(allowed)}")
        pb = entry.get("partial_below", "full")
        if pb not in allowed:
            bad.append(f"skills.{name}.requires id={rid!r} has partial_below={pb!r} outside {sorted(allowed)}")
if bad:
    for b in bad: print(b)
    sys.exit(1)
' "$CAPS"
}

check_team_heavy_partial_mode() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
TEAM_HEAVY = {"bootstrap", "implement", "spec"}
bad = []
for name in TEAM_HEAVY:
    spec = d["skills"].get(name)
    if not spec:
        bad.append(f"skills.{name} missing"); continue
    requires = spec.get("requires", [])
    object_entries = [e for e in requires if isinstance(e, dict)]
    if not object_entries:
        bad.append(f"skills.{name}.requires has no object-form entries — partial-mode unreachable")
        continue
    needed = {"team_messaging", "task_completed_hook"}
    object_ids = {e["id"] for e in object_entries}
    missing = needed - object_ids
    if missing:
        bad.append(f"skills.{name}.requires missing object-form entries for {sorted(missing)}")
if bad:
    for b in bad: print(b)
    sys.exit(1)
' "$CAPS"
}

check_spec_team_messaging_fanout_contract() {
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
spec = d["skills"]["spec"]
reqs = {entry["id"]: entry for entry in spec["requires"] if isinstance(entry, dict)}
team = reqs.get("team_messaging")
subagents = reqs.get("subagents")
if not team or not subagents:
    print("spec must declare object-form team_messaging and subagents requirements")
    sys.exit(1)
if team.get("partial_below") != "none":
    print("team_messaging must not hard-refuse /spec when absent")
    sys.exit(1)
text = " ".join([team.get("notes", ""), spec.get("notes", "")]).lower()
if "lead-orchestrated researcher fanout" not in text:
    print("spec contract must name lead-orchestrated researcher fanout")
    sys.exit(1)
if "no researcher fanout" in text:
    print("spec contract must not collapse team_messaging=none to no researcher fanout")
    sys.exit(1)
if "subagents=none" not in text or "spec-short" not in text:
    print("spec contract must reserve spec-short collapse for subagents=none")
    sys.exit(1)
' "$CAPS"
}

# --- filter_harness_args_for_headless behavior ---
#
# The declaration is only worth anything if its consumer groups by it, so
# these drive scripts/lib.sh::filter_harness_args_for_headless directly. The
# shipped contract covers the filtered and shared-parser modes; the absence
# cases need a fixture, because no shipped framework leaves the block out.

FILTER_TMP=$(mktemp -d "${TMPDIR:-/tmp}/cap-filter.XXXXXX")
trap 'rm -rf "$FILTER_TMP"' EXIT

FILTER_OUT=""
FILTER_ERR=""
FILTER_RC=0

run_filter() {
  # run_filter <lib.sh> <framework> [arg...] — leaves the filtered list in
  # FILTER_OUT with newlines rendered as `|` (so an assertion can pin the
  # exact sequence), stderr in FILTER_ERR, and the exit code in FILTER_RC.
  local lib="$1"
  shift
  local outf errf
  outf=$(mktemp "$FILTER_TMP/out.XXXXXX")
  errf=$(mktemp "$FILTER_TMP/err.XXXXXX")
  FILTER_RC=0
  bash -c 'source "$1"; shift; filter_harness_args_for_headless "$@"' \
    _ "$lib" "$@" >"$outf" 2>"$errf" || FILTER_RC=$?
  FILTER_OUT=$(tr '\n' '|' <"$outf")
  FILTER_ERR=$(cat "$errf")
  rm -f "$outf" "$errf"
}

fixture_lib() {
  # fixture_lib <capabilities.json body> — build a throwaway repo layout whose
  # adapters/capabilities.json is the supplied document and print the path to
  # its lib.sh copy. lib.sh locates the registry relative to its own file, so
  # the copy reads the fixture registry.
  local caps_json="$1"
  local dir
  dir=$(mktemp -d "$FILTER_TMP/fixture.XXXXXX")
  mkdir -p "$dir/scripts" "$dir/adapters"
  cp "$REPO_DIR/scripts/lib.sh" "$dir/scripts/lib.sh"
  printf '%s\n' "$caps_json" > "$dir/adapters/capabilities.json"
  echo "$dir/scripts/lib.sh"
}

assert_str() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_has() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected to contain: $needle"
    echo "    actual: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_lacks() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label — expected NOT to contain: $needle"
    echo "    actual: $haystack"
    FAIL=$((FAIL + 1))
  fi
}

fixture_caps() {
  # fixture_caps <argument_contract JSON or the literal `omit`> — a one-framework
  # registry whose headless_runner cell carries the supplied declaration.
  local contract="$1"
  local cell='"headless_runner": {"support": "full", "evidence": "fixture"}'
  if [[ "$contract" != "omit" ]]; then
    cell='"headless_runner": {"support": "full", "evidence": "fixture", "argument_contract": '"$contract"'}'
  fi
  printf '{"frameworks": {"fixture": {"id": "fixture", "capabilities": {%s}}}}' "$cell"
}

LIB="$REPO_DIR/scripts/lib.sh"

run_filter_suite() {
  echo "== filter_harness_args_for_headless =="

  run_filter "$LIB" codex --enable guardian_approval
  assert_str   "accepted flag keeps its value with it"       "$FILTER_OUT" "--enable|guardian_approval|"
  assert_str   "accepted pair exits 0"                       "$FILTER_RC"  "0"
  assert_lacks "accepted pair emits no degradation notice"   "$FILTER_ERR" "[lore] degraded:"

  run_filter "$LIB" codex --ask-for-approval on-request --model gpt-5.6
  assert_str   "rejected pair drops flag and value together" "$FILTER_OUT" "--model|gpt-5.6|"
  assert_lacks "rejected value never survives as positional" "$FILTER_OUT" "on-request"
  assert_has   "drop is announced in the closed vocabulary"  "$FILTER_ERR" "[lore] degraded:"
  assert_has   "drop notice names the dropped flag"          "$FILTER_ERR" "--ask-for-approval"
  assert_str   "dropping a flag is not an error"             "$FILTER_RC"  "0"

  run_filter "$LIB" codex --sandbox=read-only
  assert_str "--flag=value passes as one group" "$FILTER_OUT" "--sandbox=read-only|"

  run_filter "$LIB" codex -c 'a="1"' --enable feat -c 'b="2"'
  assert_str "repetition and order are preserved" "$FILTER_OUT" '-c|a="1"|--enable|feat|-c|b="2"|'

  run_filter "$LIB" claude-code --dangerously-skip-permissions
  assert_str   "shared-parser mode passes args through"        "$FILTER_OUT" "--dangerously-skip-permissions|"
  assert_lacks "shared-parser mode emits no notice"            "$FILTER_ERR" "[lore] degraded:"

  run_filter "$LIB" codex --no-such-codex-flag
  assert_str   "unknown flag under a present contract is rc=64" "$FILTER_RC"  "64"
  assert_str   "unknown flag yields no filtered list at all"    "$FILTER_OUT" ""

  local absent_lib empty_lib nogrammar_lib
  absent_lib=$(fixture_lib "$(fixture_caps omit)")
  run_filter "$absent_lib" fixture --anything value
  assert_str "absent declaration passes args through unfiltered" "$FILTER_OUT" "--anything|value|"
  assert_str "absent declaration is not an error"                "$FILTER_RC"  "0"
  assert_has "absent declaration degrades explicitly"            "$FILTER_ERR" "no-evidence"

  empty_lib=$(fixture_lib "$(fixture_caps '{}')")
  run_filter "$empty_lib" fixture --anything value
  assert_str "empty declaration passes args through unfiltered" "$FILTER_OUT" "--anything|value|"
  assert_has "empty declaration degrades explicitly"            "$FILTER_ERR" "no-evidence"

  nogrammar_lib=$(fixture_lib "$(fixture_caps '{"mode": "filtered", "evidence": "fixture", "cli_version": "0"}')")
  run_filter "$nogrammar_lib" fixture --anything
  assert_str "filtered mode without a grammar is rc=64" "$FILTER_RC" "64"

  # The unprobed-surface notice is latched per framework so a batch of judge
  # invocations in one shell reports it once rather than once per claim.
  local repeat_count
  repeat_count=$(bash -c '
    source "$1"
    filter_harness_args_for_headless fixture --anything >/dev/null
    filter_harness_args_for_headless fixture --anything >/dev/null
  ' _ "$absent_lib" 2>&1 | grep -c "no-evidence" || true)
  assert_str "unprobed-surface notice fires once per shell" "$repeat_count" "1"
}

# --- session_lifecycle_hooks D8 behavior ---
#
# The shipped cells are all `none` today, so the full/partial branches of the
# D8 check only run against fixtures. Each fixture is one framework with one
# cell plus a one-row evidence file, judged against a fixed reference date.

lifecycle_fixture() {
  # lifecycle_fixture <support> <evidence id or ""> <notes> <retrieved> <version>
  # — print the fixture directory holding capabilities.json and evidence.md.
  local support="$1" ev="$2" notes="$3" retrieved="$4" version="$5" dir
  dir=$(mktemp -d "$FILTER_TMP/lifecycle.XXXXXX")
  python3 - "$dir/capabilities.json" "$support" "$ev" "$notes" <<'PYEOF'
import json, sys
path, support, ev, notes = sys.argv[1:]
cell = {"support": support, "channel": "settings-json", "notes": notes,
        "events": [{"hook_event": "Stop", "event": "needs_input", "activity": "idle"}]}
if ev:
    cell["evidence"] = ev
json.dump({"support_levels": {"full": "", "partial": "", "fallback": "", "none": ""},
           "frameworks": {"fixture": {"session_lifecycle_hooks": cell}}}, open(path, "w"))
PYEOF
  printf '# Evidence\n\n### fixture-lifecycle\n\n- **Source:** fixture\n- **Retrieved:** %s\n- **Product / version:** %s\n- **Claim:** fixture\n\n## _index\n\n- fixture-lifecycle\n' \
    "$retrieved" "$version" > "$dir/evidence.md"
  echo "$dir"
}

LIFECYCLE_OUT=""
LIFECYCLE_RC=0

run_lifecycle_d8() {
  # run_lifecycle_d8 <fixture dir> <reference date>
  LIFECYCLE_RC=0
  LIFECYCLE_OUT=$(check_lifecycle_hooks_d8 "$1/capabilities.json" "$1/evidence.md" "$2" 2>&1) || LIFECYCLE_RC=$?
}

run_lifecycle_d8_suite() {
  echo "== session_lifecycle_hooks D8 check =="
  local dir

  dir=$(lifecycle_fixture full fixture-lifecycle "" 2026-10-18 "Claude Code 2.1.299")
  run_lifecycle_d8 "$dir" 2026-10-18
  assert_str "full cell with a same-day versioned row passes" "$LIFECYCLE_RC" "0"

  dir=$(lifecycle_fixture full fixture-lifecycle "" 2026-07-20 "Claude Code 2.1.299")
  run_lifecycle_d8 "$dir" 2026-10-18
  assert_str "full cell with a row exactly 90 days old passes" "$LIFECYCLE_RC" "0"

  dir=$(lifecycle_fixture full fixture-lifecycle "" 2026-07-19 "Claude Code 2.1.299")
  run_lifecycle_d8 "$dir" 2026-10-18
  assert_str "full cell with a row 91 days old fails" "$LIFECYCLE_RC" "1"
  assert_has "stale refusal names the age and reference date" "$LIFECYCLE_OUT" "91 days before 2026-10-18"

  dir=$(lifecycle_fixture full fixture-lifecycle "" 2026-10-18 "Claude Code, unversioned")
  run_lifecycle_d8 "$dir" 2026-10-18
  assert_str "full cell with a versionless row fails" "$LIFECYCLE_RC" "1"

  dir=$(lifecycle_fixture full fixture-lifecycle "" 2026-10-18 "Claude Code 2.1.299")
  run_lifecycle_d8 "$dir" 2027-01-16
  assert_str "verdict follows the reference date: 90 days later still passes" "$LIFECYCLE_RC" "0"
  run_lifecycle_d8 "$dir" 2027-01-17
  assert_str "verdict follows the reference date: 91 days later fails" "$LIFECYCLE_RC" "1"

  dir=$(lifecycle_fixture partial fixture-lifecycle "" 2026-05-03 "Claude Code, unversioned")
  run_lifecycle_d8 "$dir" 2026-10-18
  assert_str "partial cell may cite an old versionless row" "$LIFECYCLE_RC" "0"

  dir=$(lifecycle_fixture fallback fixture-lifecycle "" 2025-01-01 "unversioned")
  run_lifecycle_d8 "$dir" 2026-10-18
  assert_str "fallback cell may cite an old row" "$LIFECYCLE_RC" "0"

  dir=$(lifecycle_fixture partial no-such-row "" 2026-10-18 "Claude Code 2.1.299")
  run_lifecycle_d8 "$dir" 2026-10-18
  assert_str "partial cell citing no evidence row fails" "$LIFECYCLE_RC" "1"

  dir=$(lifecycle_fixture none "" "Blocked on a live probe of the channel." 2026-10-18 "x 1.0")
  run_lifecycle_d8 "$dir" 2026-10-18
  assert_str "none cell whose notes name its premise passes" "$LIFECYCLE_RC" "0"

  dir=$(lifecycle_fixture none "" "  " 2026-10-18 "x 1.0")
  run_lifecycle_d8 "$dir" 2026-10-18
  assert_str "none cell with blank notes fails" "$LIFECYCLE_RC" "1"
}

# --- Run all ---

echo "== Schema shape =="
assert_ok "capabilities.json parses as JSON"                          check_json_parses
assert_ok "capabilities.json has required top-level keys"             check_top_level_keys
assert_ok "support_levels is exactly {full, partial, fallback, none}" check_support_levels
assert_ok "frameworks include claude-code, opencode, codex"           check_frameworks_present

echo "== Per-cell schema =="
assert_ok "every cell uses a support level from the closed set"       check_support_level_closed_set
assert_ok "every per-cell capability key is declared globally"        check_per_cell_capability_declared
assert_ok "every framework declares all known capabilities"           check_no_partial_profiles
assert_ok "every non-none cell carries a non-empty evidence pointer"  check_evidence_present_for_non_none
assert_ok "every framework's model_routing.shape and evidence valid"  check_model_routing
assert_ok "every framework's interaction rows are evidence-gated + typed" check_interaction_rows
assert_ok "every framework's spend_telemetry block is evidence-gated + typed" check_spend_telemetry
assert_ok "every framework's session_lifecycle_hooks block is typed"   check_lifecycle_hooks_shape "$CAPS"
CAPS_COMMIT_DATE=$(capabilities_commit_date)
if [[ -n "$CAPS_COMMIT_DATE" ]]; then
  assert_ok "session_lifecycle_hooks cells follow D8 as of $CAPS_COMMIT_DATE (capabilities.json last commit)" \
    check_lifecycle_hooks_d8 "$CAPS" "$EVID" "$CAPS_COMMIT_DATE"
else
  echo "  SKIP: session_lifecycle_hooks D8 check — no git history to date adapters/capabilities.json against"
fi
assert_ok "every headless_runner cell declares a typed argument contract" check_headless_argument_contract
assert_ok "codex rejects --ask-for-approval at arity 1 for headless use"   check_codex_rejects_ask_for_approval

echo "== Evidence cross-reference =="
assert_ok "every consumed evidence id resolves in _index"             check_consumed_resolve_in_index
assert_ok "every _index id has a matching ### body section"           check_index_has_body_sections
assert_ok "every ### body id is referenced in _index"                 check_body_sections_in_index
assert_ok "every _index id is consumed by some capability cell"       check_no_unused_evidence

echo "== T41 skills.requires partial-mode gating =="
assert_ok "skills block exposes the closed degradation_vocab"         check_degradation_vocab
assert_ok "skills._levels_order matches support_levels closed set"    check_levels_order
assert_ok "every skills.<name>.requires id is known"                  check_skills_requires_known_ids
assert_ok "object-form requires entries name valid levels"            check_skills_requires_levels
assert_ok "team-heavy skills declare partial-mode tolerance"          check_team_heavy_partial_mode
assert_ok "spec team_messaging=none preserves researcher fanout"      check_spec_team_messaging_fanout_contract

echo ""
run_filter_suite

echo ""
run_lifecycle_d8_suite

echo ""
echo "Total: $((PASS + FAIL)) | PASS: $PASS | FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
