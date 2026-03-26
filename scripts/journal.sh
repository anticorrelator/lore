#!/usr/bin/env bash
# journal.sh — Write and read effectiveness journal entries
# Usage: lore journal write --observation "..." --context "..." [--work-item "..."] [--role "..."] [--scores '<json>']
#        lore journal show [--limit N] [--role <role>] [--since <date>]
#        lore journal show --aggregate [--limit N] [--since <date>]
#
# Appends JSONL entries to _meta/effectiveness-journal.jsonl.
# In aggregate mode, interleaves entries from all three log sources.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- write subcommand ---
journal_write() {
  local observation="" context="" work_item="" role="interactive" scores=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --observation)
        observation="$2"
        shift 2
        ;;
      --context)
        context="$2"
        shift 2
        ;;
      --work-item)
        work_item="$2"
        shift 2
        ;;
      --role)
        role="$2"
        shift 2
        ;;
      --scores)
        scores="$2"
        shift 2
        ;;
      --help|-h)
        cat >&2 <<EOF
Usage: lore journal write --observation "..." --context "..." [--work-item "..."] [--role "..."] [--scores '<json>']

Options:
  --observation   The observation to record (required)
  --context       Context for the observation (required)
  --work-item     Associated work item slug (optional)
  --role          Role of the observer: interactive, worker, hook, spec, retro (default: interactive)
  --scores        JSON object with numeric scores (optional, e.g. '{"accuracy": 0.8}')
  --help, -h      Show this help
EOF
        return 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        echo "Usage: lore journal write --observation \"...\" --context \"...\" [--scores '<json>']" >&2
        return 1
        ;;
    esac
  done

  # Validate required args
  if [[ -z "$observation" ]]; then
    die "--observation is required"
  fi
  if [[ -z "$context" ]]; then
    die "--context is required"
  fi

  # Resolve knowledge directory
  local knowledge_dir
  knowledge_dir=$(resolve_knowledge_dir)

  if [[ ! -f "$knowledge_dir/_manifest.json" ]]; then
    die "No knowledge store found at: $knowledge_dir. Run \`lore init\` to initialize one."
  fi

  # Ensure _meta/ exists
  local meta_dir="$knowledge_dir/_meta"
  mkdir -p "$meta_dir"

  # Build JSONL entry
  local timestamp branch
  timestamp=$(timestamp_iso)
  branch=$(get_git_branch)

  local entry
  entry=$(python3 -c "
import json, sys
entry = {
    'timestamp': sys.argv[1],
    'observation': sys.argv[2],
    'context': sys.argv[3],
    'role': sys.argv[4],
    'git_branch': sys.argv[5],
}
if sys.argv[6]:
    entry['work_item'] = sys.argv[6]
if sys.argv[7]:
    entry['scores'] = json.loads(sys.argv[7])
print(json.dumps(entry, ensure_ascii=False))
" "$timestamp" "$observation" "$context" "$role" "$branch" "$work_item" "$scores")

  # Append to journal
  local logfile="$meta_dir/effectiveness-journal.jsonl"
  echo "$entry" >> "$logfile"

  echo "[journal] Recorded observation (role=$role)"
}

# --- show subcommand ---
journal_show() {
  local limit=20 role_filter="" since="" aggregate=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit)
        limit="$2"
        shift 2
        ;;
      --role)
        role_filter="$2"
        shift 2
        ;;
      --since)
        since="$2"
        shift 2
        ;;
      --aggregate)
        aggregate=1
        shift
        ;;
      --help|-h)
        cat >&2 <<EOF
Usage: lore journal show [--limit N] [--role <role>] [--since <date>]
       lore journal show --aggregate [--limit N] [--since <date>]

Options:
  --limit N       Maximum entries to show (default: 20)
  --role <role>   Filter by role (only in default mode)
  --since <date>  Only show entries after this date (ISO 8601, e.g. 2026-02-01)
  --aggregate     Interleave entries from all log sources (journal, retrieval, friction)
  --help, -h      Show this help
EOF
        return 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        return 1
        ;;
    esac
  done

  # Resolve knowledge directory
  local knowledge_dir
  knowledge_dir=$(resolve_knowledge_dir)

  local meta_dir="$knowledge_dir/_meta"

  if [[ "$aggregate" -eq 1 ]]; then
    _show_aggregate "$meta_dir" "$limit" "$since"
  else
    _show_journal "$meta_dir" "$limit" "$role_filter" "$since"
  fi
}

# --- show: default (journal only) ---
_show_journal() {
  local meta_dir="$1" limit="$2" role_filter="$3" since="$4"
  local logfile="$meta_dir/effectiveness-journal.jsonl"

  if [[ ! -f "$logfile" ]]; then
    echo "No journal entries yet."
    return 0
  fi

  python3 -c "
import json, sys

logfile = sys.argv[1]
limit = int(sys.argv[2])
role_filter = sys.argv[3]
since = sys.argv[4]

entries = []
with open(logfile) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        entry = json.loads(line)
        if role_filter and entry.get('role') != role_filter:
            continue
        if since and entry.get('timestamp', '') < since:
            continue
        entries.append(entry)

# Show most recent entries (tail)
entries = entries[-limit:]

if not entries:
    print('No matching journal entries.')
    sys.exit(0)

for e in entries:
    ts = e.get('timestamp', '?')
    role = e.get('role', '?')
    obs = e.get('observation', '')
    ctx = e.get('context', '')
    wi = e.get('work_item', '')
    branch = e.get('git_branch', '')

    print(f'[{ts}] ({role}) {obs}')
    print(f'  context: {ctx}')
    if wi:
        print(f'  work-item: {wi}')
    if branch:
        print(f'  branch: {branch}')
    print()
" "$logfile" "$limit" "$role_filter" "$since"
}

# --- show: aggregate (all sources) ---
_show_aggregate() {
  local meta_dir="$1" limit="$2" since="$3"

  python3 -c "
import json, sys, os

meta_dir = sys.argv[1]
limit = int(sys.argv[2])
since = sys.argv[3]

sources = {
    'journal': os.path.join(meta_dir, 'effectiveness-journal.jsonl'),
    'retrieval': os.path.join(meta_dir, 'retrieval-log.jsonl'),
    'friction': os.path.join(meta_dir, 'friction-log.jsonl'),
}

all_entries = []

for source_name, path in sources.items():
    if not os.path.isfile(path):
        continue
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            entry = json.loads(line)
            ts = entry.get('timestamp', '')
            if since and ts < since:
                continue
            all_entries.append((ts, source_name, entry))

# Sort by timestamp
all_entries.sort(key=lambda x: x[0])

# Show most recent entries (tail)
all_entries = all_entries[-limit:]

if not all_entries:
    print('No log entries found.')
    sys.exit(0)

for ts, source, entry in all_entries:
    if source == 'journal':
        role = entry.get('role', '?')
        obs = entry.get('observation', '')
        print(f'[{ts}] journal ({role}): {obs}')
    elif source == 'retrieval':
        budget = entry.get('budget_used', 0)
        total = entry.get('budget_total', 0)
        files_full = entry.get('files_full', 0)
        files_sum = entry.get('files_summary', 0)
        branch = entry.get('git_branch', '')
        print(f'[{ts}] retrieval: budget={budget}/{total} files_full={files_full} files_summary={files_sum} branch={branch}')
    elif source == 'friction':
        intent = entry.get('intent', '')
        outcome = entry.get('outcome', '')
        friction = entry.get('friction', '')
        line = f'[{ts}] friction: outcome={outcome} intent=\"{intent}\"'
        if friction:
            line += f' friction=\"{friction}\"'
        print(line)
" "$meta_dir" "$limit" "$since"
}

# --- query subcommand ---
journal_query() {
  local role_filter="" extract_scores=0 since="" json_output=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)
        role_filter="$2"
        shift 2
        ;;
      --extract-scores)
        extract_scores=1
        shift
        ;;
      --since)
        since="$2"
        shift 2
        ;;
      --json)
        json_output=1
        shift
        ;;
      --help|-h)
        cat >&2 <<EOF
Usage: lore journal query --role <role> --extract-scores [--since <date>] [--json]

Extract structured scores from journal entries over time.

Options:
  --role <role>      Filter by role (e.g. retro, self-test) (required)
  --extract-scores   Output a table of scores over time (required)
  --since <date>     Only include entries after this date (ISO 8601)
  --json             Output as JSON array instead of table
  --help, -h         Show this help
EOF
        return 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        echo "Usage: lore journal query --role <role> --extract-scores [--since <date>] [--json]" >&2
        return 1
        ;;
    esac
  done

  if [[ "$extract_scores" -ne 1 ]]; then
    die "--extract-scores is required for journal query"
  fi
  if [[ -z "$role_filter" ]]; then
    die "--role is required for journal query"
  fi

  # Resolve knowledge directory
  local knowledge_dir
  knowledge_dir=$(resolve_knowledge_dir)

  local logfile="$knowledge_dir/_meta/effectiveness-journal.jsonl"

  if [[ ! -f "$logfile" ]]; then
    echo "No journal entries yet."
    return 0
  fi

  python3 -c "
import json, re, sys

logfile = sys.argv[1]
role_filter = sys.argv[2]
since = sys.argv[3]
json_output = int(sys.argv[4])

entries = []
with open(logfile) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if role_filter and entry.get('role') != role_filter:
            continue
        ts = entry.get('timestamp', '')
        if since and ts < since:
            continue

        # Extract scores: structured field first, fallback to regex
        scores = entry.get('scores')
        if not scores or not isinstance(scores, dict):
            # Backward compatibility: parse scores from observation text
            scores = {}
            obs = entry.get('observation', '') + ' ' + entry.get('context', '')
            # Match patterns like 'accuracy: 0.8' or 'accuracy=0.8' or 'accuracy 0.8/1.0'
            for m in re.finditer(r'(\b[a-z_-]+)\s*[:=]\s*(\d+(?:\.\d+)?)', obs, re.IGNORECASE):
                key = m.group(1).lower().replace('-', '_')
                try:
                    val = float(m.group(2))
                    scores[key] = val
                except ValueError:
                    pass

        if scores:
            entries.append({
                'timestamp': ts[:10],  # date only
                'scores': scores,
            })

if not entries:
    print('No entries with scores found.')
    sys.exit(0)

if json_output:
    print(json.dumps(entries, indent=2))
    sys.exit(0)

# Collect all score keys across entries
all_keys = []
seen = set()
for e in entries:
    for k in e['scores']:
        if k not in seen:
            seen.add(k)
            all_keys.append(k)

# Print table header
header = 'Date       '
for k in all_keys:
    header += f' | {k:>10}'
print(header)
print('-' * len(header))

# Print rows
for e in entries:
    row = f'{e[\"timestamp\"]:10}'
    for k in all_keys:
        val = e['scores'].get(k)
        if val is not None:
            row += f' | {val:>10.2f}'
        else:
            row += f' | {\"—\":>10}'
    print(row)
" "$logfile" "$role_filter" "$since" "$json_output"
}

# --- Subcommand dispatch ---
if [[ $# -eq 0 ]]; then
  cat >&2 <<EOF
Usage: lore journal <subcommand> [args...]

Subcommands:
  write   Record a journal observation
  show    Display journal entries (default or --aggregate)
  query   Extract structured data from journal entries

Run 'lore journal <subcommand> --help' for details.
EOF
  exit 1
fi

SUBCMD="$1"
shift

case "$SUBCMD" in
  write)
    journal_write "$@"
    ;;
  show)
    journal_show "$@"
    ;;
  query)
    journal_query "$@"
    ;;
  --help|-h)
    cat >&2 <<EOF
Usage: lore journal <subcommand> [args...]

Subcommands:
  write   Record a journal observation
  show    Display journal entries (default or --aggregate)
  query   Extract structured data from journal entries

Run 'lore journal <subcommand> --help' for details.
EOF
    exit 0
    ;;
  *)
    echo "Error: unknown journal subcommand '$SUBCMD'" >&2
    exit 1
    ;;
esac
