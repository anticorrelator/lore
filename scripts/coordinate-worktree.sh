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
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path


SCRIPT_DIR = Path(sys.argv[1])
ARGV = sys.argv[2:]
REPO_ROOT = SCRIPT_DIR.parent
SCHEMA_VERSION = 1
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
# The declared machine is the observed one. `sweep_claimed` and `swept` are no
# longer written — they name the reclaim a lease-expiry sweeper used to perform
# — but archived rows carry them in their histories, so a record must still read
# back. `recovered` and `cleanup_blocked` are not here at all: neither ever
# appeared in a row's history, and a state nothing has ever reached teaches a
# lifecycle nobody walks.
STATES = {
    "reserved", "bound", "active", "quiescent", "reconciling",
    "cleanup_due", "sweep_claimed", "removed", "swept",
}
TRANSITIONS = {
    "reserved": {"bound"},
    "bound": {"active"},
    "active": {"quiescent"},
    "quiescent": {"reconciling"},
    "reconciling": {"cleanup_due"},
}


def now():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def iso(value):
    return value.isoformat().replace("+00:00", "Z")


def fail(message):
    raise SystemExit(f"Error: {message}")


def warn(message):
    # stderr only — stdout is the JSON record contract.
    print(f"Warning: {message}", file=sys.stderr)


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
        for path in (self.registry, self.claims, self.archive, self.trees):
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
            "attempt_id", "owner", "guard_identity", "state", "history",
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
        # A row written while worker sessions could still be pinned to a
        # manager-allocated tree carries kind=session. It stays readable; it is
        # no longer creatable.
        if row["owner"].get("kind") not in ("session", "seat") or not row["owner"].get("id"):
            fail("owner must carry kind=seat and a durable id")

    def validate_identity(self, row):
        observed = guard("validate", identity=row["guard_identity"])
        if observed != row["guard_identity"]:
            fail("guard identity changed during validation")

    def add_history(self, row, state, reason):
        row["state"] = state
        row["updated_at"] = iso(now())
        row["history"].append({"state": state, "at": row["updated_at"], "reason": reason})

    def allocate(self, args):
        for value, label in ((args.work_item, "work item"), (args.stream, "stream"), (args.attempt, "attempt"), (args.owner_id, "owner id")):
            safe_id(value, label)
        if args.owner_kind != "seat":
            fail(
                f"owner kind must be seat, not {args.owner_kind!r}. Pinning a worker "
                "session to a manager-allocated tree was the bridge that put such a "
                "session into this registry, and nothing has crossed it since "
                "2026-07-25 — worker sessions get their checkout from the claiming "
                "TUI, which owns it end to end.\n"
                "  A seat allocates here for the subagents it dispatches itself."
            )
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
        owner = {"kind": args.owner_kind, "id": args.owner_id}
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
            "guard_identity": identity,
            "state": "reserved",
            "created_at": iso(stamp),
            "updated_at": iso(stamp),
            "history": [{"state": "reserved", "at": iso(stamp), "reason": "allocated"}],
            "cleanup_proof": None,
        }
        atomic_json(self.registry / f"{worktree_id}.json", row)
        return row

    def bind(self, args):
        path, row = self.load(args.worktree_id)
        if path.parent != self.registry:
            fail(claimed_or_terminal(row, "bind"))
        if row["state"] not in ("reserved", "bound", "active"):
            fail(
                f"worktree {args.worktree_id} is at '{row['state']}'; bind attaches the owner "
                "to a tree that is still being worked, and quiescent onward is the teardown "
                "half of the lifecycle — the owner has already released it.\n"
                + remaining_steps(row)
            )
        if row["owner"]["id"] != args.owner_id:
            fail(owner_mismatch(row, args.owner_id))
        self.validate_identity(row)
        if row["state"] == "reserved":
            row["guard_identity"] = guard("transition", identity=row["guard_identity"], state="active")
        if row["state"] == "reserved":
            self.add_history(row, "bound", "owner bound")
        else:
            row["updated_at"] = iso(now())
        atomic_json(path, row)
        return row

    def transition(self, args):
        path, row = self.load(args.worktree_id)
        if path.parent != self.registry:
            fail(claimed_or_terminal(row, "transition"))
        if args.to not in TRANSITIONS.get(row["state"], set()):
            fail(transition_refusal(row, args.to))
        self.validate_identity(row)
        self.add_history(row, args.to, args.reason or "manager transition")
        atomic_json(path, row)
        if args.to == "cleanup_due":
            # Removal hangs on the one act only the releasing owner performs.
            # Asking for the release and asking for the teardown were two calls,
            # and the second was the one that went missing.
            return self.remove(row, args.reason or "released by its owner")
        return row

    def claim(self, row):
        source = self.registry / f"{row['worktree_id']}.json"
        target = self.claims / source.name
        if target.exists():
            fail(f"cleanup already claimed: {row['worktree_id']}")
        os.rename(source, target)
        return target

    def reconcile(self, operation, row, *extra):
        """Invoke the reconciliation sole writer.

        streams.json belongs to coordinate-reconcile.py. The manager asks it
        for changes and never edits the file, exactly as callers ask the
        manager rather than editing the registry.
        """
        return run([
            sys.executable, SCRIPT_DIR / "coordinate-reconcile.py", operation,
            "--kdir", self.kdir, "--slug", row["owner_item"],
            "--stream", row["stream_id"], "--attempt", row["attempt_id"],
            "--json", *extra,
        ], check=False)

    @staticmethod
    def proc_detail(proc):
        return (proc.stderr.decode(errors="replace").strip()
                or proc.stdout.decode(errors="replace").strip()
                or f"exit {proc.returncode}")

    def register_lifecycle(self, row):
        """Give a fresh allocation its stream lifecycle record.

        The registry row is already durable here, so a failure must not cost
        the caller its checkout. It reports the repair instead of unwinding:
        replaying register-attempt with the same identity adopts the existing
        tree rather than allocating a second one.
        """
        proc = self.reconcile("register-attempt", row, "--tree", "writer",
                              "--worktree-id", row["worktree_id"])
        if proc.returncode == 0:
            return {"registered": True}
        detail = self.proc_detail(proc)
        repair = (
            f"lore coordinate reconcile register-attempt {row['owner_item']} "
            f"--stream {row['stream_id']} --attempt {row['attempt_id']} "
            f"--tree writer --worktree-id {row['worktree_id']}"
        )
        warn(f"stream lifecycle registration failed: {detail}\n"
             f"  The tree exists and is yours. Replay registration: {repair}")
        return {"registered": False, "error": detail, "repair": repair}

    def remove_and_prove(self, row, reason):
        """Take the checkout down and prove it is gone, keeping what it committed.

        The temporary branch is deleted here, so anything committed on it would
        become unreachable. A quarantine ref pinned at the tip before the
        deletion preserves every commit for the cost of one Git command, and the
        proof names it — a proof that reads as pure destruction is how a
        preserved tree came to be reported as data loss.
        """
        worktree = Path(row["execution_dir"])
        repository = row["guard_identity"]["captured"]["canonical_path"]
        if worktree.exists():
            self.validate_identity(row)
            if os.environ.get("LORE_WORKTREE_FAIL_REMOVE") == "1":
                raise RuntimeError("injected worktree removal failure")
            git(repository, "worktree", "remove", "--force", worktree)
        else:
            # A previous manager may have died after removal. Finish the
            # registry/ref proof over a checkout that is already gone.
            git(repository, "worktree", "remove", "--force", worktree, check=False)
        branch_ref = "refs/heads/" + row["temporary_branch"]
        quarantine_ref = f"refs/lore/quarantine/{row['worktree_id']}"
        # Read the tip while the ref still exists: after the deletion below
        # nothing can tell whether the owner ever committed.
        probe = git(repository, "rev-parse", "--verify", "--quiet",
                    branch_ref + "^{commit}", check=False)
        tip = probe.stdout.decode(errors="replace").strip() if probe.returncode == 0 else ""
        # A branch still sitting on its allocation base has nothing of its own:
        # every commit on it is already reachable from where it was cut, so a
        # ref there would preserve nothing and read as though it did.
        if tip and tip != row.get("allocation_base_sha"):
            git(repository, "update-ref", quarantine_ref, tip)
        else:
            tip = ""
        guard_refs = [
            f"refs/lore/worktrees/{row['worktree_id']}/captured",
            f"refs/lore/worktrees/{row['worktree_id']}/result",
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
            "quarantine_ref": quarantine_ref if tip else None,
            "quarantine_sha": tip or None,
            "verified_at": iso(now()),
        }
        proof["verified"] = path_absent and registry_absent and branch_absent and guard_absent
        row["cleanup_proof"] = proof
        if not proof["verified"]:
            raise RuntimeError("cleanup proof incomplete across path, Git registry, or refs")
        self.add_history(row, "removed", reason)
        return row

    def remove(self, row, reason):
        """Move the record registry -> claims -> archive as the tree comes down.

        The rename is the transition: a crash leaves the record in the directory
        that says how far the teardown got, and never in a state that claims
        more than happened. A failure puts it back in the registry one state
        short of released, so re-driving the release is the retry.
        """
        claim_path = self.claim(row)
        try:
            row = self.remove_and_prove(row, reason)
        except BaseException as exc:
            row["last_cleanup_error"] = str(exc)
            self.add_history(row, "reconciling", f"teardown did not finish: {exc}")
            atomic_json(claim_path, row)
            os.replace(claim_path, self.registry / claim_path.name)
            raise
        atomic_json(claim_path, row)
        os.replace(claim_path, self.archive / claim_path.name)
        return row

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

    allocate = sub.add_parser(
        "allocate", parents=[common],
        description=(
            "Allocate a manager-owned stream worktree for a seat and the "
            "subagents it dispatches into that tree. A worker session gets its "
            "checkout from the claiming TUI instead. Release it with "
            "`transition --to cleanup_due`, which is also what takes it down: "
            "anything committed on its temporary branch is pinned at "
            "refs/lore/quarantine/<worktree-id> before the branch is deleted, "
            "and the cleanup proof names that ref."
        ),
    )
    allocate.add_argument("--work-item", required=True)
    allocate.add_argument("--stream", required=True)
    allocate.add_argument("--attempt", required=True)
    allocate.add_argument("--owner-kind", required=True,
                          help="seat — the only owner this manager allocates for")
    allocate.add_argument("--owner-id", required=True)
    allocate.add_argument("--source-dir", required=True)

    bind = sub.add_parser(
        "bind", parents=[common],
        description=(
            "Attach the owner to an allocated tree, advancing its guard "
            "identity to active. This is the step between allocate and work."
        ),
    )
    bind.add_argument("--worktree-id", required=True)
    bind.add_argument("--owner-id", required=True)

    transition = sub.add_parser(
        "transition", parents=[common],
        description=(
            "Take one lifecycle edge. `--to cleanup_due` is the release, and "
            "the release is the teardown: it removes the checkout, deletes the "
            "temporary branch, and archives the record."
        ),
    )
    transition.add_argument("--worktree-id", required=True)
    transition.add_argument("--to", required=True)
    transition.add_argument("--reason")

    show = sub.add_parser("show", parents=[common])
    show.add_argument("--worktree-id")
    return root


def cleanup_route(state):
    """The states still to be driven from `state` before cleanup will accept.

    Read out of TRANSITIONS rather than restated beside it. A second copy of
    the machine is how the protocol prose came to teach `bound -> quiescent`,
    an edge that has never existed; a hint derived from the machine cannot
    drift away from it.
    """
    route = []
    cursor = state
    while cursor in TRANSITIONS and len(route) < len(STATES):
        nxt = sorted(TRANSITIONS[cursor])[0]
        route.append(nxt)
        if nxt == "cleanup_due":
            break
        cursor = nxt
    return route


def remaining_steps(row, indent="    "):
    """The commands, in order, that carry this tree from here to cleanup.

    Every refusal that turns a seat away from a lifecycle verb ends in this, so
    the seat learns the lifecycle at the point it got it wrong rather than from
    prose it read before it had a tree to apply it to.
    """
    state = row["state"]
    steps = []
    if state == "reserved":
        # reserved -> bound is bind's, not transition's: bind is the step that
        # advances the guard identity and checks the owner handle.
        steps.append(
            f"lore coordinate worktree bind --worktree-id {row['worktree_id']} "
            f"--owner-id {row['owner']['id']} --owner-pid <long-lived harness pid>"
        )
        state = "bound"
    for nxt in cleanup_route(state):
        steps.append(
            f"lore coordinate worktree transition --worktree-id {row['worktree_id']} --to {nxt}"
        )
    if not steps:
        return ""
    body = "\n".join(indent + step for step in steps)
    return "  Drive it there first, one command per state:\n" + body


def claimed_or_terminal(row, verb):
    """Why a record outside the live registry answers no verb at all."""
    return (
        f"worktree {row['worktree_id']} is at '{row['state']}' and its record has left the "
        f"live registry, so {verb} has nothing to act on: teardown has already claimed or "
        "finished this tree.\n"
        f"  Its cleanup proof, including the quarantine ref, is still readable: "
        f"lore coordinate worktree show --worktree-id {row['worktree_id']}"
    )


def owner_mismatch(row, offered):
    return (
        f"owner id {offered!r} does not own worktree {row['worktree_id']}; this tree belongs "
        f"to {row['owner']['id']!r}.\n"
        "  A tree answers only to the owner that allocated it, so that a second seat cannot "
        "re-bind one it is not working in."
    )


def transition_refusal(row, target):
    legal = sorted(TRANSITIONS.get(row["state"], set()))
    lines = [f"invalid coordination lifecycle transition {row['state']!r} -> {target!r}."]
    if legal:
        lines.append(f"  From '{row['state']}' the only legal next states are: {', '.join(legal)}.")
    else:
        lines.append(
            f"  '{row['state']}' has no outgoing transition: cleanup_due takes the tree down "
            "as it is entered, and sweep_claimed, removed and swept are terminal."
        )
    route = cleanup_route(row["state"])
    if route:
        lines.append(
            "  The accept-and-integrate route from here is "
            + " -> ".join(route)
            + " — one transition per state, and none of them can be skipped."
        )
    return "\n".join(lines)


def next_hint(row):
    """One line naming the lifecycle verb the owner has to drive next.

    A fresh allocation sits at `reserved`, and nothing downstream complains
    about that: the seat can allocate, dispatch, and integrate without the
    manifest ever leaving the state it started in — the omission only surfaces
    at teardown, when the checkout it thought it had finished with is still on
    disk. The hint rides the allocate output rather than the manifest, because
    it is advice to the caller, not state the manager owns.
    """
    return (
        "bind this tree before you dispatch into it "
        f"(lore coordinate worktree bind --worktree-id {row['worktree_id']} "
        f"--owner-id {row['owner']['id']}), then walk it through "
        + " -> ".join(cleanup_route("bound")) + " as you accept and integrate; "
        "the last of those removes the checkout, and a tree left at reserved is "
        "still on disk with nothing before teardown to say so."
    )


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
    # Added after the manifest is persisted, so the durable record stays exactly
    # the manager's own state and the hint lives only in what the caller reads.
    output = {**output, "lifecycle": manager.register_lifecycle(output)}
    hint = next_hint(output)
    if hint:
        output = {**output, "next": hint}
elif args.command == "bind":
    output = manager.bind(args)
elif args.command == "transition":
    output = manager.transition(args)
else:
    output = manager.show(args)
print(json.dumps(output, indent=2 if args.json else None, sort_keys=True))
PYEOF
