#!/usr/bin/env bash
# write-execution-log.sh — Append an entry to a work item's execution-log.md
# Usage: write-execution-log.sh --slug <slug> --source <source> [--phase <phase>] [--template-version <hash>]
#        [--captured-at-branch <name>] [--captured-at-sha <sha>] [--captured-at-merge-base-sha <sha>]
#        Entry body is read from stdin.
# Creates execution-log.md if missing (with header).
# Sources: implement-lead | spec-lead | remember | manual | audit | impl-verb | spec-verb | ceremony
#
# Optional flags:
#   --template-version   Template-version hash of the producing agent template (see scripts/template-version.sh).
#                        When supplied, emitted as a `Template-version: <hash>` header line immediately after the
#                        entry's `##` header. When omitted, the header line is omitted entirely — legacy callers
#                        that do not pass the flag produce byte-identical output to pre-Phase-1.
#
# Branch-provenance flags (task 7 — always emitted when any is resolvable):
#   --captured-at-branch          Branch at log-write time. Defaults to local git resolution; falls back to "null".
#   --captured-at-sha             HEAD commit SHA at log-write time. Defaults to local git resolution; falls back to "null".
#   --captured-at-merge-base-sha  Merge-base against origin/main. Defaults to local git resolution; falls back to "null".
#   Emitted as a single `Captured-at: branch=<b> sha=<s> merge-base-sha=<mb>` header line below the `##` line,
#   so each entry records *where* the logging agent was operating from. No network access.
#
# Compiled-producer flags (optional, always paired):
#   --position-dispatch-manifest  Absolute path to the immutable dispatch manifest.json a compiled
#   --position-dispatch-sha256    producer was given, and the digest returned at its publication.
#                        Passing one without the other is an error: half a reference cannot be
#                        resolved, and guessing the other half would attribute the entry to bytes
#                        nobody checked. When the flags are omitted, the entry body is read for the
#                        same two headers, so an accepted report's reduction carries its producer
#                        forward without the filing caller having to restate it.
#                        Both are emitted verbatim as header lines, followed by one
#                        `Producer-attribution:` line holding the projection read at write time
#                        (status resolved | unknown, and the producer identity when resolved).
#                        `--template-version` keeps its own meaning throughout: it is the filing
#                        caller's own template hash, never the producing brief's.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
SLUG=""
SOURCE=""
PHASE=""
TEMPLATE_VERSION=""
CAPTURED_AT_BRANCH=""
CAPTURED_AT_SHA=""
CAPTURED_AT_MERGE_BASE_SHA=""
POSITION_MANIFEST=""
POSITION_SHA256=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --position-dispatch-manifest)
      POSITION_MANIFEST="$2"
      shift 2
      ;;
    --position-dispatch-sha256)
      POSITION_SHA256="$2"
      shift 2
      ;;
    --slug)
      SLUG="$2"
      shift 2
      ;;
    --source)
      SOURCE="$2"
      shift 2
      ;;
    --phase)
      PHASE="$2"
      shift 2
      ;;
    --template-version)
      TEMPLATE_VERSION="$2"
      shift 2
      ;;
    --captured-at-branch)
      CAPTURED_AT_BRANCH="$2"
      shift 2
      ;;
    --captured-at-sha)
      CAPTURED_AT_SHA="$2"
      shift 2
      ;;
    --captured-at-merge-base-sha)
      CAPTURED_AT_MERGE_BASE_SHA="$2"
      shift 2
      ;;
    *)
      echo "[execution-log] Error: Unknown flag '$1'" >&2
      echo "Usage: write-execution-log.sh --slug <slug> --source <source> [--phase <phase>] [--template-version <hash>] [--captured-at-branch <name>] [--captured-at-sha <sha>] [--captured-at-merge-base-sha <sha>] [--position-dispatch-manifest <path> --position-dispatch-sha256 <sha256>]" >&2
      exit 1
      ;;
  esac
done

if [[ ( -n "$POSITION_MANIFEST" && -z "$POSITION_SHA256" ) || ( -z "$POSITION_MANIFEST" && -n "$POSITION_SHA256" ) ]]; then
  echo "[execution-log] Error: --position-dispatch-manifest and --position-dispatch-sha256 travel together; a reference missing either half cannot be resolved." >&2
  exit 1
fi

if [[ -z "$SLUG" ]]; then
  echo "[execution-log] Error: --slug is required." >&2
  exit 1
fi

if [[ -z "$SOURCE" ]]; then
  echo "[execution-log] Error: --source is required." >&2
  exit 1
fi

case "$SOURCE" in
  implement-lead|spec-lead|remember|manual|audit|impl-verb|spec-verb|ceremony) ;;
  *)
    echo "[execution-log] Error: --source must be one of: implement-lead, spec-lead, remember, manual, audit, impl-verb, spec-verb, ceremony" >&2
    exit 1
    ;;
esac

# --- Resolve paths ---
KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work"
ITEM_DIR="$WORK_DIR/$SLUG"

if [[ ! -d "$ITEM_DIR" ]]; then
  echo "[execution-log] Error: Work item not found: $SLUG" >&2
  exit 1
fi

LOG_FILE="$ITEM_DIR/execution-log.md"

# --- Create log file with header if missing ---
if [[ ! -f "$LOG_FILE" ]]; then
  {
    echo "# Execution Log: $SLUG"
    echo ""
    echo "<!-- Auto-generated by write-execution-log.sh. Do not edit the header. -->"
    echo ""
  } > "$LOG_FILE"
fi

# --- Read entry body from stdin ---
ENTRY_BODY=$(cat)

# --- Build entry header ---
TIMESTAMP=$(timestamp_iso)

PHASE_LABEL=""
if [[ -n "$PHASE" ]]; then
  PHASE_LABEL=" | phase: $PHASE"
fi

# --- Resolve branch-provenance defaults ---
if [[ -z "$CAPTURED_AT_BRANCH" ]]; then
  CAPTURED_AT_BRANCH=$(captured_at_branch)
fi
if [[ -z "$CAPTURED_AT_SHA" ]]; then
  CAPTURED_AT_SHA=$(captured_at_sha)
fi
if [[ -z "$CAPTURED_AT_MERGE_BASE_SHA" ]]; then
  CAPTURED_AT_MERGE_BASE_SHA=$(captured_at_merge_base_sha)
fi

# --- Resolve the compiled producer behind this entry -------------------------
# Two ways in, and they mean the same thing: the filing caller names the
# reference on the command line, or the entry body is a reduction of a report
# that already carries the pair as headers. Either way the projection is read
# here, at write time, and recorded beside the reference — so a later reader
# can re-resolve the original bytes rather than trust this line, and can still
# tell what was true when the entry was filed. An entry with no reference gets
# no producer lines at all: byte-identical to every legacy emission.
PRODUCER_ATTRIBUTION=""
PRODUCER_TEMPLATE_VERSION=""
if [[ -z "$POSITION_MANIFEST" ]]; then
  while IFS= read -r _pd_line; do
    case "$_pd_line" in
      Position-dispatch-manifest:*) POSITION_MANIFEST="${_pd_line#Position-dispatch-manifest:}" ;;
      '**Position-dispatch-manifest:**'*) POSITION_MANIFEST="${_pd_line#'**Position-dispatch-manifest:**'}" ;;
      Position-dispatch-sha256:*) POSITION_SHA256="${_pd_line#Position-dispatch-sha256:}" ;;
      '**Position-dispatch-sha256:**'*) POSITION_SHA256="${_pd_line#'**Position-dispatch-sha256:**'}" ;;
      *) continue ;;
    esac
  done < <(printf '%s\n' "$ENTRY_BODY")
  POSITION_MANIFEST="${POSITION_MANIFEST#"${POSITION_MANIFEST%%[![:space:]]*}"}"
  POSITION_SHA256="${POSITION_SHA256#"${POSITION_SHA256%%[![:space:]]*}"}"
  POSITION_MANIFEST="${POSITION_MANIFEST%"${POSITION_MANIFEST##*[![:space:]]}"}"
  POSITION_SHA256="${POSITION_SHA256%"${POSITION_SHA256##*[![:space:]]}"}"
fi

if [[ -n "$POSITION_MANIFEST" || -n "$POSITION_SHA256" ]]; then
  PRODUCER_ATTRIBUTION=$(jq -nc --arg p "$POSITION_MANIFEST" --arg s "$POSITION_SHA256" \
      '{position_dispatch: {manifest_path: $p, manifest_sha256: $s}}' \
    | python3 "$SCRIPT_DIR/position_attribution.py" 2>/dev/null || echo "")
  if [[ -z "$PRODUCER_ATTRIBUTION" ]]; then
    PRODUCER_ATTRIBUTION=$(jq -nc '{status: "unknown", reason: "attribution projection unavailable at write time"}')
  fi
  PRODUCER_TEMPLATE_VERSION=$(printf '%s' "$PRODUCER_ATTRIBUTION" \
    | jq -r 'if .status == "resolved" then .template_version else "" end' 2>/dev/null || echo "")
fi

# --- Append entry ---
{
  echo "## $TIMESTAMP | source: $SOURCE$PHASE_LABEL"
  if [[ -n "$TEMPLATE_VERSION" ]]; then
    echo "Template-version: $TEMPLATE_VERSION"
  fi
  if [[ -n "$PRODUCER_ATTRIBUTION" ]]; then
    echo "Position-dispatch-manifest: $POSITION_MANIFEST"
    echo "Position-dispatch-sha256: $POSITION_SHA256"
    echo "Producer-attribution: $PRODUCER_ATTRIBUTION"
  fi
  echo "Captured-at: branch=$CAPTURED_AT_BRANCH sha=$CAPTURED_AT_SHA merge-base-sha=$CAPTURED_AT_MERGE_BASE_SHA"
  echo ""
  echo "$ENTRY_BODY"
  echo ""
} >> "$LOG_FILE"

echo "[execution-log] Entry written to $LOG_FILE"

# --- Off-scale routing ingestion (task 29) ---
# Parse the entry body for `Surfaced concerns:` / `Worker leads:` fields
# (task 27/28 producer surfaces) and forward non-None payloads to the
# off-scale sidecar via scripts/off-scale-append.sh.
#
# Both spellings of each label are recognized. Every producer emits the bold
# form — `**Surfaced concerns:**` is what the worker report contract asks for
# and what a reduction copies — while the plain form is what a caller composes
# by hand. Matching only the plain form let the bold payload through silently:
# the field was filled in, the reduction carried it, and no sidecar row was
# ever written. Reading both is what makes the documented forwarding true.
#
# Parsing is line-anchored:
#   * A line whose first word is `Surfaced concerns:` or `Worker leads:` (bold
#     or plain) starts a route payload. The remainder of the line is the first
#     payload line.
#   * Subsequent non-empty lines that are indented OR start with `- ` continue
#     the payload. A blank line or a new top-level field ends it.
#   * A payload that is exactly `None` (case-sensitive, whitespace-trimmed) is
#     the acknowledged honest-negative signal and produces no sidecar row.
#
# Dedupe within the work item is the off-scale-append.sh responsibility.
# Cycle id derives from the slug + entry timestamp — a stable proxy that
# groups all routes emitted during a single write-execution-log.sh invocation.
#
# The row's template_version is the *producing* brief's version when this
# entry resolved one, and otherwise the filing caller's — a concern surfaced
# by a worker belongs to the brief that worker read, not to the lead template
# that filed the reduction. Entries with no producer reference keep the
# filing version exactly as before.
CYCLE_ID="${SLUG}-${TIMESTAMP}"

# Pass the entry body via an env var so the python heredoc does not compete
# with its own stdin. `_LORE_ENTRY_BODY` is an implementation detail — not a
# public interface.
_LORE_ENTRY_BODY="$ENTRY_BODY" python3 - "$SCRIPT_DIR/off-scale-append.sh" "$SLUG" "$CYCLE_ID" "${PRODUCER_TEMPLATE_VERSION:-$TEMPLATE_VERSION}" << 'PYEOF'
import os
import subprocess
import sys

helper, slug, cycle_id, template_version = sys.argv[1:5]
body = os.environ.get("_LORE_ENTRY_BODY", "")

FIELD_MAP = {
    "Surfaced concerns:": {"source": "worker",     "producer_role": "worker",     "protocol_slot": "Surfaced-concerns"},
    "Worker leads:":      {"source": "researcher", "producer_role": "researcher", "protocol_slot": "Worker-leads"},
}
# The label as producers spell it, mapped to the canonical field key.
PREFIXES = {}
for _field in FIELD_MAP:
    PREFIXES[_field] = _field
    PREFIXES["**" + _field[:-1] + ":**"] = _field


def match_prefix(stripped):
    for prefix, field in PREFIXES.items():
        if stripped.startswith(prefix):
            return prefix, field
    return None, None


def iter_routes(text):
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.lstrip()
        matched_prefix, matched_field = match_prefix(stripped)
        if not matched_prefix:
            i += 1
            continue

        first_rest = stripped[len(matched_prefix):].strip()
        payload_lines = [first_rest] if first_rest else []

        # Continuation: subsequent lines that are indented OR begin with "- ",
        # and are not themselves a new field.
        j = i + 1
        while j < len(lines):
            cont = lines[j]
            if not cont.strip():
                break
            cont_stripped = cont.lstrip()
            if match_prefix(cont_stripped)[0]:
                break
            is_indented = cont.startswith((" ", "\t"))
            is_bullet = cont_stripped.startswith(("- ", "* "))
            if not (is_indented or is_bullet):
                break
            payload_lines.append(cont_stripped)
            j += 1

        payload = "\n".join(payload_lines).strip()
        if payload and payload != "None":
            yield matched_field, payload
        i = j if j > i else i + 1

for prefix, payload in iter_routes(body):
    meta = FIELD_MAP[prefix]
    argv = [
        helper,
        "--work-item", slug,
        "--source", meta["source"],
        "--producer-role", meta["producer_role"],
        "--protocol-slot", meta["protocol_slot"],
        "--cycle-id", cycle_id,
        "--payload", payload,
    ]
    if template_version:
        argv.extend(["--template-version", template_version])
    try:
        subprocess.run(argv, check=True)
    except subprocess.CalledProcessError as e:
        print(f"[execution-log] Warning: off-scale-append.sh exited {e.returncode} for {prefix!r} payload (skipped)", file=sys.stderr)
PYEOF
