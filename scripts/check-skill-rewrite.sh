#!/usr/bin/env bash
# check-skill-rewrite.sh — Verify a per-skill SKILL.md rewrite against its
# audit table and (optionally) its rewrite-log.
#
# Usage:
#   check-skill-rewrite.sh \
#     --audit     <audit.md> \
#     --original  <pre-rewrite SKILL.md> \
#     --rewritten <post-rewrite SKILL.md> \
#     [--rewrite-log <log.md>]
#
# Runs three independent checks. Each check produces its own failure block on
# stderr; the script exits non-zero if any check fails. The checks are:
#
#   (a) Preserve-trace — every cat-2 stance_phrase and every inline
#       canonical_definition prose snippet from the audit must survive
#       verbatim in the rewritten file (grep -F substring match). Audit rows
#       whose canonical_definition citation is a path:line_range reference
#       only (no inline quoted prose) produce stderr warnings rather than
#       failures — the reviewer is expected to sample those by hand and the
#       rewrite-log must still list them (enforced by check (c)).
#
#       When a rewrite-log row is `applied_disposition: moved_to_sidecar`
#       and `new_anchor_or_DELETED_or_MERGED: SIDECAR:<rel-path>`, the
#       probe for that row is matched against `<dirname(--rewritten)>/<rel-path>`
#       instead of `--rewritten`. A missing sidecar file fails check (a)
#       with a clear error naming the missing path.
#
#   (b) Frontmatter byte-compare — the YAML block between the leading
#       --- markers in --original and --rewritten must be byte-identical.
#       Frontmatter is parse-fragile (strict-YAML quoting in `description:`
#       is enforced by codex's skill loader), so we never parse and re-emit;
#       we compare bytes.
#
#   (c) Rewrite-log coverage — when --rewrite-log is supplied: every audit
#       row_id appears exactly once in the disposition table; every
#       handoff_review row has a non-empty note; every row whose
#       applied_disposition diverges from the default for its
#       (primary_category, flags, failure_vocab_role, canonical_site) tuple
#       has a non-empty note; every path:line_range-only warning row from
#       check (a) appears in the disposition table.
#
# When --rewrite-log is omitted, check (c) is skipped — checks (a) and (b)
# remain a useful in-progress signal for the worker.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

PARSER="$SCRIPT_DIR/check_skill_rewrite_lib.py"
if [[ ! -f "$PARSER" ]]; then
  die "missing helper: $PARSER"
fi
# Exported so embedded python heredocs that re-invoke the parser as a
# subprocess can locate it without parsing $0.
export PARSER

# --- Parse arguments ---
AUDIT=""
ORIGINAL=""
REWRITTEN=""
REWRITE_LOG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --audit)
      AUDIT="${2:-}"
      shift 2
      ;;
    --original)
      ORIGINAL="${2:-}"
      shift 2
      ;;
    --rewritten)
      REWRITTEN="${2:-}"
      shift 2
      ;;
    --rewrite-log)
      REWRITE_LOG="${2:-}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,40p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [[ -z "$AUDIT" || -z "$ORIGINAL" || -z "$REWRITTEN" ]]; then
  die "missing required flag. Usage: check-skill-rewrite.sh --audit <audit.md> --original <pre.md> --rewritten <post.md> [--rewrite-log <log.md>]"
fi

[[ -f "$AUDIT" ]]     || die "audit file not found: $AUDIT"
[[ -f "$ORIGINAL" ]]  || die "original file not found: $ORIGINAL"
[[ -f "$REWRITTEN" ]] || die "rewritten file not found: $REWRITTEN"
if [[ -n "$REWRITE_LOG" && ! -f "$REWRITE_LOG" ]]; then
  die "rewrite-log not found (omit --rewrite-log to skip check (c)): $REWRITE_LOG"
fi

command -v python3 >/dev/null 2>&1 || die "python3 is required"

CHECK_A_FAIL=0
CHECK_B_FAIL=0
CHECK_C_FAIL=0

# --- Check (a): preserve-trace ---------------------------------------------
#
# The Python helper emits one JSON record per preserve probe. We feed them to
# `match-probe`, which normalizes both probe and rewritten file (markdown
# emphasis stripped, Unicode dashes collapsed) before substring-matching.
# Records flagged kind=canonical_link_only emit a stderr warning and are
# tracked in LINK_ONLY_IDS so check (c) can require their presence in the
# disposition table.

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SNIPPETS_FILE="$TMP_DIR/snippets.jsonl"
LINK_ONLY_FILE="$TMP_DIR/link-only.json"
MISSING_PROBES_FILE="$TMP_DIR/missing.txt"

if ! python3 "$PARSER" preserve-snippets "$AUDIT" > "$SNIPPETS_FILE"; then
  die "failed to parse audit table: $AUDIT"
fi

# Split the snippet stream: link-only rows go to stderr as warnings (and to
# the link-only id file for check (c)); the rest are fed to match-probe.
python3 - "$SNIPPETS_FILE" "$LINK_ONLY_FILE" <<'PYEOF' >&2
import json
import sys

snippets_path, link_only_path = sys.argv[1:3]
link_only_ids = []
with open(snippets_path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        if rec.get("kind") == "canonical_link_only":
            link_only_ids.append(rec["row_id"])
            print(f"[warn] {rec['row_id']}: {rec.get('skip_reason','')}")

with open(link_only_path, "w", encoding="utf-8") as f:
    json.dump(link_only_ids, f)
PYEOF

python3 "$PARSER" match-probe "$REWRITTEN" < "$SNIPPETS_FILE" > "$MISSING_PROBES_FILE"

# Build the sidecar route table (row_id -> sidecar relative path) when a
# rewrite-log is available. Rows whose applied_disposition is
# `moved_to_sidecar` route their preserve-trace probes to the named
# sidecar file instead of the rewritten SKILL.md. Empty file = no
# moved_to_sidecar rows = legacy single-file behavior.
SIDECAR_MAP_FILE="$TMP_DIR/sidecar-map.tsv"
: > "$SIDECAR_MAP_FILE"
if [[ -n "$REWRITE_LOG" ]]; then
  python3 "$PARSER" sidecar-targets "$REWRITE_LOG" > "$SIDECAR_MAP_FILE"
fi

# Retry sidecar-routed misses against their named sidecar files. The
# rewritten SKILL.md's parent directory is the resolution root for the
# SIDECAR:<rel-path> reference. A missing sidecar file is a hard check (a)
# failure (we surface the resolved path). A probe that still misses after
# retry stays in the missing-probes list and falls through to the
# documented/undocumented partition below.
SIDECAR_MISSING_FILE_ERRS="$TMP_DIR/sidecar-missing-files.txt"
: > "$SIDECAR_MISSING_FILE_ERRS"
if [[ -s "$MISSING_PROBES_FILE" && -s "$SIDECAR_MAP_FILE" ]]; then
  REWRITTEN_DIR="$(cd "$(dirname "$REWRITTEN")" && pwd)"
  SIDECAR_RETRY_INPUT="$TMP_DIR/sidecar-retry.txt"
  SIDECAR_SURVIVED="$TMP_DIR/sidecar-survived.txt"
  NON_SIDECAR="$TMP_DIR/non-sidecar.txt"
  : > "$SIDECAR_RETRY_INPUT"
  : > "$SIDECAR_SURVIVED"
  : > "$NON_SIDECAR"

  # Split the missing-probes list into sidecar-routed and non-sidecar
  # buckets using the sidecar map.
  python3 - "$MISSING_PROBES_FILE" "$SIDECAR_MAP_FILE" "$SIDECAR_RETRY_INPUT" "$NON_SIDECAR" <<'PYEOF'
import sys

missing_path, map_path, retry_path, non_sidecar_path = sys.argv[1:5]

sidecar_by_id: dict[str, str] = {}
with open(map_path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        rid, rel = line.split("\t", 1)
        sidecar_by_id[rid] = rel

with open(missing_path, "r", encoding="utf-8") as src, \
     open(retry_path, "w", encoding="utf-8") as retry_f, \
     open(non_sidecar_path, "w", encoding="utf-8") as other_f:
    for line in src:
        if not line.strip():
            continue
        rid = line.split("\t", 1)[0]
        if rid in sidecar_by_id:
            # Prepend the sidecar relative path as a fourth TSV column so
            # the bash side can route the retry without re-consulting the map.
            retry_f.write(line.rstrip("\n") + "\t" + sidecar_by_id[rid] + "\n")
        else:
            other_f.write(line)
PYEOF

  # Retry each sidecar-routed probe against its named sidecar file. We
  # rebuild a synthetic JSONL probe stream (one entry per retry row) and
  # feed it to match-probe so the normalization rules stay identical to
  # the primary path.
  if [[ -s "$SIDECAR_RETRY_INPUT" ]]; then
    # Re-load the original snippet text by row_id from the snippets JSONL.
    python3 - "$SNIPPETS_FILE" "$SIDECAR_RETRY_INPUT" "$REWRITTEN_DIR" "$SIDECAR_SURVIVED" "$SIDECAR_MISSING_FILE_ERRS" <<'PYEOF'
import json
import os
import re
import subprocess
import sys

snippets_path, retry_path, rewritten_dir, survived_path, missing_files_path = sys.argv[1:6]

# Index original snippets by row_id so we can recover the full snippet
# text (the missing-probes TSV truncates long snippets for display).
snippet_by_id: dict[str, dict] = {}
with open(snippets_path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        snippet_by_id[rec["row_id"]] = rec

# Group retry rows by sidecar relative path so we make one match-probe
# call per sidecar file (cheaper, and the existing match-probe contract
# is one-target-file-per-invocation).
by_sidecar: dict[str, list[str]] = {}
with open(retry_path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        rid = parts[0]
        rel = parts[-1]
        by_sidecar.setdefault(rel, []).append(rid)

survived: list[str] = []
missing_files: list[str] = []

# Resolve PARSER from the wrapper's environment (exported below before we
# enter this heredoc). Falling back to the python file name would break
# in unusual layouts; we require the env var.
parser_path = os.environ["PARSER"]

for rel, row_ids in by_sidecar.items():
    abs_sidecar = os.path.join(rewritten_dir, rel)
    if not os.path.isfile(abs_sidecar):
        missing_files.append(f"{rel}\t{abs_sidecar}\t{','.join(row_ids)}")
        # Every row routed to this sidecar survives as a hard miss (file
        # absent), so they all remain "missing" — append back to survived.
        for rid in row_ids:
            rec = snippet_by_id.get(rid, {})
            snippet_display = (rec.get("snippet", "")
                               .replace("\n", " ").replace("\r", " "))
            if len(snippet_display) > 200:
                snippet_display = snippet_display[:197] + "..."
            survived.append(f"{rid}\t{rec.get('kind','')}\t{snippet_display}")
        continue

    # Build a synthetic JSONL probe stream containing just these rows.
    probe_lines = []
    for rid in row_ids:
        rec = snippet_by_id.get(rid)
        if rec is None:
            # Should not happen — the row_id came from preserve-snippets
            # output and we read the same file here.
            continue
        probe_lines.append(json.dumps(rec, ensure_ascii=False))

    proc = subprocess.run(
        ["python3", parser_path, "match-probe", abs_sidecar],
        input="\n".join(probe_lines) + ("\n" if probe_lines else ""),
        capture_output=True, text=True, check=False,
    )
    if proc.returncode != 0:
        # Surface match-probe stderr verbatim so the wrapper can route it.
        sys.stderr.write(proc.stderr)
        sys.exit(proc.returncode)
    # match-probe prints one TSV line per *still-missing* probe.
    for line in proc.stdout.splitlines():
        if line.strip():
            survived.append(line)

with open(survived_path, "w", encoding="utf-8") as f:
    for line in survived:
        f.write(line + "\n")
with open(missing_files_path, "w", encoding="utf-8") as f:
    for line in missing_files:
        f.write(line + "\n")
PYEOF
  fi

  # Reassemble the missing-probes list: non-sidecar misses + sidecar
  # misses that survived retry. The remainder of the pipeline (documented
  # vs undocumented partition) treats this combined set uniformly.
  cat "$NON_SIDECAR" "$SIDECAR_SURVIVED" > "$MISSING_PROBES_FILE"
fi

# Missing sidecar files are an unconditional check (a) failure — surface
# them now so the worker sees the missing path with both the resolved
# absolute path and the affected row_ids.
if [[ -s "$SIDECAR_MISSING_FILE_ERRS" ]]; then
  CHECK_A_FAIL=1
  echo "Check (a) FAILED — moved_to_sidecar rows reference missing sidecar files:" >&2
  while IFS=$'\t' read -r rel abs rids; do
    echo "  sidecar missing: $rel (resolved to $abs) — affected rows: $rids" >&2
  done < "$SIDECAR_MISSING_FILE_ERRS"
fi

# Partition missing probes into "documented" (the row appears in the
# rewrite-log with a non-empty note) and "undocumented" (no documenting
# note). Documented exceptions demote to warnings — the rewrite-log's note
# column is the audit trail for cases where the audit's transcription does
# not match the source verbatim (table flattening, punctuation drift,
# mid-snippet elision the verifier still cannot bridge). Undocumented
# misses fail check (a). Without --rewrite-log we have no source of
# documented exceptions, so every miss fails.
if [[ -s "$MISSING_PROBES_FILE" ]]; then
  DOCUMENTED_PROBES_FILE="$TMP_DIR/missing.documented.txt"
  UNDOCUMENTED_PROBES_FILE="$TMP_DIR/missing.undocumented.txt"
  : > "$DOCUMENTED_PROBES_FILE"
  : > "$UNDOCUMENTED_PROBES_FILE"

  if [[ -n "$REWRITE_LOG" ]]; then
    python3 - "$REWRITE_LOG" "$MISSING_PROBES_FILE" "$DOCUMENTED_PROBES_FILE" "$UNDOCUMENTED_PROBES_FILE" "$SIDECAR_MAP_FILE" <<'PYEOF'
import sys

log_path, missing_path, documented_path, undocumented_path, sidecar_map_path = sys.argv[1:6]

# Sidecar-routed row_ids that survived retry are hard misses regardless
# of the note column — the note on a moved_to_sidecar row documents the
# on-demand load condition, NOT a transcription-drift exception that
# should demote a miss to a warning.
sidecar_routed: set[str] = set()
try:
    with open(sidecar_map_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            rid = line.split("\t", 1)[0]
            sidecar_routed.add(rid)
except FileNotFoundError:
    pass

# Parse the rewrite-log disposition table once: row_id -> note (or "" if
# the row exists but has no note, or absent if the row is not in the log).
notes: dict[str, str] = {}
with open(log_path, "r", encoding="utf-8") as f:
    in_table = False
    for raw in f:
        line = raw.rstrip("\n")
        stripped = line.strip()
        if not stripped.startswith("|"):
            in_table = False
            continue
        cells = [c.strip() for c in stripped.strip("|").split("|")]
        if not in_table:
            # Skip header row and the markdown table separator row.
            if cells and cells[0].lower().replace(" ", "") in {"row_id", "rowid"}:
                in_table = True
            continue
        if cells and set(cells[0]) <= set("- :"):
            # Markdown table separator (`|---|---|...`)
            continue
        if len(cells) < 4:
            continue
        rid = cells[0]
        note = cells[3].strip()
        # Treat `none` and the literal placeholder `-` as empty.
        if note.lower() in {"none", "-", ""}:
            note = ""
        notes[rid] = note

with open(missing_path, "r", encoding="utf-8") as src, \
     open(documented_path, "w", encoding="utf-8") as docf, \
     open(undocumented_path, "w", encoding="utf-8") as undocf:
    for line in src:
        if not line.strip():
            continue
        rid = line.split("\t", 1)[0]
        if rid in sidecar_routed:
            # Sidecar-routed survivor — the probe was missing from the
            # rewritten SKILL.md AND from the named sidecar. Notes on
            # moved_to_sidecar rows document load conditions, not
            # transcription drift, so they cannot demote this miss.
            undocf.write(line)
        elif notes.get(rid):
            docf.write(line)
        else:
            undocf.write(line)
PYEOF
  else
    cp "$MISSING_PROBES_FILE" "$UNDOCUMENTED_PROBES_FILE"
  fi

  if [[ -s "$DOCUMENTED_PROBES_FILE" ]]; then
    echo "Check (a) noted exceptions — probes missing but documented in rewrite-log:" >&2
    while IFS=$'\t' read -r rid kind snippet; do
      echo "  [warn] $rid [$kind] (documented): $snippet" >&2
    done < "$DOCUMENTED_PROBES_FILE"
  fi

  if [[ -s "$UNDOCUMENTED_PROBES_FILE" ]]; then
    CHECK_A_FAIL=1
    echo "Check (a) FAILED — preserve-trace probes missing from rewritten file:" >&2
    while IFS=$'\t' read -r rid kind snippet; do
      echo "  $rid [$kind]: $snippet" >&2
    done < "$UNDOCUMENTED_PROBES_FILE"
  fi
fi

# --- Check (b): frontmatter byte-compare -----------------------------------
#
# Extract the YAML block delimited by leading `---` markers. Both files must
# open with --- on line 1; we read until the second --- and byte-compare the
# two extracts. We do NOT parse YAML — strict-YAML quoting in the
# description field is enforced by codex's skill loader, and a parse/re-emit
# round-trip risks introducing unquoted `': '` substrings.

extract_frontmatter() {
  local file="$1"
  local out="$2"
  # awk reads until the second `---` line; emits everything between the two
  # markers verbatim (including the markers themselves). If the file has no
  # leading frontmatter, awk emits nothing and the byte-compare will fail
  # cleanly below — we don't need a separate "missing frontmatter" path.
  awk '
    NR == 1 && /^---$/ { in_fm = 1; print; next }
    in_fm && /^---$/ { print; in_fm = 0; exit }
    in_fm { print }
  ' "$file" > "$out"
}

ORIG_FM="$TMP_DIR/original.fm"
REW_FM="$TMP_DIR/rewritten.fm"
extract_frontmatter "$ORIGINAL" "$ORIG_FM"
extract_frontmatter "$REWRITTEN" "$REW_FM"

if ! cmp -s "$ORIG_FM" "$REW_FM"; then
  CHECK_B_FAIL=1
  echo "Check (b) FAILED — frontmatter byte-compare diverged:" >&2
  diff -u "$ORIG_FM" "$REW_FM" >&2 || true
fi

# --- Check (c): rewrite-log coverage ---------------------------------------

if [[ -n "$REWRITE_LOG" ]]; then
  COVERAGE_OUT="$TMP_DIR/coverage.txt"
  set +e
  python3 "$PARSER" validate-rewrite-log "$AUDIT" "$REWRITE_LOG" "$LINK_ONLY_FILE" > "$COVERAGE_OUT"
  COVERAGE_RC=$?
  set -e
  if (( COVERAGE_RC != 0 )); then
    CHECK_C_FAIL=1
    echo "Check (c) FAILED — rewrite-log coverage issues:" >&2
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "  $line" >&2
    done < "$COVERAGE_OUT"
  fi
fi

# --- Exit -----------------------------------------------------------------

EXIT_CODE=0
(( CHECK_A_FAIL )) && EXIT_CODE=1
(( CHECK_B_FAIL )) && EXIT_CODE=1
(( CHECK_C_FAIL )) && EXIT_CODE=1

exit "$EXIT_CODE"
