#!/usr/bin/env bash
# test_session_digest_provenance.sh — the digest writer must skip headless
# `claude -p` sessions (judge/worker/settlement/batch-spec) and still digest
# conversational ones.
#
# Root cause (see work item session-digest-extractor-treats-headless-judge-ses):
# extract-session-digest.py writes a SINGLE _pending_digest.md in 'w' (overwrite)
# mode. A headless judge session ending between a real conversational session and
# its /remember intake clobbers the real, not-yet-processed digest with machine
# traffic. Claude Code stamps every user turn with an `entrypoint` field
# (`cli` = interactive, `sdk-cli` = headless), so the writer discriminates on that.
#
# Each case stages a fake ~/.claude/projects/<encoded-cwd>/ with two JSONL files:
# a newer dummy (the "current" session, ignored) and the fixture as the
# second-most-recent (the "previous" session previous_session_path selects).

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIGEST="$REPO_DIR/scripts/extract-session-digest.py"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# run_case <label> <fixture-provenance> <expect: digest|no-digest>
# Provenance kinds: headless | conversational | peer | ambiguous
run_case() {
  local label="$1" kind="$2" expect="$3"

  local home kd cwd proj_id proj_dir
  home="$(mktemp -d)"
  kd="$(mktemp -d)"
  cwd="/work/digest-provenance-test"
  proj_id="${cwd//\//-}"
  proj_dir="$home/.claude/projects/$proj_id"
  mkdir -p "$proj_dir"
  mkdir -p "$kd"
  printf '{}' > "$kd/_manifest.json"

  # Build the fixture (the previous session) with the requested provenance.
  KIND="$kind" FIX="$proj_dir/previous.jsonl" python3 <<'PYEOF'
import json, os

kind = os.environ["KIND"]

def user(text, extra):
    rec = {"sessionId": "prov-sess", "timestamp": "2026-07-07T09:00:00Z",
           "type": "user", "message": {"role": "user", "content": text}}
    rec.update(extra)
    return rec

if kind == "headless":
    extra = {"entrypoint": "sdk-cli", "promptSource": "sdk"}
elif kind == "conversational":
    extra = {"entrypoint": "cli", "promptSource": "typed", "origin": {"kind": "human"}}
elif kind == "peer":
    # Interactive coordinator/peer session — cli entrypoint, non-human origin.
    extra = {"entrypoint": "cli", "promptSource": "system", "origin": {"kind": "peer"}}
elif kind == "ambiguous":
    # No provenance markers at all (old transcript / unknown format).
    extra = {}
else:
    raise SystemExit(f"unknown kind {kind}")

entries = [
    user("first substantive request about the subsystem design", extra),
    user("second message refining the approach and constraints", extra),
    user("third message confirming the direction to take", extra),
    {"sessionId": "prov-sess", "timestamp": "2026-07-07T09:00:05Z",
     "type": "assistant",
     "message": {"role": "assistant",
                 "content": [{"type": "text", "text": "Acknowledged."}]}},
]
with open(os.environ["FIX"], "w") as f:
    for e in entries:
        f.write(json.dumps(e) + "\n")
PYEOF

  # A newer dummy file so the fixture is the *second*-most-recent (the previous
  # session). previous_session_path returns index [1] after mtime-desc sort.
  printf '{}\n' > "$proj_dir/current.jsonl"
  touch -t 202607070900 "$proj_dir/previous.jsonl"
  touch -t 202607070901 "$proj_dir/current.jsonl"

  # Run the writer bare (no pipe on the exit-code path).
  #   HOME          → find_project_dir resolves the staged ~/.claude/projects tree
  #   LORE_DATA_DIR → the provider loads the real transcript/digest helper scripts
  #                   from $REPO_DIR/scripts (see claude_code.py::_resolve_scripts_dir)
  HOME="$home" LORE_DATA_DIR="$REPO_DIR" LORE_FRAMEWORK="claude-code" \
    python3 "$DIGEST" --knowledge-dir "$kd" --cwd "$cwd" --framework claude-code
  local rc=$?

  local digest_file="$kd/_threads/_pending_digest.md"
  local got
  if [ -f "$digest_file" ]; then got="digest"; else got="no-digest"; fi

  if [ "$rc" -ne 0 ]; then
    fail "$label (writer exited $rc, expected 0)"
  elif [ "$got" = "$expect" ]; then
    pass "$label ($got)"
  else
    fail "$label (expected $expect, got $got)"
  fi

  rm -rf "$home" "$kd"
}

echo "== session digest provenance filtering =="
# The bug: headless judge/worker sessions were digested as conversational.
run_case "headless judge session generates NO digest"        headless       no-digest
# The baseline that must keep working.
run_case "conversational session still generates a digest"   conversational digest
# Guard against over-filtering: peer/coordinator sessions are interactive too.
run_case "interactive peer session still generates a digest" peer           digest
# Conservative default: unknown provenance generates (false junk beats lost memory).
run_case "ambiguous provenance still generates a digest"     ambiguous      digest

echo
echo "session-digest-provenance: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
