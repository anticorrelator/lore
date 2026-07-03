#!/usr/bin/env bash
# merge-work-stub.sh — Merge an active settlement-residue stub into its archive sibling
# Usage: bash merge-work-stub.sh [--check] <slug>
#
# Archive-residue repair tool, not a general work-item merge: it operates only
# when _work/<slug>/ is a stub (no _meta.json, or one matching the heal
# scaffold fingerprint) coexisting with _work/_archive/<slug>/. It relocates
# rows and files verbatim — it never authors or rewrites row content:
#   - JSONL files: append rows absent from the archive copy, deduped by
#     natural id (reattempt_id; judge_run_at+artifact_id for verdict
#     envelopes; candidate_id / attempt_id / claim_id for queue and commons
#     rows; exact line otherwise), so re-running the merge is a no-op
#   - heal-scaffolded _meta.json / notes.md: discarded by template fingerprint
#     (empty project, created == updated, empty intent_anchor)
#   - any other file: moved, erroring on basename collision with differing
#     content — no mutation happens when a collision is detected
# Then removes the emptied stub dir and regenerates the work index.
#
# --check: report eligibility without mutating. Exit 0 = eligible, 2 = the
# active dir is a real work item (not residue), 1 = shape error (missing dir,
# underscore slug). heal-work.sh probes this before routing an orphan here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

CHECK_ONLY=false
SLUG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK_ONLY=true
      shift
      ;;
    *)
      if [[ -z "$SLUG" ]]; then
        SLUG="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$SLUG" ]]; then
  echo "[work] Error: Missing required argument: slug" >&2
  echo "Usage: bash merge-work-stub.sh [--check] <slug>" >&2
  exit 1
fi

if [[ "$SLUG" == _* ]]; then
  echo "[work] Error: '$SLUG' is not a work item slug" >&2
  exit 1
fi

KNOWLEDGE_DIR=$(resolve_knowledge_dir)
WORK_DIR="$KNOWLEDGE_DIR/_work"
ACTIVE_DIR="$WORK_DIR/$SLUG"
ARCHIVE_DIR="$WORK_DIR/_archive/$SLUG"

if [[ ! -d "$ACTIVE_DIR" ]]; then
  echo "[work] Error: No active directory at _work/$SLUG" >&2
  exit 1
fi

if [[ ! -d "$ARCHIVE_DIR" ]]; then
  echo "[work] Error: No archive sibling at _work/_archive/$SLUG — nothing to merge into" >&2
  exit 1
fi

python3 - "$ACTIVE_DIR" "$ARCHIVE_DIR" "$SLUG" "$CHECK_ONLY" << 'PYEOF'
import json, os, shutil, sys

active_dir, archive_dir, slug, check_only = sys.argv[1:5]
check_only = check_only == "true"

NOTES_TEMPLATE = (
    "# Session Notes: {title}\n"
    "\n"
    "<!-- Append session entries below. Entry format: ## YYYY-MM-DDTHH:MM"
    " followed by **Focus:**, **Progress:**, **Next:** fields. -->\n"
)


def title_from_slug(s):
    return " ".join(w[:1].upper() + w[1:] for w in s.split("-"))


def meta_is_scaffold(path):
    """Heal/create scaffold fingerprint: empty project, created == updated,
    empty intent_anchor. Unparseable or real metadata is not a scaffold."""
    try:
        with open(path) as f:
            meta = json.load(f)
    except (json.JSONDecodeError, OSError):
        return False, None
    if not isinstance(meta, dict):
        return False, None
    is_scaffold = (
        meta.get("project", "") == ""
        and meta.get("intent_anchor", "") == ""
        and meta.get("created") == meta.get("updated")
    )
    return is_scaffold, meta.get("title")


def notes_is_scaffold(path, titles):
    try:
        with open(path) as f:
            content = f.read()
    except OSError:
        return False
    return any(content == NOTES_TEMPLATE.format(title=t) for t in titles if t)


def row_key(rel_path, line):
    """Deterministic natural key for a JSONL row. Path-shaped: files under
    verdicts/ are judge envelopes keyed by run time + artifact; root files
    key by their id field. Unparseable rows fall back to exact-line identity."""
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        return ("line", line)
    if not isinstance(row, dict):
        return ("line", line)

    def field_key(*names):
        vals = [row.get(n) for n in names]
        if all(v is not None for v in vals):
            return (rel_path,) + tuple(vals)
        return ("line", line)

    if rel_path.startswith("verdicts/") or rel_path.startswith("verdicts" + os.sep):
        return field_key("judge_run_at", "artifact_id")
    base = os.path.basename(rel_path)
    if base == "audit-reattempts.jsonl":
        return field_key("reattempt_id")
    if base == "audit-candidates.jsonl":
        return field_key("candidate_id")
    if base == "audit-attempts.jsonl":
        return field_key("attempt_id")
    if base in ("promoted-commons.jsonl", "task-claims.jsonl"):
        return field_key("claim_id")
    return ("line", line)


def read_rows(path):
    with open(path) as f:
        return [ln.rstrip("\n") for ln in f if ln.strip()]


# --- Eligibility: the active dir must be residue, not a real item ---
meta_path = os.path.join(active_dir, "_meta.json")
meta_title = None
if os.path.exists(meta_path):
    is_scaffold, meta_title = meta_is_scaffold(meta_path)
    if not is_scaffold:
        print(f"[work] Error: _work/{slug}/_meta.json is not a heal scaffold — "
              f"refusing to merge a real work item into its archive", file=sys.stderr)
        sys.exit(2)

if check_only:
    print(f"[merge] _work/{slug} is mergeable residue (archive sibling present)")
    sys.exit(0)

titles = [meta_title, title_from_slug(slug)]

# --- Plan pass: classify every stub file; abort before mutating on collision ---
discards, jsonl_merges, moves, errors = [], [], [], []
for root, _dirs, files in os.walk(active_dir):
    for name in sorted(files):
        src = os.path.join(root, name)
        rel = os.path.relpath(src, active_dir)
        dst = os.path.join(archive_dir, rel)
        if rel == "_meta.json":
            discards.append(rel)  # scaffold — validated above
        elif rel == "notes.md" and notes_is_scaffold(src, titles):
            discards.append(rel)
        elif name.endswith(".jsonl"):
            jsonl_merges.append(rel)
        elif not os.path.exists(dst):
            moves.append(rel)
        else:
            with open(src, "rb") as f1, open(dst, "rb") as f2:
                if f1.read() == f2.read():
                    discards.append(rel)
                else:
                    errors.append(rel)

if errors:
    for rel in errors:
        print(f"[work] Error: '{rel}' exists in both _work/{slug} and its archive "
              f"with differing content — resolve manually; nothing was merged", file=sys.stderr)
    sys.exit(1)

# --- Execute pass ---
print(f"=== Work Stub Merge: {slug} ===")
for rel in jsonl_merges:
    src = os.path.join(active_dir, rel)
    dst = os.path.join(archive_dir, rel)
    existing = set()
    if os.path.exists(dst):
        existing = {row_key(rel, ln) for ln in read_rows(dst)}
    new_rows = []
    duplicates = 0
    for ln in read_rows(src):
        if row_key(rel, ln) in existing:
            duplicates += 1
        else:
            new_rows.append(ln)
    if new_rows:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        needs_newline = (
            os.path.exists(dst)
            and os.path.getsize(dst) > 0
            and open(dst, "rb").read()[-1:] != b"\n"
        )
        with open(dst, "a") as f:
            if needs_newline:
                f.write("\n")
            for ln in new_rows:
                f.write(ln + "\n")
    os.remove(src)
    print(f"[merge] {rel}: +{len(new_rows)} rows ({duplicates} duplicates skipped)")

for rel in moves:
    src = os.path.join(active_dir, rel)
    dst = os.path.join(archive_dir, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.move(src, dst)
    print(f"[merge] {rel}: moved to archive")

for rel in discards:
    os.remove(os.path.join(active_dir, rel))
    print(f"[merge] {rel}: discarded (scaffold or identical archive copy)")

# Remove the emptied stub tree; anything left behind is a bug, not cleanup.
for root, dirs, files in os.walk(active_dir, topdown=False):
    if files:
        print(f"[work] Error: unexpected leftover files in {root} after merge", file=sys.stderr)
        sys.exit(1)
    os.rmdir(root)
print(f"[merge] removed stub directory _work/{slug}")
PYEOF

if [[ "$CHECK_ONLY" == true ]]; then
  exit 0
fi

bash "$SCRIPT_DIR/update-work-index.sh" >/dev/null
echo "[merge] work index regenerated"
