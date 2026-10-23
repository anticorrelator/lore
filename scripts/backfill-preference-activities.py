#!/usr/bin/env python3
"""File a store's existing preferences/ entries under the activities they govern.

preferences/ holds the project's accumulated working style. Each entry names
the activity it governs in its metadata footer (``activity: <a>`` or
``activity: <a>, <b>``); entries written before that field existed carry
none, and many carry a title cut off mid-sentence. This pass applies a
reviewed mapping to such a store:

    backfill-preference-activities.py <kdir> --map <map.json>          # dry run
    backfill-preference-activities.py <kdir> --map <map.json> --apply  # write
    backfill-preference-activities.py <kdir> --check

The map is a JSON object whose ``entries`` list has one object per entry:

    {"path": "preferences/<slug>.md",
     "activities": ["<a>"] or ["<a>", "<b>"],
     "title": "<new H1, one line>",            # optional
     "current_title": "<H1 the map was written against>"}  # optional

The dry run reports, per entry, what --apply would change. --apply replaces the
H1 text where the map gives a title and appends ``| activity: ...`` to the end
of the footer; nothing else in the file moves. An entry already in the mapped
state is left as it is, so a second --apply changes nothing.

The whole map is checked before anything is written, and one problem anywhere
means no file is touched. Refused: a path that is not a preferences/ entry in
the store, a retired entry, a path named twice, an activity name outside
[a-z0-9-]+, more than two names, an entry whose footer already carries a
different activity, a title that is not one line, and (when current_title is
given) an H1 that matches neither current_title nor title.

--check reads only the store. It exits 1 and names every live preferences/
entry that carries no activity, and exits 0 when every live entry carries one.
Exit 2 is a usage or unreadable-input error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pk_activities import (  # noqa: E402
    CATEGORY,
    MAX_PER_ENTRY,
    UNTAGGED,
    footer_value,
    live_entries,
    read_entry,
    split_value,
)
from pk_markdown import MarkdownParser  # noqa: E402
from pk_search import DEFAULT_STATUS_FILTER  # noqa: E402

NAME_RE = re.compile(r"[a-z0-9-]+")
H1_RE = re.compile(r"^#\s+(.+)$", re.MULTILINE)
FOOTER_RE = re.compile(r"<!--(.*?)-->", re.DOTALL)
ACTIVITY_KEY_RE = re.compile(r"(?:^|\|)\s*activity:")
MAP_KEYS = {"path", "activities", "title", "current_title"}


class MapError(Exception):
    """The map file cannot be read at all; reported as a usage error."""


@dataclass
class Plan:
    path: str
    old_title: str
    new_title: str | None
    activities: list[str]
    add_activity: bool
    new_text: str

    @property
    def changed(self) -> bool:
        return self.new_title is not None or self.add_activity


def load_map(map_path: str) -> list:
    try:
        with open(map_path, encoding="utf-8") as handle:
            data = json.load(handle)
    except OSError as exc:
        raise MapError(f"cannot read map {map_path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise MapError(f"map {map_path} is not valid JSON: {exc}") from exc
    if not isinstance(data, dict) or not isinstance(data.get("entries"), list):
        raise MapError(f'map {map_path} must be a JSON object with an "entries" list')
    return data["entries"]


def _entry_file(kdir: Path, rel: str) -> Path | None:
    """The file for a map path when it names a preferences/ entry in the store."""
    parts = Path(rel).parts
    if (
        Path(rel).is_absolute()
        or len(parts) < 2
        or parts[0] != CATEGORY
        or ".." in parts
        or any(p.startswith((".", "_")) for p in parts)
        or not rel.endswith(".md")
        or parts[-1] == "README.md"
    ):
        return None
    path = kdir / rel
    root = (kdir / CATEGORY).resolve()
    if not path.is_file() or root not in path.resolve().parents:
        return None
    return path


def _activities(value) -> tuple[list[str], list[str]]:
    """Validated names from a map row, and the problems found in them."""
    if isinstance(value, str):
        raw = split_value(value)
    elif isinstance(value, list) and all(isinstance(v, str) for v in value):
        raw = list(value)
    else:
        return [], ['"activities" must be a list of names']
    problems = []
    if not raw:
        problems.append("no activities given")
    if len(raw) > MAX_PER_ENTRY:
        problems.append(f"{len(raw)} activities given; an entry takes at most {MAX_PER_ENTRY}")
    names = []
    for name in raw:
        if not NAME_RE.fullmatch(name):
            problems.append(f'activity name "{name}" is outside [a-z0-9-]+')
        elif name == UNTAGGED:
            problems.append(f'"{UNTAGGED}" is reserved for live entries with no activity')
        elif name in names:
            problems.append(f'activity "{name}" is named twice')
        else:
            names.append(name)
    return names, problems


def _footer(text: str) -> re.Match | None:
    for m in FOOTER_RE.finditer(text):
        if "learned:" in m.group(1):
            return m
    return None


def _h1(text: str) -> re.Match | None:
    front = MarkdownParser._FRONTMATTER_RE.match(text)
    return H1_RE.search(text, front.end() if front else 0)


def plan_entry(kdir: Path, row) -> tuple[Plan | None, list[str]]:
    if not isinstance(row, dict):
        return None, ["map row is not an object"]
    rel = row.get("path")
    if not isinstance(rel, str) or not rel:
        return None, ['map row has no "path"']
    unknown = sorted(set(row) - MAP_KEYS)
    if unknown:
        return None, [f"{rel}: unknown map field(s) {', '.join(unknown)}"]
    path = _entry_file(kdir, rel)
    if path is None:
        return None, [f"{rel}: not a {CATEGORY}/ entry in {kdir}"]

    problems = []
    names, name_problems = _activities(row.get("activities"))
    problems += [f"{rel}: {p}" for p in name_problems]

    with open(path, encoding="utf-8", newline="") as handle:
        text = handle.read()
    entry = read_entry(str(kdir), path)
    if entry["status"] not in DEFAULT_STATUS_FILTER:
        problems.append(f"{rel}: status is {entry['status']}; only live entries are filed under an activity")

    footer = _footer(text)
    add_activity = False
    if footer is None:
        problems.append(f"{rel}: has no metadata footer to carry the activity")
    elif ACTIVITY_KEY_RE.search(footer.group(1)):
        raw = MarkdownParser._extract_metadata(text).get("activity") or ""
        existing = split_value(raw)
        if not names or sorted(existing) != sorted(names):
            problems.append(
                f'{rel}: already carries "activity: {raw.strip()}"; the map gives "{footer_value(names)}"'
            )
    else:
        add_activity = True

    h1 = _h1(text)
    old_title = h1.group(1).strip() if h1 else ""
    new_title = None
    title = row.get("title")
    if title is not None:
        current = row.get("current_title")
        if not isinstance(title, str) or not title.strip() or "\n" in title or "\r" in title:
            problems.append(f"{rel}: title must be one non-empty line")
        elif title != title.strip():
            problems.append(f"{rel}: title has leading or trailing whitespace")
        elif h1 is None:
            problems.append(f"{rel}: has no H1 to retitle")
        elif old_title != title:
            if isinstance(current, str) and old_title != current:
                problems.append(
                    f'{rel}: H1 is "{old_title}", which matches neither the map\'s current_title nor its title'
                )
            else:
                new_title = title

    if problems:
        return None, problems

    new_text = text
    if new_title is not None and h1 is not None:
        new_text = new_text[: h1.start(1)] + new_title + new_text[h1.end(1):]
    footer = _footer(new_text) if add_activity else None
    if footer is not None:
        inner = footer.group(1)
        kept = inner.rstrip()
        inner = f"{kept} | activity: {footer_value(names)}{inner[len(kept):]}"
        new_text = new_text[: footer.start(1)] + inner + new_text[footer.end(1):]
    return Plan(rel, old_title, new_title, names, add_activity, new_text), []


def plan_map(kdir: Path, rows: list) -> tuple[list[Plan], list[str]]:
    plans, problems, seen = [], [], set()
    for row in rows:
        rel = row.get("path") if isinstance(row, dict) else None
        if isinstance(rel, str) and rel in seen:
            problems.append(f"{rel}: named more than once in the map")
            continue
        if isinstance(rel, str):
            seen.add(rel)
        plan, row_problems = plan_entry(kdir, row)
        problems += row_problems
        if plan is not None:
            plans.append(plan)
    return plans, problems


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


def untagged(kdir: Path) -> list[dict]:
    return [e for e in live_entries(str(kdir)) if not e["activities"]]


def describe(plan: Plan, verb: str) -> str:
    if not plan.changed:
        return f"{plan.path}: unchanged (activity: {footer_value(plan.activities)})"
    lines = [f"{plan.path}: {verb}"]
    if plan.new_title is not None:
        lines.append(f"  title:    {plan.old_title}")
        lines.append(f"         -> {plan.new_title}")
    if plan.add_activity:
        lines.append(f"  activity: {footer_value(plan.activities)}")
    return "\n".join(lines)


def run_map(kdir: Path, map_path: str, apply: bool) -> int:
    try:
        rows = load_map(map_path)
    except MapError as exc:
        print(exc, file=sys.stderr)
        return 2
    plans, problems = plan_map(kdir, rows)
    if problems:
        for problem in problems:
            print(f"refused: {problem}", file=sys.stderr)
        noun = "problem" if len(problems) == 1 else "problems"
        print(f"{len(problems)} {noun} in the map; nothing was written.", file=sys.stderr)
        return 1

    verb = "changed" if apply else "would change"
    for plan in plans:
        if apply and plan.changed:
            try:
                write_atomic(kdir / plan.path, plan.new_text)
            except OSError as exc:
                print(f"cannot write {plan.path}: {exc}; entries listed above were written", file=sys.stderr)
                return 2
        print(describe(plan, verb))

    changed = [p for p in plans if p.changed]
    titles = sum(1 for p in changed if p.new_title is not None)
    fields = sum(1 for p in changed if p.add_activity)
    print()
    print(
        f"{len(plans)} entries in the map: {len(changed)} {verb} "
        f"({titles} titles, {fields} activity fields), {len(plans) - len(changed)} unchanged."
    )
    mapped = {p.path for p in plans}
    missed = [e for e in untagged(kdir) if e["path"] not in mapped]
    if missed:
        print(f"Live {CATEGORY}/ entries the map does not name, which carry no activity ({len(missed)}):")
        for entry in missed:
            print(f"  {entry['path']}  {entry['title']}")
    else:
        print(f"No live {CATEGORY}/ entry outside the map is left without an activity.")
    if not apply:
        print("Dry run: nothing was written. Re-run with --apply to write these changes.")
    return 0


def run_check(kdir: Path) -> int:
    live = live_entries(str(kdir))
    missing = [e for e in live if not e["activities"]]
    if missing:
        noun = "entry carries" if len(missing) == 1 else "entries carry"
        print(f"{len(missing)} live {CATEGORY}/ {noun} no activity:")
        for entry in missing:
            print(f"  {entry['path']}  {entry['title']}")
        return 1
    print(f"All {len(live)} live {CATEGORY}/ entries carry an activity.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="backfill-preference-activities.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("kdir", help="Knowledge store directory")
    parser.add_argument("--map", dest="map_path", help="Mapping JSON: entry path -> activities and title")
    parser.add_argument("--apply", action="store_true", help="Write the changes (default: dry run)")
    parser.add_argument(
        "--check", action="store_true",
        help="Name every live preferences/ entry that carries no activity; exit 1 if any",
    )
    args = parser.parse_args(argv)

    kdir = Path(args.kdir)
    if not kdir.is_dir():
        parser.error(f"no knowledge store at {kdir}")
    if args.check:
        if args.map_path or args.apply:
            parser.error("--check reads only the store; drop --map and --apply")
        return run_check(kdir)
    if not args.map_path:
        parser.error("--map is required unless --check is given")
    return run_map(kdir, args.map_path, args.apply)


if __name__ == "__main__":
    sys.exit(main())
