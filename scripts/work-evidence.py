#!/usr/bin/env python3
"""Read work evidence without repairing or publishing any source files."""

from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

READER_CONTRACT_VERSION = "2"
EVIDENCE_SCHEMA_VERSION = 1
CODE_DIGEST_VERSION = "1"
GENERATED_RETRO_FILES = {"retro-evidence-pack", "retro-filing"}


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def envelope(path, state="absent", reason="missing"):
    return {"state": state, "reason": reason, "path": path, "sha256": None,
            "size": None, "content": None}


def mark(source, state, reason):
    source.update(state=state, reason=reason)
    return source


def read_file(path, root, *, json_file=False, versions=None):
    path, root = Path(path), Path(root)
    label = os.path.relpath(path, root)
    result = envelope(label)
    try:
        path.resolve().relative_to(root.resolve())
        mode = path.stat().st_mode
        if not stat.S_ISREG(mode):
            return mark(result, "unreadable", "not-a-regular-file")
        raw = path.read_bytes()
    except ValueError:
        return mark(result, "unreadable", "reference-outside-store")
    except FileNotFoundError:
        return result
    except OSError as exc:
        return mark(result, "unreadable", f"read-error:{exc.errno}")
    result.update(state="read", reason=None, sha256=sha256(raw), size=len(raw))
    try:
        result["content"] = raw.decode("utf-8")
    except UnicodeDecodeError:
        result["content_base64"] = base64.b64encode(raw).decode("ascii")
        if json_file:
            mark(result, "unreadable", "invalid-utf8")
        return result
    if json_file:
        try:
            data = json.loads(result["content"])
        except ValueError:
            return mark(result, "unreadable", "invalid-json")
        result["data"] = data
        if not isinstance(data, dict):
            return mark(result, "unreadable", "expected-object")
        if versions is not None and "schema_version" in data:
            if str(data["schema_version"]) not in versions:
                mark(result, "unsupported", "unsupported-schema-version")
    return result


def read_ledger(path, root, versions=None, *, select=None, prefix=None):
    result = read_file(path, root)
    result.update(rows=[], row_count=0, errors=[])
    if result["state"] != "read":
        return result
    if result["content"] is None:
        return mark(result, "unreadable", "invalid-utf8")
    selected = []
    for line_number, line in enumerate(result["content"].splitlines(keepends=True), 1):
        if prefix is not None:
            if not line.startswith(prefix):
                continue
            line = line[len(prefix):]
        if not line.strip():
            continue
        try:
            row = json.loads(line)
            if not isinstance(row, dict):
                raise ValueError("expected-object")
        except ValueError:
            selected.append(line)
            result["errors"].append({"line": line_number, "reason": "invalid-json-row"})
            continue
        if select is not None and not select(row):
            continue
        selected.append(line)
        result["rows"].append(row)
        if versions is not None and str(row.get("schema_version")) not in versions:
            result["errors"].append({"line": line_number, "reason": "unsupported-schema-version"})
    # Filtered streams fingerprint exactly the raw rows they expose.
    if select is not None or prefix is not None:
        result["content"] = "".join(selected)
        result["size"] = len(result["content"].encode())
        result["sha256"] = sha256(result["content"].encode())
    result["row_count"] = len(result["rows"])
    if result["errors"]:
        unsupported = all(e["reason"] == "unsupported-schema-version" for e in result["errors"])
        mark(result, "unsupported" if unsupported else "unreadable",
             "unsupported-schema-version" if unsupported else "malformed-ledger")
    return result


def read_directory(path, root, *, reports=False):
    path = Path(path)
    result = envelope(os.path.relpath(path, root))
    result["entries"] = []
    if not path.exists():
        return result
    try:
        path.resolve().relative_to(Path(root).resolve())
        if path.is_symlink() or not path.is_dir():
            return mark(result, "unreadable", "not-a-readable-directory")
        def onerror(exc):
            raise exc
        for directory, dirs, files in os.walk(path, onerror=onerror, followlinks=False):
            for name in sorted(dirs):
                child = Path(directory) / name
                if child.is_symlink():
                    result["entries"].append(envelope(os.path.relpath(child, root),
                                                       "unreadable", "directory-symlink"))
            dirs[:] = sorted(d for d in dirs if not (Path(directory) / d).is_symlink())
            for name in sorted(files):
                child = Path(directory) / name
                entry = read_file(child, root, json_file=child.suffix == ".json", versions={"1"})
                if reports:
                    text = entry.get("content") or ""
                    def header(key):
                        match = re.search(r"(?m)^" + key + r":\s*([^\n]+)", text)
                        return match.group(1).strip() if match else None
                    entry.update(id=header("Report-id") or child.stem,
                                 declared_status=header("Status") or "unknown")
                    version = header("Report-schema")
                    if version is not None and version != "1":
                        mark(entry, "unsupported", "unsupported-report-schema")
                result["entries"].append(entry)
    except (OSError, ValueError) as exc:
        return mark(result, "unreadable", "directory-unavailable:" + type(exc).__name__)
    result["entries"].sort(key=lambda e: e["path"])
    result.update(state="read", reason=None,
                  sha256=sha256(canonical(result["entries"])), size=len(result["entries"]))
    bad = [entry for entry in result["entries"] if entry["state"] != "read"]
    if bad:
        mark(result, "unsupported" if all(e["state"] == "unsupported" for e in bad) else "unreadable",
             "incomplete-directory-coverage")
    return result


def task_rows(data):
    if not isinstance(data, dict):
        return []
    if "tasks" in data:
        return data["tasks"] if isinstance(data["tasks"], list) else []
    phases = data.get("phases", [])
    if not isinstance(phases, list):
        return []
    return [task for phase in phases if isinstance(phase, dict) and isinstance(phase.get("tasks"), list)
            for task in phase["tasks"] if isinstance(task, dict)]


def criterion_version(criterion):
    return sha256(canonical({k: v for k, v in criterion.items()
                             if k not in {"criterion_version", "version"}}))


def validate_records(source, kind):
    previous, seen = None, {}
    source["invalid_rows"] = []
    for index, row in enumerate(source["rows"]):
        if str(row.get("schema_version")) not in ({"1", "2"} if kind == "packets" else {"1"}):
            source["invalid_rows"].append(index)
            continue
        invalid = None
        if kind == "revisions":
            rid = row.get("revision_id")
            if not isinstance(rid, str) or not re.fullmatch(r"[0-9a-f]{12}", rid):
                invalid = "invalid-revision-id"
            elif row.get("record_type", "revision") == "decision":
                if rid not in seen:
                    invalid = "decision-revision-unavailable"
            elif row.get("record_type", "revision") != "revision":
                invalid = "invalid-revision-record-type"
            elif rid in seen:
                if row != seen[rid]:
                    invalid = "revision-id-collision"
            elif row.get("predecessor") != previous:
                invalid = "revision-predecessor-mismatch"
            elif any(not isinstance(row.get(k), str) or not re.fullmatch(r"[0-9a-f]{64}", row[k])
                     for k in ("plan_sha256", "tasks_sha256")):
                invalid = "invalid-revision-hashes"
            elif any(not isinstance(row.get(k), str) or not row[k] for k in ("plan_path", "tasks_path")):
                invalid = "missing-revision-snapshots"
            else:
                seen[rid], previous = row, rid
        elif kind == "packets" and str(row.get("schema_version")) == "2":
            if any(not isinstance(row.get(k), str) or not row[k]
                   for k in ("packet_id", "task_id", "dispatch_attempt_id", "revision_id")):
                invalid = "missing-packet-attribution"
            elif not re.fullmatch(r"[0-9a-f]{12}", row["revision_id"]):
                invalid = "invalid-packet-revision"
            elif "source_head" not in row or (row["source_head"] is not None and
                    (not isinstance(row["source_head"], str) or not row["source_head"])):
                invalid = "invalid-packet-source-head"
        elif kind == "results":
            if any(not isinstance(row.get(k), str) or not row[k]
                   for k in ("result_id", "execution_attempt_id", "task_id", "criterion_id", "revision_id", "criterion_version")):
                invalid = "missing-result-attribution"
            elif not re.fullmatch(r"[0-9a-f]{12}", row["revision_id"]):
                invalid = "invalid-result-revision"
            elif not re.fullmatch(r"[0-9a-f]{64}", row["criterion_version"]):
                invalid = "invalid-criterion-version"
            elif not isinstance(row.get("state"), str) or row["state"] not in {"pass", "fail", "skipped", "unavailable"}:
                invalid = "invalid-result-state"
            elif row.get("packet_id") and not row.get("dispatch_attempt_id"):
                invalid = "missing-dispatch-attempt"
            elif not row.get("packet_id") and not row.get("unbound_reason"):
                invalid = "missing-unbound-reason"
            elif any(row.get(k) is not None and (not isinstance(row[k], dict) or any(
                    row[k].get(field) is not None and not isinstance(row[k][field], str)
                    for field in ("head", "digest", "digest_version", "worktree")))
                    for k in ("source_start", "source_end")):
                invalid = "invalid-code-identity"
            elif row.get("state") == "pass":
                if (not isinstance(row.get("exit"), int) or isinstance(row.get("exit"), bool)
                        or row.get("signal") is not None or row.get("timed_out") is not False):
                    invalid = "invalid-passing-execution"
                elif any(not isinstance(row.get(k), str) or not row[k] for k in ("output_path", "output_sha256")):
                    invalid = "missing-passing-output"
                elif any(not isinstance(row.get(k), dict) or any(not row[k].get(field) for field in
                         ("head", "digest", "digest_version", "worktree")) for k in ("source_start", "source_end")):
                    invalid = "missing-passing-code-identity"
        if invalid:
            source["invalid_rows"].append(index)
            source["errors"].append({"row_index": index, "reason": invalid})
            mark(source, "unreadable", "invalid-" + kind + "-record")


def code_identity(worktree, excluded_paths=()):
    """Hash index entries, tracked worktree bytes, and nonignored untracked files."""
    result = {"state": "unreadable", "reason": "code-unavailable", "worktree": str(worktree),
              "head": None, "digest": None, "digest_version": CODE_DIGEST_VERSION}
    root = Path(worktree)
    try:
        root = root.resolve(strict=True)
        def git(*args):
            return subprocess.run(["git", "--no-optional-locks", "-C", str(root), *args],
                                  check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  timeout=15).stdout
        if Path(os.fsdecode(git("rev-parse", "--show-toplevel")).strip()).resolve() != root:
            return mark(result, "unreadable", "not-a-worktree-root")
        result["head"] = git("rev-parse", "HEAD").decode().strip()
        excluded = [Path(p).resolve() for p in excluded_paths]
        def omit(path):
            return any(path == p or p in path.parents for p in excluded)
        entries = git("ls-files", "--stage", "-z")
        names = {}
        index = []
        for entry in entries.split(b"\0"):
            if not entry:
                continue
            metadata, name = entry.split(b"\t", 1)
            path = root / os.fsdecode(name)
            if omit(path):
                continue
            index.append([os.fsdecode(name), metadata.decode()])
            names[name] = metadata.split()[0] == b"160000"
        for name in git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0"):
            if name and not omit(root / os.fsdecode(name)):
                names[name] = False
        files = []
        for name, submodule in sorted(names.items()):
            path = root / os.fsdecode(name)
            record = {"path": os.fsdecode(name)}
            try:
                info = path.lstat()
                record["mode"] = stat.S_IMODE(info.st_mode)
                if stat.S_ISLNK(info.st_mode):
                    record["symlink"] = os.readlink(path)
                elif submodule:
                    record["submodule"] = code_identity(path)
                    if record["submodule"]["state"] != "read":
                        return mark(result, "unreadable", "submodule-unavailable")
                    record["submodule"].pop("worktree", None)
                elif stat.S_ISREG(info.st_mode):
                    record["sha256"] = sha256(path.read_bytes())
                else:
                    return mark(result, "unreadable", "unsupported-code-file")
            except FileNotFoundError:
                record["deleted"] = True
            files.append(record)
        result.update(state="read", reason=None,
                      digest=sha256(canonical({"version": CODE_DIGEST_VERSION, "index": index, "files": files})))
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    return result


def references(row, item, root):
    found = {}
    def visit(value):
        if isinstance(value, dict):
            for key, child in value.items():
                if isinstance(child, str) and (key.endswith("_path") or key == "path"):
                    # Source placement is code identity, not an artifact reference.
                    if key in {"worktree_path", "source_path", "execution_path"}:
                        continue
                    candidate = Path(child)
                    if candidate.is_absolute():
                        found[child] = envelope(child, "unreadable", "absolute-artifact-reference")
                    else:
                        base = root if child.startswith("_work/") else item
                        try:
                            (base / child).resolve().relative_to(item.resolve())
                            found[child] = read_file(base / child, root,
                                                     json_file=candidate.suffix == ".json", versions={"1"})
                            expected = value.get(key[:-5] + "_sha256" if key.endswith("_path") else "sha256")
                            if expected is not None:
                                found[child]["expected_sha256"] = expected
                                if found[child]["state"] == "read" and expected != found[child]["sha256"]:
                                    mark(found[child], "unreadable", "artifact-digest-mismatch")
                        except ValueError:
                            found[child] = envelope(child, "unreadable", "reference-outside-item")
                elif isinstance(child, (dict, list)):
                    visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
    visit(row)
    return [{"reference": key, **value} for key, value in sorted(found.items())]


def revision_view(source, tasks, plan):
    rows, seen = [], set()
    for index, row in enumerate(source["rows"]):
        rid = row.get("revision_id")
        if (index not in source.get("invalid_rows", []) and row.get("record_type", "revision") == "revision"
                and isinstance(rid, str) and rid not in seen):
            rows.append(row)
            seen.add(rid)
    result = {"head": rows[-1] if rows else None, "publication_state": "legacy-unbound", "reason": None}
    if source["state"] not in {"read", "absent"}:
        result.update(publication_state="incomplete", reason="revision-history-" + source["state"])
        return result
    data = tasks.get("data") if isinstance(tasks.get("data"), dict) else {}
    if not rows:
        if data.get("revision_id"):
            result.update(publication_state="incomplete", reason="missing-revision-history")
        return result
    head = rows[-1]
    checks = [bool(re.fullmatch(r"[0-9a-f]{12}", str(head.get("revision_id")))),
              tasks["state"] == "read", data.get("revision_id") == head.get("revision_id"),
              tasks.get("sha256") == head.get("tasks_sha256"), plan.get("sha256") == head.get("plan_sha256")]
    result.update(publication_state="current" if all(checks) else "incomplete",
                  reason=None if all(checks) else "committed-generation-mismatch")
    return result


def dispatch_projection(history, item, root):
    """Fold authored decisions by task while preserving their source revision."""
    import copy
    result = {"schema_version": 1, "state": "read", "reason": "", "tasks": {}, "blocked": {}}
    if history["state"] not in {"read", "absent"}:
        result.update(state="unreadable", reason="revision-history-unavailable")
        return result
    states = {}
    decisions = {}
    for row in history["rows"]:
        if row.get("record_type") == "decision":
            decisions.setdefault(row["revision_id"], []).append(row)
    try:
        for row in history["rows"]:
            if row.get("record_type", "revision") != "revision":
                continue
            rid = row["revision_id"]
            path = (item / row["tasks_path"]).resolve()
            if not path.is_relative_to(item.resolve()):
                raise ValueError("revision snapshot outside item")
            source = read_file(path, root, json_file=True, versions={"1"})
            if source["state"] != "read" or source["sha256"] != row["tasks_sha256"]:
                raise ValueError("revision task snapshot unavailable")
            ids = {task["id"] for task in task_rows(source["data"])}
            current = {tid: copy.deepcopy(value) for tid, value in states.get(row.get("predecessor"), {}).items()
                       if tid in ids}
            changed = set(row.get("changed_task_ids", ids)) if row.get("kind") != "progress" else set()
            for tid in ids:
                if tid in changed or tid not in current:
                    current[tid] = {"coverage": row.get("anchor_coverage"), "coverage_revision_id": rid,
                                    "dispatch": None, "dispatch_revision_id": None}
            def apply(value, coverage_all=False):
                if coverage_all and value.get("anchor_coverage") is not None:
                    for entry in current.values():
                        entry.update(coverage=value["anchor_coverage"], coverage_revision_id=rid)
                dispatch = value.get("dispatch_decision") or {}
                for tid in dispatch.get("task_ids", []):
                    if tid in current:
                        current[tid].update(dispatch=dispatch, dispatch_revision_id=rid)
            if row.get("kind") != "progress":
                apply(row, coverage_all="anchor_coverage" in row.get("decision_overrides", {}))
            else:
                apply(row.get("decision_overrides", {}), coverage_all=True)
            for decision in decisions.get(rid, []):
                apply(decision, coverage_all=True)
            states[rid] = current
            result["tasks"] = current
        for tid, value in sorted(result["tasks"].items()):
            coverage, dispatch = value["coverage"] or {}, value["dispatch"] or {}
            if coverage.get("disposition") != "covered":
                result["blocked"][tid] = "pending anchor coverage decision"
            elif not dispatch:
                result["blocked"][tid] = "missing authored dispatch decision"
            elif dispatch.get("disposition") not in {"proceed", "reuse"}:
                result["blocked"][tid] = "authored dispatch decision is wait"
    except (OSError, ValueError, KeyError, TypeError) as exc:
        result.update(state="unreadable", reason=str(exc), tasks={}, blocked={})
    return result


def publication_for_dispatch(item_dir, knowledge_dir):
    """Read the committed generation and the authored decisions for dispatch."""
    item, root = Path(item_dir), Path(knowledge_dir)
    history = read_ledger(item / "revisions.jsonl", root, {"1"})
    validate_records(history, "revisions")
    generated = read_file(item / "tasks.json", root, json_file=True, versions={"1"})
    revision = revision_view(history, generated, read_file(item / "plan.md", root))
    if revision["publication_state"] == "incomplete":
        raise ValueError("incomplete revision publication: " + revision["reason"])
    head = revision["head"]
    if head is None:
        return {"revision_id": None, "source_head": None, "blocked": {}}
    for reference in references(head, item, root):
        if reference["state"] != "read":
            raise ValueError("committed revision snapshot unavailable: " + reference["reference"])
    dispatch = dispatch_projection(history, item, root)
    if dispatch["state"] != "read":
        raise ValueError("dispatch decisions unavailable: " + dispatch["reason"])
    return {"revision_id": head["revision_id"], "source_head": head.get("source_head"), "blocked": dispatch["blocked"]}


def binding(row, revision):
    recorded = row.get("revision_id")
    head = (revision.get("head") or {}).get("revision_id")
    if recorded is None:
        return {"state": "legacy-unbound" if str(row.get("schema_version")) == "1" else "unbound",
                "reason": row.get("unbound_reason") or "revision-not-recorded"}
    if head is None:
        return {"state": "unknown", "reason": "revision-head-unavailable"}
    return {"state": "current" if recorded == head else "stale",
            "reason": None if recorded == head else "revision-mismatch"}


def result_freshness(row, revision, criteria, artifacts, item, cache):
    stale, unknown = [], []
    bound = binding(row, revision)
    if bound["state"] == "stale":
        stale.append("revision-mismatch")
    elif bound["state"] != "current":
        unknown.append(bound["reason"])
    if revision["publication_state"] == "incomplete":
        unknown.append("revision-publication-incomplete")
    definition = criteria.get((row.get("task_id"), row.get("criterion_id")))
    if definition is None:
        stale.append("criterion-not-in-current-tasks")
    elif row.get("criterion_version") != criterion_version(definition):
        stale.append("criterion-version-mismatch")
    start = row.get("source_start")
    end = row.get("source_end")
    if not isinstance(start, dict) or not isinstance(end, dict):
        unknown.append("code-identity-not-recorded")
    else:
        if any(start.get(key) != end.get(key) for key in ("head", "digest", "digest_version")):
            stale.append("code-changed-during-execution")
        worktree = end.get("worktree")
        if not worktree or end.get("digest_version") != CODE_DIGEST_VERSION:
            unknown.append("code-identity-unavailable")
        else:
            result_id = row.get("result_id")
            excluded = (item / "results" / str(result_id),) if result_id else ()
            key = (worktree, str(result_id))
            if key not in cache:
                cache[key] = code_identity(worktree, excluded)
            current = cache[key]
            if current["state"] != "read":
                unknown.append("code-unavailable")
            elif any(current.get(k) != end.get(k) for k in ("head", "digest")):
                stale.append("source-code-mismatch")
    output = next((a for a in artifacts if a["reference"] == row.get("output_path")), None)
    if output is not None and output["reason"] == "artifact-digest-mismatch":
        stale.append("output-digest-mismatch")
    elif output is None or output["state"] != "read":
        unknown.append("result-output-unavailable")
    elif not row.get("output_sha256"):
        unknown.append("output-digest-not-recorded")
    elif row["output_sha256"] != output["sha256"]:
        stale.append("output-digest-mismatch")
    return {"state": "stale" if stale else "unknown" if unknown else "current",
            "reasons": sorted(set(stale + unknown))}


def project(item_dir, knowledge_dir):
    item, root = Path(item_dir).absolute(), Path(knowledge_dir).absolute()
    tasks = read_file(item / "tasks.json", root, json_file=True, versions={"1"})
    if tasks["state"] == "read":
        data = tasks["data"]
        if not (("tasks" in data and isinstance(data["tasks"], list)) or
                ("tasks" not in data and isinstance(data.get("phases"), list))):
            mark(tasks, "unreadable", "missing-task-array")
        elif any(not isinstance(t, dict) or not isinstance(t.get("id"), str) for t in task_rows(data)):
            mark(tasks, "unreadable", "invalid-task-record")
    revisions = read_ledger(item / "revisions.jsonl", root, {"1"})
    revisions["snapshots"] = read_directory(item / "revisions", root)
    sources = {
        "tasks": tasks,
        "revisions": revisions,
        "results": read_ledger(item / "results.jsonl", root, {"1"}),
        "packets": read_ledger(root / "_packets" / "packets.jsonl", root, {"1", "2"},
                               select=lambda row: row.get("work_item") == item.name),
        "outcomes": read_ledger(item / "execution-log.md", root, {"1", "2"}, prefix="Spec-outcome-record: "),
        "reviews": read_directory(item / "reviews", root),
        "reports": read_directory(item / "worker-reports", root, reports=True),
        "claims": read_ledger(item / "task-claims.jsonl", root),
        "bundle": read_file(item / "retro-bundle.json", root, json_file=True, versions={"0"}),
    }
    sources["results"]["artifacts"] = read_directory(item / "results", root)
    for kind in ("revisions", "results", "packets"):
        validate_records(sources[kind], kind)
    bundle = sources["bundle"]
    if bundle["state"] == "read":
        required = {"work_item", "tasks_completed", "tier2_claim_ids", "tier3_promoted_ids",
                    "advisor_consultations_count", "blockers", "template_versions", "captured_at_sha", "run_started_at"}
        if not required <= bundle["data"].keys():
            mark(bundle, "unreadable", "invalid-legacy-bundle")
        else:
            data = bundle["data"]
            if (data["work_item"] != item.name or not isinstance(data["template_versions"], dict)
                    or any(not isinstance(data[k], int) or isinstance(data[k], bool) or data[k] < 0
                           for k in ("tasks_completed", "advisor_consultations_count"))
                    or any(not isinstance(data[k], list) or any(not isinstance(v, str) for v in data[k])
                           for k in ("tier2_claim_ids", "tier3_promoted_ids", "blockers"))):
                mark(bundle, "unreadable", "invalid-legacy-bundle")
    bundle.update(format="legacy-v0", role="last-close-snapshot")
    revision = revision_view(revisions, tasks, read_file(item / "plan.md", root))
    if revision["head"] is not None:
        artifacts = references(revision["head"], item, root)
        if any(a["state"] != "read" for a in artifacts):
            revision.update(publication_state="incomplete", reason="revision-snapshot-unavailable")
    revision["dispatch"] = dispatch_projection(revisions, item, root)
    for entry in sources["reviews"]["entries"]:
        if isinstance(entry.get("data"), dict) and entry["data"].get("revision_id"):
            entry["binding"] = binding(entry["data"], revision)
    criteria = {}
    for task in task_rows(tasks.get("data")):
        if isinstance(task, dict) and isinstance(task.get("id"), str):
            declared = task.get("close_criteria", [])
            for criterion in declared if isinstance(declared, list) else []:
                if isinstance(criterion, dict) and isinstance(criterion.get("id"), str):
                    criteria[(task.get("id"), criterion["id"])] = criterion
    latest, cache = {}, {}
    for name in ("revisions", "results", "packets", "outcomes"):
        source = sources[name]
        source["records"] = []
        for index, row in enumerate(source["rows"]):
            artifacts = references(row, item, root) if name != "packets" else []
            record = {"row_index": index, "binding": binding(row, revision), "artifacts": artifacts}
            if name == "packets":
                record["dispatch_attempt_id"] = row.get("dispatch_attempt_id")
                record["packet_id"] = row.get("packet_id")
                record["task_id"] = row.get("task_id")
                record["receipt"] = "delivered" if row.get("delivery_stage") == "delivered" else "unknown"
                if index in source["invalid_rows"]:
                    record["binding"] = {"state": "invalid", "reason": "invalid-packet-attribution"}
            if name == "results":
                invalid = index in source["invalid_rows"]
                freshness = ({"state": "unknown", "reasons": ["invalid-result-record"]} if invalid else
                             result_freshness(row, revision, criteria, artifacts, item, cache))
                record["freshness"] = freshness
                key = (row.get("task_id"), row.get("criterion_id"))
                if all(isinstance(k, str) and k for k in key):
                    latest[key] = {"task_id": key[0], "criterion_id": key[1],
                                   "result_id": row.get("result_id"), "row_index": index,
                                   "state": "unreadable" if invalid else row.get("state", "unavailable"), "freshness": freshness}
            source["records"].append(record)
    for key in criteria:
        if key not in latest:
            latest[key] = {"task_id": key[0], "criterion_id": key[1], "result_id": None, "row_index": None,
                           "state": "missing", "freshness": {"state": "unknown", "reasons": ["no-result"]}}
    if sources["results"]["state"] not in {"read", "absent"}:
        for summary in latest.values():
            summary["freshness"] = {"state": "unknown", "reasons": ["result-history-" + sources["results"]["state"]]}
    return {"schema_version": EVIDENCE_SCHEMA_VERSION, "reader_contract_version": READER_CONTRACT_VERSION,
            "sources": sources, "revision": revision,
            "packet_summary": [{"packet_id": row.get("packet_id"), "task_id": row.get("task_id"),
                                "dispatch_attempt_id": row.get("dispatch_attempt_id"),
                                "revision_id": row.get("revision_id"),
                                "binding": record["binding"], "receipt": record["receipt"]}
                               for row, record in zip(sources["packets"]["rows"], sources["packets"]["records"])],
            "result_summary": [latest[k] for k in sorted(latest)]}


def work_view(item_dir, knowledge_dir):
    item, root = Path(item_dir), Path(knowledge_dir)
    try:
        meta = json.loads((item / "_meta.json").read_text())
    except json.JSONDecodeError as exc:
        raise ValueError(f"malformed _meta.json: {exc}") from exc
    if not isinstance(meta, dict):
        raise ValueError("_meta.json must contain an object")
    result = {k: meta.get(k, []) for k in ("branches", "tags", "related_work", "blocked_by")}
    result.update({k: meta.get(k, "") for k in ("title", "status", "project", "issue", "pr",
                   "intent_anchor", "created", "updated", "source_checkout")})
    result.update(slug=item.name, archived=item.parent.name == "_archive", ceremony_depth=meta.get("ceremony_depth"),
                  reader_contract_version=READER_CONTRACT_VERSION)
    for name, key in (("plan.md", "plan_content"), ("notes.md", "notes_content"),
                      ("execution-log.md", "exec_log_content")):
        result[key] = read_file(item / name, root)["content"]
    result.update(has_tasks=(item / "tasks.json").is_file(),
                  has_execution_log=(item / "execution-log.md").is_file())
    result["evidence"] = project(item, root)
    result["tasks_content"] = result["evidence"]["sources"]["tasks"].get("data")
    extra = []
    for path in sorted(item.glob("*.md")):
        if path.name.startswith("_") or path.name in {"plan.md", "notes.md", "execution-log.md"}:
            continue
        source = read_file(path, root)
        if source["content"] is not None:
            extra.append({"name": path.stem, "content": source["content"]})
    if extra:
        result["extra_files"] = extra
    return result


def identity_projection(work):
    """Retain work evidence except the retrospective's own publication artifacts."""
    result = copy.deepcopy(work)
    text = result.get("exec_log_content") or ""
    sections = re.split(r"(?m)(?=^## \S+\s*\|\s*source:)", text)
    kept = []
    removed = False
    for section in sections:
        lines = section.splitlines(keepends=True)
        atoms = [line for line in lines if line.startswith("Retro-prepare-atom: ")]
        if not atoms:
            kept.append(section)
            continue
        removed = True
        filtered = [line for line in lines if not line.startswith("Retro-prepare-atom: ")]
        substantive = [line for line in filtered if line.strip() and not re.match(
            r"^(## \S+\s*\|\s*source:|(?:Template-version|Captured-at):)", line)]
        if substantive:
            kept.append("".join(filtered))
    filtered_log = "".join(kept)
    if removed and re.fullmatch(r"# Execution Log: [^\n]+\n\n<!-- Auto-generated by write-execution-log.sh\. Do not edit the header\. -->\n\n", filtered_log):
        filtered_log = ""
    result["exec_log_content"] = filtered_log or None
    result["has_execution_log"] = bool(filtered_log)
    if "extra_files" in result:
        result["extra_files"] = [entry for entry in result["extra_files"]
                                 if entry.get("name") not in GENERATED_RETRO_FILES]
        if not result["extra_files"]:
            result.pop("extra_files")
    # An absent log and a log containing only prepare's atom both lack outcomes.
    outcomes = result.get("evidence", {}).get("sources", {}).get("outcomes")
    if outcomes is not None and outcomes["state"] in {"read", "absent"} and not outcomes.get("rows"):
        outcomes.update(state="absent", reason="no-outcome-records", content="", size=0, sha256=sha256(b""))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--item-dir")
    parser.add_argument("--knowledge-dir")
    parser.add_argument("--work", action="store_true")
    parser.add_argument("--identity", action="store_true")
    args = parser.parse_args()
    try:
        if args.identity:
            result = identity_projection(json.load(sys.stdin))
        else:
            if not args.item_dir or not args.knowledge_dir:
                parser.error("--item-dir and --knowledge-dir are required")
            result = (work_view if args.work else project)(args.item_dir, args.knowledge_dir)
        print(canonical(result).decode())
    except (OSError, ValueError) as exc:
        print(json.dumps({"error": str(exc)}))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
