#!/usr/bin/env python3
"""Sole writer and validator for coordinated stream reconciliation evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


SCHEMA_VERSION = 2
WORKTREE_SCHEMA_VERSION = 1
TERMINAL_WORKTREE_STATES = {"removed", "swept"}
VERDICTS = {"full", "partial", "none"}
TREES = {"writer", "read-only"}
TOKEN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


def fail(message: str) -> None:
    raise SystemExit(f"[coordinate-reconcile] Error: {message}")


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def immutable_write(path: Path, data: bytes) -> None:
    if path.exists():
        if path.read_bytes() != data:
            fail(f"immutable object collision at {path}")
        return
    atomic_write(path, data)


def require_token(name: str, value: str) -> str:
    if not TOKEN.fullmatch(value or ""):
        fail(f"invalid {name}: {value!r}")
    return value


def git_common(common_dir: str, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    proc = subprocess.run(
        ["git", "--git-dir", str(common_dir), *args],
        text=True, capture_output=True, check=False,
    )
    if check and proc.returncode != 0:
        fail(proc.stderr.strip() or proc.stdout.strip() or f"git {args[0] if args else ''} failed")
    return proc


def accepted_ref_names(slug: str, stream: str, attempt: str) -> dict:
    base = f"refs/lore/accepted/{slug}/{stream}/{attempt}"
    return {"integrated": f"{base}/integrated", "source": f"{base}/source"}


def resolve_commit(common_dir: str, candidate: str | None) -> str | None:
    """Return the canonical OID if candidate names an existing commit, else None."""
    if not candidate:
        return None
    if git_common(common_dir, "cat-file", "-e", f"{candidate}^{{commit}}", check=False).returncode != 0:
        return None
    return git_common(common_dir, "rev-parse", "--verify", f"{candidate}^{{commit}}").stdout.strip()


def write_accepted_ref(common_dir: str, ref: str, sha: str) -> None:
    """Create-only pin of ref -> sha. Same OID is idempotent; a different OID is refused."""
    if git_common(common_dir, "check-ref-format", ref, check=False).returncode != 0:
        fail(f"invalid acceptance ref name: {ref}")
    existing = git_common(common_dir, "rev-parse", "--verify", "--quiet", ref, check=False)
    current = existing.stdout.strip()
    if existing.returncode == 0 and current:
        if current != sha:
            fail(f"acceptance ref {ref} is immutable; use a new attempt id")
        return
    git_common(common_dir, "update-ref", ref, sha, "")


def audit_accepted_refs(common_dir: str | None, refs: list) -> None:
    """Fail closed unless every recorded acceptance ref resolves to its recorded SHA."""
    if not common_dir:
        fail("acceptance ref audit requires git_common_dir")
    for entry in refs:
        ref = entry.get("ref") if isinstance(entry, dict) else None
        sha = entry.get("sha") if isinstance(entry, dict) else None
        if not ref or not sha:
            fail(f"malformed acceptance ref record: {entry!r}")
        proc = git_common(common_dir, "rev-parse", "--verify", "--quiet", ref, check=False)
        resolved = proc.stdout.strip()
        if proc.returncode != 0 or not resolved:
            fail(f"acceptance ref is missing: {ref}")
        if resolved != sha:
            fail(f"acceptance ref mismatch: {ref} resolves to {resolved} expected {sha}")


def load_json(path: Path, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"{label} is missing: {path}")
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"{label} is unreadable: {exc}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def worktree_record(kdir: Path, worktree_id: str) -> tuple[dict, str]:
    roots = (
        (kdir / "_coordination" / "worktrees" / "archive", "archive"),
        (kdir / "_coordination" / "worktrees" / "registry", "registry"),
    )
    for root, source in roots:
        path = root / f"{worktree_id}.json"
        if path.is_file():
            row = load_json(path, f"worktree {source} record")
            if row.get("schema_version") != WORKTREE_SCHEMA_VERSION:
                fail(f"worktree {source} record declares unsupported schema_version={row.get('schema_version')!r}")
            return row, source
    fail(f"worktree identity is absent from registry and archive: {worktree_id}")


def validate_identity(row: dict, slug: str, stream: str, attempt: str, worktree_id: str) -> None:
    expected = {
        "worktree_id": worktree_id,
        "owner_item": slug,
        "stream_id": stream,
        "attempt_id": attempt,
    }
    mismatches = {key: {"expected": value, "observed": row.get(key)}
                  for key, value in expected.items() if row.get(key) != value}
    if mismatches:
        fail(f"worktree identity mismatch: {json.dumps(mismatches, sort_keys=True)}")


def cleanup_status(row: dict, source: str) -> dict:
    proof = row.get("cleanup_proof")
    branch = proof.get("branch_disposition") if isinstance(proof, dict) else None
    verified = bool(
        source == "archive"
        and row.get("state") in TERMINAL_WORKTREE_STATES
        and isinstance(proof, dict)
        and proof.get("path_absent") is True
        and proof.get("git_registry_absent") is True
        and isinstance(branch, str)
        and (branch == "deleted" or branch.startswith("retained:"))
        and isinstance(proof.get("verified_at"), str)
        and proof.get("verified_at")
    )
    return {
        "verified": verified,
        "state": row.get("state"),
        "record_source": source,
        "proof": proof if isinstance(proof, dict) else None,
    }


class Store:
    def __init__(self, kdir: Path, slug: str):
        self.kdir = kdir
        self.slug = slug
        self.root = kdir / "_coordination" / "reconciliation" / slug
        self.state_path = self.root / "streams.json"
        self.lock_path = self.root / ".writer.lock"

    def load(self, allow_missing: bool = False) -> dict:
        if not self.state_path.exists():
            if allow_missing:
                return {"schema_version": SCHEMA_VERSION, "work_item": self.slug, "streams": []}
            fail(f"reconciliation state is missing: {self.state_path}")
        state = load_json(self.state_path, "reconciliation state")
        if state.get("schema_version") != SCHEMA_VERSION:
            fail(f"unsupported reconciliation schema_version={state.get('schema_version')!r}")
        if state.get("work_item") != self.slug or not isinstance(state.get("streams"), list):
            fail("reconciliation state identity or streams shape is invalid")
        return state

    def locked(self):
        self.root.mkdir(parents=True, exist_ok=True)
        handle = self.lock_path.open("a+")
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        return handle

    def write(self, state: dict) -> None:
        state["updated_at"] = now()
        state["streams"] = sorted(state["streams"], key=lambda row: row["stream_id"])
        atomic_write(self.state_path, json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True).encode() + b"\n")

    def stream(self, state: dict, stream_id: str, tree: str, depends_on: list[str]) -> dict:
        for row in state["streams"]:
            if row.get("stream_id") == stream_id:
                if row.get("tree") != tree or row.get("depends_on") != depends_on:
                    fail(f"stream {stream_id} was already frozen with different tree/dependency identity")
                return row
        row = {"stream_id": stream_id, "tree": tree, "depends_on": depends_on, "attempts": []}
        state["streams"].append(row)
        return row

    @staticmethod
    def attempt(stream: dict, attempt_id: str, create: bool = False) -> dict:
        for row in stream["attempts"]:
            if row.get("attempt_id") == attempt_id:
                return row
        if not create:
            fail(f"unknown attempt {stream['stream_id']}/{attempt_id}")
        row = {"attempt_id": attempt_id, "status": "pending", "updated_at": now()}
        stream["attempts"].append(row)
        return row

    def freeze_object(self, kind: str, stream: str, attempt: str, patch_path: Path,
                      metadata: dict) -> dict:
        try:
            patch = patch_path.read_bytes()
        except OSError as exc:
            fail(f"cannot read {kind} patch: {exc}")
        patch_hash = sha256(patch)
        object_dir = self.root / "objects"
        stored_patch = object_dir / f"sha256-{patch_hash}.patch"
        immutable_write(stored_patch, patch)
        manifest = {
            "schema_version": 1,
            "kind": kind,
            "work_item": self.slug,
            "stream_id": stream,
            "attempt_id": attempt,
            "patch": {"sha256": patch_hash, "bytes": len(patch),
                      "path": str(stored_patch.relative_to(self.kdir))},
            **metadata,
        }
        body = canonical_json(manifest)
        manifest_hash = sha256(body)
        stored_manifest = object_dir / f"sha256-{manifest_hash}.json"
        immutable_write(stored_manifest, body)
        return {"sha256": manifest_hash, "path": str(stored_manifest.relative_to(self.kdir)),
                "patch_sha256": patch_hash}

    def validate_manifest(self, ref: dict, expected_kind: str, stream: str, attempt: str) -> dict:
        if not isinstance(ref, dict) or set(ref) != {"sha256", "path", "patch_sha256"}:
            fail(f"{expected_kind} manifest reference is malformed")
        object_root = (self.root / "objects").resolve()
        path = (self.kdir / ref["path"]).resolve()
        if object_root not in path.parents:
            fail(f"manifest path escapes the reconciliation object store: {ref['path']}")
        body = path.read_bytes() if path.is_file() else fail(f"manifest object is missing: {path}")
        if sha256(body) != ref["sha256"]:
            fail(f"manifest hash mismatch: {path}")
        manifest = json.loads(body)
        if manifest.get("schema_version") != 1 or manifest.get("kind") != expected_kind:
            fail(f"manifest kind/version mismatch: {path}")
        if manifest.get("work_item") != self.slug or manifest.get("stream_id") != stream or manifest.get("attempt_id") != attempt:
            fail(f"manifest identity mismatch: {path}")
        patch = manifest.get("patch")
        patch_path = (self.kdir / patch.get("path", "")).resolve() if isinstance(patch, dict) else None
        if patch_path and object_root not in patch_path.parents:
            fail(f"patch path escapes the reconciliation object store: {patch.get('path')}")
        if not patch_path or not patch_path.is_file() or sha256(patch_path.read_bytes()) != ref["patch_sha256"]:
            fail(f"manifest patch is missing or hash-invalid: {path}")
        return manifest


def parse_depends(raw: str) -> list[str]:
    values = []
    for value in raw.split(",") if raw else []:
        token = require_token("dependency", value.strip())
        if token not in values:
            values.append(token)
    return values


def command_freeze_source(args, store: Store) -> dict:
    stream_id = require_token("stream", args.stream)
    attempt_id = require_token("attempt", args.attempt)
    worktree_id = require_token("worktree id", args.worktree_id)
    depends_on = parse_depends(args.depends_on)
    if args.tree not in TREES:
        fail(f"invalid tree: {args.tree!r}")
    identity, source = worktree_record(store.kdir, worktree_id)
    validate_identity(identity, store.slug, stream_id, attempt_id, worktree_id)
    if source != "registry" or identity.get("state") not in {"quiescent", "reconciling"}:
        fail("source freeze requires a live quiescent|reconciling registry identity")
    manifest_ref = store.freeze_object("source", stream_id, attempt_id, Path(args.patch), {
        "worktree_id": worktree_id,
        "allocation_base_sha": identity.get("allocation_base_sha"),
        "temporary_branch": identity.get("temporary_branch"),
        "head_sha": args.head_sha,
        "changed_paths": args.changed_path,
    })
    with store.locked():
        state = store.load(allow_missing=True)
        stream = store.stream(state, stream_id, args.tree, depends_on)
        attempt = store.attempt(stream, attempt_id, create=True)
        if attempt.get("source_manifest") not in (None, manifest_ref):
            fail("attempt source manifest is immutable; use a new attempt id")
        attempt.update({"worktree_id": worktree_id, "status": "source_frozen",
                        "source_manifest": manifest_ref, "updated_at": now()})
        store.write(state)
    return {"status": "source_frozen", "stream_id": stream_id, "attempt_id": attempt_id,
            "manifest": manifest_ref}


def command_conflict(args, store: Store) -> dict:
    if not args.conflict_path:
        fail("record-conflict requires at least one --conflict-path")
    with store.locked():
        state = store.load()
        stream = next((s for s in state["streams"] if s.get("stream_id") == args.stream), None)
        if stream is None:
            fail(f"unknown stream {args.stream}")
        attempt = store.attempt(stream, args.attempt)
        store.validate_manifest(attempt.get("source_manifest"), "source", args.stream, args.attempt)
        attempt.update({"status": "needs_judgment", "conflicts": sorted(set(args.conflict_path)),
                        "conflict_reason": args.reason, "updated_at": now()})
        store.write(state)
    return {"status": "needs_judgment", "stream_id": args.stream,
            "attempt_id": args.attempt, "conflicts": sorted(set(args.conflict_path))}


def command_merge(args, store: Store) -> dict:
    """Attempt a no-commit merge; abort and record conflicts without editing them."""
    repo = Path(args.repo or os.getcwd()).resolve()
    clean = subprocess.run(
        ["git", "-C", str(repo), "status", "--porcelain"],
        text=True, capture_output=True, check=False,
    )
    if clean.returncode != 0:
        fail(clean.stderr.strip() or "cannot inspect control checkout")
    if clean.stdout:
        fail("control checkout must be clean before reconciliation merge")
    with store.locked():
        state = store.load()
        stream = next((s for s in state["streams"] if s.get("stream_id") == args.stream), None)
        if stream is None:
            fail(f"unknown stream {args.stream}")
        attempt = store.attempt(stream, args.attempt)
        store.validate_manifest(attempt.get("source_manifest"), "source", args.stream, args.attempt)
        identity, source = worktree_record(store.kdir, attempt["worktree_id"])
        validate_identity(identity, store.slug, args.stream, args.attempt, attempt["worktree_id"])
        if source != "registry" or identity.get("state") not in {"quiescent", "reconciling"}:
            fail("merge requires a live quiescent|reconciling worktree identity")
        source_ref = identity.get("temporary_branch")
        if not isinstance(source_ref, str) or not source_ref:
            fail("worktree identity has no temporary_branch")
        merged = subprocess.run(
            ["git", "-C", str(repo), "merge", "--no-ff", "--no-commit", source_ref],
            text=True, capture_output=True, check=False,
        )
        if merged.returncode == 0:
            attempt.update({"status": "merge_ready", "control_checkout": str(repo),
                            "source_ref": source_ref, "updated_at": now()})
            store.write(state)
            return {"status": "merge_ready", "stream_id": args.stream,
                    "attempt_id": args.attempt, "source_ref": source_ref,
                    "control_checkout": str(repo)}
        conflicts = subprocess.run(
            ["git", "-C", str(repo), "diff", "--name-only", "--diff-filter=U"],
            text=True, capture_output=True, check=False,
        )
        conflict_paths = sorted({line for line in conflicts.stdout.splitlines() if line})
        subprocess.run(
            ["git", "-C", str(repo), "merge", "--abort"],
            text=True, capture_output=True, check=False,
        )
        if not conflict_paths:
            fail(merged.stderr.strip() or merged.stdout.strip() or "merge failed without conflict paths")
        attempt.update({"status": "needs_judgment", "conflicts": conflict_paths,
                        "conflict_reason": "merge conflict requires coordinator judgment and worker source edits",
                        "updated_at": now()})
        store.write(state)
        return {"status": "needs_judgment", "stream_id": args.stream,
                "attempt_id": args.attempt, "conflicts": conflict_paths,
                "merge_aborted": True}


def command_freeze_integrated(args, store: Store) -> dict:
    if args.verdict not in VERDICTS:
        fail(f"invalid verdict: {args.verdict!r}")
    with store.locked():
        state = store.load()
        stream = next((s for s in state["streams"] if s.get("stream_id") == args.stream), None)
        if stream is None:
            fail(f"unknown stream {args.stream}")
        attempt = store.attempt(stream, args.attempt)
        source = store.validate_manifest(attempt.get("source_manifest"), "source", args.stream, args.attempt)

        identity, _ = worktree_record(store.kdir, attempt.get("worktree_id"))
        common_dir = identity.get("git_common_dir")
        if not common_dir:
            fail("worktree identity carries no git_common_dir for acceptance refs")
        integrated_commit = resolve_commit(common_dir, args.integrated_sha)
        if integrated_commit is None:
            fail(f"integrated sha does not resolve to a commit: {args.integrated_sha!r}")
        source_tip = (resolve_commit(common_dir, source.get("head_sha"))
                      or resolve_commit(common_dir, source.get("temporary_branch")))
        if source_tip is None:
            fail("stream tip does not resolve: neither source head_sha nor temporary_branch is a commit")
        names = accepted_ref_names(store.slug, args.stream, args.attempt)
        acceptance_refs = [
            {"ref": names["integrated"], "sha": integrated_commit},
            {"ref": names["source"], "sha": source_tip},
        ]
        # Anchor the accepted commits before the manifest and streams.json record
        # the acceptance: a crash after this point leaves at most an orphan ref,
        # never an acceptance without its durable anchor.
        for entry in acceptance_refs:
            write_accepted_ref(common_dir, entry["ref"], entry["sha"])

        metadata = {
            "worktree_id": attempt.get("worktree_id"),
            "integrated_sha": args.integrated_sha,
            "source_manifest_sha256": attempt["source_manifest"]["sha256"],
            "changed_paths": args.changed_path,
            "verdict": args.verdict,
            "acceptance_refs": acceptance_refs,
        }
        manifest_ref = store.freeze_object("integrated", args.stream, args.attempt, Path(args.patch), metadata)
        if attempt.get("integrated_manifest") not in (None, manifest_ref):
            fail("attempt integrated manifest is immutable; use a new attempt id")
        if attempt.get("verdict") not in (None, args.verdict):
            fail("attempt verdict is immutable; use a new attempt id")
        attempt.update({"status": "integrated", "verdict": args.verdict,
                        "integrated_manifest": manifest_ref, "updated_at": now()})
        store.write(state)
    return {"status": "integrated", "stream_id": args.stream, "attempt_id": args.attempt,
            "source_manifest": source, "manifest": manifest_ref, "verdict": args.verdict,
            "acceptance_refs": acceptance_refs}


def command_status(args, store: Store) -> dict:
    state = store.load()
    output = {"schema_version": SCHEMA_VERSION, "work_item": store.slug, "streams": [], "valid": True}
    for stream in state["streams"]:
        rendered = {key: stream.get(key) for key in ("stream_id", "tree", "depends_on")}
        rendered["attempts"] = []
        for attempt in stream.get("attempts", []):
            row = dict(attempt)
            try:
                if attempt.get("source_manifest"):
                    store.validate_manifest(attempt["source_manifest"], "source", stream["stream_id"], attempt["attempt_id"])
                integrated_manifest = None
                if attempt.get("integrated_manifest"):
                    integrated_manifest = store.validate_manifest(attempt["integrated_manifest"], "integrated", stream["stream_id"], attempt["attempt_id"])
                identity, source = worktree_record(store.kdir, attempt["worktree_id"])
                validate_identity(identity, store.slug, stream["stream_id"], attempt["attempt_id"], attempt["worktree_id"])
                if integrated_manifest is not None and isinstance(integrated_manifest.get("acceptance_refs"), list):
                    audit_accepted_refs(identity.get("git_common_dir"), integrated_manifest["acceptance_refs"])
                row["cleanup"] = cleanup_status(identity, source)
                row["valid"] = True
            except (SystemExit, OSError, json.JSONDecodeError) as exc:
                row["valid"] = False
                row["validation_error"] = str(exc)
                row["cleanup"] = {"verified": False}
                output["valid"] = False
            row["terminal_full_cleaned"] = bool(
                row.get("status") == "integrated" and row.get("verdict") == "full"
                and row.get("valid") and row["cleanup"].get("verified")
            )
            rendered["attempts"].append(row)
        output["streams"].append(rendered)
    return output


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser()
    p.add_argument("operation", choices=("freeze-source", "merge", "record-conflict", "freeze-integrated", "status"))
    p.add_argument("--kdir", required=True)
    p.add_argument("--slug", required=True)
    p.add_argument("--stream")
    p.add_argument("--attempt")
    p.add_argument("--worktree-id")
    p.add_argument("--tree", default="writer")
    p.add_argument("--depends-on", default="")
    p.add_argument("--patch")
    p.add_argument("--head-sha")
    p.add_argument("--integrated-sha")
    p.add_argument("--changed-path", action="append", default=[])
    p.add_argument("--conflict-path", action="append", default=[])
    p.add_argument("--reason", default="merge conflict requires coordinator judgment and worker source edits")
    p.add_argument("--verdict")
    p.add_argument("--repo")
    p.add_argument("--json", action="store_true")
    return p


def main() -> int:
    args = parser().parse_args()
    store = Store(Path(args.kdir).resolve(), require_token("work item", args.slug))
    if args.operation != "status":
        if not args.stream or not args.attempt:
            fail(f"{args.operation} requires --stream and --attempt")
    if args.operation in {"freeze-source", "freeze-integrated"} and not args.patch:
        fail(f"{args.operation} requires --patch")
    if args.operation == "freeze-source" and not args.worktree_id:
        fail("freeze-source requires --worktree-id")
    if args.operation == "freeze-integrated" and not args.integrated_sha:
        fail("freeze-integrated requires --integrated-sha")
    functions = {
        "freeze-source": command_freeze_source,
        "merge": command_merge,
        "record-conflict": command_conflict,
        "freeze-integrated": command_freeze_integrated,
        "status": command_status,
    }
    result = functions[args.operation](args, store)
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"[coordinate-reconcile] {result.get('status', 'valid')} {store.slug}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
