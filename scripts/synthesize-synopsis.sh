#!/usr/bin/env bash
# synthesize-synopsis.sh — Synthesize a scale-appropriate synopsis for a knowledge entry
#
# Usage:
#   synthesize-synopsis.sh <entry_id> <requesting_scale>
#
# Where:
#   entry_id        — relative entry path without .md (e.g. conventions/scripts/lib-portability)
#   requesting_scale — scale id of the consuming agent (e.g. worker, subsystem)
#
# Behavior:
#   1. Check synopsis cache via `lore synopsis get`. On cache hit:
#      - If synopsis_status=generated or fallback-with-no-API-key: return cached content.
#      - If synopsis_status=fallback AND ANTHROPIC_API_KEY is now set: skip cache, re-synthesize.
#   2. On miss or fallback-retry: read parent entry body, call Haiku API with a 2-second budget.
#   3. Persist result via `lore synopsis put`.
#   4. Output the synopsis text on stdout.
#
# On synthesis failure (no API key, network error, timeout > 2s), emits the first 3 sentences
# or 300 chars (whichever shorter) of the entry body as a fallback with synopsis_status=fallback.
# Fallback entries are eligible for re-synthesis on the next read when API key becomes available.
#
# Environment:
#   ANTHROPIC_API_KEY — required for synthesis (fallback mode when absent)
#   LORE_SYNOPSIS_SKIP_CACHE=1 — force re-synthesis even if cache exists

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if [[ $# -lt 2 ]]; then
  echo "Usage: synthesize-synopsis.sh <entry_id> <requesting_scale>" >&2
  exit 1
fi

ENTRY_ID="$1"
SCALE="$2"

KDIR=$(resolve_knowledge_dir)
ENTRY_PATH="$KDIR/${ENTRY_ID}.md"

if [[ ! -f "$ENTRY_PATH" ]]; then
  echo "Error: entry not found: $ENTRY_PATH" >&2
  exit 1
fi

# --- Check cache unless forced ---
if [[ "${LORE_SYNOPSIS_SKIP_CACHE:-0}" != "1" ]]; then
  SFILE_CHECK="$(lore resolve 2>/dev/null)/_edge_synopses/$(printf '%s' "$ENTRY_ID" | sed 's|/|__|g')__${SCALE}.md"
  if [[ -f "$SFILE_CHECK" ]]; then
    CACHED_STATUS=$(head -1 "$SFILE_CHECK" | python3 -c "
import re, sys
m = re.search(r'synopsis_status:\s*([^\s|>]+)', sys.stdin.read())
print(m.group(1).strip() if m else 'generated')
" 2>/dev/null || echo "generated")
    # Re-synthesize fallback entries when API key is now available
    if [[ "$CACHED_STATUS" == "fallback" && -n "${ANTHROPIC_API_KEY:-}" ]]; then
      : # fall through to re-synthesis
    elif cached=$("$SCRIPT_DIR/edge-synopsis.sh" get "$ENTRY_ID" "$SCALE" 2>/dev/null); then
      printf '%s' "$cached"
      exit 0
    fi
    # edge-synopsis.sh get may have exited 2 (stale) and deleted the file — fall through
  fi
fi

# --- Compute parent content hash ---
PARENT_HASH=$(sha256sum "$ENTRY_PATH" 2>/dev/null | awk '{print $1}' \
  || shasum -a 256 "$ENTRY_PATH" 2>/dev/null | awk '{print $1}' \
  || echo "unknown")

# --- Read entry body (strip HTML comment metadata header) ---
ENTRY_BODY=$(python3 - "$ENTRY_PATH" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
# Remove HTML comment metadata blocks
text = re.sub(r'<!--.*?-->', '', text, flags=re.DOTALL).strip()
# Limit to ~3000 chars to stay within Haiku context budget
print(text[:3000])
PYEOF
)

# --- Resolve template version ---
TEMPLATE_VERSION=$(bash "$SCRIPT_DIR/template-version.sh" 2>/dev/null || echo "unknown")

CONTENT_FILE=$(mktemp /tmp/synopsis-content-XXXXXX.txt)
# Ensure temp file is cleaned up
trap 'rm -f "$CONTENT_FILE"' EXIT

# --- Attempt Haiku synthesis ---
STATUS="fallback"
SYNOPSIS=""
INPUT_TOKENS=0
OUTPUT_TOKENS=0
START_MS=$(python3 -c "import time; print(int(time.time() * 1000))")

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  # Build prompt
  PROMPT="Summarize this knowledge entry for an agent working at ${SCALE} scale. Output one paragraph, focused on what matters at ${SCALE} for a consumer who will descend if they need detail. Be concrete and use the terminology from the entry.\n\n${ENTRY_BODY}"

  PAYLOAD=$(python3 -c "
import json, sys
prompt = sys.argv[1]
print(json.dumps({
    'model': 'claude-haiku-4-5-20251001',
    'max_tokens': 300,
    'messages': [{'role': 'user', 'content': prompt}]
}))
" "$PROMPT")

  HTTP_RESPONSE=$(curl -s --max-time 2 \
    -X POST "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$PAYLOAD" 2>/dev/null || true)

  if [[ -n "$HTTP_RESPONSE" ]]; then
    read -r SYNOPSIS INPUT_TOKENS OUTPUT_TOKENS <<< "$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    content = data.get('content', [])
    text = ''
    if content and content[0].get('type') == 'text':
        text = content[0]['text'].strip()
    usage = data.get('usage', {})
    print(text.replace('\n', ' '), usage.get('input_tokens', 0), usage.get('output_tokens', 0))
except Exception:
    print('', 0, 0)
" "$HTTP_RESPONSE" 2>/dev/null || echo " 0 0")"
  fi

  if [[ -n "$SYNOPSIS" ]]; then
    STATUS="generated"
  fi
fi

END_MS=$(python3 -c "import time; print(int(time.time() * 1000))")
ELAPSED_MS=$((END_MS - START_MS))

# --- Fallback: first 3 sentences or 300 chars, whichever is shorter ---
if [[ -z "$SYNOPSIS" ]]; then
  SYNOPSIS=$(python3 -c "
import re, sys
text = sys.argv[1]
# Strip markdown headers
text = re.sub(r'^#+\s+.*$', '', text, flags=re.MULTILINE).strip()
# Extract sentences (split on '. ', '! ', '? ')
sentences = re.split(r'(?<=[.!?])\s+', text)
sentences = [s.strip() for s in sentences if s.strip()]
# Take first 3 sentences
candidate = ' '.join(sentences[:3])
# Enforce 300-char limit
if len(candidate) > 300:
    candidate = candidate[:300].rsplit(' ', 1)[0]
print(candidate)
" "$ENTRY_BODY" 2>/dev/null || printf '%s\n' "$ENTRY_BODY" | grep -v '^#' | grep -v '^\s*$' | head -2 | tr '\n' ' ')
  STATUS="fallback"
  INPUT_TOKENS=0
  OUTPUT_TOKENS=0
fi

# --- Persist to cache ---
printf '%s\n' "$SYNOPSIS" > "$CONTENT_FILE"
"$SCRIPT_DIR/edge-synopsis.sh" put "$ENTRY_ID" "$SCALE" \
  --content-file "$CONTENT_FILE" \
  --parent-hash "$PARENT_HASH" \
  --parent-template-version "$TEMPLATE_VERSION" \
  --status "$STATUS" > /dev/null

# --- Log synthesis cost ---
# Haiku 4.5 pricing: $0.80/M input tokens, $4.00/M output tokens
python3 - "$KDIR" "$ENTRY_ID" "$SCALE" "$STATUS" "$ELAPSED_MS" "$INPUT_TOKENS" "$OUTPUT_TOKENS" "$TEMPLATE_VERSION" <<'PYEOF'
import json, os, sys, datetime

kdir, entry_id, scale, status, elapsed_ms, input_tok, output_tok, tmpl_ver = sys.argv[1:9]

# Cost model: Haiku 4.5 — $0.80/M input, $4.00/M output
input_tokens = int(input_tok)
output_tokens = int(output_tok)
cost = (input_tokens * 0.80 + output_tokens * 4.00) / 1_000_000

row = {
    "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "entry_id": entry_id,
    "requesting_scale": scale,
    "synopsis_status": status,
    "elapsed_ms": int(elapsed_ms),
    "input_tokens": input_tokens,
    "output_tokens": output_tokens,
    "estimated_cost_usd": round(cost, 8),
    "parent_template_version": tmpl_ver,
}

log_dir = os.path.join(kdir, "_scorecards")
os.makedirs(log_dir, exist_ok=True)
log_file = os.path.join(log_dir, "synthesis-log.jsonl")

with open(log_file, "a") as f:
    f.write(json.dumps(row) + "\n")

# --- 24h rolling budget alert ($5 threshold) ---
try:
    cutoff = datetime.datetime.now(datetime.timezone.utc).timestamp() - 86400
    total_cost = 0.0
    with open(log_file) as f:
        for line in f:
            try:
                r = json.loads(line.strip())
                # Parse ts to epoch
                ts = datetime.datetime.fromisoformat(r["ts"].replace("Z", "+00:00")).timestamp()
                if ts >= cutoff:
                    total_cost += r.get("estimated_cost_usd", 0.0)
            except Exception:
                pass
    if total_cost > 5.0:
        print(f"[synopsis] WARNING: Haiku synopsis cost in 24h: ${total_cost:.4f} — exceeds $5 budget alert threshold.", file=sys.stderr)
except Exception:
    pass
PYEOF

printf '%s\n' "$SYNOPSIS"
