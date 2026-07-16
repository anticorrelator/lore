#!/usr/bin/env bash
# conformance-render.sh — Assemble work-item conformance evidence without judgment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

REF=""
DIFF_BASE=""
JSON_MODE=0

usage() {
  cat >&2 <<'EOF'
Usage: lore work conformance <ref> [--diff-base <ref>] [--json]

Write closure-conformance.md by assembling discovery, woven norms, recorded
dispositions, the shipped diff, and diff-seeded closure discovery. The artifact
presents evidence and absences; it does not decide applicability or conformance.
EOF
}

fail() {
  local message="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    python3 - "$message" <<'PY'
import json, sys
print(json.dumps({"error": sys.argv[1]}, ensure_ascii=False))
PY
  else
    echo "[conformance] Error: $message" >&2
  fi
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --diff-base)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "--diff-base requires a ref"
      DIFF_BASE="$2"
      shift 2
      ;;
    --diff-base=*)
      DIFF_BASE="${1#--diff-base=}"
      [[ -n "$DIFF_BASE" ]] || fail "--diff-base requires a ref"
      shift
      ;;
    --json) JSON_MODE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) fail "unknown flag: $1" ;;
    *)
      [[ -z "$REF" ]] || fail "unexpected extra argument: $1"
      REF="$1"
      shift
      ;;
  esac
done

[[ -n "$REF" ]] || { usage; fail "missing required argument: <ref>"; }

set +e
RESOLVED=$(bash "$SCRIPT_DIR/resolve-work-ref.sh" "$REF" 2>&1)
RESOLVE_RC=$?
set -e
if [[ $RESOLVE_RC -ne 0 ]]; then
  printf '%s\n' "$RESOLVED" >&2
  exit "$RESOLVE_RC"
fi

SLUG=$(printf '%s\n' "$RESOLVED" | sed -n '1p')
ARCHIVED=$(printf '%s\n' "$RESOLVED" | sed -n '2p')
KDIR=$(resolve_knowledge_dir)
if [[ "$ARCHIVED" == "true" ]]; then
  ITEM_DIR="$KDIR/_work/_archive/$SLUG"
else
  ITEM_DIR="$KDIR/_work/$SLUG"
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
  || fail "current directory is not inside a git repository"
HEAD_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null) \
  || fail "could not resolve HEAD"

if [[ -n "$DIFF_BASE" ]]; then
  BASE_REF="$DIFF_BASE"
else
  BASE_REF=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [[ -z "$BASE_REF" ]]; then
    for candidate in origin/main main origin/master master; do
      if git -C "$REPO_ROOT" rev-parse --verify --quiet "$candidate^{commit}" >/dev/null; then
        BASE_REF="$candidate"
        break
      fi
    done
  fi
  [[ -n "$BASE_REF" ]] || fail "could not resolve the repository default branch"
fi

BASE_TIP=$(git -C "$REPO_ROOT" rev-parse --verify "$BASE_REF^{commit}" 2>/dev/null) \
  || fail "diff base '$BASE_REF' does not resolve to a commit"
BASE_SHA=$(git -C "$REPO_ROOT" merge-base "$HEAD_SHA" "$BASE_TIP" 2>/dev/null) \
  || fail "could not compute merge-base for '$BASE_REF' and HEAD"

CHANGED_PATHS=$(git -C "$REPO_ROOT" diff --name-only "$BASE_SHA" "$HEAD_SHA")
DIFF_NUMSTAT=$(git -C "$REPO_ROOT" diff --numstat "$BASE_SHA" "$HEAD_SHA")

SEEDS_JSON=$(printf '%s\n' "$CHANGED_PATHS" | python3 -c '
import json, pathlib, sys
seen, seeds = set(), []
for raw in sys.stdin:
    path = raw.strip()
    if not path:
        continue
    parts = pathlib.PurePosixPath(path).parts
    candidates = list(parts) + [pathlib.PurePosixPath(path).name]
    for value in candidates:
        if value and value not in seen:
            seen.add(value)
            seeds.append(value)
print(json.dumps(seeds[:40], ensure_ascii=False))
')

DISCOVERY_JSON=""
DISCOVERY_ERROR=""
if [[ "$SEEDS_JSON" != "[]" ]]; then
  DISCOVERY_ARGS=("$SLUG")
  while IFS= read -r seed; do
    DISCOVERY_ARGS+=(--seed "$seed")
  done < <(printf '%s' "$SEEDS_JSON" | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))')
  DISCOVERY_ARGS+=(--json)
  set +e
  DISCOVERY_JSON=$(bash "$SCRIPT_DIR/spec-discover.sh" "${DISCOVERY_ARGS[@]}" 2>&1)
  DISCOVERY_RC=$?
  set -e
  if [[ $DISCOVERY_RC -ne 0 ]]; then
    DISCOVERY_ERROR="$DISCOVERY_JSON"
    DISCOVERY_JSON=""
  fi
fi

SUMMARY_FILE=$(mktemp)
trap 'rm -f "$SUMMARY_FILE"' EXIT
_LORE_CHANGED_PATHS="$CHANGED_PATHS" \
  _LORE_DIFF_NUMSTAT="$DIFF_NUMSTAT" \
  _LORE_DISCOVERY_JSON="$DISCOVERY_JSON" \
  _LORE_DISCOVERY_ERROR="$DISCOVERY_ERROR" \
  python3 - "$ITEM_DIR" "$SLUG" "$BASE_REF" "$BASE_SHA" "$HEAD_SHA" >"$SUMMARY_FILE" <<'PY'
import datetime
import glob
import json
import os
import pathlib
import re
import sys
import tempfile

item_dir, slug, base_ref, base_sha, head_sha = sys.argv[1:6]
artifact_path = os.path.join(item_dir, "closure-conformance.md")


def coverage(status, reason=None):
    return {"status": status, "reason": reason}


def label_from_target(target):
    value = target.removeprefix("knowledge:").split("#", 1)[0].rstrip("/")
    label = value.rsplit("/", 1)[-1]
    return label[:-3] if label.endswith(".md") else label


def parse_backlinks(text):
    rows, seen = [], set()
    for line in text.splitlines():
        match = re.search(r"\[\[(knowledge:[^\]]+)\]\](?:\s*—\s*(.*))?", line)
        if not match:
            continue
        target = match.group(1).strip()
        label = label_from_target(target)
        if not label or label in seen:
            continue
        seen.add(label)
        rows.append({"label": label, "backlink": target,
                     "annotation": (match.group(2) or "").strip()})
    return rows


plan_path = os.path.join(item_dir, "plan.md")
spec_rows = []
if os.path.isfile(plan_path):
    plan_text = pathlib.Path(plan_path).read_text(encoding="utf-8")
    match = re.search(
        r"(?ms)^\*\*Related preferences/conventions:\*\*\s*$\n"
        r"((?:- .*\n?)*)", plan_text)
    if match:
        spec_rows = parse_backlinks(match.group(1))
        spec_cov = coverage("present" if spec_rows else "present-empty")
    else:
        spec_cov = coverage("absent", "plan.md has no Related preferences/conventions block")
else:
    fallback_files = [os.path.join(item_dir, "notes.md")]
    fallback_files.extend(glob.glob(os.path.join(item_dir, "*brief*.md")))
    fallback_text = []
    for path in fallback_files:
        if os.path.isfile(path):
            fallback_text.append(pathlib.Path(path).read_text(encoding="utf-8"))
    spec_rows = parse_backlinks("\n".join(fallback_text))
    if spec_rows:
        spec_cov = coverage("fallback", "plan.md unavailable; scanned notes and brief files")
    else:
        spec_cov = coverage("absent", "plan.md and brief-cited knowledge entries are unavailable")


tasks_path = os.path.join(item_dir, "tasks.json")
woven_by_label = {}
if os.path.isfile(tasks_path):
    try:
        tasks_data = json.loads(pathlib.Path(tasks_path).read_text(encoding="utf-8"))
        for phase in tasks_data.get("phases", []):
            for task in phase.get("tasks", []):
                task_id = task.get("id")
                for label in task.get("woven_norms") or []:
                    if isinstance(label, str) and label.strip():
                        woven_by_label.setdefault(label.strip(), [])
                        if task_id not in woven_by_label[label.strip()]:
                            woven_by_label[label.strip()].append(task_id)
        woven_cov = coverage("present" if woven_by_label else "present-empty")
    except (OSError, ValueError, TypeError) as exc:
        woven_cov = coverage("absent", f"tasks.json could not be read: {exc}")
else:
    woven_cov = coverage("absent", "tasks.json is unavailable")


dispositions = []
disposition_seen = set()


def add_disposition(label, status, rationale, source):
    label = (label or "").strip().strip("`")
    rationale = (rationale or "").strip()
    if not label:
        return
    key = (label, status, rationale, source)
    if key in disposition_seen:
        return
    disposition_seen.add(key)
    dispositions.append({"label": label, "status": status,
                         "rationale": rationale or None, "source": source})


def parse_disposition_lines(lines, source):
    for line in lines:
        segments = re.split(r";\s*(?=(?:honored|diverged):)", line)
        for segment in segments:
            match = re.match(r"^\s*-?\s*(honored|diverged):\s*(.*)$", segment)
            if not match:
                continue
            parts = re.split(r"\s+[—–-]+\s+", match.group(2).strip(), maxsplit=1)
            add_disposition(parts[0], match.group(1),
                            parts[1] if len(parts) > 1 else "", source)


log_path = os.path.join(item_dir, "execution-log.md")
log_available = os.path.isfile(log_path)
if log_available:
    log_lines = pathlib.Path(log_path).read_text(encoding="utf-8").splitlines()
    for line in log_lines:
        if line.startswith("Convention handling:"):
            match = re.search(r"diverged=(\[.*\])\s*$", line)
            if match:
                try:
                    for row in json.loads(match.group(1)):
                        if isinstance(row, dict):
                            add_disposition(row.get("label"), "diverged",
                                            row.get("rationale"), "execution-log.md")
                except ValueError:
                    pass
        elif line.startswith("Convention:"):
            parse_disposition_lines([line.removeprefix("Convention:").strip()],
                                    "execution-log.md")

report_files = sorted(glob.glob(os.path.join(item_dir, "worker-reports", "*.md")))
for report_path in report_files:
    lines = pathlib.Path(report_path).read_text(encoding="utf-8").splitlines()
    section = []
    active = False
    for line in lines:
        match = re.match(r"^\s*\*\*([^*]+?):\*\*\s*(.*)$", line)
        if match:
            if active:
                break
            active = match.group(1).strip() == "Convention handling"
            if active and match.group(2).strip():
                section.append(match.group(2).strip())
        elif active:
            section.append(line)
    parse_disposition_lines(section, os.path.relpath(report_path, item_dir))

if log_available or report_files:
    disp_cov = coverage("present" if dispositions else "present-empty")
else:
    disp_cov = coverage("absent", "execution-log.md and worker report files are unavailable")


changed_paths = [p for p in os.environ.get("_LORE_CHANGED_PATHS", "").splitlines() if p]
numstat = {}
for line in os.environ.get("_LORE_DIFF_NUMSTAT", "").splitlines():
    parts = line.split("\t", 2)
    if len(parts) == 3:
        added, deleted, path = parts
        numstat[path] = {
            "added": None if added == "-" else int(added),
            "deleted": None if deleted == "-" else int(deleted),
        }
diff_rows = [{"path": path, **numstat.get(path, {"added": 0, "deleted": 0})}
             for path in changed_paths]
diff_cov = coverage("present" if diff_rows else "present-empty")


closure_rows = []
discovery_raw = os.environ.get("_LORE_DISCOVERY_JSON", "")
discovery_error = os.environ.get("_LORE_DISCOVERY_ERROR", "").strip()
if discovery_raw:
    try:
        discovery = json.loads(discovery_raw)
        seen_paths = set()
        for row in discovery.get("candidates", []):
            if row.get("kind") != "knowledge-search":
                continue
            path = row.get("path")
            if not path or path in seen_paths:
                continue
            seen_paths.add(path)
            closure_rows.append({
                "label": pathlib.PurePosixPath(path).stem,
                "path": path,
                "source_rank": row.get("source_rank"),
                "query": row.get("query"),
            })
        close_cov = coverage("present" if closure_rows else "present-empty")
    except ValueError as exc:
        close_cov = coverage("absent", f"closure discovery returned malformed JSON: {exc}")
elif changed_paths:
    close_cov = coverage("absent", discovery_error or "closure discovery failed")
else:
    close_cov = coverage("present-empty", "the diff contains no changed paths to seed discovery")


spec_by_label = {row["label"]: row for row in spec_rows}
close_by_label = {row["label"]: row for row in closure_rows}
disp_by_label = {}
for row in dispositions:
    disp_by_label.setdefault(row["label"], []).append(row)
labels = sorted(set(spec_by_label) | set(woven_by_label) |
                set(disp_by_label) | set(close_by_label))
cross_tab = []
for label in labels:
    cross_tab.append({
        "label": label,
        "surfaced_at_spec": label in spec_by_label,
        "woven_task_ids": woven_by_label.get(label, []),
        "dispositions": disp_by_label.get(label, []),
        "surfaced_at_close": label in close_by_label,
    })

panel_coverage = {
    "spec_discovery": spec_cov,
    "woven_norms": woven_cov,
    "recorded_dispositions": disp_cov,
    "shipped_diff": diff_cov,
    "closure_discovery": close_cov,
}
rendered_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
aggregate = {
    "schema_version": 1,
    "work_item": slug,
    "rendered_at": rendered_at,
    "diff": {"base_ref": base_ref, "base_sha": base_sha,
             "head_sha": head_sha, "files": diff_rows},
    "panel_coverage": panel_coverage,
    "spec_discovery": spec_rows,
    "woven_norms": [{"label": label, "task_ids": task_ids}
                    for label, task_ids in sorted(woven_by_label.items())],
    "recorded_dispositions": dispositions,
    "closure_discovery": closure_rows,
    "cross_tab": cross_tab,
}


def escape(value):
    return str(value).replace("|", "\\|").replace("\n", " ")


def status_line(name, row):
    text = f"- {name}: {row['status']}"
    if row.get("reason"):
        text += f" — {row['reason']}"
    return text


lines = [
    "# Closure Conformance Aggregate",
    "",
    f"Work item: `{slug}`  ",
    f"Rendered: `{rendered_at}`  ",
    f"Diff base: `{base_ref}` (`{base_sha}`)  ",
    f"HEAD: `{head_sha}`",
    "",
    "This artifact presents the available evidence and names missing inputs. "
    "Applicability and conformance remain coordinator judgments.",
    "",
    "## Panel Coverage",
    "",
]
for name, row in panel_coverage.items():
    lines.append(status_line(name.replace("_", " ").title(), row))

lines.extend(["", "## Panel A — Spec-Time Discovery", ""])
if spec_rows:
    for row in spec_rows:
        suffix = f" — {row['annotation']}" if row["annotation"] else ""
        lines.append(f"- `{row['label']}` ({row['backlink']}){suffix}")
else:
    lines.append(f"Absent: {spec_cov.get('reason') or 'no entries were surfaced.'}")

lines.extend(["", "## Panel B — Woven Norms", ""])
if woven_by_label:
    for label, task_ids in sorted(woven_by_label.items()):
        lines.append(f"- `{label}` — tasks: {', '.join(str(v) for v in task_ids)}")
else:
    lines.append(f"Absent: {woven_cov.get('reason') or 'no structured woven norms were recorded.'}")

lines.extend(["", "## Panel C — Recorded Dispositions", ""])
if dispositions:
    for row in dispositions:
        rationale = f" — {row['rationale']}" if row["rationale"] else ""
        lines.append(f"- {row['status']}: `{row['label']}`{rationale} ({row['source']})")
else:
    lines.append(f"Absent: {disp_cov.get('reason') or 'no honored or diverged dispositions were recorded.'}")

lines.extend(["", "## Panel D — Shipped Diff", ""])
if diff_rows:
    lines.extend(["| File | Added | Deleted |", "|---|---:|---:|"])
    for row in diff_rows:
        added = "binary" if row["added"] is None else row["added"]
        deleted = "binary" if row["deleted"] is None else row["deleted"]
        lines.append(f"| `{escape(row['path'])}` | {added} | {deleted} |")
else:
    lines.append("Present, with no committed file changes between the recorded SHAs.")

lines.extend(["", "## Panel E — Closure-Time Diff-Seeded Discovery", ""])
if closure_rows:
    for row in closure_rows:
        lines.append(f"- `{row['label']}` — {row['path']} (rank {row['source_rank']})")
else:
    lines.append(f"Absent: {close_cov.get('reason') or 'the diff-seeded search returned no knowledge entries.'}")

lines.extend([
    "", "## Label Cross-Tabulation", "",
    "| Label | Surfaced at spec | Woven tasks | Recorded dispositions | Surfaced at close |",
    "|---|---|---|---|---|",
])
if cross_tab:
    for row in cross_tab:
        disp = "; ".join(
            f"{d['status']}" + (f": {d['rationale']}" if d.get("rationale") else "")
            for d in row["dispositions"]
        ) or "—"
        tasks = ", ".join(str(v) for v in row["woven_task_ids"]) or "—"
        lines.append(
            f"| `{escape(row['label'])}` | {'yes' if row['surfaced_at_spec'] else 'no'} | "
            f"{escape(tasks)} | {escape(disp)} | {'yes' if row['surfaced_at_close'] else 'no'} |"
        )
else:
    lines.append("| — | no | — | — | no |")

lines.extend([
    "", "## Machine Aggregate", "", "```json",
    json.dumps(aggregate, ensure_ascii=False, indent=2),
    "```", "",
])

os.makedirs(item_dir, exist_ok=True)
fd, temp_path = tempfile.mkstemp(prefix=".closure-conformance.", dir=item_dir, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))
    os.replace(temp_path, artifact_path)
finally:
    if os.path.exists(temp_path):
        os.unlink(temp_path)

summary = {
    "artifact": artifact_path,
    "panel_coverage": panel_coverage,
    "counts": {
        "spec_discovery": len(spec_rows),
        "woven_norms": len(woven_by_label),
        "recorded_dispositions": len(dispositions),
        "changed_files": len(diff_rows),
        "closure_discovery": len(closure_rows),
        "cross_tab_labels": len(cross_tab),
    },
}
print(json.dumps(summary, ensure_ascii=False))
PY
RENDER_SUMMARY=$(<"$SUMMARY_FILE")
rm -f "$SUMMARY_FILE"
trap - EXIT

if [[ $JSON_MODE -eq 1 ]]; then
  printf '%s\n' "$RENDER_SUMMARY"
else
  ARTIFACT=$(printf '%s' "$RENDER_SUMMARY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["artifact"])')
  echo "[conformance] Rendered $ARTIFACT"
fi
