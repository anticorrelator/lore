#!/usr/bin/env bash
# capture.sh — Capture an insight to the knowledge store
# Usage: lore capture --insight "..." --scale "<bucket>" [--context "..."] [--category "..."] [--confidence "..."] [--related-files "..."] [--source "..."] [--example "..."]
#        [--producer-role "..."] [--protocol-slot "..."] [--template-version "..."] [--capturer-role "..."] [--source-artifact-ids "..."]
#        [--captured-at-branch "..."] [--captured-at-sha "..."] [--captured-at-merge-base-sha "..."] [--work-item "..."]
#        [--kind "<kind>"] [--kind-status "<value>"] [--where-looked "..."] [--answered-by "..."] [--subsystem "..."]
#        [--executable-falsifier '<json>'] [--kdir "<path>"]
#
# Writes an individual entry file to the category directory (e.g., conventions/<slug>.md).
#
# Store selection:
#   --kdir <path>  Write to this knowledge store, skipping resolution. Normally the store is
#     resolved from the current checkout's git remote. When that answer disagrees with the store
#     the current directory sits inside, capture refuses and names both candidates rather than
#     picking one — a wrong pick files the entry into an unrelated store and still reports
#     success. --kdir is how the caller settles it.
#
# Provenance flags (omitted-field convention):
#   --producer-role         Role of the agent that produced the insight (e.g., researcher, worker, lead).
#   --protocol-slot         Protocol slot in which the insight emerged (e.g., capture, synthesis, review).
#   --template-version      Template-version hash of the producing agent template (see scripts/template-version.sh).
#   --capturer-role         Role of the agent writing this capture (set only when different from producer — lead-synthesis path).
#   --source-artifact-ids   Comma-separated artifact IDs the capture synthesizes from (lead-synthesis path).
#
# Branch-provenance flags (always-present convention):
#   --captured-at-branch          Branch at capture time. Defaults to `git rev-parse --abbrev-ref HEAD`; falls back to "null".
#   --captured-at-sha             HEAD commit SHA at capture time. Defaults to `git rev-parse HEAD`; falls back to "null".
#   --captured-at-merge-base-sha  Merge-base of HEAD against origin/main. Defaults to `git merge-base origin/main HEAD`;
#                                 falls back to "null" when the repo, origin/main, or merge-base is unavailable.
#   All three fields are emitted on every capture — with their resolved value OR the literal string "null". No network access.
#
# Scale:
#   --scale <bucket>  Required. One of: abstract, architecture, subsystem, implementation (single label),
#     or two adjacent labels comma-delimited (e.g. "subsystem,implementation").
#     The caller declares scale explicitly; no formula derivation at capture time.
#
# Epistemic kind:
#   --kind <kind>  What sort of claim the entry makes: fact, hypothesis, question, or theory.
#     Defaults to `fact`, which is what every entry written before this field existed is.
#     The vocabulary and each kind's own fields come from scripts/kind-registry.json.
#   --kind-status <value>  The kind's lifecycle state — untested|supported|refuted for a
#     hypothesis, open|answered|dissolved for a question. Required for those two kinds and
#     rejected for the others. Deliberately NOT named `status`: that key already carries
#     entry lifecycle, and its default retrieval filter admits only `current` and
#     `corrected`, so an entry written as `status: untested` disappears from every
#     unfiltered search.
#   --where-looked <text>  Question only, optional. Where someone already looked.
#   --answered-by <text>   Question only, optional. What answered the question.
#   --subsystem <name>     Theory only, required. The subsystem the theory is about.
#   Values bound for the footer are sanitized (see lib.sh sanitize_footer_value) —
#   long-form context belongs in the entry body under a heading, not here.
#
# Executable falsifier (optional):
#   --executable-falsifier '<json>'  Optional object {command, expected_output_shape[, root]}.
#     Shape-validated fail-closed here, then surfaced in the --json output for the
#     orchestrating layer (e.g. promotion) to persist into the producer row — the
#     durable home of falsifiers (this script persists neither the prose falsifier
#     nor the executable one into the entry .md). NOT written into the META footer:
#     footer consumers split the block on "|" (drift-sweep.py parse_meta), which
#     raw command JSON containing pipes would corrupt.
#
# Convention: when a provenance flag is omitted OR passed an empty string, the corresponding field is OMITTED from the
# HTML metadata comment block (rather than emitted with an empty value). This keeps legacy captures visually identical
# to pre-Phase-1 captures and avoids empty-field noise. The branch-provenance trio is a deliberate exception — each
# field is always emitted so downstream reconciliation can distinguish "not yet introduced" from "resolved to null".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Parse arguments ---
INSIGHT=""
CONTEXT=""
CATEGORY=""
CONFIDENCE="high"
RELATED_FILES=""
SOURCE="manual"
EXAMPLE=""
PRODUCER_ROLE=""
PROTOCOL_SLOT=""
TEMPLATE_VERSION=""
CAPTURER_ROLE=""
SOURCE_ARTIFACT_IDS=""
CAPTURED_AT_BRANCH=""
CAPTURED_AT_SHA=""
CAPTURED_AT_MERGE_BASE_SHA=""
WORK_ITEM=""
SCALE=""
KIND=""
KIND_STATUS=""
WHERE_LOOKED=""
ANSWERED_BY=""
SUBSYSTEM=""
EXECUTABLE_FALSIFIER=""
JSON_MODE=0
SKIP_MANIFEST=0
KDIR_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --insight)
      INSIGHT="$2"
      shift 2
      ;;
    --context)
      CONTEXT="$2"
      shift 2
      ;;
    --category)
      CATEGORY="$2"
      shift 2
      ;;
    --confidence)
      CONFIDENCE="$2"
      shift 2
      ;;
    --related-files)
      RELATED_FILES="$2"
      shift 2
      ;;
    --source)
      SOURCE="$2"
      shift 2
      ;;
    --example)
      EXAMPLE="$2"
      shift 2
      ;;
    --producer-role)
      PRODUCER_ROLE="$2"
      shift 2
      ;;
    --protocol-slot)
      PROTOCOL_SLOT="$2"
      shift 2
      ;;
    --template-version)
      TEMPLATE_VERSION="$2"
      shift 2
      ;;
    --capturer-role)
      CAPTURER_ROLE="$2"
      shift 2
      ;;
    --source-artifact-ids)
      SOURCE_ARTIFACT_IDS="$2"
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
    --work-item)
      WORK_ITEM="$2"
      shift 2
      ;;
    --scale)
      SCALE="$2"
      shift 2
      ;;
    --scale=*)
      SCALE="${1#--scale=}"
      shift
      ;;
    --kind)
      KIND="$2"
      shift 2
      ;;
    --kind=*)
      KIND="${1#--kind=}"
      shift
      ;;
    --kind-status)
      KIND_STATUS="$2"
      shift 2
      ;;
    --kind-status=*)
      KIND_STATUS="${1#--kind-status=}"
      shift
      ;;
    --where-looked)
      WHERE_LOOKED="$2"
      shift 2
      ;;
    --where-looked=*)
      WHERE_LOOKED="${1#--where-looked=}"
      shift
      ;;
    --answered-by)
      ANSWERED_BY="$2"
      shift 2
      ;;
    --answered-by=*)
      ANSWERED_BY="${1#--answered-by=}"
      shift
      ;;
    --subsystem)
      SUBSYSTEM="$2"
      shift 2
      ;;
    --subsystem=*)
      SUBSYSTEM="${1#--subsystem=}"
      shift
      ;;
    --executable-falsifier)
      EXECUTABLE_FALSIFIER="$2"
      shift 2
      ;;
    --kdir)
      KDIR_OVERRIDE="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --skip-manifest)
      SKIP_MANIFEST=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: capture.sh --insight \"...\" [--context \"...\"] [--category \"...\"] [--confidence \"...\"] [--related-files \"...\"] [--source \"...\"] [--example \"...\"] [--producer-role \"...\"] [--protocol-slot \"...\"] [--template-version \"...\"] [--capturer-role \"...\"] [--source-artifact-ids \"...\"] [--captured-at-branch \"...\"] [--captured-at-sha \"...\"] [--captured-at-merge-base-sha \"...\"] [--work-item \"...\"] [--kind \"...\"] [--kind-status \"...\"] [--where-looked \"...\"] [--answered-by \"...\"] [--subsystem \"...\"] [--executable-falsifier '<json>'] [--kdir <path>] [--json] [--skip-manifest]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$INSIGHT" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "--insight is required"
  fi
  die "--insight is required"
fi

_VALID_SCALES=$("$SCRIPT_DIR/scale-registry.sh" get-ids 2>/dev/null || echo "implementation subsystem architecture abstract")
_enum_list=$(echo "$_VALID_SCALES" | tail -r 2>/dev/null || echo "$_VALID_SCALES" | awk '{lines[NR]=$0} END{for(i=NR;i>=1;i--) print lines[i]}')
_enum_list=$(echo "$_enum_list" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')

if [[ -z "$SCALE" ]]; then
  _msg="--scale is required; one of: $_enum_list (single label) or two adjacent labels comma-delimited (e.g. \"subsystem,implementation\")"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$_msg"
  fi
  die "$_msg"
fi

# Split SCALE on comma into elements, trim whitespace.
_scale_elements=()
_IFS_orig="$IFS"
IFS=','
for _piece in $SCALE; do
  # trim leading/trailing whitespace
  _piece="${_piece#"${_piece%%[![:space:]]*}"}"
  _piece="${_piece%"${_piece##*[![:space:]]}"}"
  _scale_elements+=("$_piece")
done
IFS="$_IFS_orig"

_scale_count=${#_scale_elements[@]}
if [[ $_scale_count -lt 1 || $_scale_count -gt 2 ]]; then
  _msg="--scale accepts 1 or 2 labels (max two labels); got $_scale_count from \"$SCALE\". Use one of: $_enum_list, or two adjacent labels comma-delimited."
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$_msg"
  fi
  die "$_msg"
fi

# Validate each element is a known registry id.
for _el in "${_scale_elements[@]}"; do
  _scale_valid=0
  for _s in $_VALID_SCALES; do
    if [[ "$_el" == "$_s" ]]; then
      _scale_valid=1
      break
    fi
  done
  if [[ $_scale_valid -eq 0 ]]; then
    _msg="scale label \"$_el\" is not a registered scale id; one of: $_enum_list (single label) or two adjacent labels comma-delimited (e.g. \"subsystem,implementation\")"
    if [[ $JSON_MODE -eq 1 ]]; then
      json_error "$_msg"
    fi
    die "$_msg"
  fi
done

# For two-label form, enforce adjacency by consulting scale-registry.sh get-adjacency.
if [[ $_scale_count -eq 2 ]]; then
  _first="${_scale_elements[0]}"
  _second="${_scale_elements[1]}"
  if [[ "$_first" == "$_second" ]]; then
    _msg="--scale pair must be two distinct labels; got \"$_first,$_second\""
    if [[ $JSON_MODE -eq 1 ]]; then
      json_error "$_msg"
    fi
    die "$_msg"
  fi
  _adj_output=$("$SCRIPT_DIR/scale-registry.sh" get-adjacency "$_first" 2>/dev/null || echo "")
  _below=$(echo "$_adj_output" | sed -n '1p')
  _above=$(echo "$_adj_output" | sed -n '2p')
  if [[ "$_second" != "$_below" && "$_second" != "$_above" ]]; then
    _msg="--scale pair \"$_first,$_second\" is not adjacent; valid neighbors of \"$_first\" are: ${_below:-(none)} (below), ${_above:-(none)} (above). Allowed adjacent pairs follow the ordinal order $_enum_list."
    if [[ $JSON_MODE -eq 1 ]]; then
      json_error "$_msg"
    fi
    die "$_msg"
  fi
  # Normalize to canonical top-to-bottom ordinal order (D5).
  # If _second == _above, _second has higher ordinal — swap so top is first.
  # If _second == _below, _first already has higher ordinal — order is canonical.
  if [[ "$_second" == "$_above" ]]; then
    SCALE="$_second,$_first"
  else
    SCALE="$_first,$_second"
  fi
fi

# --- Epistemic kind ---
# The vocabulary, each kind's lifecycle values, and each kind's footer fields all
# come from scripts/kind-registry.json so the writer and any later validator read
# one list. The fallback keeps capture working if the registry read fails.
_VALID_KINDS=$("$SCRIPT_DIR/kind-registry.sh" get-ids 2>/dev/null || printf '%s\n' fact hypothesis question theory)

_format_enum_list() {
  echo "$1" | tr '\n' ' ' | tr -s ' ' | sed 's/^ *//;s/ *$//' | sed 's/ /, /g'
}

# Kind refusals carry the script's own bracketed prefix; die() emits an
# unprefixed "Error:" line.
refuse_kind() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "$msg"
  fi
  echo "[capture] Error: $msg" >&2
  exit 1
}

if [[ -z "$KIND" ]]; then
  KIND="fact"
fi

_kind_valid=0
for _k in $_VALID_KINDS; do
  if [[ "$KIND" == "$_k" ]]; then
    _kind_valid=1
    break
  fi
done
if [[ $_kind_valid -eq 0 ]]; then
  refuse_kind "--kind \"$KIND\" is not a registered kind id; one of: $(_format_enum_list "$_VALID_KINDS")"
fi

_registry_readable=1
_kind_fields=$("$SCRIPT_DIR/kind-registry.sh" get-fields "$KIND" 2>/dev/null) || _registry_readable=0
_kind_required=$("$SCRIPT_DIR/kind-registry.sh" get-required-fields "$KIND" 2>/dev/null) || _registry_readable=0
_kind_statuses=$("$SCRIPT_DIR/kind-registry.sh" get-statuses "$KIND" 2>/dev/null) || _registry_readable=0

# An unreadable registry leaves every per-kind declaration empty, which reads as
# "this kind has no fields" and would refuse legal flags. `fact` genuinely
# declares none, so a default capture still lands; any other kind is refused
# rather than validated against nothing.
if [[ $_registry_readable -eq 0 ]]; then
  if [[ "$KIND" != "fact" || -n "$KIND_STATUS$WHERE_LOOKED$ANSWERED_BY$SUBSYSTEM" ]]; then
    refuse_kind "cannot read the kind registry at $SCRIPT_DIR/kind-registry.json, so --kind \"$KIND\" and its fields cannot be validated"
  fi
fi

kind_accepts_field() {
  local field="$1" known
  for known in $_kind_fields; do
    [[ "$field" == "$known" ]] && return 0
  done
  return 1
}

# A kind-specific flag passed against a kind that has no such field would be
# dropped from the footer without a word — refuse instead of writing an entry
# that silently lost part of what the caller declared.
if [[ -n "$KIND_STATUS" ]] && ! kind_accepts_field kind_status; then
  refuse_kind "--kind-status does not apply to --kind \"$KIND\"; it belongs to hypothesis and question entries"
fi
if [[ -n "$WHERE_LOOKED" ]] && ! kind_accepts_field where_looked; then
  refuse_kind "--where-looked does not apply to --kind \"$KIND\"; it belongs to question entries"
fi
if [[ -n "$ANSWERED_BY" ]] && ! kind_accepts_field answered_by; then
  refuse_kind "--answered-by does not apply to --kind \"$KIND\"; it belongs to question entries"
fi
if [[ -n "$SUBSYSTEM" ]] && ! kind_accepts_field subsystem; then
  refuse_kind "--subsystem does not apply to --kind \"$KIND\"; it belongs to theory entries"
fi

for _rf in $_kind_required; do
  case "$_rf" in
    kind_status)
      if [[ -z "$KIND_STATUS" ]]; then
        refuse_kind "--kind-status is required for --kind \"$KIND\"; one of: $(_format_enum_list "$_kind_statuses")"
      fi
      ;;
    where_looked)
      [[ -n "$WHERE_LOOKED" ]] || refuse_kind "--where-looked is required for --kind \"$KIND\""
      ;;
    answered_by)
      [[ -n "$ANSWERED_BY" ]] || refuse_kind "--answered-by is required for --kind \"$KIND\""
      ;;
    subsystem)
      [[ -n "$SUBSYSTEM" ]] || refuse_kind "--subsystem is required for --kind \"$KIND\" — a theory is a claim about one named subsystem"
      ;;
  esac
done

if [[ -n "$KIND_STATUS" ]]; then
  _kind_status_valid=0
  for _ks in $_kind_statuses; do
    if [[ "$KIND_STATUS" == "$_ks" ]]; then
      _kind_status_valid=1
      break
    fi
  done
  if [[ $_kind_status_valid -eq 0 ]]; then
    refuse_kind "--kind-status \"$KIND_STATUS\" is not valid for --kind \"$KIND\"; one of: $(_format_enum_list "$_kind_statuses")"
  fi
fi

# --- Executable-falsifier shape validator (fail-closed when the flag is passed) ---
# Same shape rule as validate-tier2.sh / validate-tier3.sh / promote-commons-append.sh:
# object with non-empty-string command + expected_output_shape; optional
# non-empty-string root. python3 (not jq) — capture.sh has no jq dependency.
if [[ -n "$EXECUTABLE_FALSIFIER" ]]; then
  _EF_ERR=$(printf '%s' "$EXECUTABLE_FALSIFIER" | python3 -c '
import json, sys
try:
    ef = json.load(sys.stdin)
except Exception as e:
    print(f"is not valid JSON: {e}"); sys.exit(0)
if not isinstance(ef, dict):
    print("must be an object: {command, expected_output_shape}"); sys.exit(0)
for key in ("command", "expected_output_shape"):
    v = ef.get(key)
    if not isinstance(v, str) or not v.strip():
        print(f".{key} must be a non-empty string"); sys.exit(0)
if "root" in ef and (not isinstance(ef["root"], str) or not ef["root"].strip()):
    print(".root, when present, must be a non-empty string"); sys.exit(0)
')
  if [[ -n "$_EF_ERR" ]]; then
    _msg="--executable-falsifier $_EF_ERR"
    if [[ $JSON_MODE -eq 1 ]]; then
      json_error "$_msg"
    fi
    die "$_msg"
  fi
fi

# --- Provenance validator ---
if [[ -z "$PRODUCER_ROLE" || -z "$PROTOCOL_SLOT" ]]; then
  echo "[capture] WARNING: Missing provenance — --producer-role=${PRODUCER_ROLE}, --protocol-slot=${PROTOCOL_SLOT}." >&2
  echo "[capture] Captures without provenance cannot be scale-typed and degrade renormalize drift detection." >&2
  echo "[capture] If this is a manual /remember, pass --producer-role and --protocol-slot explicitly." >&2
fi

# --- Resolve knowledge directory ---
# --kdir names the store outright and skips resolution entirely, so it is also
# the way past the ambiguity refusal below.
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)

  # Two ways to name a store can disagree: resolve_knowledge_dir maps the
  # current checkout to a store via its git remote, while the cwd may already
  # sit inside a store of its own. When they name different stores, either could
  # be the one meant and writing to the resolved one files the entry into the
  # wrong store while reporting success. Refuse and let the caller say which.
  #
  # This lives here rather than in resolve-repo.sh on purpose: that script is a
  # pure path resolver whose callers include the SessionStart hooks, and a hard
  # refusal there would take them down too. Capture is the writer, so capture is
  # where the wrong answer becomes durable.
  #
  # LORE_KNOWLEDGE_DIR is the env-var form of --kdir: resolve-repo.sh returns it
  # verbatim without inferring anything, so there is no second candidate and
  # nothing to be ambiguous about.
  _cwd_store=""
  if [[ -z "${LORE_KNOWLEDGE_DIR:-}" ]]; then
    _cwd_store=$(knowledge_store_containing "$PWD" 2>/dev/null) || _cwd_store=""
  fi
  if [[ -n "$_cwd_store" ]]; then
    # Compare symlink-resolved forms — the resolved path is assembled from
    # $LORE_DATA_DIR while knowledge_store_containing returns a realpath, and on
    # macOS those differ textually for the same directory (/var vs /private/var).
    _resolved_real=$(cd "$KNOWLEDGE_DIR" 2>/dev/null && pwd -P) || _resolved_real="$KNOWLEDGE_DIR"
    if [[ "$_cwd_store" != "$_resolved_real" ]]; then
      _msg="ambiguous knowledge store — refusing to choose. Resolved from this checkout: $KNOWLEDGE_DIR. Store containing the current directory: $_cwd_store. Re-run with --kdir <path> naming the store this insight belongs to."
      if [[ $JSON_MODE -eq 1 ]]; then
        json_error "$_msg"
      fi
      echo "[capture] Two knowledge stores are in play here and capture cannot tell which one you mean:" >&2
      echo "[capture]   resolved from this checkout:       $KNOWLEDGE_DIR" >&2
      echo "[capture]   store containing this directory:   $_cwd_store" >&2
      echo "[capture] Filing into the wrong one is silent, so capture stops rather than guessing." >&2
      die "Name the store you mean: --kdir <path>"
    fi
  fi
fi

# --- Verify knowledge store exists ---
if [[ ! -f "$KNOWLEDGE_DIR/_manifest.json" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "No knowledge store found at: $KNOWLEDGE_DIR"
  fi
  die "No knowledge store found at: $KNOWLEDGE_DIR. Run \`lore init\` to initialize one."
fi

# --- Default category ---
if [[ -z "$CATEGORY" ]]; then
  CATEGORY="conventions"
fi

# --- Generate title from the insight ---
# For lifecycle kinds, a leading kind marker in the prose ("Hypothesis
# (untested):", "Believed:", "Open question —", "PROSPECTIVE TRIGGER —")
# duplicates the footer's kind/kind_status fields and bakes a status into the
# slug that goes stale the moment the claim settles. Strip such markers from
# title derivation only — the entry body keeps the author's phrasing. Only
# leading markers with an explicit separator (:, —, –, or dashes) are
# stripped, and only when --kind is hypothesis or question, so an ordinary
# title that merely contains the word "hypothesis" is untouched.
strip_kind_title_prefix() {
  local text="$1" prev=""
  local re='^[[:space:]]*(prospective[[:space:]]+trigger|open[[:space:]]+question|hypothesis([[:space:]]*\(?[a-z]+\)?)?|believed|belief|question|untested)([[:space:]]*(:|—|–)[[:space:]]*|[[:space:]]+-+[[:space:]]+)'
  shopt -s nocasematch
  while [[ "$text" != "$prev" ]]; do
    prev="$text"
    if [[ "$text" =~ $re ]]; then
      text="${text:${#BASH_REMATCH[0]}}"
    fi
  done
  shopt -u nocasematch
  # A marker-only insight would leave an empty title; keep the original then.
  if [[ -z "${text//[[:space:]]/}" ]]; then
    printf '%s' "$1"
  else
    printf '%s' "$text"
  fi
}

generate_title() {
  local source_text="$1"
  if [[ "$KIND" == "hypothesis" || "$KIND" == "question" ]]; then
    source_text=$(strip_kind_title_prefix "$source_text")
  fi
  derive_entry_title "$source_text"
}

TITLE=$(generate_title "$INSIGHT")
SLUG=$(slugify "$TITLE")

# --- Determine target directory ---
DATE_TODAY=$(date +"%Y-%m-%d")

# Category maps directly to directory (e.g., conventions, domains/evaluators)
TARGET_DIR="$KNOWLEDGE_DIR/$CATEGORY"
mkdir -p "$TARGET_DIR"

# --- Build metadata comment ---
# Every value passes through sanitize_footer_value on its way in: the footer is
# one line of " | "-joined pairs with no escaping anywhere, so a "|" or ">" in
# any value splits or truncates that field for all six footer parsers.
append_meta() {
  META="$META | $1: $(sanitize_footer_value "$2")"
}

META="<!-- learned: $DATE_TODAY"
append_meta confidence "$CONFIDENCE"
append_meta source "$SOURCE"
if [[ -n "$RELATED_FILES" ]]; then
  append_meta related_files "$RELATED_FILES"
fi
if [[ -n "$PRODUCER_ROLE" ]]; then
  append_meta producer_role "$PRODUCER_ROLE"
fi
if [[ -n "$PROTOCOL_SLOT" ]]; then
  append_meta protocol_slot "$PROTOCOL_SLOT"
fi
if [[ -n "$TEMPLATE_VERSION" ]]; then
  append_meta template_version "$TEMPLATE_VERSION"
fi
if [[ -n "$CAPTURER_ROLE" ]]; then
  append_meta capturer_role "$CAPTURER_ROLE"
fi
if [[ -n "$SOURCE_ARTIFACT_IDS" ]]; then
  append_meta source_artifact_ids "$SOURCE_ARTIFACT_IDS"
fi
if [[ -n "$WORK_ITEM" ]]; then
  append_meta work_item "$WORK_ITEM"
fi

# Scale is always declared by the caller.
append_meta scale "$SCALE"

# Kind is always emitted, defaulted to `fact` above. Its kind-specific fields
# follow only for the kinds that declare them.
append_meta kind "$KIND"
if [[ -n "$KIND_STATUS" ]]; then
  append_meta kind_status "$KIND_STATUS"
fi
if [[ -n "$WHERE_LOOKED" ]]; then
  append_meta where_looked "$WHERE_LOOKED"
fi
if [[ -n "$ANSWERED_BY" ]]; then
  append_meta answered_by "$ANSWERED_BY"
fi
if [[ -n "$SUBSYSTEM" ]]; then
  append_meta subsystem "$SUBSYSTEM"
fi

# Branch-provenance trio (always emitted). Fill from git when the caller did
# not pass an explicit value; fall back to "null" on any git failure so capture
# never aborts because of repo state.
if [[ -z "$CAPTURED_AT_BRANCH" ]]; then
  CAPTURED_AT_BRANCH=$(captured_at_branch)
fi
if [[ -z "$CAPTURED_AT_SHA" ]]; then
  CAPTURED_AT_SHA=$(captured_at_sha)
fi
if [[ -z "$CAPTURED_AT_MERGE_BASE_SHA" ]]; then
  CAPTURED_AT_MERGE_BASE_SHA=$(captured_at_merge_base_sha)
fi
append_meta captured_at_branch "$CAPTURED_AT_BRANCH"
append_meta captured_at_sha "$CAPTURED_AT_SHA"
append_meta captured_at_merge_base_sha "$CAPTURED_AT_MERGE_BASE_SHA"
META="$META | status: current"
META="$META -->"

# --- Write individual entry file ---
TARGET_FILE="$TARGET_DIR/${SLUG}.md"

# Avoid overwriting existing entries — keep final stem ≤ MAX_SLUG_LENGTH
if [[ -f "$TARGET_FILE" ]]; then
  SLUG_BASE="$SLUG"
  COUNTER=2
  while true; do
    SUFFIX="-${COUNTER}"
    TRIMMED="${SLUG_BASE:0:$((MAX_SLUG_LENGTH - ${#SUFFIX}))}"
    TRIMMED="${TRIMMED%-}"
    CANDIDATE="${TRIMMED}${SUFFIX}"
    if [[ ! -f "$TARGET_DIR/${CANDIDATE}.md" ]]; then
      break
    fi
    COUNTER=$((COUNTER + 1))
  done
  TARGET_FILE="$TARGET_DIR/${CANDIDATE}.md"
fi

{
  echo "# $TITLE"
  echo "$INSIGHT"
  if [[ -n "$EXAMPLE" ]]; then
    echo "**Example:** $EXAMPLE"
  fi
  echo "$META"
} > "$TARGET_FILE"

RELPATH="${TARGET_FILE#$KNOWLEDGE_DIR/}"

# --- Infer parent edges from /spec researcher assertions ---
if [[ -n "$WORK_ITEM" ]]; then
  "$SCRIPT_DIR/infer-parent-edges.sh" --entry "$TARGET_FILE" --work-item "$WORK_ITEM" 2>/dev/null || true
fi

# --- Append to capture log ---
# Schema: timestamp,source,category,confidence,template_version
# The `template_version` column was added in Phase 2 (work item 02-durable-signal-foundation).
# Readers must tolerate legacy rows lacking this column — a missing trailing field is treated as empty.
LOG_FILE="$KNOWLEDGE_DIR/_capture_log.csv"
if [[ ! -f "$LOG_FILE" ]]; then
  echo "timestamp,source,category,confidence,template_version" > "$LOG_FILE"
fi
echo "$(timestamp_iso),$SOURCE,$CATEGORY,$CONFIDENCE,$TEMPLATE_VERSION" >> "$LOG_FILE"

# --- Run manifest update ---
if [[ $SKIP_MANIFEST -eq 0 ]]; then
  "$SCRIPT_DIR/update-manifest.sh" > /dev/null 2>&1 || true
  bash "$SCRIPT_DIR/export-obsidian.sh" --file "$TARGET_FILE" > /dev/null 2>&1 || true
fi

# --- Output ---
if [[ $JSON_MODE -eq 1 ]]; then
  JSON_RESULT=$(python3 -c "
import json, sys
d = {'path': sys.argv[1], 'category': sys.argv[2], 'title': sys.argv[3], 'confidence': sys.argv[4]}
if len(sys.argv) > 5 and sys.argv[5]:
    # Shape-validated above; surfaced for the orchestrating layer to persist
    # into the producer row (never written into the entry .md).
    d['executable_falsifier'] = json.loads(sys.argv[5])
print(json.dumps(d))
" "$RELPATH" "$CATEGORY" "$TITLE" "$CONFIDENCE" "$EXECUTABLE_FALSIFIER")
  json_output "$JSON_RESULT"
fi

echo "[capture] Filed to $RELPATH"
