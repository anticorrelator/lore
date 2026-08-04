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


SCHEMA_VERSION = 3
# A record written before the lifecycle phases existed is still valid and is
# read unchanged; it is rewritten at version 3 by the first operation that
# actually changes it.
SUPPORTED_SCHEMA_VERSIONS = (2, 3)
WORKTREE_SCHEMA_VERSION = 1
TERMINAL_WORKTREE_STATES = {"removed", "swept"}
VERDICTS = {"full", "partial", "none"}
TREES = {"writer", "read-only"}
TOKEN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")

# This module is the only place the `coord_` vocabulary is defined. The
# worktree manager and the board readers quote these strings; they do not
# maintain their own copies. The prefix is load-bearing rather than
# decorative: `reserved` is already a manager lifecycle state, `quarantine` is
# already a guard identity state, `disposition` already names three unrelated
# axes (branch_disposition, guard_refs_disposition, and the knowledge ledger's
# held/contradicted), and `stream` is this record's own key — so an unprefixed
# token would read as one of those.
#
# Statuses an attempt passes through before any evidence is frozen. They
# precede "pending" and the post-freeze statuses the reconciliation verbs own.
COORD_ALLOCATED = "coord_allocated"
COORD_DISPATCHED = "coord_dispatched"
COORD_REPORT_ACCEPTED = "coord_report_accepted"
# Forward edges the advance verb may take. Everything else, including a skip
# and a walk backward, is refused. "pending" is the hand-off: from there the
# existing reconciliation verbs own the transitions and their side effects.
COORD_TRANSITIONS = {
    COORD_ALLOCATED: {COORD_DISPATCHED},
    COORD_DISPATCHED: {COORD_REPORT_ACCEPTED},
    COORD_REPORT_ACCEPTED: {"pending"},
}
# Whether a swept tree's temporary branch ever moved off its allocation base.
# "unchanged" means only that there is no committed delta beyond the base; the
# recovery bundle may still hold uncommitted work.
BRANCH_RELEVANCE = {
    "coord_branch_unchanged", "coord_branch_advanced", "coord_branch_unavailable",
}
# Where a quarantined result went, as judged by a caller who looked. Absence of
# the field is the distinct state meaning nobody looked; "coord_delivery_unknown"
# is a recorded judgment that the evidence was inconclusive. None of the three
# ever means publication succeeded.
DELIVERY_CLASSIFICATIONS = {
    "coord_quarantine_routine_residue", "coord_quarantine_unintegrated",
    "coord_delivery_unknown",
}
# Lookup answers. Each names a different situation, so a caller never has to
# read an empty result to guess which one it got.
LOOKUP_RECORD_ABSENT = "coord_lookup_record_absent"
LOOKUP_STREAM_ABSENT = "coord_lookup_stream_absent"
LOOKUP_ATTEMPT_ABSENT = "coord_lookup_attempt_absent"
LOOKUP_TREE_ABSENT = "coord_lookup_tree_absent"
LOOKUP_RESOLVED = "coord_lookup_resolved"
LOOKUP_STALE_POINTER = "coord_lookup_stale_pointer"


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


def find_worktree_record(kdir: Path, worktree_id: str) -> tuple[dict | None, str | None]:
    """Resolve a worktree pointer, returning (None, None) when it names nothing.

    An unreadable or wrong-version record still fails: only absence is a
    reportable outcome.
    """
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
    return None, None


def worktree_record(kdir: Path, worktree_id: str) -> tuple[dict, str]:
    row, source = find_worktree_record(kdir, worktree_id)
    if row is None:
        fail(f"worktree identity is absent from registry and archive: {worktree_id}")
    return row, source


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
        if state.get("schema_version") not in SUPPORTED_SCHEMA_VERSIONS:
            fail(f"unsupported reconciliation schema_version={state.get('schema_version')!r}")
        if state.get("work_item") != self.slug or not isinstance(state.get("streams"), list):
            fail("reconciliation state identity or streams shape is invalid")
        return state

    def locked(self):
        self.root.mkdir(parents=True, exist_ok=True)
        handle = self.lock_path.open("a+")
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        return handle

    @staticmethod
    def snapshot(state: dict) -> str:
        """Serialize everything an operation could change, so replays are detectable.

        `updated_at` and `schema_version` are excluded: both move as a
        consequence of writing rather than as content, and including either
        would make every replay look like a change.
        """
        body = {key: value for key, value in state.items()
                if key not in ("updated_at", "schema_version")}
        body["streams"] = sorted(state["streams"], key=lambda row: row["stream_id"])
        return json.dumps(body, ensure_ascii=False, sort_keys=True)

    def write(self, state: dict) -> None:
        state["schema_version"] = SCHEMA_VERSION
        state["updated_at"] = now()
        state["streams"] = sorted(state["streams"], key=lambda row: row["stream_id"])
        atomic_write(self.state_path, json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True).encode() + b"\n")

    def commit(self, state: dict, before: str) -> bool:
        """Write only when the operation actually changed the record."""
        if self.snapshot(state) == before:
            return False
        self.write(state)
        return True

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
        worktree_id = attempt.get("worktree_id")
        if not worktree_id:
            fail(f"attempt {args.stream}/{args.attempt} owns no worktree; there is "
                 "nothing to merge from a read-only stream")
        identity, source = worktree_record(store.kdir, worktree_id)
        validate_identity(identity, store.slug, args.stream, args.attempt, worktree_id)
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

        if not attempt.get("worktree_id"):
            fail(f"attempt {args.stream}/{args.attempt} owns no worktree; a read-only "
                 "stream carries no integrated evidence to freeze")
        identity, _ = worktree_record(store.kdir, attempt["worktree_id"])
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


def declared_edges() -> str:
    return ", ".join(f"{source} -> {target}"
                     for source, targets in COORD_TRANSITIONS.items()
                     for target in sorted(targets))


def find_stream(state: dict, stream_id: str) -> dict | None:
    return next((row for row in state["streams"] if row.get("stream_id") == stream_id), None)


def find_attempt(stream: dict, attempt_id: str) -> dict | None:
    return next((row for row in stream.get("attempts", []) if row.get("attempt_id") == attempt_id), None)


def sweep_recovery_fact(args) -> dict | None:
    """Build the recorded sweep fact, or None when the caller supplied none."""
    if not args.branch_relevance:
        return None
    if args.branch_relevance not in BRANCH_RELEVANCE:
        fail(f"invalid --branch-relevance: {args.branch_relevance!r}; "
             f"choose one of {', '.join(sorted(BRANCH_RELEVANCE))}")
    fact = {"relevance": args.branch_relevance}
    for key, value in (("allocation_base_sha", args.branch_base_sha),
                       ("branch_tip_sha", args.branch_tip_sha),
                       ("recovery_bundle_path", args.recovery_bundle),
                       ("quarantine_patch_path", args.quarantine_patch)):
        if value:
            fact[key] = value
    return fact


def delivery_fact(args) -> dict | None:
    """Build the recorded delivery judgment, or None when the caller supplied none."""
    if not args.delivery_classification:
        return None
    if args.delivery_classification not in DELIVERY_CLASSIFICATIONS:
        fail(f"invalid --delivery-classification: {args.delivery_classification!r}; "
             f"choose one of {', '.join(sorted(DELIVERY_CLASSIFICATIONS))}")
    # A classification is a judgment somebody made, so it has to arrive with
    # what it was made from. Nothing here reads the session journal: journal
    # silence is not evidence and never produces a classification.
    if not args.delivery_evidence:
        fail("--delivery-classification requires at least one --delivery-evidence "
             "naming what the judgment rests on (a quarantine ref, patch path, "
             "commit sha, or report id)")
    return {"classification": args.delivery_classification,
            "evidence": sorted(set(args.delivery_evidence))}


def command_register_attempt(args, store: Store) -> dict:
    """Bring an attempt into the record at its first lifecycle phase."""
    stream_id = require_token("stream", args.stream)
    attempt_id = require_token("attempt", args.attempt)
    depends_on = parse_depends(args.depends_on)
    if args.tree not in TREES:
        fail(f"invalid tree: {args.tree!r}")
    worktree_id = args.worktree_id or None
    if args.tree == "read-only":
        if worktree_id:
            fail("a read-only stream owns no worktree; drop --worktree-id")
        initial = COORD_DISPATCHED
    else:
        if not worktree_id:
            fail("register-attempt on a writer stream requires --worktree-id "
                 "(pass --tree read-only for a stream that owns no checkout)")
        require_token("worktree id", worktree_id)
        identity, _ = worktree_record(store.kdir, worktree_id)
        validate_identity(identity, store.slug, stream_id, attempt_id, worktree_id)
        initial = COORD_ALLOCATED

    with store.locked():
        state = store.load(allow_missing=True)
        before = store.snapshot(state)
        stream = store.stream(state, stream_id, args.tree, depends_on)
        attempt = find_attempt(stream, attempt_id)
        if attempt is None:
            attempt = {"attempt_id": attempt_id, "status": initial, "updated_at": now()}
            if worktree_id:
                attempt["worktree_id"] = worktree_id
            stream["attempts"].append(attempt)
        elif attempt.get("worktree_id") != worktree_id:
            fail(f"attempt {stream_id}/{attempt_id} is already registered against "
                 f"worktree {attempt.get('worktree_id')!r}, not {worktree_id!r}; "
                 "use a new attempt id")
        wrote = store.commit(state, before)
        status = attempt.get("status")
    return {"outcome": "coord_registered" if wrote else "coord_register_replayed",
            "work_item": store.slug, "stream_id": stream_id, "attempt_id": attempt_id,
            "tree": args.tree, "worktree_id": worktree_id, "status": status}


def command_advance_attempt(args, store: Store) -> dict:
    """Take one declared lifecycle edge, or attach recorded facts in place."""
    stream_id = require_token("stream", args.stream)
    attempt_id = require_token("attempt", args.attempt)
    if not args.expected_status:
        fail("advance-attempt requires --expected-status naming the status you "
             "believe the attempt is at, so a stale caller conflicts instead of "
             "overwriting a newer one")
    target = args.to or None
    recovery = sweep_recovery_fact(args)
    delivery = delivery_fact(args)
    if target is None and recovery is None and delivery is None:
        fail("advance-attempt needs --to, or at least one recorded fact "
             "(--branch-relevance / --delivery-classification)")
    if target is not None and target not in COORD_TRANSITIONS.get(args.expected_status, set()):
        fail(f"undeclared coordination transition {args.expected_status!r} -> {target!r}; "
             f"the declared edges are {declared_edges()}. The reconciliation verbs "
             "own source_frozen, merge_ready, needs_judgment, and integrated.")

    with store.locked():
        state = store.load()
        before = store.snapshot(state)
        stream = find_stream(state, stream_id)
        if stream is None:
            fail(f"unknown stream {stream_id}")
        attempt = find_attempt(stream, attempt_id)
        if attempt is None:
            fail(f"unknown attempt {stream_id}/{attempt_id}")
        current = attempt.get("status")
        # An advance that already landed leaves the attempt sitting on its
        # target, so replaying the same call is a success, not a conflict.
        replayed_edge = target is not None and current == target
        if not replayed_edge and current != args.expected_status:
            fail(f"advance-attempt conflict: {stream_id}/{attempt_id} is at "
                 f"{current!r}, caller expected {args.expected_status!r}")
        if target is not None and not replayed_edge:
            attempt["status"] = target
        if recovery is not None:
            attempt["coord_sweep_recovery"] = recovery
        if delivery is not None:
            attempt["coord_delivery"] = delivery
        if store.snapshot(state) != before:
            attempt["updated_at"] = now()
        wrote = store.commit(state, before)
        status = attempt.get("status")
    return {"outcome": "coord_advanced" if wrote else "coord_advance_replayed",
            "work_item": store.slug, "stream_id": stream_id, "attempt_id": attempt_id,
            "status": status, "coord_sweep_recovery": recovery, "coord_delivery": delivery}


def command_lookup_attempt(args, store: Store) -> dict:
    """Answer (work item, stream, attempt) -> tree identity without a caller-held id.

    Every outcome is a successful read: the caller branches on `outcome` rather
    than on an empty payload, so "no record yet" and "the pointer went stale"
    never render alike.
    """
    stream_id = require_token("stream", args.stream)
    attempt_id = require_token("attempt", args.attempt)
    result = {"work_item": store.slug, "stream_id": stream_id, "attempt_id": attempt_id,
              "schema_version": None, "tree": None, "status": None, "worktree_id": None,
              "coord_sweep_recovery": None, "coord_delivery": None, "worktree": None}
    if not store.state_path.exists():
        return {**result, "outcome": LOOKUP_RECORD_ABSENT}
    state = store.load()
    result["schema_version"] = state.get("schema_version")
    stream = find_stream(state, stream_id)
    if stream is None:
        return {**result, "outcome": LOOKUP_STREAM_ABSENT}
    result["tree"] = stream.get("tree")
    attempt = find_attempt(stream, attempt_id)
    if attempt is None:
        return {**result, "outcome": LOOKUP_ATTEMPT_ABSENT}
    result.update({
        "status": attempt.get("status"),
        "worktree_id": attempt.get("worktree_id"),
        "coord_sweep_recovery": attempt.get("coord_sweep_recovery"),
        "coord_delivery": attempt.get("coord_delivery"),
    })
    worktree_id = attempt.get("worktree_id")
    if not worktree_id:
        return {**result, "outcome": LOOKUP_TREE_ABSENT}
    identity, source = find_worktree_record(store.kdir, worktree_id)
    if identity is None:
        return {**result, "outcome": LOOKUP_STALE_POINTER}
    validate_identity(identity, store.slug, stream_id, attempt_id, worktree_id)
    # Manager-owned fields are projected, never copied into the record: the
    # registry stays their only writer.
    result["worktree"] = {
        "record_source": source,
        "state": identity.get("state"),
        "execution_dir": identity.get("execution_dir"),
        "temporary_branch": identity.get("temporary_branch"),
        "git_common_dir": identity.get("git_common_dir"),
        "allocation_base_sha": identity.get("allocation_base_sha"),
        "owner": identity.get("owner"),
        "lease": identity.get("lease"),
        "cleanup": cleanup_status(identity, source),
    }
    return {**result, "outcome": LOOKUP_RESOLVED}


def command_status(args, store: Store) -> dict:
    state = store.load()
    output = {"schema_version": state.get("schema_version"), "work_item": store.slug,
              "streams": [], "valid": True}
    for stream in state["streams"]:
        rendered = {key: stream.get(key) for key in ("stream_id", "tree", "depends_on")}
        rendered["attempts"] = []
        for attempt in stream.get("attempts", []):
            row = dict(attempt)
            worktree_id = attempt.get("worktree_id")
            try:
                if attempt.get("source_manifest"):
                    store.validate_manifest(attempt["source_manifest"], "source", stream["stream_id"], attempt["attempt_id"])
                integrated_manifest = None
                if attempt.get("integrated_manifest"):
                    integrated_manifest = store.validate_manifest(attempt["integrated_manifest"], "integrated", stream["stream_id"], attempt["attempt_id"])
                if not worktree_id:
                    # A read-only stream owns no checkout, so there is no
                    # cleanup to verify and nothing here is wrong.
                    row["worktree"] = LOOKUP_TREE_ABSENT
                    row["cleanup"] = {"verified": False, "state": None,
                                      "record_source": None, "proof": None}
                else:
                    identity, source = worktree_record(store.kdir, worktree_id)
                    validate_identity(identity, store.slug, stream["stream_id"], attempt["attempt_id"], worktree_id)
                    if integrated_manifest is not None and isinstance(integrated_manifest.get("acceptance_refs"), list):
                        audit_accepted_refs(identity.get("git_common_dir"), integrated_manifest["acceptance_refs"])
                    row["worktree"] = LOOKUP_RESOLVED
                    row["cleanup"] = cleanup_status(identity, source)
                row["valid"] = True
            except (SystemExit, OSError, KeyError, json.JSONDecodeError) as exc:
                row["valid"] = False
                row["validation_error"] = str(exc)
                row["worktree"] = LOOKUP_STALE_POINTER if worktree_id else LOOKUP_TREE_ABSENT
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
    p.add_argument("operation", choices=("register-attempt", "advance-attempt", "lookup-attempt",
                                         "freeze-source", "merge", "record-conflict",
                                         "freeze-integrated", "status"))
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
    p.add_argument("--expected-status", help="status advance-attempt believes the attempt is at")
    p.add_argument("--to", help="lifecycle status to advance to; omit to record facts in place")
    p.add_argument("--branch-relevance", choices=sorted(BRANCH_RELEVANCE))
    p.add_argument("--branch-base-sha")
    p.add_argument("--branch-tip-sha")
    p.add_argument("--recovery-bundle")
    p.add_argument("--quarantine-patch")
    p.add_argument("--delivery-classification", choices=sorted(DELIVERY_CLASSIFICATIONS))
    p.add_argument("--delivery-evidence", action="append", default=[],
                   help="identifier the delivery judgment rests on; repeatable")
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
        "register-attempt": command_register_attempt,
        "advance-attempt": command_advance_attempt,
        "lookup-attempt": command_lookup_attempt,
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
        print(f"[coordinate-reconcile] {result.get('outcome') or result.get('status') or 'valid'} {store.slug}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
