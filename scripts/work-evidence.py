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
RESULT_CODE_DIGEST_VERSION = "2"
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


class LedgerSnapshot:
    """One invocation's parsed ledger; selections retain raw row fingerprints.

    Malformed rows belong to every selection because their owner is unknown.
    Each read returns independent data for the projection's validation passes.
    """

    def __init__(self, path, root, versions=None, *, prefix=None):
        self.source = read_file(path, root)
        self.versions = versions
        self.prefix = prefix
        self.lines = []
        if self.source["state"] != "read":
            return
        if self.source["content"] is None:
            mark(self.source, "unreadable", "invalid-utf8")
            return
        for line_number, line in enumerate(self.source["content"].splitlines(keepends=True), 1):
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
                row = None
            self.lines.append((line_number, line, row))

    def read(self, *, select=None):
        result = dict(self.source, rows=[], row_count=0, errors=[])
        if result["state"] != "read":
            return result
        selected = []
        for line_number, line, row in self.lines:
            if row is None:
                selected.append(line)
                result["errors"].append({"line": line_number, "reason": "invalid-json-row"})
                continue
            if select is not None and not select(row):
                continue
            selected.append(line)
            result["rows"].append(copy.deepcopy(row))
            if self.versions is not None and str(row.get("schema_version")) not in self.versions:
                result["errors"].append({"line": line_number, "reason": "unsupported-schema-version"})
        # Filtered streams fingerprint exactly the raw rows they expose.
        if select is not None or self.prefix is not None:
            result["content"] = "".join(selected)
            result["size"] = len(result["content"].encode())
            result["sha256"] = sha256(result["content"].encode())
        result["row_count"] = len(result["rows"])
        if result["errors"]:
            unsupported = all(e["reason"] == "unsupported-schema-version" for e in result["errors"])
            mark(result, "unsupported" if unsupported else "unreadable",
                 "unsupported-schema-version" if unsupported else "malformed-ledger")
        return result


def read_ledger(path, root, versions=None, *, select=None, prefix=None):
    return LedgerSnapshot(path, root, versions, prefix=prefix).read(select=select)


def read_directory(path, root, *, reports=False, versions=None):
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
                entry = read_file(child, root, json_file=child.suffix == ".json", versions=versions or {"1"})
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
            elif "execution_sequence" in row and (type(row["execution_sequence"]) is not int or row["execution_sequence"] < 1):
                invalid = "invalid-execution-sequence"
            elif "execution_sequence" in row and row["execution_sequence"] in seen and seen[row["execution_sequence"]] != row["result_id"]:
                invalid = "duplicate-execution-sequence"
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
        if kind == "results" and not invalid and "execution_sequence" in row:
            seen[row["execution_sequence"]] = row["result_id"]
        if invalid:
            source["invalid_rows"].append(index)
            source["errors"].append({"row_index": index, "reason": invalid})
            mark(source, "unreadable", "invalid-" + kind + "-record")


def code_identity(worktree, excluded_paths=(), result_exclusion=None):
    """Hash index entries, tracked worktree bytes, and nonignored untracked files."""
    version = RESULT_CODE_DIGEST_VERSION if result_exclusion else CODE_DIGEST_VERSION
    result = {"state": "unreadable", "reason": "code-unavailable", "worktree": str(worktree),
              "head": None, "digest": None, "digest_version": version}
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
        result_ledger = None
        if result_exclusion:
            result_item, result_id = result_exclusion
            excluded.append((Path(result_item) / "results" / result_id).resolve())
            result_ledger = (Path(result_item) / "results.jsonl").resolve()
        def omit(path):
            return any(path.is_relative_to(p) for p in excluded)
        entries = git("ls-files", "--stage", "-z")
        names = {}
        index = []
        tracked = set()
        for entry in entries.split(b"\0"):
            if not entry:
                continue
            metadata, name = entry.split(b"\t", 1)
            path = root / os.fsdecode(name)
            if omit(path):
                continue
            index.append([os.fsdecode(name), metadata.decode()])
            tracked.add(name)
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
                    record["submodule"] = code_identity(path, excluded_paths, result_exclusion)
                    if record["submodule"]["state"] != "read":
                        return mark(result, "unreadable", "submodule-unavailable")
                    record["submodule"].pop("worktree", None)
                elif stat.S_ISREG(info.st_mode):
                    raw = path.read_bytes()
                    if path == result_ledger:
                        # Remove only this publication; malformed and older evidence still participates.
                        retained = []
                        for line in raw.splitlines(keepends=True):
                            try:
                                row = json.loads(line)
                            except (ValueError, UnicodeError):
                                row = None
                            if not isinstance(row, dict) or row.get("result_id") != result_id:
                                retained.append(line)
                        raw = b"".join(retained)
                        if not raw and name not in tracked:
                            continue
                    record["sha256"] = sha256(raw)
                else:
                    return mark(result, "unreadable", "unsupported-code-file")
            except FileNotFoundError:
                record["deleted"] = True
            files.append(record)
        result.update(state="read", reason=None,
                      digest=sha256(canonical({"version": version, "index": index, "files": files})))
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
        if not worktree or end.get("digest_version") not in {CODE_DIGEST_VERSION, RESULT_CODE_DIGEST_VERSION}:
            unknown.append("code-identity-unavailable")
        else:
            result_id = row.get("result_id")
            excluded = (item / "results" / str(result_id),) if result_id else ()
            key = (worktree, str(result_id), end.get("digest_version"))
            if key not in cache:
                cache[key] = (code_identity(worktree, result_exclusion=(item, str(result_id)))
                              if result_id and end["digest_version"] == RESULT_CODE_DIGEST_VERSION
                              else code_identity(worktree, excluded))
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


REVIEW_PURPOSES = {"criterion-adequacy", "integration"}
REVIEW_EVALUATOR_FIELDS = {"evaluator_locator", "evaluator_template_version", "framework", "model", "final_round"}


def review_json(item, relative, expected=None):
    source = read_file(Path(item) / relative, item, json_file=True, versions={"1", "2"})
    if source["state"] != "read" or (expected is not None and source["sha256"] != expected):
        raise ValueError("review artifact unavailable or hash mismatch: " + relative)
    return source["data"]


def validate_review_judgments(data, purpose):
    if not isinstance(data, dict) or set(data) != {"schema_version", "outcome", "verdict", "reason", "judgments", "dispositions"}:
        raise ValueError("dispositions must contain only schema_version, outcome, verdict, reason, judgments, dispositions")
    if type(data["schema_version"]) is not int or data["schema_version"] != 1:
        raise ValueError("dispositions schema_version must be 1")
    if data["outcome"] not in {"completed", "failed", "skipped", "needs-decision"}:
        raise ValueError("invalid review outcome")
    if not isinstance(data["verdict"], str) or not data["verdict"].strip():
        raise ValueError("review verdict is required")
    if data["outcome"] in {"skipped", "needs-decision"}:
        if not isinstance(data["reason"], str) or not data["reason"].strip():
            raise ValueError("this review outcome requires a reason")
    elif data["reason"] is not None:
        raise ValueError("completed/failed review reason must be null")
    if not isinstance(data["judgments"], list) or not data["judgments"]:
        raise ValueError("at least one authored judgment is required")
    purposes = set()
    for judgment in data["judgments"]:
        if not isinstance(judgment, dict) or set(judgment) != {"purpose", "judgment", "rationale", "result_ids"}:
            raise ValueError("judgments accept purpose, judgment, rationale, result_ids only; command results belong to the executor")
        if judgment["purpose"] not in REVIEW_PURPOSES or judgment["purpose"] in purposes:
            raise ValueError("judgment purposes must be distinct supported purposes")
        purposes.add(judgment["purpose"])
        if any(not isinstance(judgment[k], str) or not judgment[k].strip() for k in ("judgment", "rationale")):
            raise ValueError("judgment and rationale must be authored text")
        ids = judgment["result_ids"]
        if not isinstance(ids, list) or any(not isinstance(r, str) or not r.strip() for r in ids) or len(ids) != len(set(ids)):
            raise ValueError("result_ids must be distinct nonempty references")
    if purpose not in purposes:
        raise ValueError("judgments must address the prepared purpose")
    if not isinstance(data["dispositions"], list):
        raise ValueError("dispositions must be an array")
    for disposition in data["dispositions"]:
        if not isinstance(disposition, dict) or set(disposition) != {"finding", "disposition", "reason"} or any(
                not isinstance(v, str) or not v.strip() for v in disposition.values()):
            raise ValueError("each disposition requires authored finding, disposition, reason")
    return data


def validate_review_evaluator(data):
    if not isinstance(data, dict) or set(data) != REVIEW_EVALUATOR_FIELDS:
        raise ValueError("evaluator manifest must declare exactly " + ", ".join(sorted(REVIEW_EVALUATOR_FIELDS)))
    if any(not isinstance(data[k], str) or not data[k].strip() for k in REVIEW_EVALUATOR_FIELDS - {"final_round"}):
        raise ValueError("evaluator identity fields must be nonempty text")
    if not re.fullmatch(r"[0-9a-f]{12}", data["evaluator_template_version"]):
        raise ValueError("evaluator template version must be 12 lowercase hex")
    if type(data["final_round"]) is not int or data["final_round"] < 1:
        raise ValueError("final_round must be a positive integer")
    return data


def review_prepared(item, attempt):
    if not isinstance(attempt, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", attempt):
        raise ValueError("invalid review attempt id")
    base = "reviews/" + attempt
    prepared = review_json(item, base + "/prepared.json")
    if prepared.get("schema_version") != 1 or prepared.get("record_type") != "review-input" or prepared.get("attempt_id") != attempt:
        raise ValueError("invalid prepared review identity")
    if prepared.get("ceremony") not in {"spec-design", "spec-post-plan"} or prepared.get("purpose") not in REVIEW_PURPOSES:
        raise ValueError("invalid prepared ceremony or purpose")
    if not isinstance(prepared.get("revision_id"), str) or not re.fullmatch(r"[0-9a-f]{12}", prepared["revision_id"]):
        raise ValueError("invalid prepared revision")
    for name, filename in (("plan", "plan.md"), ("tasks", "tasks.json"), ("anchor", "anchor.md")):
        if prepared.get(name + "_path") != base + "/" + filename:
            raise ValueError("invalid prepared snapshot reference")
        source = read_file(Path(item) / prepared[name + "_path"], item)
        if source["state"] != "read" or source["sha256"] != prepared.get(name + "_sha256"):
            raise ValueError("prepared " + name + " snapshot hash mismatch")
    history = read_ledger(Path(item) / "revisions.jsonl", item, {"1"})
    validate_records(history, "revisions")
    if history["state"] != "read":
        raise ValueError("review revision history unavailable")
    row = next((r for r in history["rows"] if r.get("record_type", "revision") == "revision" and r.get("revision_id") == prepared["revision_id"]), None)
    if row is None or any(row.get(k + "_sha256") != prepared[k + "_sha256"] for k in ("plan", "tasks")):
        raise ValueError("prepared snapshot does not match committed revision")
    source = prepared.get("source_identity")
    if prepared["purpose"] == "integration" and (not isinstance(source, dict) or source.get("state") != "read" or not source.get("head") or not source.get("digest")):
        raise ValueError("integration review requires frozen source identity")
    return prepared


def review_sealed(item, attempt):
    prepared = review_prepared(item, attempt)
    base = "reviews/" + attempt
    sealed = review_json(item, base + "/sealed/seal.json")
    if sealed.get("schema_version") != 1 or sealed.get("record_type") != "review-seal" or sealed.get("attempt_id") != attempt:
        raise ValueError("invalid review seal identity")
    if any(sealed.get(k) != prepared[k] for k in ("revision_id", "ceremony", "purpose")):
        raise ValueError("review seal does not match prepared identity")
    for name, path in (("prepared", base + "/prepared.json"), ("output", base + "/sealed/output.md"),
                       ("disposition_ledger", base + "/sealed/dispositions.json"),
                       ("cited_results", base + "/sealed/cited-results.json")):
        if sealed.get(name + "_path") != path:
            raise ValueError("invalid seal artifact reference")
        source = read_file(Path(item) / path, item)
        if source["state"] != "read" or source["sha256"] != sealed.get(name + "_sha256"):
            raise ValueError("sealed " + name + " hash mismatch")
    judgments = validate_review_judgments(review_json(item, sealed["disposition_ledger_path"]), prepared["purpose"])
    validate_review_evaluator(sealed.get("evaluator"))
    frozen = review_json(item, sealed["cited_results_path"])
    ids = sorted({rid for j in judgments["judgments"] for rid in j["result_ids"]})
    if frozen.get("schema_version") != 1 or frozen.get("result_ids") != ids or not isinstance(frozen.get("results"), list) or sorted(
            r.get("row", {}).get("result_id", "") for r in frozen["results"]) != ids:
        raise ValueError("frozen result citations differ from review judgments")
    return prepared, sealed, judgments


def review_evidence(item, attempt):
    prepared, sealed, judgments = review_sealed(item, attempt)
    path = "reviews/" + attempt + "/sealed/seal.json"
    manifest = {"schema_version": 2, **sealed["evaluator"], "revision_id": prepared["revision_id"],
                "purpose": prepared["purpose"], "source_plan_sha256": prepared["plan_sha256"],
                "source_tasks_sha256": prepared["tasks_sha256"],
                "disposition_ledger_sha256": sealed["disposition_ledger_sha256"],
                "review_path": path, "review_sha256": sha256((Path(item) / path).read_bytes())}
    return manifest, prepared, sealed, judgments


def review_projection(item, root, revision, sources):
    summary = []
    attempts = sorted({Path(e["path"]).relative_to(Path(item).relative_to(root)).parts[1]
                       for e in sources["reviews"]["entries"]
                       if len(Path(e["path"]).relative_to(Path(item).relative_to(root)).parts) >= 3})
    attempts = sorted(set(attempts) | {r["attempt_id"] for r in sources["outcomes"]["rows"]
                                     if str(r.get("schema_version")) == "2" and isinstance(r.get("attempt_id"), str)})
    for attempt in attempts:
        if attempt.startswith("."):
            continue
        row = {"attempt_id": attempt, "state": "unreadable", "reason": None,
               "revision_id": None, "purpose": None, "ceremony": None,
               "binding": {"state": "unknown", "reason": "review-input-unavailable"},
               "result_ids": [], "outcomes": [], "prepared_path": "reviews/" + attempt + "/prepared.json"}
        try:
            if not (item / "reviews" / attempt / "prepared.json").exists():
                row.update(state="missing", reason="prepared-review-unavailable")
                summary.append(row)
                continue
            prepared = review_prepared(item, attempt)
            row.update({k: prepared[k] for k in ("revision_id", "purpose", "ceremony")})
            row.update(binding=binding(prepared, revision), state="unsealed", reason="review-output-not-sealed")
            if (item / "reviews" / attempt / "sealed").exists():
                _, sealed, judgments = review_sealed(item, attempt)
                row.update(state="sealed", reason=None, seal_path="reviews/" + attempt + "/sealed/seal.json",
                           outcome=judgments["outcome"], verdict=judgments["verdict"],
                           execution_evidence="cited" if any(j["result_ids"] for j in judgments["judgments"]) else "none",
                           result_ids=sorted({rid for j in judgments["judgments"] for rid in j["result_ids"]}))
        except (ValueError, OSError, TypeError, KeyError) as exc:
            row.update(state="unreadable", reason=str(exc))
        summary.append(row)
    return summary


def _review_requirement_projection(history, revision):
    head = revision.get("head")
    result = {"state": "absent", "reason": "no-revision", "value": None,
              "revision_id": None, "decision_id": None, "inherited_from_revision": None}
    if history["state"] not in {"read", "absent"}:
        result.update(state="unreadable", reason=history["reason"])
    elif head:
        states = {}
        for row in history["rows"]:
            rid = row["revision_id"]
            if row.get("record_type", "revision") == "revision":
                inherited = row.get("inherited_from_revision")
                source = states.get(inherited, {}) if "review_requirement" not in row.get("decision_overrides", {}) else {}
                states[rid] = {"state": "read", "reason": None, "value": row.get("review_requirement"),
                               "revision_id": source.get("revision_id", rid), "decision_id": source.get("decision_id"),
                               "inherited_from_revision": inherited if source else None}
            elif "review_requirement" in row and rid in states:
                states[rid].update(value=row["review_requirement"], revision_id=rid,
                                   decision_id=row.get("decision_id"), inherited_from_revision=None)
        result = states[head["revision_id"]]
        value = result["value"]
        if not isinstance(value, dict) or value.get("disposition") not in {"required", "not-required", "pending"} or any(
                (not isinstance(value.get(k), str) or not value[k].strip()) and not (k == "by" and value.get("disposition") == "pending" and value.get(k) is None) for k in ("by", "note")):
            result.update(state="unreadable", reason="missing-or-invalid-authored-review-requirement")
    return result


def review_requirement_projection(history, revision):
    try:
        return _review_requirement_projection(history, revision)
    except (KeyError, TypeError, ValueError):
        return {"state": "unreadable", "reason": "invalid-authored-review-requirement",
                "value": None, "revision_id": None, "decision_id": None, "inherited_from_revision": None}


def packet_summary(rows, records):
    """One entry per packet id. Rows supersede by append (assembled, then synthesized), so the latest row
    describes the packet; superseded_rows counts the history behind it."""
    summary, order = {}, []
    for row, record in zip(rows, records):
        packet_id = row.get("packet_id")
        if packet_id not in summary:
            order.append(packet_id)
        prior = summary.get(packet_id)
        summary[packet_id] = {"packet_id": packet_id, "task_id": row.get("task_id"),
                              "dispatch_attempt_id": row.get("dispatch_attempt_id"),
                              "revision_id": row.get("revision_id"),
                              "binding": record["binding"], "receipt": record["receipt"],
                              "delivery_stage": record.get("delivery_stage"),
                              "synthesis": record.get("synthesis"), "synthesis_waiver": record.get("synthesis_waiver"),
                              "superseded_rows": (prior["superseded_rows"] + 1) if prior else 0}
    return [summary[k] for k in order]


def project(item_dir, knowledge_dir, *, packet_ledger=None):
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
        "packets": (packet_ledger if packet_ledger is not None else
                    LedgerSnapshot(root / "_packets" / "packets.jsonl", root, {"1", "2"})).read(
                        select=lambda row: row.get("work_item") == item.name),
        "outcomes": read_ledger(item / "execution-log.md", root, {"1", "2"}, prefix="Spec-outcome-record: "),
        "reviews": read_directory(item / "reviews", root, versions={"1", "2"}),
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
    revision["review_requirement"] = review_requirement_projection(revisions, revision)
    review_summary = review_projection(item, root, revision, sources)
    if any(r["state"] == "unreadable" for r in review_summary):
        mark(sources["reviews"], "unreadable", "invalid-review-artifacts")
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
                record["delivery_stage"] = row.get("delivery_stage")
                synthesis = row.get("synthesis") if isinstance(row.get("synthesis"), dict) else None
                record["synthesis"] = ({"by": synthesis.get("by"), "kept": len(synthesis.get("kept") or []),
                                        "dropped": len(synthesis.get("dropped") or []), "added": len(synthesis.get("added") or [])}
                                       if synthesis else None)
                record["synthesis_waiver"] = row.get("synthesis_waiver") if isinstance(row.get("synthesis_waiver"), dict) else None
                if index in source["invalid_rows"]:
                    record["binding"] = {"state": "invalid", "reason": "invalid-packet-attribution"}
            if name == "outcomes":
                if str(row.get("schema_version")) == "1":
                    record["binding"] = {"state": "legacy-unbound", "reason": "schema-1-outcome"}
                elif str(row.get("schema_version")) == "2":
                    try:
                        manifest, prepared, _, judgments = review_evidence(item, row.get("attempt_id"))
                        if row.get("evidence") != manifest or any(row.get(k) != prepared[k] for k in ("revision_id", "ceremony", "purpose")) or any(
                                row.get(k) != judgments[k] for k in ("outcome", "verdict", "reason")):
                            raise ValueError("outcome differs from sealed review")
                        artifacts.extend(references(prepared, item, root))
                        artifacts.extend(references(manifest, item, root))
                    except (ValueError, OSError, TypeError, KeyError) as exc:
                        record["binding"] = {"state": "invalid", "reason": str(exc)}
                        mark(source, "unreadable", "invalid-bound-outcome")
                for review in review_summary:
                    if review["attempt_id"] == row.get("attempt_id"):
                        review["outcomes"].append({"outcome_id": row.get("outcome_id"), "outcome": row.get("outcome"),
                                                   "binding": record["binding"]})
            if name == "results":
                invalid = index in source["invalid_rows"]
                freshness = ({"state": "unknown", "reasons": ["invalid-result-record"]} if invalid else
                             result_freshness(row, revision, criteria, artifacts, item, cache))
                record["freshness"] = freshness
                key = (row.get("task_id"), row.get("criterion_id"))
                if all(isinstance(k, str) and k for k in key):
                    prior = latest.get(key)
                    sequence = row.get("execution_sequence")
                    order = (1, sequence) if type(sequence) is int and sequence > 0 else (0, index)
                    if prior is not None:
                        previous_row = source["rows"][prior["row_index"]]
                        previous_sequence = previous_row.get("execution_sequence")
                        previous_order = ((1, previous_sequence) if type(previous_sequence) is int and previous_sequence > 0
                                          else (0, prior["row_index"]))
                    else:
                        previous_order = (-1, -1)
                    if order >= previous_order:
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
            "sources": sources, "revision": revision, "review_summary": review_summary,
            "packet_summary": packet_summary(sources["packets"]["rows"], sources["packets"]["records"]),
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
