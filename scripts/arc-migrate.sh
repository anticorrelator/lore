#!/usr/bin/env bash
# arc-migrate.sh — give every coordination arc that exists today its own
# directory under _work/_arcs/.
#
# Usage: bash arc-migrate.sh [--commit | --verify] [--json] [--kdir <path>]
#
# A bare run is a preflight: it scans the four places arcs live today, reports
# every record it would create with its derived slug and status, and writes
# nothing at all. --commit performs the migration. --verify checks a completed
# migration against the manifest it recorded.
#
# Nothing under the legacy seats is modified or removed. The migration is
# additive, so the readers that still consume those files keep working until
# they are cut over.
#
# Exit codes: 0 clean, 1 refusal or error, 3 verification found drift.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  lore arc migrate [--commit | --verify] [--json] [--kdir <path>]

Moves every coordination arc that exists today into its own directory under
_work/_arcs/, carrying its ledger, its report, and its history. Source files
stay exactly where they are.

Modes:
  (none)      Preflight. Scans and reports the full plan without writing
              anything. Refuses if any record cannot be named or classified.
  --commit    Perform the migration. Records already migrated are left alone;
              a destination that has diverged from what was recorded is named
              and refused rather than overwritten.
  --verify    Check a completed migration against its manifest. A legacy source
              that has changed since migration is reported as drift (exit 3),
              which is information for the cutover rather than a failure.

Options:
  --json                Emit the result as JSON.
  --kdir <path>         Override the resolved knowledge dir (testing).
  --classify <seat> <report-present> <origin-status> <stub>
                        Print how a record with those characteristics
                        classifies. Read-only; useful when a preflight refusal
                        names a record you did not expect.
  --help, -h            Show this help.
EOF
}

MODE="preflight"
JSON_MODE=0
KDIR_OVERRIDE=""
COMMIT=0
VERIFY=0
CLASSIFY_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --commit) COMMIT=1; shift ;;
    --verify) VERIFY=1; shift ;;
    --json) JSON_MODE=1; shift ;;
    --kdir) KDIR_OVERRIDE="${2:-}"; shift 2 ;;
    --classify)
      if [[ $# -lt 5 ]]; then
        echo "[arc] Error: --classify takes four values: <seat> <report-present> <origin-status> <stub>" >&2
        exit 1
      fi
      MODE="classify"
      CLASSIFY_ARGS=("$2" "$3" "$4" "$5")
      shift 5 ;;
    -h|--help) usage; exit 0 ;;
    --*)
      if [[ $JSON_MODE -eq 1 ]]; then json_error "Unknown option '$1'"; fi
      echo "[arc] Error: unknown option '$1'" >&2; usage; exit 1 ;;
    *)
      if [[ $JSON_MODE -eq 1 ]]; then json_error "'$1' is unexpected — arc migrate takes no positional arguments"; fi
      echo "[arc] Error: '$1' is unexpected — arc migrate takes no positional arguments" >&2
      usage
      exit 1 ;;
  esac
done

if [[ $COMMIT -eq 1 && $VERIFY -eq 1 ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then json_error "--commit and --verify ask for different runs — pass one"; fi
  echo "[arc] Error: --commit and --verify ask for different runs — pass one" >&2
  exit 1
fi
if [[ "$MODE" != "classify" ]]; then
  [[ $COMMIT -eq 1 ]] && MODE="commit"
  [[ $VERIFY -eq 1 ]] && MODE="verify"
fi

if [[ -n "$KDIR_OVERRIDE" ]]; then
  KNOWLEDGE_DIR="$KDIR_OVERRIDE"
else
  KNOWLEDGE_DIR="$(resolve_knowledge_dir)"
fi
if [[ ! -d "$KNOWLEDGE_DIR" ]]; then
  if [[ $JSON_MODE -eq 1 ]]; then json_error "knowledge store not found at: $KNOWLEDGE_DIR"; fi
  echo "[arc] Error: knowledge store not found at: $KNOWLEDGE_DIR" >&2
  exit 1
fi

set +e
ARC_KDIR="$KNOWLEDGE_DIR" \
ARC_MODE="$MODE" \
ARC_JSON="$JSON_MODE" \
ARC_SCRIPT_DIR="$SCRIPT_DIR" \
python3 - "${CLASSIFY_ARGS[@]+"${CLASSIFY_ARGS[@]}"}" <<'PYEOF'
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone

env = os.environ
KDIR = env["ARC_KDIR"]
MODE = env["ARC_MODE"]
JSON_MODE = env["ARC_JSON"] == "1"
SCRIPT_DIR = env["ARC_SCRIPT_DIR"]
WRITE_META = os.path.join(SCRIPT_DIR, "arc-write-meta.sh")

WORK = os.path.join(KDIR, "_work")
PROJECTS = os.path.join(WORK, "_projects")
ARCHIVE = os.path.join(WORK, "_archive")
ARCS = os.path.join(WORK, "_arcs")
MANIFEST = os.path.join(ARCS, "_migration-manifest.json")

MAX_SLUG_LENGTH = 50
SEATS = ("project-home", "ledgers", "active-item", "archived-item")
ORIGIN_STATUSES = ("active", "archived", "none")
TITLE_LABELS = ("Coordination Ledger —", "Coordination Ledger -",
                "Coordination —", "Coordination -", "Coordination:")
POINTER = re.compile(r"→\s*`([^`]+\.md)`")
WORK_BACKLINK = re.compile(r"\[\[work:([a-z0-9][a-z0-9-]*)\]\]")


def out(message):
    if not JSON_MODE:
        print(message)


def rel(path):
    return os.path.relpath(path, KDIR)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def iso_utc(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def mtime_iso(path):
    return iso_utc(os.path.getmtime(path))


def read_text(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def read_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


# --- derivation ------------------------------------------------------------

_slug_cache = {}


def slugify(text):
    """The same slug lib.sh gives `lore arc open`, so both name arcs alike."""
    if text in _slug_cache:
        return _slug_cache[text]
    result = subprocess.run(
        ["bash", "-c", 'source "$1"/lib.sh; slugify "$2"', "_", SCRIPT_DIR, text],
        capture_output=True, text=True)
    value = result.stdout.strip() if result.returncode == 0 else ""
    _slug_cache[text] = value
    return value


def slug_from_stem(stem):
    """A filename or directory stem reduced to slug characters, uncapped words."""
    value = re.sub(r"[^a-z0-9]+", "-", stem.lower()).strip("-")
    return value[:MAX_SLUG_LENGTH].rstrip("-")


def strip_stem(stem, project):
    """Leading project label, then a leading date, then one trailing -arc/-report.

    The suffix strip is anchored at the end and applied once: one stem is
    genuinely `…-arc-close-report-arc`, and another carries `-arc-` mid-string.
    """
    value = stem
    if project and value.startswith(project + "-"):
        value = value[len(project) + 1:]
    dated = re.match(r"^\d{4}-\d{2}-\d{2}-(.*)$", value)
    if dated:
        value = dated.group(1)
    for suffix in ("-arc", "-report"):
        if value.endswith(suffix):
            value = value[: -len(suffix)]
            break
    return value


def ledger_h1(path):
    for line in read_text(path).splitlines():
        match = re.match(r"^#\s+(.*\S)\s*$", line)
        if match:
            return match.group(1)
        if line.startswith("#"):
            return ""
    return ""


def strip_title_label(title):
    for label in TITLE_LABELS:
        if title.startswith(label):
            return title[len(label):].strip()
    return title.strip()


def ledger_anchor(path):
    for line in read_text(path).splitlines():
        if line.startswith("**Intent anchor:**"):
            return line[len("**Intent anchor:**"):].strip()
    return ""


def ledger_cited_items(path):
    """Work items named in the ledger's header block and its Brief section.

    Deliberately narrow: only items the ledger names outright. Folding in every
    item sharing the arc's project label would infer membership from exactly the
    containment this substrate dissolves.
    """
    cited = []
    in_header = True
    in_brief = False
    for line in read_text(path).splitlines():
        if line.startswith("## "):
            in_header = False
            in_brief = line.strip().lower() == "## brief"
            continue
        if in_header or in_brief:
            cited.extend(WORK_BACKLINK.findall(line))
    return cited


def item_exists(slug):
    return (os.path.isdir(os.path.join(WORK, slug))
            or os.path.isdir(os.path.join(ARCHIVE, slug)))


def git_added_iso(path):
    """Author date of the commit that first added the file, following renames."""
    try:
        result = subprocess.run(
            ["git", "-C", KDIR, "log", "--diff-filter=A", "--follow", "--format=%aI",
             "--", rel(path)],
            capture_output=True, text=True)
    except OSError:
        return None
    if result.returncode != 0:
        return None
    stamps = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if not stamps:
        return None
    try:
        parsed = datetime.fromisoformat(stamps[-1])
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def opened_for(path):
    stamp = git_added_iso(path)
    if stamp:
        return stamp, "git"
    return mtime_iso(path), "mtime"


# --- classification --------------------------------------------------------

def classify(seat, report_present, origin_status, is_stub):
    """Which row of the migration's status table a record lands on.

    Rows are evaluated top down and the first match wins. A record matching no
    row is an error to surface, never a case to route somewhere plausible.
    Returns (row, status); row "merge" means the record folds into the record
    it forwards to. (None, None) means nothing matched.
    """
    if is_stub:
        return ("merge", None)
    if seat == "ledgers":
        return ("2", "closed")
    if seat == "archived-item" and origin_status == "archived":
        return ("3", "archived")
    if seat == "active-item" and origin_status == "active":
        return ("4", "closed") if report_present else ("5", "active")
    if seat == "project-home":
        return ("6", "closed") if report_present else ("7", "active")
    return (None, None)


if MODE == "classify":
    seat, report_raw, origin, stub_raw = sys.argv[1:5]
    truthy = {"yes": True, "no": False, "true": True, "false": False, "1": True, "0": False}
    if seat not in SEATS:
        sys.stderr.write("[arc] Error: '%s' is not a seat — use one of %s\n"
                         % (seat, ", ".join(SEATS)))
        sys.exit(1)
    if origin not in ORIGIN_STATUSES:
        sys.stderr.write("[arc] Error: '%s' is not an originating-item status — use one of %s\n"
                         % (origin, ", ".join(ORIGIN_STATUSES)))
        sys.exit(1)
    if report_raw.lower() not in truthy or stub_raw.lower() not in truthy:
        sys.stderr.write("[arc] Error: report-present and stub take yes or no\n")
        sys.exit(1)
    row, status = classify(seat, truthy[report_raw.lower()], origin, truthy[stub_raw.lower()])
    if row is None:
        sys.stderr.write(
            "[arc] Error: no row covers seat=%s report=%s origin=%s stub=%s\n"
            % (seat, report_raw, origin, stub_raw))
        sys.exit(1)
    if JSON_MODE:
        print(json.dumps({"row": row, "status": status}))
    else:
        print("row %s → %s" % (row, status if status else "merged into its target"))
    sys.exit(0)


# --- discovery -------------------------------------------------------------

def item_meta(directory):
    record = read_json(os.path.join(directory, "_meta.json")) or {}
    if not isinstance(record, dict):
        record = {}
    return record


def discover():
    """Every arc across the four seats, plus anything a human has to look at."""
    records = []
    problems = []

    if os.path.isdir(PROJECTS):
        for project in sorted(os.listdir(PROJECTS)):
            home = os.path.join(PROJECTS, project)
            if project.startswith((".", "_")) or not os.path.isdir(home):
                continue
            ledger = os.path.join(home, "coordination.md")
            if os.path.isfile(ledger):
                report = os.path.join(home, "report.md")
                records.append({
                    "seat": "project-home", "ledger": ledger,
                    "report": report if os.path.isfile(report) else None,
                    "project": project, "item": None, "origin": "none",
                })
            filed = os.path.join(home, "_ledgers")
            if os.path.isdir(filed):
                names = sorted(n for n in os.listdir(filed) if n.endswith(".md"))
                paired = {n[: -len("-arc.md")] for n in names if n.endswith("-arc.md")}
                for name in names:
                    if name.endswith("-report.md"):
                        stem = name[: -len("-report.md")]
                        if stem not in paired:
                            problems.append(
                                "%s is a report with no `%s-arc.md` beside it — say which "
                                "arc it belongs to before migrating"
                                % (rel(os.path.join(filed, name)), stem))
                        continue
                    path = os.path.join(filed, name)
                    report = None
                    if name.endswith("-arc.md"):
                        candidate = os.path.join(filed, name[: -len("-arc.md")] + "-report.md")
                        if os.path.isfile(candidate):
                            report = candidate
                    records.append({
                        "seat": "ledgers", "ledger": path, "report": report,
                        "project": project, "item": None, "origin": "none",
                    })

    for seat, root in (("active-item", WORK), ("archived-item", ARCHIVE)):
        if not os.path.isdir(root):
            continue
        for name in sorted(os.listdir(root)):
            directory = os.path.join(root, name)
            if name.startswith((".", "_")) or not os.path.isdir(directory):
                continue
            ledger = os.path.join(directory, "coordination.md")
            if not os.path.isfile(ledger):
                continue
            report = os.path.join(directory, "report.md")
            meta = item_meta(directory)
            if seat == "archived-item":
                origin = "archived"
            else:
                origin = meta.get("status") or "none"
                if origin not in ORIGIN_STATUSES:
                    origin = origin if origin in ("active", "archived") else "none"
            records.append({
                "seat": seat, "ledger": ledger,
                "report": report if os.path.isfile(report) else None,
                "project": (meta.get("project") or None), "item": name, "origin": origin,
            })

    return records, problems


def link_stubs(records, problems):
    """Fold each forwarding stub into the record it points at."""
    by_rel = {rel(r["ledger"]): r for r in records}
    by_base = {}
    for record in records:
        by_base.setdefault(os.path.basename(record["ledger"]), []).append(record)

    for record in records:
        record["forwards_to"] = None
        for match in POINTER.findall(read_text(record["ledger"])):
            candidate = match.strip().lstrip("/")
            target = by_rel.get(candidate)
            if target is None:
                same_name = [r for r in by_base.get(os.path.basename(candidate), [])
                             if r is not record]
                target = same_name[0] if len(same_name) == 1 else None
            if target is not None and target is not record:
                record["forwards_to"] = target
                break

    for record in records:
        target = record["forwards_to"]
        if target is not None and target["forwards_to"] is not None:
            problems.append(
                "%s forwards to %s, which forwards on again — untangle the chain "
                "before migrating"
                % (rel(record["ledger"]), rel(target["ledger"])))
            record["forwards_to"] = None


def derive(record):
    """Slug, title, and the rest of the record's fields, with every fallback named."""
    notes = []
    title = strip_title_label(ledger_h1(record["ledger"]))
    slug = slugify(title) if title else ""
    slug_source = "title"
    if not slug:
        if record["seat"] == "ledgers":
            stem = os.path.basename(record["ledger"])[: -len(".md")]
        else:
            stem = os.path.basename(os.path.dirname(record["ledger"]))
        slug = slug_from_stem(strip_stem(stem, record["project"]))
        slug_source = "stem"

    failure = None
    if not slug:
        failure = ("%s yields no name from either its heading or its filename"
                   % rel(record["ledger"]))

    if slug and slug_source == "title":
        unclipped = subprocess.run(
            ["bash", "-c", 'source "$1"/lib.sh; MAX_SLUG_LENGTH=500; slugify "$2"',
             "_", SCRIPT_DIR, title],
            capture_output=True, text=True).stdout.strip()
        if unclipped and unclipped != slug:
            notes.append("%s: the heading is longer than the name allows, so the name "
                         "is a clipped form of it" % slug)

    if not title:
        title = slug.replace("-", " ")
        title = title[:1].upper() + title[1:]
        notes.append("%s: no usable heading, so the title comes from the name" % slug)

    anchor = ledger_anchor(record["ledger"])
    if not anchor and record["item"]:
        root = WORK if record["seat"] == "active-item" else ARCHIVE
        anchor = item_meta(os.path.join(root, record["item"])).get("intent_anchor") or ""
    if not anchor:
        notes.append("%s: no intent anchor recorded anywhere — left empty" % slug)

    if record["item"]:
        members = [record["item"]]
    else:
        members = [s for s in dict.fromkeys(ledger_cited_items(record["ledger"]))
                   if item_exists(s)]

    opened, opened_source = opened_for(record["ledger"])
    if opened_source == "mtime":
        notes.append("%s: no commit introduces the ledger, so `opened` is its file "
                     "timestamp" % slug)

    return {
        "slug": slug, "slug_source": slug_source, "title": title, "anchor": anchor,
        "project": record["project"], "members": members,
        "opened": opened, "opened_source": opened_source,
    }, notes, failure


def build_plan():
    records, problems = discover()
    link_stubs(records, problems)

    notes = []
    derived = {}
    for record in records:
        fields, record_notes, failure = derive(record)
        # A stub's own derivations feed the merge, not a record of its own, so
        # notes about them would name an arc nobody will find on disk.
        if record["forwards_to"] is None:
            notes.extend(record_notes)
            if failure:
                problems.append(failure)
                continue
        derived[id(record)] = fields

    rows = []
    for record in records:
        fields = derived.get(id(record))
        if fields is None:
            continue
        is_stub = record["forwards_to"] is not None
        row, status = classify(record["seat"], record["report"] is not None,
                               record["origin"], is_stub)
        if row is None:
            problems.append(
                "%s matches no row of the status table (seat %s, report %s, "
                "originating item %s) — classify it by hand before migrating"
                % (rel(record["ledger"]), record["seat"],
                   "present" if record["report"] else "absent", record["origin"]))
            continue
        if row == "merge":
            continue
        rows.append({"record": record, "fields": fields, "row": row, "status": status})

    for row in rows:
        record = row["record"]
        fields = row["fields"]
        sources = [record["ledger"]]
        documents = {"coordination.md": record["ledger"]}
        if record["report"]:
            sources.append(record["report"])
            documents["report.md"] = record["report"]

        for other in records:
            if other["forwards_to"] is not record:
                continue
            stub_fields = derived.get(id(other))
            if stub_fields is None:
                continue
            sources.append(other["ledger"])
            origin = other["item"] or os.path.basename(other["ledger"])[: -len(".md")]
            documents["forwarded-from-%s.md" % origin] = other["ledger"]
            if stub_fields["opened"] < fields["opened"]:
                fields["opened"] = stub_fields["opened"]
                fields["opened_source"] = stub_fields["opened_source"]
            fields["members"] = sorted(set(fields["members"]) | set(stub_fields["members"]))
            notes.append("%s: merged with the forwarding stub at %s"
                         % (fields["slug"], rel(other["ledger"])))

        if not fields["members"]:
            notes.append("%s: no members could be read from the ledger — add them with "
                         "`lore arc member add`" % fields["slug"])

        if row["status"] == "active":
            closed_at = None
        elif record["report"]:
            closed_at = mtime_iso(record["report"])
        else:
            closed_at = mtime_iso(record["ledger"])

        row["sources"] = sources
        row["documents"] = documents
        row["closed_at"] = closed_at
        row["destination"] = os.path.join(ARCS, fields["slug"])

    seen = {}
    for row in rows:
        seen.setdefault(row["fields"]["slug"], []).append(row)
    for slug, colliding in sorted(seen.items()):
        if len(colliding) > 1:
            problems.append(
                "%s of these want the name '%s': %s — give them distinguishing "
                "headings before migrating"
                % (len(colliding), slug,
                   ", ".join(rel(r["record"]["ledger"]) for r in colliding)))

    rows.sort(key=lambda r: r["fields"]["slug"])
    return rows, problems, notes


# --- manifest --------------------------------------------------------------

def load_manifest():
    data = read_json(MANIFEST)
    if not isinstance(data, dict) or not isinstance(data.get("rows"), list):
        return {"schema_version": 1, "rows": []}
    return data


def save_manifest(manifest):
    os.makedirs(ARCS, exist_ok=True)
    temp = MANIFEST + ".tmp.%d" % os.getpid()
    with open(temp, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(manifest, indent=2) + "\n")
    os.replace(temp, MANIFEST)


def manifest_row(manifest, slug):
    for row in manifest["rows"]:
        if row.get("slug") == slug:
            return row
    return None


def artifacts_match(directory, recorded):
    for name, digest in recorded.items():
        path = os.path.join(directory, name)
        if not os.path.isfile(path) or sha256_file(path) != digest:
            return False
    return True


def identity_matches(directory, recorded):
    meta = read_json(os.path.join(directory, "_meta.json"))
    if not isinstance(meta, dict):
        return False
    return all(meta.get(key) == value for key, value in recorded.items())


# --- commit ----------------------------------------------------------------

def write_meta_import(row, record_dir):
    fields = row["fields"]
    args = [WRITE_META, "--kdir", KDIR, "--slug", fields["slug"], "--op", "import",
            "--record-dir", record_dir, "--title", fields["title"],
            "--anchor", fields["anchor"], "--status", row["status"],
            "--opened", fields["opened"]]
    if fields["project"]:
        args += ["--project", fields["project"]]
    if row["closed_at"]:
        args += ["--closed-at", row["closed_at"]]
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        return result.stderr.strip() or "the record could not be written"
    return None


def apply_members(slug, members):
    for member in members:
        result = subprocess.run(
            [WRITE_META, "--kdir", KDIR, "--slug", slug, "--op", "member-add",
             "--member", member],
            capture_output=True, text=True)
        if result.returncode != 0:
            return result.stderr.strip() or "member '%s' could not be added" % member
    return None


def stage_record(row, staging):
    """Build the record's whole directory off to the side, then hand back its hashes."""
    if os.path.exists(staging):
        shutil.rmtree(staging)
    os.makedirs(staging)
    for name, source in row["documents"].items():
        shutil.copyfile(source, os.path.join(staging, name))
    failure = write_meta_import(row, staging)
    if failure:
        shutil.rmtree(staging, ignore_errors=True)
        return None, failure
    return {name: sha256_file(os.path.join(staging, name))
            for name in row["documents"]}, None


def commit(rows):
    os.makedirs(ARCS, exist_ok=True)
    manifest = load_manifest()
    migrated, skipped, failures = [], [], []

    for row in rows:
        slug = row["fields"]["slug"]
        destination = row["destination"]
        staging = os.path.join(ARCS, ".staging-%s" % slug)
        recorded = manifest_row(manifest, slug)

        if os.path.isdir(destination):
            if recorded is None:
                failures.append("%s already exists and this migration did not write it "
                                "— move it aside or remove it" % rel(destination))
                continue
            if not artifacts_match(destination, recorded["artifacts"]):
                failures.append("%s has changed since it was migrated — refusing to "
                                "overwrite it" % rel(destination))
                continue
            if not identity_matches(destination, recorded["identity"]):
                failures.append("%s carries a record that no longer matches what was "
                                "imported — refusing to overwrite it" % rel(destination))
                continue
            if not recorded.get("members_applied"):
                failure = apply_members(slug, recorded.get("members") or [])
                if failure:
                    failures.append("%s: %s" % (slug, failure))
                    continue
                recorded["members_applied"] = True
                save_manifest(manifest)
            skipped.append(slug)
            continue

        artifacts, failure = stage_record(row, staging)
        if failure:
            failures.append("%s: %s" % (slug, failure))
            continue

        if recorded is not None:
            # A row with no destination is an interrupted commit. The row says what
            # the destination should hash to; anything else needs a human.
            if recorded["artifacts"] != artifacts:
                shutil.rmtree(staging, ignore_errors=True)
                failures.append("%s was recorded with different content than it now "
                                "derives — resolve the difference before re-running" % slug)
                continue
            manifest["rows"] = [r for r in manifest["rows"] if r.get("slug") != slug]

        identity = {"schema_version": 1, "slug": slug, "opened": row["fields"]["opened"]}
        manifest["rows"].append({
            "slug": slug,
            "status": row["status"],
            "classification_row": row["row"],
            "destination": rel(destination),
            "sources": [{"path": rel(p), "sha256": sha256_file(p)} for p in row["sources"]],
            "artifacts": artifacts,
            "identity": identity,
            "opened_source": row["fields"]["opened_source"],
            "members": row["fields"]["members"],
            "members_applied": False,
        })
        manifest["rows"].sort(key=lambda r: r["slug"])
        save_manifest(manifest)

        os.rename(staging, destination)

        failure = apply_members(slug, row["fields"]["members"])
        if failure:
            failures.append("%s: %s" % (slug, failure))
            continue
        manifest_row(manifest, slug)["members_applied"] = True
        save_manifest(manifest)
        migrated.append(slug)

    return migrated, skipped, failures


# --- verify ----------------------------------------------------------------

def verify():
    if not os.path.isfile(MANIFEST):
        return None, None, ["no migration manifest at %s — nothing has been migrated yet"
                            % rel(MANIFEST)]
    manifest = load_manifest()
    drift, failures = [], []

    for row in manifest["rows"]:
        slug = row.get("slug", "(unnamed)")
        destination = os.path.join(KDIR, row.get("destination", ""))
        if not os.path.isdir(destination):
            failures.append("%s: %s is gone" % (slug, row.get("destination")))
            continue
        meta_path = os.path.join(destination, "_meta.json")
        meta = read_json(meta_path)
        if not isinstance(meta, dict):
            failures.append("%s: the record at %s is missing or unreadable"
                            % (slug, rel(meta_path)))
            continue
        for key, value in row.get("identity", {}).items():
            if meta.get(key) != value:
                failures.append("%s: %s reads '%s' but was imported as '%s'"
                                % (slug, key, meta.get(key), value))
        for name, digest in (row.get("artifacts") or {}).items():
            path = os.path.join(destination, name)
            if not os.path.isfile(path):
                failures.append("%s: %s is gone" % (slug, name))
            elif sha256_file(path) != digest:
                failures.append("%s: %s has changed since it was migrated" % (slug, name))
        for source in row.get("sources") or []:
            path = os.path.join(KDIR, source.get("path", ""))
            if not os.path.isfile(path):
                drift.append("%s: the legacy source %s is gone" % (slug, source.get("path")))
            elif sha256_file(path) != source.get("sha256"):
                drift.append("%s: the legacy source %s has changed since migration"
                             % (slug, source.get("path")))

    return len(manifest["rows"]), drift, failures


# --- reporting -------------------------------------------------------------

def plan_json(rows):
    return [{
        "slug": r["fields"]["slug"],
        "title": r["fields"]["title"],
        "status": r["status"],
        "classification_row": r["row"],
        "seat": r["record"]["seat"],
        "slug_source": r["fields"]["slug_source"],
        "project": r["fields"]["project"],
        "members": r["fields"]["members"],
        "opened": r["fields"]["opened"],
        "opened_source": r["fields"]["opened_source"],
        "closed_at": r["closed_at"],
        "sources": [rel(p) for p in r["sources"]],
        "destination": rel(r["destination"]),
    } for r in rows]


if MODE == "verify":
    checked, drift, failures = verify()
    if JSON_MODE:
        print(json.dumps({"mode": "verify", "checked": checked or 0,
                          "drift": drift or [], "failures": failures}, indent=2))
    else:
        if failures:
            for line in failures:
                sys.stderr.write("[arc] Error: %s\n" % line)
        if drift:
            for line in drift:
                sys.stderr.write("[arc] Drift: %s\n" % line)
        if checked is not None:
            out("[arc] Verified %d migrated arc%s." % (checked, "" if checked == 1 else "s"))
    if failures:
        sys.exit(1)
    sys.exit(3 if drift else 0)


rows, problems, notes = build_plan()

if MODE == "preflight":
    if JSON_MODE:
        print(json.dumps({"mode": "preflight", "records": plan_json(rows),
                          "notes": notes, "refusals": problems}, indent=2))
    else:
        out("[arc] %d arc%s to migrate." % (len(rows), "" if len(rows) == 1 else "s"))
        for row in rows:
            out("  %-50s %-8s row %s  %s"
                % (row["fields"]["slug"], row["status"], row["row"],
                   rel(row["record"]["ledger"])))
        if notes:
            out("")
            out("Worth knowing:")
            for note in notes:
                out("  - %s" % note)
        for line in problems:
            sys.stderr.write("[arc] Error: %s\n" % line)
    sys.exit(1 if problems else 0)

if problems:
    if JSON_MODE:
        print(json.dumps({"mode": "commit", "migrated": [], "skipped": [],
                          "failures": problems}, indent=2))
    else:
        for line in problems:
            sys.stderr.write("[arc] Error: %s\n" % line)
        sys.stderr.write("[arc] Error: nothing was written — resolve the above and re-run.\n")
    sys.exit(1)

migrated, skipped, failures = commit(rows)
if JSON_MODE:
    print(json.dumps({"mode": "commit", "migrated": migrated, "skipped": skipped,
                      "failures": failures}, indent=2))
else:
    out("[arc] Migrated %d arc%s; %d already in place."
        % (len(migrated), "" if len(migrated) == 1 else "s", len(skipped)))
    for line in failures:
        sys.stderr.write("[arc] Error: %s\n" % line)
sys.exit(1 if failures else 0)
PYEOF
RC=$?
set -e
exit $RC
