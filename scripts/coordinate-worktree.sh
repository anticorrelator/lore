#!/usr/bin/env bash
# coordinate-worktree.sh — sole manager for coordinated stream worktrees.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

exec python3 - "$SCRIPT_DIR" "$@" <<'PYEOF'
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import uuid
from pathlib import Path


SCRIPT_DIR = Path(sys.argv[1])
ARGV = sys.argv[2:]
REPO_ROOT = SCRIPT_DIR.parent
LEASE_SECONDS = 15 * 60
SCHEMA_VERSION = 1
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
STATES = {
    "reserved", "bound", "active", "recovered", "quiescent",
    "reconciling", "cleanup_due", "cleanup_blocked", "sweep_claimed",
    "removed", "swept",
}
TRANSITIONS = {
    "reserved": {"bound"},
    "bound": {"active", "recovered"},
    "active": {"recovered", "quiescent"},
    "recovered": {"quiescent"},
    "quiescent": {"reconciling"},
    "reconciling": {"cleanup_due"},
    "cleanup_blocked": {"cleanup_due"},
}


def now():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def iso(value):
    return value.isoformat().replace("+00:00", "Z")


def parse_time(value):
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def fail(message):
    raise SystemExit(f"Error: {message}")


def run(args, cwd=None, input_bytes=None, check=True):
    proc = subprocess.run(
        [str(x) for x in args], cwd=cwd, input=input_bytes,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if check and proc.returncode != 0:
        detail = proc.stderr.decode(errors="replace").strip() or proc.stdout.decode(errors="replace").strip()
        fail(f"command failed ({' '.join(map(str, args))}): {detail}")
    return proc


def git(repo, *args, check=True):
    return run(["git", "-C", repo, *args], check=check)


def git_text(repo, *args):
    return git(repo, *args).stdout.decode().strip()


def guard(command, identity=None, **flags):
    helper = os.environ.get("LORE_WORKTREE_GUARD")
    if helper:
        cmd = [helper, command]
        cwd = None
    else:
        cmd = ["go", "run", "./cmd/lore-worktree-guard", command]
        cwd = REPO_ROOT / "tui"
    temporary = None
    try:
        if identity is not None:
            fd, name = tempfile.mkstemp(prefix="lore-worktree-identity-", suffix=".json")
            temporary = name
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(identity, handle, sort_keys=True, separators=(",", ":"))
            cmd += ["--identity", name]
        for key, value in flags.items():
            if value is not None:
                cmd += ["--" + key.replace("_", "-"), str(value)]
        proc = run(cmd, cwd=cwd)
        return json.loads(proc.stdout)
    finally:
        if temporary:
            Path(temporary).unlink(missing_ok=True)


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".tmp-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(name, 0o600)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_id(value, label):
    if not ID_RE.fullmatch(value or ""):
        fail(f"invalid {label}: {value!r}")
    return value


def branch_component(value):
    value = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip(".-")
    return value[:48] or "stream"


class Manager:
    def __init__(self, kdir):
        self.kdir = Path(kdir).resolve()
        self.root = self.kdir / "_coordination" / "worktrees"
        self.registry = self.root / "registry"
        self.claims = self.root / "claims"
        self.archive = self.root / "archive"
        self.trees = self.root / "trees"
        self.recovery = self.kdir / "_coordination" / "recovery"
        for path in (self.registry, self.claims, self.archive, self.trees, self.recovery):
            path.mkdir(parents=True, exist_ok=True)
        self.lock_handle = open(self.root / ".manager.lock", "a+")
        fcntl.flock(self.lock_handle, fcntl.LOCK_EX)

    def path_for(self, worktree_id, include_terminal=False):
        safe_id(worktree_id, "worktree id")
        live = self.registry / f"{worktree_id}.json"
        if live.is_file():
            return live
        claim = self.claims / f"{worktree_id}.json"
        if claim.is_file():
            return claim
        if include_terminal:
            archived = self.archive / f"{worktree_id}.json"
            if archived.is_file():
                return archived
        fail(f"unknown worktree id: {worktree_id}")

    def load(self, worktree_id, include_terminal=False):
        path = self.path_for(worktree_id, include_terminal)
        try:
            row = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            fail(f"worktree manifest is unreadable: {exc}")
        self.validate_manifest(row)
        return path, row

    def validate_manifest(self, row):
        required = (
            "schema_version", "worktree_id", "execution_dir", "temporary_branch",
            "git_common_dir", "allocation_base_sha", "owner_item", "stream_id",
            "attempt_id", "owner", "lease", "guard_identity", "state", "history",
        )
        missing = [field for field in required if field not in row]
        if missing:
            fail("worktree manifest missing fields: " + ", ".join(missing))
        if row["schema_version"] != SCHEMA_VERSION:
            fail(f"unsupported worktree manifest schema_version={row['schema_version']}")
        if row["state"] not in STATES:
            fail(f"unknown worktree lifecycle state: {row['state']}")
        safe_id(row["worktree_id"], "worktree id")
        if Path(row["execution_dir"]).parent != self.trees:
            fail("execution_dir is outside the manager-owned namespace")
        if row["owner"].get("kind") not in ("session", "seat") or not row["owner"].get("id"):
            fail("owner must carry kind=session|seat and a durable id")
        if row["lease"].get("duration_seconds") != LEASE_SECONDS:
            fail("lease duration must be exactly 900 seconds")

    def validate_identity(self, row):
        observed = guard("validate", identity=row["guard_identity"])
        if observed != row["guard_identity"]:
            fail("guard identity changed during validation")

    def add_history(self, row, state, reason):
        row["state"] = state
        row["updated_at"] = iso(now())
        row["history"].append({"state": state, "at": row["updated_at"], "reason": reason})

    def allocate(self, args):
        sweep_result = self.sweep_all()
        if sweep_result["failed"]:
            fail("stale cleanup is blocked; retry sweep before allocating: " + ", ".join(sweep_result["failed"]))
        for value, label in ((args.work_item, "work item"), (args.stream, "stream"), (args.attempt, "attempt"), (args.owner_id, "owner id")):
            safe_id(value, label)
        if args.owner_kind not in ("session", "seat"):
            fail("owner kind must be session or seat")
        item_dir = self.kdir / "_work" / args.work_item
        if not item_dir.is_dir():
            fail(f"active owner work item not found: {args.work_item}")
        source = Path(args.source_dir).resolve()
        if not source.is_dir():
            fail(f"source checkout not found: {source}")
        common = Path(git_text(source, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()
        base = git_text(source, "rev-parse", "HEAD")
        worktree_id = "wt-" + hashlib.sha256(
            f"{args.work_item}\0{args.stream}\0{args.attempt}\0{uuid.uuid4().hex}".encode()
        ).hexdigest()[:24]
        execution = self.trees / worktree_id
        identity = guard("create", source=source, path=execution, epoch=worktree_id)
        branch = "lore/streams/{}/{}/{}/{}".format(
            branch_component(args.work_item), branch_component(args.stream),
            branch_component(args.attempt), worktree_id[3:15],
        )
        try:
            git(execution, "switch", "-c", branch)
            self.validate_identity({
                "guard_identity": identity,
            })
        except BaseException:
            git(source, "worktree", "remove", "--force", execution, check=False)
            git(source, "branch", "-D", branch, check=False)
            raise
        stamp = now()
        expires = stamp + dt.timedelta(seconds=LEASE_SECONDS)
        owner = {"kind": args.owner_kind, "id": args.owner_id}
        if args.owner_pid is not None:
            owner["pid"] = args.owner_pid
        if args.owner_tmux:
            owner["tmux_name"] = args.owner_tmux
            owner["tmux_server"] = args.tmux_server
        row = {
            "schema_version": SCHEMA_VERSION,
            "worktree_id": worktree_id,
            "execution_dir": str(execution),
            "temporary_branch": branch,
            "git_common_dir": str(common),
            "allocation_base_sha": base,
            "owner_item": args.work_item,
            "stream_id": args.stream,
            "attempt_id": args.attempt,
            "owner": owner,
            "lease": {"duration_seconds": LEASE_SECONDS, "renewed_at": iso(stamp), "expires_at": iso(expires)},
            "guard_identity": identity,
            "state": "reserved",
            "created_at": iso(stamp),
            "updated_at": iso(stamp),
            "history": [{"state": "reserved", "at": iso(stamp), "reason": "allocated"}],
            "cleanup_proof": None,
            "recovery": None,
        }
        atomic_json(self.registry / f"{worktree_id}.json", row)
        return row

    def bind(self, args):
        path, row = self.load(args.worktree_id)
        if path.parent != self.registry or row["state"] not in ("reserved", "bound", "active", "recovered"):
            fail("bind requires a reserved or owner-retaining live manifest")
        if row["owner"]["id"] != args.owner_id:
            fail("owner id does not match the allocation lease")
        self.validate_identity(row)
        if row["state"] == "reserved":
            row["guard_identity"] = guard("transition", identity=row["guard_identity"], state="active")
        if args.owner_pid is not None:
            row["owner"]["pid"] = args.owner_pid
        if args.owner_tmux:
            row["owner"]["tmux_name"] = args.owner_tmux
            row["owner"]["tmux_server"] = args.tmux_server
        if row["state"] == "reserved":
            self.add_history(row, "bound", "owner bound")
        else:
            row["updated_at"] = iso(now())
        atomic_json(path, row)
        return row

    def transition(self, args):
        path, row = self.load(args.worktree_id)
        if path.parent != self.registry:
            fail("claimed or terminal worktree cannot transition")
        if args.to not in TRANSITIONS.get(row["state"], set()):
            fail(f"invalid coordination lifecycle transition {row['state']!r} -> {args.to!r}")
        self.validate_identity(row)
        self.add_history(row, args.to, args.reason or "manager transition")
        atomic_json(path, row)
        return row

    def renew(self, args):
        path, row = self.load(args.worktree_id)
        if path.parent != self.registry or row["state"] in ("cleanup_due", "cleanup_blocked"):
            fail("lease cannot be renewed after cleanup becomes due")
        if row["owner"]["id"] != args.owner_id:
            fail("owner id does not match the allocation lease")
        self.validate_identity(row)
        stamp = now()
        row["lease"]["renewed_at"] = iso(stamp)
        row["lease"]["expires_at"] = iso(stamp + dt.timedelta(seconds=LEASE_SECONDS))
        row["updated_at"] = iso(stamp)
        atomic_json(path, row)
        return row

    def owner_live(self, row):
        owner = row["owner"]
        pid = owner.get("pid")
        if isinstance(pid, int) and pid > 0:
            try:
                os.kill(pid, 0)
                return True
            except ProcessLookupError:
                pass
            except PermissionError:
                return True
        tmux_name = owner.get("tmux_name")
        if tmux_name:
            server = owner.get("tmux_server") or "lore-tui"
            proc = run(["tmux", "-L", server, "has-session", "-t", tmux_name], check=False)
            if proc.returncode == 0:
                return True
        return False

    def claim(self, row):
        source = self.registry / f"{row['worktree_id']}.json"
        target = self.claims / source.name
        if target.exists():
            fail(f"cleanup already claimed: {row['worktree_id']}")
        os.rename(source, target)
        return target

    def capture_bundle(self, row, reason):
        worktree = Path(row["execution_dir"])
        stamp = iso(now()).replace(":", "").replace("-", "")
        bundle = self.recovery / row["worktree_id"] / stamp
        bundle.mkdir(parents=True, exist_ok=False)
        commands = {
            "status-v2.z": ("status", "--porcelain=v2", "-z", "--untracked-files=all"),
            "tracked.patch": ("diff", "--binary", "HEAD", "--"),
            "staged.patch": ("diff", "--binary", "--cached", "HEAD", "--"),
            "unstaged.patch": ("diff", "--binary", "--"),
        }
        for name, command in commands.items():
            (bundle / name).write_bytes(git(worktree, *command).stdout)
        untracked_raw = git(worktree, "ls-files", "--others", "--exclude-standard", "-z").stdout
        (bundle / "untracked.z").write_bytes(untracked_raw)
        names = [part.decode(errors="surrogateescape") for part in untracked_raw.split(b"\0") if part]
        with tarfile.open(bundle / "untracked.tar", "w") as archive:
            for relative in names:
                candidate = worktree / relative
                if candidate.exists() or candidate.is_symlink():
                    archive.add(candidate, arcname=relative, recursive=True)
        files = []
        for artifact in sorted(bundle.iterdir()):
            files.append({"name": artifact.name, "sha256": sha256_file(artifact), "size": artifact.stat().st_size})
        manifest = {
            "schema_version": 1,
            "worktree_id": row["worktree_id"],
            "captured_at": iso(now()),
            "reason": reason,
            "source_identity": row["guard_identity"],
            "files": files,
        }
        atomic_json(bundle / "manifest.json", manifest)
        return bundle, sha256_file(bundle / "manifest.json")

    def remove_and_prove(self, row, sweep, reason):
        worktree = Path(row["execution_dir"])
        repository = row["guard_identity"]["captured"]["canonical_path"]
        if worktree.exists():
            self.validate_identity(row)
            if row["guard_identity"]["state"] == "captured":
                row["guard_identity"] = guard("transition", identity=row["guard_identity"], state="active")
            if row["guard_identity"]["state"] != "quarantined":
                bundle, bundle_hash = self.capture_bundle(row, reason)
                quarantine = guard("quarantine", identity=row["guard_identity"], reason=reason)
                row["guard_identity"] = quarantine["identity"]
                row["recovery"] = {
                    "bundle_path": str(bundle),
                    "manifest_sha256": bundle_hash,
                    "result_artifact": quarantine["artifact"],
                    "captured_before_removal": True,
                }
            elif not row.get("recovery", {}).get("captured_before_removal"):
                raise RuntimeError("quarantined identity lacks persisted pre-removal recovery evidence")
            # Persist the evidence pointer while the checkout still exists.
            atomic_json(self.claims / f"{row['worktree_id']}.json", row)
            if os.environ.get("LORE_WORKTREE_FAIL_REMOVE") == "1":
                raise RuntimeError("injected worktree removal failure")
            git(repository, "worktree", "remove", "--force", worktree)
        elif not row.get("recovery", {}).get("captured_before_removal"):
            raise RuntimeError("worktree vanished before recovery evidence was persisted")
        else:
            # A previous manager may have died after removal. Finish the
            # registry/ref proof from the already-persisted recovery record.
            git(repository, "worktree", "remove", "--force", worktree, check=False)
        branch_ref = "refs/heads/" + row["temporary_branch"]
        guard_refs = [
            f"refs/lore/worktrees/{row['worktree_id']}/captured",
            f"refs/lore/worktrees/{row['worktree_id']}/result",
            f"refs/lore/quarantine/{row['worktree_id']}",
        ]
        for ref in [branch_ref, *guard_refs]:
            git(repository, "update-ref", "-d", ref)
        registry_paths = []
        listing = git(repository, "worktree", "list", "--porcelain").stdout.decode(errors="replace")
        for line in listing.splitlines():
            if line.startswith("worktree "):
                registry_paths.append(os.path.abspath(line[len("worktree "):]))
        path_absent = not worktree.exists()
        registry_absent = os.path.abspath(str(worktree)) not in registry_paths
        branch_absent = git(repository, "show-ref", "--verify", "--quiet", branch_ref, check=False).returncode != 0
        guard_absent = all(
            git(repository, "show-ref", "--verify", "--quiet", ref, check=False).returncode != 0
            for ref in guard_refs
        )
        proof = {
            "path_absent": path_absent,
            "git_registry_absent": registry_absent,
            "branch_disposition": "deleted" if branch_absent else "present",
            "guard_refs_disposition": "deleted" if guard_absent else "present",
            "verified_at": iso(now()),
        }
        proof["verified"] = path_absent and registry_absent and branch_absent and guard_absent
        row["cleanup_proof"] = proof
        if not proof["verified"]:
            raise RuntimeError("cleanup proof incomplete across path, Git registry, or refs")
        self.add_history(row, "swept" if sweep else "removed", reason)
        return row

    def finish_claim(self, row, sweep, reason):
        claim_path = self.claims / f"{row['worktree_id']}.json"
        try:
            if sweep and row["state"] != "sweep_claimed":
                self.add_history(row, "sweep_claimed", reason)
                atomic_json(claim_path, row)
            row = self.remove_and_prove(row, sweep, reason)
        except BaseException as exc:
            row["last_cleanup_error"] = str(exc)
            self.add_history(row, "cleanup_blocked", str(exc))
            atomic_json(claim_path, row)
            os.replace(claim_path, self.registry / claim_path.name)
            raise
        atomic_json(claim_path, row)
        os.replace(claim_path, self.archive / claim_path.name)
        return row

    def cleanup(self, args):
        path, row = self.load(args.worktree_id)
        if path.parent != self.registry or row["state"] not in ("cleanup_due", "cleanup_blocked"):
            fail("normal cleanup requires cleanup_due or cleanup_blocked")
        self.validate_identity(row)
        self.claim(row)
        return self.finish_claim(row, False, args.reason or "normal cleanup")

    def sweep_all(self):
        result = {"swept": [], "protected": [], "not_expired": [], "failed": []}
        for path in sorted(self.claims.glob("*.json")):
            try:
                row = json.loads(path.read_text(encoding="utf-8"))
                self.validate_manifest(row)
                self.finish_claim(row, True, "resume interrupted cleanup claim")
                result["swept"].append(row["worktree_id"])
            except BaseException:
                result["failed"].append(path.stem)
        for path in sorted(self.registry.glob("*.json")):
            try:
                row = json.loads(path.read_text(encoding="utf-8"))
                self.validate_manifest(row)
                cleanup_retry = row["state"] in ("cleanup_due", "cleanup_blocked")
                if not cleanup_retry and parse_time(row["lease"]["expires_at"]) > now():
                    result["not_expired"].append(row["worktree_id"])
                    continue
                if not cleanup_retry and self.owner_live(row):
                    result["protected"].append(row["worktree_id"])
                    continue
                self.validate_identity(row)
                self.claim(row)
                self.finish_claim(row, True, "expired owner lease")
                result["swept"].append(row["worktree_id"])
            except BaseException:
                result["failed"].append(path.stem)
        return result

    def show(self, args):
        if args.worktree_id:
            _, row = self.load(args.worktree_id, include_terminal=True)
            return row
        rows = []
        for location in (self.registry, self.claims, self.archive):
            for path in sorted(location.glob("*.json")):
                try:
                    row = json.loads(path.read_text(encoding="utf-8"))
                    row["record_location"] = location.name
                    rows.append(row)
                except (OSError, json.JSONDecodeError):
                    continue
        return {"schema_version": 1, "worktrees": rows}


def parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--kdir")
    common.add_argument("--json", action="store_true")
    root = argparse.ArgumentParser(prog="coordinate-worktree.sh")
    sub = root.add_subparsers(dest="command", required=True)

    allocate = sub.add_parser("allocate", parents=[common])
    allocate.add_argument("--work-item", required=True)
    allocate.add_argument("--stream", required=True)
    allocate.add_argument("--attempt", required=True)
    allocate.add_argument("--owner-kind", required=True)
    allocate.add_argument("--owner-id", required=True)
    allocate.add_argument("--owner-pid", type=int)
    allocate.add_argument("--owner-tmux")
    allocate.add_argument("--tmux-server", default="lore-tui")
    allocate.add_argument("--source-dir", required=True)

    bind = sub.add_parser("bind", parents=[common])
    bind.add_argument("--worktree-id", required=True)
    bind.add_argument("--owner-id", required=True)
    bind.add_argument("--owner-pid", type=int)
    bind.add_argument("--owner-tmux")
    bind.add_argument("--tmux-server", default="lore-tui")

    transition = sub.add_parser("transition", parents=[common])
    transition.add_argument("--worktree-id", required=True)
    transition.add_argument("--to", required=True)
    transition.add_argument("--reason")

    renew = sub.add_parser("renew", parents=[common])
    renew.add_argument("--worktree-id", required=True)
    renew.add_argument("--owner-id", required=True)

    cleanup = sub.add_parser("cleanup", parents=[common])
    cleanup.add_argument("--worktree-id", required=True)
    cleanup.add_argument("--reason")

    sweep = sub.add_parser("sweep", parents=[common])
    show = sub.add_parser("show", parents=[common])
    show.add_argument("--worktree-id")
    return root


def resolve_kdir(value):
    if value:
        path = Path(value).resolve()
    else:
        proc = run([SCRIPT_DIR / "resolve-repo.sh"])
        path = Path(proc.stdout.decode().strip()).resolve()
    if not path.is_dir():
        fail(f"knowledge store not found: {path}")
    return path


args = parser().parse_args(ARGV)
manager = Manager(resolve_kdir(args.kdir))
if args.command == "allocate":
    output = manager.allocate(args)
elif args.command == "bind":
    output = manager.bind(args)
elif args.command == "transition":
    output = manager.transition(args)
elif args.command == "renew":
    output = manager.renew(args)
elif args.command == "cleanup":
    output = manager.cleanup(args)
elif args.command == "sweep":
    output = manager.sweep_all()
else:
    output = manager.show(args)
print(json.dumps(output, indent=2 if args.json else None, sort_keys=True))
PYEOF
