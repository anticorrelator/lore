#!/usr/bin/env bash
# audit-sample.sh — Risk-weighted sampler for audit claim candidates.
#
# Reads a JSON array of claim objects (from the resolved-input `claim_payload`
# defined in architecture/audit-pipeline/contract.md) and emits, per claim,
# a composite risk weight + signal breakdown. The audit wrapper uses this
# to bias sampling toward the claims most likely to reveal problems.
#
# The sampler is a *weight producer*, not a selector. Callers decide
# whether to weighted-sample, top-k, or threshold against the emitted
# weights. Contract: emit weights; do not prune candidates.
#
# Signals (each adds to a base weight of 1.0):
#   tests_skipped        +0.8   claim.test_status ∈ {skipped, not-applicable, n/a}
#   high_risk_path       +0.7   claim.file matches a risk regex (auth, security,
#                               crypto, payment, admin, migration, scorecard,
#                               audit, hook, config, secret)
#   generic_language     +0.5   claim_text has low lexical entropy OR matches a
#                               curated generic-phrasing list ("works correctly",
#                               "handles properly", "as expected", "no issues"...)
#   contradicts_prior    +0.6   lore search on claim_text returns ≥1 hit with
#                               score above threshold (topic is already covered
#                               in the knowledge store — higher likelihood of
#                               contradiction worth auditing)
#
# Usage:
#   lore audit-sample [--input <file>] [--kdir <path>] [--top-k <n>] [--json]
#   echo '<json>' | lore audit-sample
#
# Input:
#   JSON array. Each element must have claim_id. Optional fields consumed:
#     claim_text, file, test_status. Unknown fields are ignored.
#
# Output (JSON):
#   [
#     {
#       "claim_id": "finding-0",
#       "weight": 2.6,
#       "signals": {
#         "tests_skipped": true,
#         "high_risk_path": true,
#         "generic_language": false,
#         "contradicts_prior": true
#       },
#       "weight_breakdown": {
#         "base": 1.0, "tests_skipped": 0.8, "high_risk_path": 0.7,
#         "generic_language": 0.0, "contradicts_prior": 0.6
#       }
#     }
#   ]
#
# With --top-k N: emit only the N highest-weighted claims (ties broken by
# input order). Default is all claims, sorted highest-weight first.
#
# Exits:
#   0 success
#   1 usage error / input parse failure
#   2 lore search unavailable AND --require-contradicts-prior was passed
#
# Related:
#   architecture/audit-pipeline/contract.md — canonical claim shape
#   scripts/audit-artifact.sh                — audit wrapper that consumes this

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

INPUT_FILE=""
KDIR_OVERRIDE=""
TOP_K=""
JSON_MODE=1
REQUIRE_PRIOR=0

usage() {
  cat >&2 <<EOF
lore audit-sample — emit risk weights per claim for audit sampling

Usage: lore audit-sample [--input <file>] [--kdir <path>] [--top-k <n>] [--json]
       echo '<json>' | lore audit-sample

Options:
  --input <file>                 Read claims JSON from <file> instead of stdin.
  --kdir <path>                  Override resolved knowledge directory.
  --top-k <n>                    Emit only the N highest-weighted claims.
  --json                         Emit JSON (default; reserved for future modes).
  --require-contradicts-prior    Exit non-zero if lore search is unavailable.
  -h, --help                     Show this help.

Input: JSON array of claim objects. See architecture/audit-pipeline/contract.md
       for the resolved-input claim_payload shape. Minimum: claim_id.

Signals: tests_skipped (+0.8), high_risk_path (+0.7), generic_language (+0.5),
         contradicts_prior (+0.6). Base weight: 1.0.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --input)
      INPUT_FILE="$2"
      shift 2
      ;;
    --kdir)
      KDIR_OVERRIDE="$2"
      shift 2
      ;;
    --top-k)
      TOP_K="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --require-contradicts-prior)
      REQUIRE_PRIOR=1
      shift
      ;;
    *)
      echo "[audit-sample] Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

# Resolve knowledge directory (used by contradicts_prior lore-search probe).
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KDIR="$KDIR_OVERRIDE"
else
  KDIR=$(resolve_knowledge_dir 2>/dev/null || echo "")
fi

# Detect lore CLI availability for contradicts_prior signal.
LORE_AVAILABLE=0
if command -v lore >/dev/null 2>&1; then
  LORE_AVAILABLE=1
elif [[ $REQUIRE_PRIOR -eq 1 ]]; then
  echo "[audit-sample] Error: --require-contradicts-prior set but 'lore' CLI not on PATH" >&2
  exit 2
fi

# Read input JSON.
if [[ -n "$INPUT_FILE" ]]; then
  if [[ ! -f "$INPUT_FILE" ]]; then
    echo "[audit-sample] Error: input file not found: $INPUT_FILE" >&2
    exit 1
  fi
  INPUT_JSON=$(cat "$INPUT_FILE")
else
  INPUT_JSON=$(cat)
fi

if [[ -z "$INPUT_JSON" ]]; then
  echo "[audit-sample] Error: empty input" >&2
  exit 1
fi

# Delegate scoring to python3 — bash is the wrong tool for entropy + regex + JSON.
# Pass the input JSON through an env var so stdin stays free for the heredoc'd
# python source (python3 - reads the script from stdin).
export AUDIT_SAMPLE_INPUT_JSON="$INPUT_JSON"
export AUDIT_SAMPLE_LORE_AVAILABLE="$LORE_AVAILABLE"
export AUDIT_SAMPLE_TOP_K="${TOP_K:-}"

python3 <<'PYEOF'
import json, math, os, re, subprocess, sys

lore_available = os.environ.get("AUDIT_SAMPLE_LORE_AVAILABLE", "0") == "1"
top_k_raw = os.environ.get("AUDIT_SAMPLE_TOP_K", "")
top_k = int(top_k_raw) if top_k_raw else None

try:
    claims = json.loads(os.environ.get("AUDIT_SAMPLE_INPUT_JSON", ""))
except json.JSONDecodeError as e:
    print(f"[audit-sample] Error: input is not valid JSON: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(claims, list):
    print("[audit-sample] Error: input must be a JSON array of claim objects", file=sys.stderr)
    sys.exit(1)

# --- Signal 1: tests_skipped ---
SKIPPED_STATUSES = {"skipped", "skip", "not-applicable", "not applicable", "n/a", "na"}

def tests_skipped(claim):
    ts = (claim.get("test_status") or "").strip().lower()
    return ts in SKIPPED_STATUSES

# --- Signal 2: high_risk_path ---
# Paths that have historically been high-blast-radius and where audits
# repeatedly surface problems. Matched case-insensitively as substrings.
HIGH_RISK_PATH_RE = re.compile(
    r"(auth|security|crypto|credential|secret|token|password|"
    r"payment|billing|admin|sudo|privilege|"
    r"migration|schema|drop_|alter_|"
    r"scorecard|audit|hook|webhook|"
    r"config|setting|env|dotenv)",
    re.IGNORECASE,
)

def high_risk_path(claim):
    file_path = claim.get("file") or ""
    return bool(HIGH_RISK_PATH_RE.search(file_path))

# --- Signal 3: generic_language ---
# Two-stage heuristic:
#   (a) curated phrases known to be vacuous
#   (b) low Shannon entropy per token for texts with >=5 tokens
GENERIC_PHRASES = [
    "works correctly",
    "works as expected",
    "handles properly",
    "handled properly",
    "no issues",
    "no problems",
    "functions properly",
    "operates correctly",
    "behaves correctly",
    "behaves as expected",
    "appropriate error handling",
    "proper validation",
    "proper error handling",
    "improves code quality",
    "good practice",
    "follows best practices",
    "clean code",
    "well-structured",
]
GENERIC_PHRASE_RE = re.compile("|".join(re.escape(p) for p in GENERIC_PHRASES), re.IGNORECASE)

def generic_language(claim):
    text = (claim.get("claim_text") or "").strip()
    if not text:
        return False
    if GENERIC_PHRASE_RE.search(text):
        return True
    tokens = [t for t in re.findall(r"\w+", text.lower()) if len(t) > 2]
    if len(tokens) < 5:
        return False
    uniq_ratio = len(set(tokens)) / len(tokens)
    # Low uniqueness → repetitive/vague. Real observations tend to be lexically diverse.
    if uniq_ratio < 0.5:
        return True
    # Shannon entropy on token frequency.
    from collections import Counter
    counts = Counter(tokens)
    total = sum(counts.values())
    entropy = -sum((c / total) * math.log2(c / total) for c in counts.values())
    # Short texts have naturally low entropy; threshold scales with length.
    # Calibration: threshold 2.0 bits catches formulaic, preserves real prose.
    return entropy < 2.0

# --- Signal 4: contradicts_prior ---
# Topic overlap with the knowledge store is a risk signal because the
# correctness-gate is more likely to find contradiction when the claim
# touches material the store has already reasoned about. Mechanical proxy:
# run `lore search` and check whether any hit has a non-trivial score.
#
# We do NOT judge contradiction here (that's the correctness-gate's job).
# We flag candidates whose topics the store already covers.
CACHE = {}

def contradicts_prior(claim):
    if not lore_available:
        return False
    text = (claim.get("claim_text") or "").strip()
    if not text or len(text) < 8:
        return False
    # Use up to 12 words as the query — long enough to be specific, short
    # enough to avoid FTS5 query blowups. Strip punctuation.
    words = re.findall(r"\w+", text)[:12]
    if not words:
        return False
    query = " ".join(words)
    if query in CACHE:
        return CACHE[query]
    try:
        result = subprocess.run(
            ["lore", "search", query, "--json"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            CACHE[query] = False
            return False
        hits = json.loads(result.stdout or "[]")
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
        CACHE[query] = False
        return False
    # "Any hit with score above a very low threshold" — lore scores are
    # negative log-probs; higher (less negative) = better match. -10 is a
    # permissive cutoff that catches topic overlap without false alarming
    # on every query.
    has_hit = any(
        isinstance(h, dict) and isinstance(h.get("score"), (int, float)) and h["score"] > -10.0
        for h in hits
    )
    CACHE[query] = has_hit
    return has_hit

# --- Weight composition ---
SIGNAL_WEIGHTS = {
    "tests_skipped": 0.8,
    "high_risk_path": 0.7,
    "generic_language": 0.5,
    "contradicts_prior": 0.6,
}
SIGNAL_FNS = {
    "tests_skipped": tests_skipped,
    "high_risk_path": high_risk_path,
    "generic_language": generic_language,
    "contradicts_prior": contradicts_prior,
}

results = []
for claim in claims:
    if not isinstance(claim, dict) or "claim_id" not in claim:
        print(f"[audit-sample] Error: claim missing claim_id: {claim!r}", file=sys.stderr)
        sys.exit(1)
    signals = {name: bool(fn(claim)) for name, fn in SIGNAL_FNS.items()}
    breakdown = {"base": 1.0}
    breakdown.update({
        name: SIGNAL_WEIGHTS[name] if fired else 0.0
        for name, fired in signals.items()
    })
    weight = sum(breakdown.values())
    results.append({
        "claim_id": claim["claim_id"],
        "weight": round(weight, 3),
        "signals": signals,
        "weight_breakdown": {k: round(v, 3) for k, v in breakdown.items()},
    })

# Sort highest-weight first; stable so ties keep input order.
results.sort(key=lambda r: -r["weight"])
if top_k is not None:
    results = results[:top_k]

print(json.dumps(results, indent=2))
PYEOF
