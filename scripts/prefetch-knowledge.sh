#!/usr/bin/env bash
# prefetch-knowledge.sh — Search knowledge store and output formatted context for agent prompts
# Usage: bash prefetch-knowledge.sh <query> [--format prompt|summary] [--limit N] [--type knowledge|work|all] [--exclude-backlinks <paths>] [--scale-set <csv>] [--work-item <slug>] [--caller <id>]
#
# --format prompt   (default) Full resolved sections for embedding in agent prompts
# --format summary  Headings + snippets for display
# --limit N         Max results (default: 5)
# --type            Filter by source type: knowledge, work, or all (default: all)
# --exclude-backlinks  Comma-separated backlink paths to exclude from results (deduplication
#                      with pre-resolved knowledge already in task descriptions)
# --scale-set <csv>        Required. Declared retrieval scale set: comma-separated
#                          abstract, architecture, subsystem, implementation labels.
#                          No default; missing = error.
# --work-item <slug>       Work item slug (from _work/<slug>/_meta.json). Used only for
#                          scope_pointers injection; no longer used for scale computation.
# --caller <id>            Caller identifier logged to the prefetch retrieval record
#                          (e.g. 'lead', 'worker') for assessment-time attribution.
#
# Output: Clean markdown block (## Prior Knowledge) or empty string on zero results.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Defaults ---
FORMAT="prompt"
LIMIT=5
TYPE="knowledge"
QUERY=""
EXCLUDE_BACKLINKS=""
SCALE_SET=""
WORK_ITEM=""
NO_PREFERENCES=0
CALLER=""

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)
      FORMAT="$2"
      shift 2
      ;;
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    --type)
      TYPE="$2"
      shift 2
      ;;
    --exclude-backlinks)
      EXCLUDE_BACKLINKS="$2"
      shift 2
      ;;
    --scale-context)
      echo "Warning: --scale-context is deprecated; use --scale-set <bucket> instead." >&2
      shift 2
      ;;
    --scale-set)
      SCALE_SET="$2"
      shift 2
      ;;
    --scale-set=*)
      SCALE_SET="${1#--scale-set=}"
      shift
      ;;
    --work-item)
      WORK_ITEM="$2"
      shift 2
      ;;
    --no-preferences)
      NO_PREFERENCES=1
      shift
      ;;
    --caller)
      CALLER="$2"
      shift 2
      ;;
    --caller=*)
      CALLER="${1#--caller=}"
      shift
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$QUERY" ]]; then
        QUERY="$1"
      else
        echo "Unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$QUERY" ]]; then
  echo "Usage: prefetch-knowledge.sh <query> [--format prompt|summary] [--limit N] [--type knowledge|work|all] [--scale-context <role>] [--scale-set <set>] [--work-item <slug>] [--caller <id>]" >&2
  exit 1
fi

if [[ -z "$SCALE_SET" ]]; then
  echo "Error: --scale-set <csv> is required. Declare your retrieval scale before fetching." >&2
  echo "  Use: prefetch-knowledge.sh <query> --scale-set <bucket>[,<bucket>]" >&2
  echo "  Buckets: abstract, architecture, subsystem, implementation" >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)

if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  # No knowledge store — silent exit (clean no-op)
  exit 0
fi

LORE_SEARCH="$SCRIPT_DIR/pk_cli.py"

if [[ ! -f "$LORE_SEARCH" ]]; then
  exit 0
fi
check_fts_available
if [[ $USE_FTS -eq 0 ]]; then
  exit 0
fi

# --- Dispatch to the shared retrieval core ---
# Search, preferences side-channel, dedupe, budget degradation, rendering,
# retrieval logging, and scope-pointer injection all live in pk_prefetch.py.
PREFETCH_ARGS=("prefetch" "$KNOWLEDGE_DIR" "$QUERY" "--format" "$FORMAT" "--limit" "$LIMIT" "--type" "$TYPE" "--scale-set" "$SCALE_SET")
if [[ -n "$EXCLUDE_BACKLINKS" ]]; then
  PREFETCH_ARGS+=("--exclude-backlinks" "$EXCLUDE_BACKLINKS")
fi
if [[ -n "$WORK_ITEM" ]]; then
  PREFETCH_ARGS+=("--work-item" "$WORK_ITEM")
fi
if [[ $NO_PREFERENCES -eq 1 ]]; then
  PREFETCH_ARGS+=("--no-preferences")
fi
if [[ -n "$CALLER" ]]; then
  PREFETCH_ARGS+=("--caller" "$CALLER")
fi

exec python3 "$LORE_SEARCH" "${PREFETCH_ARGS[@]}"
