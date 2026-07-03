#!/usr/bin/env bash
# verify-report.sh — Producer-facing consumption report over the trust ledger
# (`lore verify --report`).
#
# Read-only aggregation over `$KDIR/_trust/trust-events.jsonl`: for an
# explicit scope of knowledge entries, project every ledger event recorded
# against each entry — per-event disposition, code anchor (file:line-range),
# source, work item, and timestamp — alongside held/contradicted,
# mechanical-check, and adjudication counts. Counts are always paired with
# the per-event evidence lines: the report answers "WHAT was verified and
# WHERE", not "how many times was the verb invoked".
#
# Retrieval loads are joined from `$KDIR/_meta/retrieval-log.jsonl` where a
# join key exists: `prefetch` and `manifest_load` rows carry `loaded_paths`;
# `search` rows carry no per-entry key and are never counted. A missing
# retrieval log degrades to a note, never a failure.
#
# Scope (exactly one required — no default; an unscoped report is an error):
#   --entry <path>       One entry, KDIR-relative (`.md` optional). The file
#                        need not exist — rows survive an entry's archival,
#                        and a superseded path is a legitimate report target.
#   --work-item <slug>   Entries whose capture footer records
#                        `work_item: <slug>` — the entries that work item
#                        produced, whoever verified them later.
#   --source <identity>  Entries whose capture footer records
#                        `source: <identity>` (e.g. lore-promote, manual).
#
# Options:
#   [--kdir <path>] [--json]
#
# Grouping is by the envelope's raw `entry_path` — no migration-chain
# resolution here (that is trust-compute.py's job). A provenance-migration
# event in an entry's listing shows `from -> to`, so historical rows under
# the old path are one `--entry <from-path>` re-run away; every number in
# this report is recomputable by hand from the raw ledger rows.
#
# Malformed ledger rows are excluded with a stderr warning per the reader
# contract (architecture/trust-ledger/README.md §1); rows the writer
# accepted are never re-validated.
#
# Exit codes:
#   0 — report printed (including an empty report: no matching entries or
#       events is an answer, not an error)
#   1 — usage error (missing/ambiguous scope, unknown flag) or missing KDIR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage: verify-report.sh (--entry <path> | --work-item <slug> | --source <identity>)
                        [--kdir <path>] [--json]

Producer-facing report over the trust ledger: per-entry verification events
(held/contradicted with code anchors), mechanical checks, adjudications,
provenance migrations, and retrieval loads for the scoped entries.

Scope (exactly one required):
  --entry <path>        One knowledge entry, KDIR-relative
  --work-item <slug>    Entries captured under that work item (footer work_item)
  --source <identity>   Entries captured by that source (footer source)

Options:
  --kdir <path>         Override knowledge-store directory
  --json                Emit structured JSON instead of the human report
  --help, -h            Show this help
EOF
}

SCOPE_ENTRY=""
SCOPE_WORK_ITEM=""
SCOPE_SOURCE=""
KDIR_OVERRIDE=""
JSON_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --entry)      SCOPE_ENTRY="$2";      shift 2 ;;
    --work-item)  SCOPE_WORK_ITEM="$2";  shift 2 ;;
    --source)     SCOPE_SOURCE="$2";     shift 2 ;;
    --kdir)       KDIR_OVERRIDE="$2";    shift 2 ;;
    --json)       JSON_MODE=1;           shift ;;
    --help|-h)    usage; exit 0 ;;
    *)
      echo "[verify-report] Error: unknown argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

fail() {
  local msg="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    json_error "[verify-report] $msg"
  fi
  echo "[verify-report] Error: $msg" >&2
  exit 1
}

# --- Exactly one scope, declared explicitly ---
SCOPE_COUNT=0
[[ -n "$SCOPE_ENTRY" ]]     && SCOPE_COUNT=$((SCOPE_COUNT + 1))
[[ -n "$SCOPE_WORK_ITEM" ]] && SCOPE_COUNT=$((SCOPE_COUNT + 1))
[[ -n "$SCOPE_SOURCE" ]]    && SCOPE_COUNT=$((SCOPE_COUNT + 1))
if [[ $SCOPE_COUNT -eq 0 ]]; then
  fail "a scope is required: --entry <path>, --work-item <slug>, or --source <identity>"
fi
if [[ $SCOPE_COUNT -gt 1 ]]; then
  fail "scopes are mutually exclusive: pass exactly one of --entry, --work-item, --source"
fi

# --- Resolve knowledge directory ---
if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR=$(resolve_knowledge_dir)
fi
if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  fail "knowledge store not found at: $KNOWLEDGE_DIR"
fi

python3 - "$KNOWLEDGE_DIR" "$SCOPE_ENTRY" "$SCOPE_WORK_ITEM" "$SCOPE_SOURCE" "$JSON_MODE" <<'PY'
import json
import os
import re
import sys

kdir, scope_entry, scope_work_item, scope_source, json_mode = sys.argv[1:6]
json_mode = json_mode == "1"

LEDGER = os.path.join(kdir, "_trust", "trust-events.jsonl")
RETRIEVAL_LOG = os.path.join(kdir, "_meta", "retrieval-log.jsonl")

warnings = []

FOOTER_RE = re.compile(r"<!--\s*learned:.*?-->", re.DOTALL)

def footer_fields(text):
    """Parse the last capture footer into a dict of its pipe-separated fields."""
    matches = FOOTER_RE.findall(text)
    if not matches:
        return {}
    body = matches[-1].strip("<!->").strip()
    fields = {}
    for part in body.split(" | "):
        key, sep, value = part.partition(":")
        if sep:
            fields[key.strip()] = value.strip()
    return fields

def scan_entries(match_key, match_value):
    """Entry paths (KDIR-relative) whose capture footer has match_key == match_value."""
    found = []
    for root, dirs, files in os.walk(kdir):
        # Substrate dirs (_work, _trust, _meta, ...) and dot dirs hold no entries.
        dirs[:] = sorted(d for d in dirs if not d.startswith(("_", ".")))
        for name in sorted(files):
            if not name.endswith(".md") or name.startswith("_"):
                continue
            path = os.path.join(root, name)
            try:
                with open(path, encoding="utf-8") as f:
                    fields = footer_fields(f.read())
            except OSError as exc:
                warnings.append(f"unreadable entry skipped: {path} ({exc})")
                continue
            if fields.get(match_key) == match_value:
                found.append(os.path.relpath(path, kdir))
    return found

# --- Resolve the scope to an entry set ---
if scope_entry:
    scope_label = f"entry={scope_entry}"
    rel = scope_entry
    if rel.startswith(kdir + "/"):
        rel = rel[len(kdir) + 1:]
    if not os.path.isfile(os.path.join(kdir, rel)) and \
            os.path.isfile(os.path.join(kdir, rel + ".md")):
        rel = rel + ".md"
    if not os.path.isfile(os.path.join(kdir, rel)):
        warnings.append(
            f"entry file not found under KDIR: {rel} — reporting any ledger rows anyway"
        )
    scoped_entries = [rel]
elif scope_work_item:
    scope_label = f"work-item={scope_work_item}"
    scoped_entries = scan_entries("work_item", scope_work_item)
else:
    scope_label = f"source={scope_source}"
    scoped_entries = scan_entries("source", scope_source)

scoped_set = set(scoped_entries)

# --- Read the ledger, group scoped rows by entry_path ---
events_by_entry = {path: [] for path in scoped_entries}
if os.path.isfile(LEDGER):
    with open(LEDGER, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                warnings.append(f"malformed ledger row skipped: line {lineno}")
                continue
            if not isinstance(row, dict) or "entry_path" not in row or "event" not in row:
                warnings.append(f"malformed ledger row skipped: line {lineno}")
                continue
            if row["entry_path"] in scoped_set:
                events_by_entry[row["entry_path"]].append(row)
else:
    warnings.append("ledger not found (_trust/trust-events.jsonl) — no events recorded yet")

for rows in events_by_entry.values():
    rows.sort(key=lambda r: r.get("observed_at") or "")

# --- Join retrieval loads (prefetch/manifest_load carry loaded_paths) ---
retrieval_log_present = os.path.isfile(RETRIEVAL_LOG)
loads_by_entry = {path: {"total": 0, "by_event": {}, "last_loaded_at": None}
                  for path in scoped_entries}
if retrieval_log_present:
    with open(RETRIEVAL_LOG, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            event = row.get("event")
            if event not in ("prefetch", "manifest_load"):
                continue
            paths = row.get("loaded_paths")
            if not isinstance(paths, list):
                continue
            for path in paths:
                stats = loads_by_entry.get(path)
                if stats is None:
                    continue
                stats["total"] += 1
                stats["by_event"][event] = stats["by_event"].get(event, 0) + 1
                ts = row.get("timestamp")
                if ts and (stats["last_loaded_at"] is None or ts > stats["last_loaded_at"]):
                    stats["last_loaded_at"] = ts
else:
    warnings.append("retrieval log not found (_meta/retrieval-log.jsonl) — load counts unavailable")

# --- Project the report structure ---
def project_entry(path):
    rows = events_by_entry[path]
    verifications = [r for r in rows if r["event"] == "consumption-verification"]
    checks = [r for r in rows if r["event"] == "mechanical-check"]
    adjudications = [r for r in rows if r["event"] == "adjudication"]
    migrations = [r for r in rows if r["event"] == "provenance-migration"]

    def pl(row):
        payload = row.get("payload")
        return payload if isinstance(payload, dict) else {}

    return {
        "entry_path": path,
        "verifications": {
            "held": sum(1 for r in verifications if pl(r).get("disposition") == "held"),
            "contradicted": sum(1 for r in verifications
                                if pl(r).get("disposition") == "contradicted"),
            "events": [{
                "disposition": pl(r).get("disposition"),
                "file": pl(r).get("file"),
                "line_range": pl(r).get("line_range"),
                "exact_snippet": pl(r).get("exact_snippet"),
                "source": r.get("source"),
                "work_item": pl(r).get("work_item"),
                "rationale": pl(r).get("rationale"),
                "observed_at": r.get("observed_at"),
                "event_id": r.get("event_id"),
            } for r in verifications],
        },
        "mechanical_checks": {
            "by_result": {result: sum(1 for r in checks if pl(r).get("result") == result)
                          for result in ("pass", "fail", "error", "skip")},
            "events": [{
                "check_name": pl(r).get("check_name"),
                "target": pl(r).get("target"),
                "result": pl(r).get("result"),
                "run_id": pl(r).get("run_id"),
                "detail": pl(r).get("detail"),
                "source": r.get("source"),
                "observed_at": r.get("observed_at"),
                "event_id": r.get("event_id"),
            } for r in checks],
        },
        "adjudications": {
            "confirmed": sum(1 for r in adjudications if pl(r).get("verdict") == "confirmed"),
            "rejected": sum(1 for r in adjudications if pl(r).get("verdict") == "rejected"),
            "events": [{
                "claim_id": pl(r).get("claim_id"),
                "verdict": pl(r).get("verdict"),
                "template_id": pl(r).get("template_id"),
                "template_version": pl(r).get("template_version"),
                "run_id": pl(r).get("run_id"),
                "source": r.get("source"),
                "observed_at": r.get("observed_at"),
                "event_id": r.get("event_id"),
            } for r in adjudications],
        },
        "migrations": [{
            "from_entry_path": pl(r).get("from_entry_path"),
            "to_entry_path": pl(r).get("to_entry_path"),
            "reason": pl(r).get("reason"),
            "observed_at": r.get("observed_at"),
            "event_id": r.get("event_id"),
        } for r in migrations],
        "retrieval": {
            "available": retrieval_log_present,
            **loads_by_entry[path],
        },
        "event_count": len(rows),
    }

report = {
    "scope": scope_label,
    "entries": [project_entry(path) for path in scoped_entries],
    "total_events": sum(len(rows) for rows in events_by_entry.values()),
    "warnings": warnings,
}

for warning in warnings:
    print(f"[verify-report] Warning: {warning}", file=sys.stderr)

if json_mode:
    print(json.dumps(report, indent=2))
    sys.exit(0)

# --- Human rendering: every count is backed by its evidence lines ---
def snippet_line(text, limit=100):
    if not text:
        return ""
    flat = " ".join(text.split())
    return flat if len(flat) <= limit else flat[:limit - 3] + "..."

print(f"Trust report — scope: {scope_label} — "
      f"{len(scoped_entries)} entr{'y' if len(scoped_entries) == 1 else 'ies'}, "
      f"{report['total_events']} ledger event{'s' if report['total_events'] != 1 else ''}")

if not scoped_entries:
    print("  (no entries match this scope)")
    sys.exit(0)

for entry in report["entries"]:
    print()
    print(entry["entry_path"])
    if entry["event_count"] == 0:
        print("  no ledger events")
    ver = entry["verifications"]
    if ver["events"]:
        print(f"  verifications: {ver['held']} held, {ver['contradicted']} contradicted")
        for ev in ver["events"]:
            context = f"source={ev['source']}"
            if ev["work_item"]:
                context += f" work-item={ev['work_item']}"
            print(f"    {ev['disposition']:<12} {ev['file']}:{ev['line_range']}  "
                  f"{context}  {ev['observed_at']}")
            if ev["exact_snippet"]:
                print(f"                 snippet: {snippet_line(ev['exact_snippet'])}")
            if ev["disposition"] == "contradicted" and ev["rationale"]:
                print(f"                 rationale: {snippet_line(ev['rationale'])}")
    checks = entry["mechanical_checks"]
    if checks["events"]:
        summary = ", ".join(f"{count} {result}"
                            for result, count in checks["by_result"].items() if count)
        print(f"  mechanical checks: {summary}")
        for ev in checks["events"]:
            print(f"    {ev['result']:<6} {ev['check_name']} target={ev['target']} "
                  f"run={ev['run_id']}  source={ev['source']}  {ev['observed_at']}")
            if ev["detail"]:
                print(f"           detail: {snippet_line(ev['detail'])}")
    adj = entry["adjudications"]
    if adj["events"]:
        print(f"  adjudications: {adj['confirmed']} confirmed, {adj['rejected']} rejected")
        for ev in adj["events"]:
            print(f"    {ev['verdict']:<10} claim={ev['claim_id']} "
                  f"template={ev['template_id']}@{ev['template_version']} "
                  f"run={ev['run_id']}  {ev['observed_at']}")
    for mig in entry["migrations"]:
        print(f"  provenance: {mig['from_entry_path']} -> {mig['to_entry_path']} "
              f"({mig['reason']})  {mig['observed_at']}")
        print(f"              historical rows stay under the old path — "
              f"re-run with --entry {mig['from_entry_path']} to see them")
    retrieval = entry["retrieval"]
    if retrieval["available"]:
        if retrieval["total"]:
            by_event = ", ".join(f"{event} {count}"
                                 for event, count in sorted(retrieval["by_event"].items()))
            print(f"  retrieval loads: {retrieval['total']} ({by_event}; "
                  f"last {retrieval['last_loaded_at']})")
        else:
            print("  retrieval loads: 0")

if retrieval_log_present:
    print()
    print("note: retrieval loads count prefetch/manifest_load rows only — "
          "search rows carry no per-entry join key")
PY
