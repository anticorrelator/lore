#!/usr/bin/env python3
"""pk_activities: the activity axis over a knowledge store's preferences/.

A preference entry names the activity it governs in its metadata footer:
``activity: <a>`` or ``activity: <a>, <b>``. The vocabulary is whatever
names live entries carry, plus ``general``, which a fresh store has no entry
to derive from. Live entries that carry no activity are grouped under
``untagged`` so that no listing silently drops them.

Usage:
    pk_activities.py --kdir <store> index [--json]
    pk_activities.py --kdir <store> entries <name> [--json]
    pk_activities.py --kdir <store> starts <command> [--json]
    pk_activities.py --kdir <store> block <activity>... [--json]
    pk_activities.py --kdir <store> check [--new-activity] <value> [--json]

``check`` validates a capture's --activity value against the vocabulary. It
prints the footer form on success and the refusal on stderr with exit 1.
An unknown name given to ``entries`` exits 1 and names the known ones.
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import NoReturn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pk_markdown import MarkdownParser  # noqa: E402
from pk_search import DEFAULT_STATUS_FILTER  # noqa: E402

CATEGORY = "preferences"
GENERAL = "general"
UNTAGGED = "untagged"
MAX_PER_ENTRY = 2

_NAME_RE = re.compile(r"[a-z0-9-]+")
_H1_RE = re.compile(r"^#\s+(.+)$", re.MULTILINE)

# The activities a command or skill starts. Names here are not a registry:
# the vocabulary still comes from entries, and an activity no entry carries
# renders as "none filed".
STARTS: dict[str, list[str]] = {
    "arc open": ["coordination", "model-routing"],
    "arc close": ["human-writing"],
    "spec start": ["work-scoping"],
    "impl start": ["model-routing"],
    "capture --category preferences": ["preference-writing"],
    "/pr-create": ["pr-bodies", "shipping", "human-writing"],
    "/pr-review": ["review-comments"],
    "/evolve": ["protocol-prose"],
    "/remember": ["preference-writing"],
}


class ActivityError(ValueError):
    """A name or value the activity axis refuses; the message is the refusal."""


class UnknownActivity(ActivityError):
    def __init__(self, name: str, known: list[str]):
        self.name = name
        self.known = known
        super().__init__(f'no activity "{name}" in {CATEGORY}/; known: {", ".join(known)}')


def canonical(name: str) -> str:
    """Fold case and whitespace; refuse anything outside [a-z0-9-]+."""
    folded = "-".join(str(name).strip().lower().split())
    if not _NAME_RE.fullmatch(folded):
        raise ActivityError(
            f'"{name}" is not a valid activity name; use lowercase letters, digits and hyphens'
        )
    return folded


def split_value(value: str | None) -> list[str]:
    """Split a footer or flag value on commas, dropping empty pieces."""
    if not value:
        return []
    return [piece.strip() for piece in value.split(",") if piece.strip()]


def _footer_activities(raw: str | None) -> list[str]:
    names = []
    for piece in split_value(raw):
        try:
            name = canonical(piece)
        except ActivityError:
            continue
        if name != UNTAGGED and name not in names:
            names.append(name)
    return names


def _body(text: str) -> str:
    text = MarkdownParser._strip_frontmatter(text)
    for m in MarkdownParser._METADATA_COMMENT_RE.finditer(text):
        if "learned:" in m.group(1):
            text = text[: m.start()] + text[m.end():]
            break
    h1 = _H1_RE.search(text)
    if h1:
        text = text[: h1.start()] + text[h1.end():]
    return text.strip()


def read_entry(kdir: str, path: Path) -> dict:
    text = path.read_text(encoding="utf-8", errors="replace")
    meta = MarkdownParser._extract_metadata(text)
    h1 = _H1_RE.search(MarkdownParser._strip_frontmatter(text))
    return {
        "path": path.relative_to(kdir).as_posix(),
        "title": h1.group(1).strip() if h1 else path.stem,
        "body": _body(text),
        "activities": _footer_activities(meta.get("activity")),
        "learned": meta.get("learned"),
        "status": meta.get("entry_status") or "current",
    }


def _entry_paths(kdir: str) -> list[Path]:
    root = Path(kdir) / CATEGORY
    if not root.is_dir():
        return []
    paths = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith((".", "_")))
        for name in filenames:
            if name.endswith(".md") and name != "README.md" and not name.startswith((".", "_")):
                paths.append(Path(dirpath) / name)
    return sorted(paths, key=lambda p: p.relative_to(root).as_posix())


def live_entries(kdir: str) -> list[dict]:
    """Every live preference entry, in filename order."""
    kdir = str(Path(kdir))
    live = []
    for path in _entry_paths(kdir):
        try:
            entry = read_entry(kdir, path)
        except OSError:
            continue
        if entry["status"] in DEFAULT_STATUS_FILTER:
            live.append(entry)
    return live


def index(kdir: str) -> dict[str, list[dict]]:
    """Activity name -> live entries filed under it, keys in name order.

    ``general`` is always present. ``untagged`` is present when some live
    entry carries no activity. An entry with two activities is under both.
    """
    groups: dict[str, list[dict]] = {GENERAL: []}
    for entry in live_entries(kdir):
        for name in entry["activities"] or [UNTAGGED]:
            groups.setdefault(name, []).append(entry)
    return {name: groups[name] for name in sorted(groups)}


def vocabulary(kdir: str) -> list[str]:
    """The names a capture may file under without --new-activity."""
    return [name for name in index(kdir) if name != UNTAGGED]


def entries(kdir: str, name: str) -> list[dict]:
    """Live entries filed under one activity; UnknownActivity if none is."""
    groups = index(kdir)
    try:
        key = canonical(name)
    except ActivityError:
        raise UnknownActivity(str(name).strip(), list(groups)) from None
    if key not in groups:
        raise UnknownActivity(key, list(groups))
    return groups[key]


def starts(command: str) -> list[str]:
    return list(STARTS.get(" ".join(str(command).split()), []))


def block(kdir: str, activities) -> str:
    """The full text of the preferences for each activity, in the order given."""
    groups = index(kdir)
    names = []
    for activity in activities:
        name = canonical(activity)
        if name not in names:
            names.append(name)
    parts = []
    for name in names:
        group = groups.get(name, [])
        if not group:
            parts.append(f"Preferences for {name}: none filed.")
            continue
        lines = [f"Preferences for {name} ({len(group)}):"]
        for entry in group:
            lines.append(f"- {entry['title']}")
            lines.extend(f"  {line}" if line.strip() else "" for line in entry["body"].splitlines())
        lines.append(f"Full set: lore search --preferences --activity {name}")
        parts.append("\n".join(lines))
    return "\n\n".join(parts) + ("\n" if parts else "")


def check(kdir: str, value: str | None, allow_new: bool = False) -> list[str]:
    """Validate a capture's --activity value; return the canonical names.

    Raises ActivityError carrying the refusal text capture prints.
    """
    known = vocabulary(kdir)
    existing = ", ".join(known)
    pieces = split_value(value)
    if not pieces:
        raise ActivityError(
            f"--activity is required for --category {CATEGORY}; existing: {existing}"
        )
    if len(pieces) > MAX_PER_ENTRY:
        raise ActivityError(
            f'--activity takes at most {MAX_PER_ENTRY} names; got {len(pieces)} from "{value}" (existing: {existing})'
        )
    names = []
    for piece in pieces:
        try:
            name = canonical(piece)
        except ActivityError as exc:
            raise ActivityError(f"--activity {exc} (existing: {existing})") from None
        if name == UNTAGGED:
            raise ActivityError(
                f'--activity "{UNTAGGED}" is reserved for live entries filed without an activity; choose a name (existing: {existing})'
            )
        if name in names:
            raise ActivityError(f'--activity names must be distinct; got "{value}"')
        names.append(name)
    if not allow_new:
        for name in names:
            if name not in known:
                raise ActivityError(
                    f'--activity "{name}" is not an existing activity (existing: {existing}); pass --new-activity to create it'
                )
    return names


def footer_value(names: list[str]) -> str:
    return ", ".join(names)


def render_listing(name: str, group: list[dict]) -> str:
    """Every entry under one activity: title line, body, path; then the count."""
    out = []
    for entry in group:
        out.append(f"# {entry['title']}")
        if entry["body"]:
            out.append(entry["body"])
        out.append(f"path: {entry['path']}")
        out.append("")
    if group:
        noun = "entry" if len(group) == 1 else "entries"
        out.append(f"Preferences for {name}: {len(group)} {noun}.")
    else:
        out.append(f"Preferences for {name}: none filed.")
    return "\n".join(out) + "\n"


def index_rows(groups: dict[str, list[dict]]) -> list[dict]:
    return [
        {
            "name": name,
            "count": len(group),
            "entries": [{"path": e["path"], "title": e["title"]} for e in group],
        }
        for name, group in groups.items()
    ]


def render_index(groups: dict[str, list[dict]]) -> str:
    return "".join(f"{name} ({len(group)})\n" for name, group in groups.items())


def _refuse(message: str, as_json: bool, known: list[str] | None = None) -> NoReturn:
    if as_json:
        payload: dict[str, object] = {"error": message}
        if known is not None:
            payload["known"] = known
        print(json.dumps(payload), file=sys.stderr)
    else:
        print(message, file=sys.stderr)
    sys.exit(1)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        prog="pk_activities.py",
        description="Read the activity axis of a store's preferences/ entries.",
    )
    parser.add_argument("--kdir", required=True, help="Knowledge store directory")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    sub = parser.add_subparsers(dest="command", required=True)
    p_index = sub.add_parser("index", help="Each activity with its count")
    p_entries = sub.add_parser("entries", help="Every live entry under one activity")
    p_entries.add_argument("name")
    p_starts = sub.add_parser("starts", help="The activities a command or skill starts")
    p_starts.add_argument("start_command", metavar="command", nargs="+")
    p_block = sub.add_parser("block", help="Full-text preferences for activities")
    p_block.add_argument("activities", nargs="+")
    p_check = sub.add_parser("check", help="Validate a capture's --activity value")
    p_check.add_argument("value", nargs="?", default="")
    p_check.add_argument("--new-activity", action="store_true")
    for p in (p_index, p_entries, p_starts, p_block, p_check):
        p.add_argument("--json", action="store_true", default=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    kdir = args.kdir
    as_json = args.json

    if args.command == "index":
        groups = index(kdir)
        if as_json:
            print(json.dumps({"activities": index_rows(groups)}, indent=2))
        else:
            sys.stdout.write(render_index(groups))
    elif args.command == "entries":
        try:
            group = entries(kdir, args.name)
        except UnknownActivity as exc:
            _refuse(str(exc), as_json, exc.known)
        name = canonical(args.name)
        if as_json:
            print(json.dumps({"activity": name, "count": len(group), "entries": group}, indent=2))
        else:
            sys.stdout.write(render_listing(name, group))
    elif args.command == "starts":
        names = starts(" ".join(args.start_command))
        if as_json:
            print(json.dumps(names))
        else:
            sys.stdout.write("".join(f"{n}\n" for n in names))
    elif args.command == "block":
        try:
            text = block(kdir, args.activities)
        except ActivityError as exc:
            _refuse(str(exc), as_json)
        if as_json:
            names = [canonical(a) for a in args.activities]
            print(json.dumps({"activities": list(dict.fromkeys(names)), "text": text}))
        else:
            sys.stdout.write(text)
    elif args.command == "check":
        try:
            names = check(kdir, args.value, allow_new=args.new_activity)
        except ActivityError as exc:
            _refuse(str(exc), as_json)
        if as_json:
            print(json.dumps({"activities": names, "footer": footer_value(names)}))
        else:
            print(footer_value(names))


if __name__ == "__main__":
    main()
