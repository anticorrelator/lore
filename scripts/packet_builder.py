import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import sys
import tempfile
import uuid

from norm_population import population

SCRIPTS = Path(__file__).resolve().parent
ROLES = ("investigator", "designer", "worker", "reviewer", "coordinator")
SCALES = ("abstract", "architecture", "subsystem", "implementation")
FLAGS = ("unverified-assumption", "unfamiliar-boundary", "conflicting-explanations")


def read_rows(kdir):
    path = Path(kdir) / "_packets/packets.jsonl"
    if path.exists():
        with path.open() as stream:
            for line in stream:
                if line.strip():
                    yield json.loads(line)


def rows_for(kdir, packet_id):
    return [row for row in read_rows(kdir) if row.get("packet_id") == packet_id]


def show(kdir, packet_id):
    """The current row for a packet id: rows supersede by append, so the last one wins."""
    rows = rows_for(kdir, packet_id)
    if not rows:
        raise ValueError(f"packet not found: {packet_id}")
    return rows[-1]


def pointer(kdir, packet_id):
    show(kdir, packet_id)
    return f"Knowledge packet: {Path(kdir).resolve() / '_packets/packets.jsonl'} ({packet_id}); read with `lore packet show {packet_id}`."


def task_owner(kdir, slug, task_id):
    path = Path(kdir) / "_work" / slug / "tasks.json"
    if not path.exists():
        if task_id:
            raise ValueError(f"tasks.json not found for {slug}")
        return {}, None
    data = json.loads(path.read_text())
    for task in data.get("tasks", []):
        if task.get("id") == task_id:
            return task, None
    for phase in data.get("phases", []):
        if any(t.get("id") == task_id for t in phase.get("tasks", [])):
            return phase, phase.get("phase_number")
    if task_id:
        raise ValueError(f"unknown task: {task_id}")
    return {}, None


def assemble(kdir, slug, directive, task_id=None, phase=None):
    with tempfile.TemporaryDirectory(prefix="packet-assembly-") as directory:
        snapshot_path = Path(directory) / "snapshot.json"
        args = ["bash", str(SCRIPTS / "resolve-manifest.sh"), slug]
        args += [str(phase)] if phase is not None else ["--task-id", task_id or "packet"]
        if phase is not None and task_id:
            args += ["--task-id", task_id]
        args += ["--directive-json", json.dumps(directive), "--delivery-json", str(snapshot_path)]
        proc = subprocess.run(args, env={**os.environ, "LORE_KNOWLEDGE_DIR": str(kdir)},
                              capture_output=True, text=True, timeout=120)
        if proc.returncode:
            raise ValueError(proc.stderr.strip())
        snapshot = json.loads(snapshot_path.read_text()) if snapshot_path.exists() else {}
        return proc.stdout, snapshot


def directive_scales(directive):
    topics = directive.get("topics", []) if directive.get("version") == 2 else [directive]
    return list(dict.fromkeys(scale for topic in topics for scale in topic.get("scale_set", [])))


def consultations(kdir, slug, task_id, phase, directive):
    owner, _ = task_owner(kdir, slug, task_id) if task_id else ({}, None)
    found = list(owner.get("consultations_required") or [])
    found += list(directive.get("consultations_required") or [])
    plan = Path(kdir) / "_work" / slug / "plan.md"
    if plan.exists():
        content = plan.read_text()
        if phase is not None or task_id:
            label = f"Phase {phase}" if phase is not None else f"Task {task_id.removeprefix('task-')}"
            match = re.search(r"^### " + re.escape(label) + r":.*?(?=^### |\Z)", content, re.M | re.S)
            content = match[0] if match else ""
        parse = runpy.run_path(str(SCRIPTS / "generate-tasks.py"))["_parse_consultations_required"]
        found += parse(content)
    return list(dict.fromkeys(found))


def build_packet(kdir, row, *, directive=None, assembly=None, role="worker", caller="worker",
                 scales=None, flags=None, thin_floor=None):
    directive = directive or {}
    if assembly is None:
        assembly = assemble(kdir, row["work_item"], directive, row.get("task_id"), row.get("phase"))
    body, snapshot = assembly
    row = dict(row)
    entries = snapshot.get("entries", row.get("delivered_entries", []))
    row.update(recipient_role=role, caller=caller, delivery_stage="assembled",
               delivered_entries=entries, content=body, norms=population(kdir), flags=flags or [],
               scales_requested=scales if scales is not None else directive_scales(directive),
               consultation_requirements=consultations(kdir, row["work_item"], row.get("task_id"), row.get("phase"), directive))
    row["budget"] = snapshot.get("budget") or row.get("budget") or {"chars_used": None, "chars_budget": None}
    if snapshot.get("trust_compute_sha"):
        row["trust_compute_sha"] = snapshot["trust_compute_sha"]
    if not entries:
        row.setdefault("empty_reason", "assembly returned no per-entry snapshot")
    else:
        row.pop("empty_reason", None)
    if not row.get("revision_id"):
        row.setdefault("unbound_reason", "revision-not-recorded" if row.get("task_id") else "task-not-requested")
    row["trust_snapshot_hash"] = hashlib.sha256(json.dumps(
        [{"path": e["path"], "trust": e["trust"]} for e in entries], sort_keys=True, separators=(",", ":")
    ).encode()).hexdigest()
    counts = {scale: len({e["path"] for e in entries if scale in {s.strip() for s in (e.get("scale") or "").split(",")}})
              for scale in row["scales_requested"]}
    row["entries_per_scale"] = counts
    if thin_floor is not None:
        row["thin_floor"] = thin_floor
    proc = subprocess.run(["bash", str(SCRIPTS / "packet-append.sh"), "--kdir", str(kdir)],
                          input=json.dumps(row, ensure_ascii=False), capture_output=True, text=True, timeout=60)
    if proc.returncode:
        raise ValueError(proc.stderr.strip())
    status = {"packet_id": row["packet_id"], "recipient_role": role, "entries_per_scale": counts,
              "scales_requested": row["scales_requested"],
              "scales_returned": [s for s, count in counts.items() if count],
              "norm_population_count": len(row["norms"]),
              "consultation_requirements": row["consultation_requirements"],
              "trust_snapshot_hash": row["trust_snapshot_hash"], "delivery_stage": "assembled",
              "location": str(Path(kdir).resolve() / "_packets/packets.jsonl"), "flags": row["flags"]}
    if thin_floor is not None:
        status["below_floor"] = [s for s, count in counts.items() if count < thin_floor]
    return status


def _strip_md(path):
    return path[:-3] if path.endswith(".md") else path


def _block_boundary(line):
    return bool(re.match(r"(#### |- \[\[knowledge:|### |## )", line))


def _drop_blocks(content, dropped_paths):
    """Remove each dropped entry's rendered block from the candidate content; return (content, headings)."""
    headings = {}
    lines = content.splitlines(keepends=True)
    kept_lines, skipping = [], False
    for line in lines:
        if _block_boundary(line):
            skipping = False
            for path in dropped_paths:
                full = re.match(r"#### (.+?) \(from " + re.escape(path) + r"\)\s*$", line)
                back = re.match(r"- \[\[knowledge:" + re.escape(_strip_md(path)) + r"(?:#([^\]]+))?\]\]\s*$", line)
                if full or back:
                    skipping = True
                    headings.setdefault(path, (full.group(1) if full else (back.group(1) or path)))
                    break
        if not skipping:
            kept_lines.append(line)
    return "".join(kept_lines), headings


def _entry_from_file(kdir, path):
    text = (Path(kdir) / path).read_text()
    heading = next((l[2:].strip() for l in text.splitlines() if l.startswith("# ")), Path(path).stem)
    scale = re.search(r"scale:\s*([a-z]+)", text)
    return heading, text, (scale.group(1) if scale else None)


def _trust_for(kdir, path):
    try:
        from pk_manifest import _trust_snapshot
        return _trust_snapshot(str(kdir), {"path": path})
    except Exception:
        return {"score": None, "status": "unknown", "confidence": "unknown", "correction_recency": None}


def synthesize(kdir, packet_id, *, by, dropped=(), added=()):
    """Supersede an assembled packet with the dispatcher's synthesis of it.

    `dropped` and `added` are sequences of (path, reason). Kept is everything
    delivered that was not dropped. The synthesized row keeps the packet id and
    its binding, re-renders the content without the dropped blocks, appends the
    added entries and a Left-out list, and travels through packet-append.sh.
    """
    candidate = show(kdir, packet_id)
    if candidate.get("delivery_stage") != "assembled":
        raise ValueError(f"synthesis: packet {packet_id} is {candidate.get('delivery_stage')}, not assembled; re-pull with `lore packet build` to synthesize again")
    if not by or not str(by).strip():
        raise ValueError("synthesis: --by must name who synthesized")
    entries = list(candidate.get("delivered_entries", []))
    delivered = list(dict.fromkeys(e["path"] for e in entries))
    drop_paths = [p for p, _ in dropped]
    add_paths = [p for p, _ in added]
    for path, reason in list(dropped) + list(added):
        if not path or not str(reason).strip():
            raise ValueError("synthesis: every dropped or added path needs a non-empty reason")
    if len(set(drop_paths)) != len(drop_paths) or len(set(add_paths)) != len(add_paths):
        raise ValueError("synthesis: a path may be dropped or added once")
    for path in drop_paths:
        if path not in delivered:
            raise ValueError(f"synthesis: {path} is not in the candidate set; only delivered entries can be dropped")
    for path in add_paths:
        if path in delivered:
            raise ValueError(f"synthesis: {path} is already delivered; drop or keep it instead of adding it")
        if Path(path).is_absolute() or ".." in Path(path).parts or not (Path(kdir) / path).is_file():
            raise ValueError(f"synthesis: {path} is not a knowledge entry under the store")
    content, headings = _drop_blocks(candidate.get("content") or "", drop_paths)
    kept_entries = [e for e in entries if e["path"] not in drop_paths]
    kept = [p for p in delivered if p not in drop_paths]
    added_entries, added_blocks = [], []
    for path, reason in added:
        heading, text, scale = _entry_from_file(kdir, path)
        added_blocks.append(f"\n#### {heading} (from {path})\n{text.rstrip()}\n")
        added_entries.append({"path": path, "scale": scale, "render_mode": "full", "section_role": "synthesis",
                              "topic": "added by synthesis", "ranking_path": "search-order", "trust": _trust_for(kdir, path)})
    if added_blocks:
        content = content.rstrip("\n") + "\n\n### Added by synthesis\n" + "".join(added_blocks)
    if dropped:
        content = content.rstrip("\n") + "\n\n## Left out by synthesis\n" + "".join(
            f"- {headings.get(path, path)} (from {path}) — {reason}\n" for path, reason in dropped)
    row = dict(candidate)
    for key in ("delivered_at", "synthesis_waiver"):
        row.pop(key, None)
    row.update(delivery_stage="synthesized", content=content, delivered_entries=kept_entries + added_entries,
               synthesized_from_delivered_at=candidate.get("delivered_at"),
               synthesis={"by": str(by), "synthesized_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                          "kept": kept, "dropped": [{"path": p, "reason": r} for p, r in dropped],
                          "added": [{"path": p, "reason": r} for p, r in added]})
    all_entries = row["delivered_entries"]
    if not all_entries:
        row["empty_reason"] = "synthesis dropped every delivered entry"
    else:
        row.pop("empty_reason", None)
    row["trust_snapshot_hash"] = hashlib.sha256(json.dumps(
        [{"path": e["path"], "trust": e["trust"]} for e in all_entries], sort_keys=True, separators=(",", ":")
    ).encode()).hexdigest()
    row["entries_per_scale"] = {scale: len({e["path"] for e in all_entries if scale in {s.strip() for s in (e.get("scale") or "").split(",")}})
                                for scale in row.get("scales_requested", [])}
    proc = subprocess.run(["bash", str(SCRIPTS / "packet-append.sh"), "--kdir", str(kdir)],
                          input=json.dumps(row, ensure_ascii=False), capture_output=True, text=True, timeout=60)
    if proc.returncode:
        raise ValueError(proc.stderr.strip())
    return {"packet_id": packet_id, "delivery_stage": "synthesized", "by": str(by), "kept": len(kept),
            "dropped": len(dropped), "added": len(added), "entries_per_scale": row["entries_per_scale"],
            "location": str(Path(kdir).resolve() / "_packets/packets.jsonl")}


def binding(kdir, slug, task_id):
    if not task_id:
        return {"unbound_reason": "task-not-requested"}
    publication = runpy.run_path(str(SCRIPTS / "work-evidence.py"))["publication_for_dispatch"](
        str(Path(kdir) / "_work" / slug), str(kdir))
    revision = publication["revision_id"]
    if not revision:
        return {"unbound_reason": "revision-not-recorded"}
    matches = [r for r in read_rows(kdir) if r.get("work_item") == slug and r.get("task_id") == task_id
               and r.get("revision_id") == revision and r.get("dispatch_attempt_id")]
    if not matches:
        return {"unbound_reason": "dispatch-attempt-not-recorded"}
    return {"schema_version": "2", "revision_id": revision, "source_head": publication["source_head"],
            "dispatch_attempt_id": matches[-1]["dispatch_attempt_id"]}


def main():
    parser = argparse.ArgumentParser(prog="lore packet")
    parser.add_argument("--kdir", required=True)
    commands = parser.add_subparsers(dest="verb", required=True)
    build = commands.add_parser("build")
    build.add_argument("--work-item", required=True)
    build.add_argument("--task")
    build.add_argument("--role", choices=ROLES, required=True)
    build.add_argument("--caller", required=True)
    build.add_argument("--topic")
    build.add_argument("--seeds", nargs="+", default=[])
    build.add_argument("--scale-set", required=True)
    build.add_argument("--thin-floor", type=int)
    build.add_argument("--flag", nargs=2, action="append", default=[], metavar=("TRIGGER", "REASON"))
    for verb in ("show", "pointer"):
        command = commands.add_parser(verb)
        command.add_argument("packet_id")
        command.add_argument("--json", action="store_true")
    synth = commands.add_parser("synthesize")
    synth.add_argument("packet_id")
    synth.add_argument("--by", required=True, help="who is synthesizing (a position or seat)")
    synth.add_argument("--drop", nargs=2, action="append", default=[], metavar=("PATH", "REASON"))
    synth.add_argument("--add", nargs=2, action="append", default=[], metavar=("PATH", "REASON"))
    synth.add_argument("--spec", help="JSON file with dropped and added lists of {path, reason}; merged with --drop/--add")
    args = parser.parse_args()
    kdir = Path(args.kdir).resolve()
    if args.verb == "synthesize":
        dropped = [tuple(d) for d in args.drop]
        added = [tuple(a) for a in args.add]
        if args.spec:
            spec = json.loads(Path(args.spec).read_text())
            if not isinstance(spec, dict) or set(spec) - {"dropped", "added", "by"}:
                parser.error("--spec must be an object with dropped and/or added lists")
            for key, target in (("dropped", dropped), ("added", added)):
                for item in spec.get(key) or []:
                    if not isinstance(item, dict) or set(item) != {"path", "reason"}:
                        parser.error(f"--spec {key} entries must be objects with path and reason")
                    target.append((item["path"], item["reason"]))
        print(json.dumps(synthesize(kdir, args.packet_id, by=args.by, dropped=dropped, added=added), ensure_ascii=False))
        return
    if args.verb != "build":
        row = show(kdir, args.packet_id)
        if args.verb == "pointer":
            print(pointer(kdir, args.packet_id))
        elif args.json:
            print(json.dumps(row, ensure_ascii=False))
        else:
            print(f"Packet {row['packet_id']} — {row.get('recipient_role', 'unrecorded')} ({row['delivery_stage']})")
            synthesis = row.get("synthesis")
            if synthesis:
                print(f"Synthesis: by {synthesis['by']} — kept {len(synthesis['kept'])}, dropped {len(synthesis['dropped'])}, added {len(synthesis['added'])}")
            elif row.get("synthesis_waiver"):
                print("Synthesis waived: " + json.dumps(row["synthesis_waiver"]))
            else:
                print("Synthesis: none — this is a candidate set; run `lore packet synthesize` before handing it on")
            print("Binding: " + json.dumps({k: row.get(k) for k in ("work_item", "task_id", "revision_id", "dispatch_attempt_id", "unbound_reason")}))
            print("Flags: " + json.dumps(row.get("flags", [])))
            print("Consultation requirements: " + json.dumps(row.get("consultation_requirements", [])))
            print(row.get("content", ""))
            if not row.get("content"):
                for entry in row.get("delivered_entries", []):
                    print(f"- {entry['path']} ({entry['render_mode']})")
            print("\n## Norms")
            for norm in row.get("norms", []):
                print(f"- `{norm['label']}` — {norm['path']}")
        return
    if not args.work_item or Path(args.work_item).name != args.work_item or args.work_item in (".", ".."):
        parser.error("--work-item must be a slug")
    if not (kdir / "_work" / args.work_item).is_dir():
        parser.error("work item not found")
    scales = list(dict.fromkeys(args.scale_set.split(",")))
    if not scales or any(s not in SCALES for s in scales):
        parser.error("--scale-set must declare comma-separated scale buckets")
    if args.thin_floor is not None and args.thin_floor < 0:
        parser.error("--thin-floor must be non-negative")
    if not args.caller.strip():
        parser.error("--caller must name a role")
    flags = []
    for flag, reason in args.flag:
        if flag not in FLAGS or not reason.strip():
            parser.error("--flag requires a named trigger and a non-empty reason")
        flags.append({"flag": flag, "reason": reason})
    owner, phase = task_owner(kdir, args.work_item, args.task)
    seeds = [seed for group in args.seeds for seed in group.split(",") if seed]
    directive = owner.get("retrieval_directive")
    if args.topic or seeds:
        directive = {"version": 2, "topics": [{"role": "focal", "topic": args.topic or " ".join(seeds),
                     "seeds": seeds, "scale_set": scales}]}
    elif directive:
        directive = json.loads(json.dumps(directive))
        for topic in directive.get("topics", []) if directive.get("version") == 2 else [directive]:
            topic["scale_set"] = scales
    else:
        parser.error("provide --topic or --seeds, or a task with a retrieval directive")
    row = {"packet_id": "pkt-" + uuid.uuid4().hex[:12], "packet_scope": "task" if args.task else "session",
           "session_id": None, "work_item": args.work_item, "task_id": args.task, "phase": phase,
           "arm": os.environ.get("LORE_PACKET_ARM") or None, "task_scale_set": ",".join(scales),
           **binding(kdir, args.work_item, args.task)}
    print(json.dumps(build_packet(kdir, row, directive=directive, role=args.role, caller=args.caller,
                                 scales=scales, flags=flags, thin_floor=args.thin_floor), ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.TimeoutExpired) as exc:
        sys.exit(f"packet: {exc}")
