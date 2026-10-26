#!/usr/bin/env python3
"""File a reviewed list of thread preferences into preferences/ and empty the threads.

Conversation threads used to collect working-style notes in each thread's
``_meta.json`` ``accumulated_preferences`` array. Those notes are curated into
a reviewed markdown list (one section per proposed entry, a table quoting the
thread notes each entry replaces, plus ``## Stale`` and
``## Already in preferences/`` tables) that carries an ``**Accepted:**`` line
once a person has read it. This script reads that list against the store:

    migrate-general-bucket.py --kdir <store> --list <list.md> --check
    migrate-general-bucket.py --kdir <store> --list <list.md> --apply --producer-role <seat>

--check reads only. It exits 1, naming each problem, when the ``**Accepted:**``
line is missing or carries no date; when a thread note is missing from the
list, appears in it more than once, or a list row quotes a note no thread
holds; or when a proposed entry has no usable title, context or activities.
Notes are matched by thread and text, with runs of whitespace treated as one
space. Entry numbers may have gaps; an entry struck from the list simply
isn't there.

--apply runs the same check and writes nothing if it fails. Otherwise it files
every proposed entry through capture.sh (the writer behind ``lore capture``):
the heading, without a trailing period, is the title; the ``**Context:**``
line is the body; the ``**Activities:**`` line is passed to ``--activity``
exactly as written, with ``--new-activity`` added only when the entry names an
activity no live entry carries yet. Each filed path is written back into its
entry as a ``- **Filed:**`` line straight away, and an entry that already has
one is skipped, so a run that stops part way can be repeated. When every entry
is filed, each thread whose notes the list placed gets
``"accumulated_preferences": []`` and a ``preferences_migrated`` note naming
the list. A thread that already carries that note is left alone.

--producer-role names the seat running the migration (scripts/seat-registry.json);
it is recorded on each entry so the entry's byline says who filed it.

Exit 2 is a usage error or an unreadable list or store.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
from pk_activities import (  # noqa: E402
    MAX_PER_ENTRY,
    UNTAGGED,
    ActivityError,
    canonical,
    split_value,
    vocabulary,
)

CAPTURE = SCRIPT_DIR / "capture.sh"
SEAT_REGISTRY = SCRIPT_DIR / "seat-registry.json"
PROTOCOL_SLOT = "migrate-general-bucket"
MIGRATED_TO = "preferences/ activity general"
SCALE = "subsystem"

ACCEPTED_RE = re.compile(r"^\*\*Accepted:\*\*[ \t]*(.*?)[ \t]*$")
DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}\b")
H2_RE = re.compile(r"^##\s+(.+?)\s*$")
ENTRY_RE = re.compile(r"^###\s+(\d+)\.\s+(.*?)\s*$")
FIELD_RE = re.compile(r"^- \*\*([^*]+):\*\*[ \t]*(.*?)[ \t]*$")
CELL_SPLIT_RE = re.compile(r"(?<!\\)\|")
PROPOSED_SECTION = "Proposed entries"


def norm(text: str) -> str:
    return " ".join(str(text).split())


@dataclass
class Row:
    thread: str
    text: str
    line: int
    where: str


@dataclass
class Entry:
    number: int
    title: str
    line: int
    fields: dict = field(default_factory=dict)
    rows: list = field(default_factory=list)

    @property
    def filed(self) -> str:
        return self.fields.get("Filed", "")

    @property
    def capture_title(self) -> str:
        title = self.title
        return title[:-1].rstrip() if title.endswith(".") and not title.endswith("..") else title


@dataclass
class BucketList:
    path: Path
    accepted: list
    entries: list
    rows: list


@dataclass
class Thread:
    slug: str
    meta_path: Path
    meta: dict
    raw: str
    notes: list

    @property
    def migrated(self) -> dict | None:
        note = self.meta.get("preferences_migrated")
        return note if isinstance(note, dict) else None


def _cells(line: str) -> list[str]:
    inner = line.strip()
    if inner.startswith("|"):
        inner = inner[1:]
    if inner.endswith("|") and not inner.endswith("\\|"):
        inner = inner[:-1]
    return [c.strip().replace("\\|", "|") for c in CELL_SPLIT_RE.split(inner)]


def _is_separator(line: str) -> bool:
    cells = _cells(line)
    return bool(cells) and all(re.fullmatch(r":?-{3,}:?", c) for c in cells)


def parse_list(path: Path) -> BucketList:
    lines = path.read_text(encoding="utf-8").splitlines()
    accepted, entries, rows = [], [], []
    section = ""
    entry: Entry | None = None
    in_table = False
    i = 0
    while i < len(lines):
        line = lines[i]
        m = ACCEPTED_RE.match(line)
        if m:
            accepted.append((i + 1, m.group(1)))
        h2 = H2_RE.match(line)
        if h2 and not line.startswith("###"):
            section, entry, in_table = h2.group(1), None, False
            i += 1
            continue
        h3 = ENTRY_RE.match(line)
        if h3 and section == PROPOSED_SECTION:
            entry = Entry(int(h3.group(1)), h3.group(2), i + 1)
            entries.append(entry)
            in_table = False
            i += 1
            continue
        if line.startswith("###"):
            entry, in_table = None, False
        if entry is not None and not in_table:
            fm = FIELD_RE.match(line)
            if fm:
                entry.fields[fm.group(1).strip()] = fm.group(2)
        if line.lstrip().startswith("|") and i + 1 < len(lines) and _is_separator(lines[i + 1]):
            header = [c.lower() for c in _cells(line)]
            in_table = len(header) >= 2 and header[0] == "thread" and header[1].startswith("preference")
            i += 2
            continue
        if in_table:
            if not line.lstrip().startswith("|"):
                in_table = False
            else:
                cells = _cells(line)
                if len(cells) >= 2:
                    where = f"entry {entry.number}" if entry is not None else (section or "list")
                    row = Row(cells[0], cells[1], i + 1, where)
                    rows.append(row)
                    if entry is not None:
                        entry.rows.append(row)
        i += 1
    return BucketList(path, accepted, entries, rows)


def load_threads(kdir: Path) -> list[Thread]:
    root = kdir / "_threads"
    threads = []
    if not root.is_dir():
        return threads
    for child in sorted(root.iterdir()):
        meta_path = child / "_meta.json"
        if not child.is_dir() or child.name.startswith((".", "_")) or not meta_path.is_file():
            continue
        raw = meta_path.read_text(encoding="utf-8")
        meta = json.loads(raw)
        notes = []
        for item in meta.get("accumulated_preferences") or []:
            text = item.get("preference") if isinstance(item, dict) else item
            if isinstance(text, str) and text.strip():
                notes.append(text)
        threads.append(Thread(child.name, meta_path, meta, raw, notes))
    return threads


def record_path(kdir: Path, list_path: Path) -> str:
    try:
        return list_path.resolve().relative_to(kdir.resolve()).as_posix()
    except ValueError:
        return str(list_path.resolve())


def _activity_names(value: str) -> tuple[list[str], list[str]]:
    pieces = split_value(value)
    problems, names = [], []
    if not pieces:
        problems.append("names no activity")
    if len(pieces) > MAX_PER_ENTRY:
        problems.append(f"names {len(pieces)} activities; an entry takes at most {MAX_PER_ENTRY}")
    for piece in pieces:
        try:
            name = canonical(piece)
        except ActivityError as exc:
            problems.append(str(exc))
            continue
        if name == UNTAGGED:
            problems.append(f'"{UNTAGGED}" is reserved for live entries with no activity')
        elif name in names:
            problems.append(f'names "{name}" twice')
        else:
            names.append(name)
    return names, problems


@dataclass
class Review:
    problems: list
    threads: list
    pending: list
    migrated: list
    placed: Counter
    new_activities: list


def review(kdir: Path, bucket: BucketList) -> Review:
    problems: list[str] = []
    record = record_path(kdir, bucket.path)

    if not bucket.accepted:
        problems.append("the list has no **Accepted:** line; filing waits for one")
    elif len(bucket.accepted) > 1:
        lines = ", ".join(str(n) for n, _ in bucket.accepted)
        problems.append(f"the list has {len(bucket.accepted)} **Accepted:** lines (lines {lines}); keep one")
    else:
        line_no, value = bucket.accepted[0]
        if not DATE_RE.match(value):
            problems.append(
                f"the **Accepted:** line (line {line_no}) is not filled; write the acceptance date after the label"
            )

    threads = load_threads(kdir)
    by_slug = {t.slug: t for t in threads}
    migrated = [t for t in threads if t.migrated and t.migrated.get("record") == record]
    migrated_slugs = {t.slug for t in migrated}
    pending = [t for t in threads if t.notes and t.slug not in migrated_slugs]

    held = Counter()
    for t in pending:
        for text in t.notes:
            held[(t.slug, norm(text))] += 1
    listed = Counter()
    first_row: dict = {}
    for row in bucket.rows:
        if row.thread in migrated_slugs:
            continue
        key = (row.thread, norm(row.text))
        listed[key] += 1
        first_row.setdefault(key, row)

    for t in pending:
        seen = set()
        for text in t.notes:
            key = (t.slug, norm(text))
            if key in seen:
                continue
            seen.add(key)
            if listed[key] < held[key]:
                problems.append(f'missing from the list: {t.slug}: "{text}"')
    for key, count in listed.items():
        slug, text = key
        row = first_row[key]
        if held[key] == 0:
            reason = "no thread by that name" if slug not in by_slug else "no such note in that thread"
            problems.append(f'line {row.line} ({row.where}): {reason}: {slug}: "{row.text}"')
        elif count > held[key]:
            places = ", ".join(
                f"line {r.line} ({r.where})" for r in bucket.rows if (r.thread, norm(r.text)) == key
            )
            problems.append(f'listed {count} times ({places}): {slug}: "{row.text}"')

    numbers = Counter(e.number for e in bucket.entries)
    for number, count in sorted(numbers.items()):
        if count > 1:
            problems.append(f"entry number {number} is used by {count} entries; each entry needs its own number")

    known = set(vocabulary(str(kdir)))
    new_activities: list[str] = []
    for entry in bucket.entries:
        label = f"entry {entry.number} (line {entry.line})"
        if not entry.capture_title.strip():
            problems.append(f"{label}: has no title")
        if not entry.fields.get("Context", "").strip():
            problems.append(f"{label}: has no **Context:** line to file as its body")
        if "Activities" not in entry.fields:
            problems.append(f"{label}: has no **Activities:** line")
        else:
            names, name_problems = _activity_names(entry.fields["Activities"])
            problems.extend(f"{label}: **Activities:** {p}" for p in name_problems)
            for name in names:
                if name not in known and name not in new_activities:
                    new_activities.append(name)
        if entry.filed and not (kdir / entry.filed).is_file():
            problems.append(f"{label}: **Filed:** names {entry.filed}, which is not in {kdir}")

    placed = Counter()
    for row in bucket.rows:
        if row.thread not in migrated_slugs:
            placed[row.thread] += 1
    return Review(problems, threads, pending, migrated, placed, new_activities)


def summary(bucket: BucketList, rv: Review) -> list[str]:
    total = sum(len(t.notes) for t in rv.pending)
    lines = []
    if rv.pending:
        per_thread = ", ".join(f"{t.slug} {len(t.notes)}" for t in rv.pending)
        lines.append(f"{total} thread notes, each placed once in {bucket.path.name} ({per_thread}).")
    else:
        lines.append("No thread holds notes that this list has not already migrated.")
    in_entries = sum(len(e.rows) for e in bucket.entries)
    lines.append(
        f"{len(bucket.entries)} proposed entries carry {in_entries} notes; "
        f"{len(bucket.rows) - in_entries} notes sit in the other tables."
    )
    filed = [e for e in bucket.entries if e.filed]
    if filed:
        lines.append(f"{len(filed)} entries already filed; {len(bucket.entries) - len(filed)} left to file.")
    if rv.new_activities:
        lines.append("New activity names this list creates: " + ", ".join(rv.new_activities) + ".")
    for t in rv.migrated:
        note = t.migrated or {}
        extra = f"; {len(t.notes)} notes recorded since are not part of this list" if t.notes else ""
        lines.append(f"{t.slug}: already migrated on {note.get('date', '?')}{extra}.")
    return lines


def write_atomic(path: Path, text: str) -> None:
    mode = stat.S_IMODE(path.stat().st_mode)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def write_filed(list_path: Path, entry: Entry, rel: str) -> None:
    """Add a ``- **Filed:**`` line after the entry's last field line."""
    text = list_path.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)
    start = None
    for idx, line in enumerate(lines):
        m = ENTRY_RE.match(line.rstrip("\r\n"))
        if m and int(m.group(1)) == entry.number and m.group(2) == entry.title:
            start = idx
            break
    if start is None:
        raise RuntimeError(f"entry {entry.number} is no longer in {list_path}")
    last_field = None
    for idx in range(start + 1, len(lines)):
        stripped = lines[idx].rstrip("\r\n")
        if stripped.startswith(("#", "|")):
            break
        if FIELD_RE.match(stripped):
            last_field = idx
    at = (last_field if last_field is not None else start) + 1
    newline = "\r\n" if lines[at - 1].endswith("\r\n") else "\n"
    if not lines[at - 1].endswith(("\n", "\r")):
        lines[at - 1] += newline
    lines.insert(at, f"- **Filed:** {rel}{newline}")
    write_atomic(list_path, "".join(lines))


def capture(kdir: Path, entry: Entry, work_item: str | None, producer_role: str, new_activity: bool) -> dict:
    argv = [
        "bash", str(CAPTURE),
        "--category", "preferences",
        "--activity", entry.fields["Activities"],
        "--title", entry.capture_title,
        "--insight", entry.fields["Context"],
        "--scale", SCALE,
        "--kdir", str(kdir),
        "--producer-role", producer_role,
        "--protocol-slot", PROTOCOL_SLOT,
        "--json",
    ]
    if work_item:
        argv += ["--work-item", work_item]
    if new_activity:
        argv.append("--new-activity")
    env = dict(os.environ, LORE_KNOWLEDGE_DIR=str(kdir))
    proc = subprocess.run(argv, capture_output=True, text=True, env=env)
    result = None
    for line in reversed(proc.stdout.splitlines()):
        line = line.strip()
        if line.startswith("{"):
            try:
                candidate = json.loads(line)
            except ValueError:
                continue
            if isinstance(candidate, dict) and candidate.get("path"):
                result = candidate
                break
    if proc.returncode != 0 or result is None:
        detail = (proc.stderr.strip().splitlines() or proc.stdout.strip().splitlines() or ["no output"])[-1]
        raise RuntimeError(f"capture exited {proc.returncode} for entry {entry.number}: {detail}")
    return result


def empty_thread(thread: Thread, record: str, today: str) -> None:
    rebuilt = {}
    for key, value in thread.meta.items():
        if key == "preferences_migrated":
            continue
        if key == "accumulated_preferences":
            rebuilt[key] = []
            rebuilt["preferences_migrated"] = {"to": MIGRATED_TO, "date": today, "record": record}
        else:
            rebuilt[key] = value
    if "preferences_migrated" not in rebuilt:
        rebuilt["accumulated_preferences"] = []
        rebuilt["preferences_migrated"] = {"to": MIGRATED_TO, "date": today, "record": record}
    ascii_only = not any(ord(ch) > 127 for ch in thread.raw)
    text = json.dumps(rebuilt, indent=2, ensure_ascii=ascii_only)
    if thread.raw.endswith("\n"):
        text += "\n"
    write_atomic(thread.meta_path, text)


def work_item_of(kdir: Path, list_path: Path) -> str | None:
    rel = record_path(kdir, list_path)
    parts = Path(rel).parts
    if len(parts) >= 3 and parts[0] == "_work":
        return parts[1]
    return None


def report_problems(problems: list[str]) -> None:
    for problem in problems:
        print(f"refused: {problem}", file=sys.stderr)
    noun = "problem" if len(problems) == 1 else "problems"
    print(f"{len(problems)} {noun} in the list; nothing was written.", file=sys.stderr)


def run_check(kdir: Path, bucket: BucketList) -> int:
    rv = review(kdir, bucket)
    if rv.problems:
        report_problems(rv.problems)
        return 1
    for line in summary(bucket, rv):
        print(line)
    print("The list is ready to file.")
    return 0


def run_apply(kdir: Path, bucket: BucketList, producer_role: str) -> int:
    rv = review(kdir, bucket)
    if rv.problems:
        report_problems(rv.problems)
        return 1
    for line in summary(bucket, rv):
        print(line)

    work_item = work_item_of(kdir, bucket.path)
    known = set(vocabulary(str(kdir)))
    filed_now = 0
    for entry in bucket.entries:
        if entry.filed:
            print(f"entry {entry.number}: already filed at {entry.filed}")
            continue
        names, _ = _activity_names(entry.fields["Activities"])
        new_activity = any(name not in known for name in names)
        try:
            result = capture(kdir, entry, work_item, producer_role, new_activity)
        except RuntimeError as exc:
            print(f"stopped: {exc}", file=sys.stderr)
            print(f"{filed_now} entries filed in this run; threads were not changed.", file=sys.stderr)
            return 1
        known.update(names)
        rel = result["path"]
        write_filed(bucket.path, entry, rel)
        filed_now += 1
        print(f"entry {entry.number}: filed at {rel} (activity: {', '.join(names)})")
        for similar in result.get("similar") or []:
            print(f"  similar entry: {similar.get('path')} (similarity {similar.get('similarity')})")
        if result.get("similar") is None:
            print(f"  similarity check skipped: {result.get('similar_skipped', 'no reason given')}")

    record = record_path(kdir, bucket.path)
    today = date.today().isoformat()
    for thread in rv.pending:
        empty_thread(thread, record, today)
        print(f"{thread.slug}: emptied {len(thread.notes)} notes; preferences_migrated points at {record}")
    print(
        f"{filed_now} entries filed in this run, {len(rv.pending)} threads emptied."
        + (" Settle each similar entry named above." if filed_now else "")
    )
    return 0


def seats() -> set[str]:
    try:
        return set(json.loads(SEAT_REGISTRY.read_text())["seats"])
    except (OSError, ValueError, KeyError, TypeError):
        return set()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="migrate-general-bucket.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--kdir", required=True, help="Knowledge store directory")
    parser.add_argument("--list", dest="list_path", required=True, help="The reviewed list (markdown)")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="Check the list against the threads; write nothing")
    mode.add_argument("--apply", action="store_true", help="File the entries and empty the threads")
    parser.add_argument("--producer-role", help="The seat running --apply, recorded on each filed entry")
    args = parser.parse_args(argv)

    kdir = Path(args.kdir)
    if not kdir.is_dir():
        parser.error(f"no knowledge store at {kdir}")
    list_path = Path(args.list_path)
    if not list_path.is_file():
        parser.error(f"no list at {list_path}")
    if args.apply:
        known_seats = seats()
        if not args.producer_role:
            parser.error("--apply needs --producer-role <seat>: " + ", ".join(sorted(known_seats)))
        if known_seats and args.producer_role not in known_seats:
            parser.error(f'--producer-role "{args.producer_role}" is not a seat: ' + ", ".join(sorted(known_seats)))
    elif args.producer_role:
        parser.error("--producer-role applies to --apply only")

    try:
        bucket = parse_list(list_path)
    except (OSError, UnicodeError) as exc:
        print(f"cannot read {list_path}: {exc}", file=sys.stderr)
        return 2
    try:
        if args.check:
            return run_check(kdir, bucket)
        return run_apply(kdir, bucket, args.producer_role)
    except (OSError, ValueError) as exc:
        print(f"cannot read the store at {kdir}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
