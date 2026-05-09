#!/usr/bin/env bash
# settlement-queue-process.sh - Process and inspect the repository-global settlement queue.
#
# Queue contract:
#   Jobs live at $KDIR/_work-queue/<role>/<request-id>.json.
#   Global leases live at $KDIR/_work-queue/settlement-audit/_leases.json.
#
# Usage:
#   settlement-queue-process.sh status  [--kdir <path>] [--role settlement-audit] [--json]
#   settlement-queue-process.sh process [--kdir <path>] [--role settlement-audit]
#                                      [--concurrency 1] [--max-jobs 1|--limit 1]
#                                      [--once] [--worker-id <id>] [--json]
#                                      [-- <audit-artifact args...>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

case "${1:-}" in
  -h|--help)
    sed -n '2,12p' "$0" >&2
    exit 0
    ;;
esac

KDIR_DEFAULT=""
if [[ " $* " != *" --kdir "* ]]; then
  KDIR_DEFAULT=$(resolve_knowledge_dir)
fi

KDIR_DEFAULT="$KDIR_DEFAULT" SCRIPT_DIR="$SCRIPT_DIR" python3 - "$@" <<'PYEOF'
import argparse
import fcntl
import glob
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path


def iso_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value):
    if not value:
        return 0.0
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return 0.0


def atomic_write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def read_json(path, default):
    try:
        with open(path) as fh:
            return json.load(fh)
    except FileNotFoundError:
        return default
    except json.JSONDecodeError:
        return default


def truncate_tail(text, limit=4000):
    if len(text) <= limit:
        return text
    return text[-limit:]


class Queue:
    def __init__(self, kdir, role, concurrency, stale_after, worker_id="", now_override="", script_dir=""):
        self.kdir = Path(kdir)
        self.role = role
        self.concurrency = max(1, int(concurrency))
        self.stale_after = max(1.0, float(stale_after))
        self.now_override = parse_iso(now_override) if now_override else 0.0
        self.queue_dir = self.kdir / "_work-queue" / role
        # The lease contract is intentionally fixed to settlement-audit so
        # different settlement queue roles still share one repository cap.
        self.lease_dir = self.kdir / "_work-queue" / "settlement-audit"
        self.leases_path = self.lease_dir / "_leases.json"
        self.lock_path = self.lease_dir / "_leases.lock"
        self.hostname = socket.gethostname()
        self.processor_id = worker_id or f"{self.hostname}:{os.getpid()}:{uuid.uuid4().hex[:8]}"
        self.last_leases_corrupt = False
        self.script_dir = Path(script_dir) if script_dir else Path(__file__).resolve().parent

    def now_ts(self):
        return self.now_override or time.time()

    def iso_now(self):
        return datetime.fromtimestamp(self.now_ts(), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def expires_iso(self):
        return datetime.fromtimestamp(self.now_ts() + self.stale_after, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    @contextmanager
    def locked(self):
        self.lease_dir.mkdir(parents=True, exist_ok=True)
        with open(self.lock_path, "a+") as lock_fh:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock_fh.fileno(), fcntl.LOCK_UN)

    def job_paths(self):
        if not self.queue_dir.exists():
            return []
        return sorted(
            p for p in glob.glob(str(self.queue_dir / "*.json"))
            if os.path.basename(p) != "_leases.json"
        )

    def load_leases(self):
        self.last_leases_corrupt = False
        try:
            with open(self.leases_path) as fh:
                data = json.load(fh)
        except FileNotFoundError:
            data = {"version": 1, "leases": []}
        except json.JSONDecodeError:
            self.last_leases_corrupt = True
            data = {"version": 1, "leases": []}
        if not isinstance(data, dict):
            self.last_leases_corrupt = True
            data = {"version": 1, "leases": []}
        leases = data.get("leases")
        if not isinstance(leases, list):
            self.last_leases_corrupt = True
            data["leases"] = []
        return data

    def save_leases(self, data):
        data["version"] = 1
        data["updated_at"] = self.iso_now()
        atomic_write_json(self.leases_path, data)

    def _requeue_job_for_lease(self, lease, recovered_at):
        job_file = lease.get("job_file") or ""
        if not job_file:
            return
        path = Path(job_file)
        if not path.exists():
            return
        job = read_json(path, {})
        if job.get("status") == "running" and job.get("lease_id") == lease.get("lease_id"):
            job["status"] = "pending"
            job["stale_recovered_at"] = recovered_at
            job["previous_lease_id"] = lease.get("lease_id")
            atomic_write_json(path, job)

    def recover_stale(self, leases_data):
        now = self.now_ts()
        recovered_at = self.iso_now()
        active = []
        recovered = 0
        active_lease_ids = set()
        for lease in leases_data.get("leases", []):
            expires = parse_iso(lease.get("expires_at"))
            heartbeat = parse_iso(lease.get("heartbeat_at"))
            stale = (expires and expires <= now) or (heartbeat and now - heartbeat > self.stale_after)
            if stale:
                self._requeue_job_for_lease(lease, recovered_at)
                recovered += 1
            else:
                active.append(lease)
                active_lease_ids.add(lease.get("lease_id"))
        leases_data["leases"] = active

        for path in self.job_paths():
            job = read_json(path, {})
            if job.get("status") == "running" and job.get("lease_id") not in active_lease_ids:
                job["status"] = "pending"
                job["stale_recovered_at"] = recovered_at
                atomic_write_json(path, job)
                recovered += 1
        return recovered

    def status_locked(self):
        leases_missing = not self.leases_path.exists()
        leases_data = self.load_leases()
        leases_repaired = self.last_leases_corrupt
        recovered = self.recover_stale(leases_data)
        if recovered or leases_repaired or leases_missing:
            self.save_leases(leases_data)

        counts = {"pending": 0, "running": 0, "completed": 0, "failed": 0, "corrupt": 0}
        next_request = ""
        total = 0
        for path in self.job_paths():
            total += 1
            try:
                with open(path) as fh:
                    job = json.load(fh)
            except Exception:
                counts["corrupt"] += 1
                continue
            status = job.get("status") or "pending"
            if status not in counts:
                counts[status] = counts.get(status, 0) + 1
            else:
                counts[status] += 1
            if status == "pending" and not next_request:
                next_request = job.get("request_id") or Path(path).stem

        active_leases = len(leases_data.get("leases", []))
        return {
            "ok": True,
            "role": self.role,
            "queue_dir": str(self.queue_dir),
            "leases_path": str(self.leases_path),
            "concurrency": self.concurrency,
            "active_leases": active_leases,
            "capacity": max(0, self.concurrency - active_leases),
            "counts": {**counts, "total": total},
            "next_request_id": next_request,
            "recovered_stale": recovered,
            "leases_repaired": leases_repaired,
            "leases": leases_data.get("leases", []),
        }

    def acquire_locked(self):
        leases_data = self.load_leases()
        if self.last_leases_corrupt:
            self.save_leases(leases_data)
            return None, "leases-corrupt-repaired"
        self.recover_stale(leases_data)
        active = leases_data.get("leases", [])
        if len(active) >= self.concurrency:
            self.save_leases(leases_data)
            return None, "capacity"

        active_request_ids = {lease.get("request_id") for lease in active}
        for path in self.job_paths():
            job = read_json(path, {})
            request_id = job.get("request_id") or Path(path).stem
            if job.get("status", "pending") != "pending":
                continue
            if request_id in active_request_ids:
                continue
            lease_id = f"lease-{uuid.uuid4().hex[:12]}"
            now = self.iso_now()
            lease = {
                "lease_id": lease_id,
                "request_id": request_id,
                "job_file": str(path),
                "pid": os.getpid(),
                "host": self.hostname,
                "processor_id": self.processor_id,
                "acquired_at": now,
                "heartbeat_at": now,
                "expires_at": self.expires_iso(),
            }
            job["request_id"] = request_id
            job["status"] = "running"
            job["lease_id"] = lease_id
            job["processor_id"] = self.processor_id
            job["started_at"] = now
            atomic_write_json(path, job)
            active.append(lease)
            leases_data["leases"] = active
            self.save_leases(leases_data)
            return {"lease": lease, "job": job, "path": str(path)}, ""

        self.save_leases(leases_data)
        return None, "empty"

    def heartbeat(self, lease_id):
        with self.locked():
            leases_data = self.load_leases()
            touched = False
            for lease in leases_data.get("leases", []):
                if lease.get("lease_id") == lease_id:
                    lease["heartbeat_at"] = self.iso_now()
                    lease["expires_at"] = self.expires_iso()
                    touched = True
                    break
            if touched:
                self.save_leases(leases_data)

    def finalize(self, acquired, returncode, stdout, stderr, duration_ms):
        lease_id = acquired["lease"]["lease_id"]
        path = Path(acquired["path"])
        with self.locked():
            leases_data = self.load_leases()
            leases_data["leases"] = [
                lease for lease in leases_data.get("leases", [])
                if lease.get("lease_id") != lease_id
            ]
            self.save_leases(leases_data)

            job = read_json(path, acquired["job"])
            if returncode == 0:
                job["status"] = "completed"
                job["completed_at"] = self.iso_now()
            else:
                job["status"] = "pending"
                job["last_failed_at"] = self.iso_now()
                job["failure_count"] = int(job.get("failure_count") or 0) + 1
            job["finished_at"] = self.iso_now()
            job["last_exit_code"] = returncode
            job["duration_ms"] = duration_ms
            job["stdout_tail"] = truncate_tail(stdout)
            job["stderr_tail"] = truncate_tail(stderr)
            atomic_write_json(path, job)
            return job

    def process_once(self, heartbeat_interval):
        with self.locked():
            acquired, reason = self.acquire_locked()
        if not acquired:
            return {"processed": False, "reason": reason}

        lease_id = acquired["lease"]["lease_id"]
        stop = threading.Event()

        def beat():
            while not stop.wait(heartbeat_interval):
                self.heartbeat(lease_id)

        thread = threading.Thread(target=beat, daemon=True)
        thread.start()

        started = time.time()
        job_obj = acquired["job"]
        try:
            proc = self.run_job(job_obj)
            returncode = proc.returncode
            stdout = proc.stdout
            stderr = proc.stderr
        except Exception as exc:
            returncode = 127
            stdout = ""
            stderr = str(exc)
        finally:
            stop.set()
            thread.join(timeout=max(0.2, heartbeat_interval))

        duration_ms = int((time.time() - started) * 1000)
        final_job = self.finalize(acquired, returncode, stdout, stderr, duration_ms)
        return {
            "processed": True,
            "request_id": final_job.get("request_id"),
            "status": "completed" if returncode == 0 else "retryable",
            "exit_code": returncode,
        }

    def run_job(self, job_obj):
        job_cmd = job_obj.get("job")
        if job_cmd:
            return subprocess.run(job_cmd, shell=True, text=True, capture_output=True)

        if job_obj.get("schema_version") != "settlement-audit.v1":
            raise RuntimeError("queue item missing job and is not settlement-audit.v1")

        artifact_path = job_obj.get("artifact_path") or ""
        claim_ids = job_obj.get("claim_ids") or []
        if not artifact_path:
            raise RuntimeError("settlement-audit.v1 item missing artifact_path")
        if not isinstance(claim_ids, list) or not claim_ids:
            raise RuntimeError("settlement-audit.v1 item missing claim_ids")

        fd, priority_path = tempfile.mkstemp(prefix="settlement-priority-", suffix=".json")
        try:
            with os.fdopen(fd, "w") as fh:
                json.dump(claim_ids, fh)
                fh.write("\n")
            cmd = [
                "bash",
                str(self.script_dir / "audit-artifact.sh"),
                artifact_path,
                "--kdir",
                str(self.kdir),
                "--priority-claims",
                priority_path,
            ] + AUDIT_ARGS
            return subprocess.run(cmd, text=True, capture_output=True)
        finally:
            try:
                os.unlink(priority_path)
            except FileNotFoundError:
                pass

    def dry_run(self, limit):
        selected = []
        with self.locked():
            status = self.status_locked()
            for path in self.job_paths():
                job = read_json(path, {})
                if job.get("status", "pending") == "pending":
                    selected.append({
                        "request_id": job.get("request_id") or Path(path).stem,
                        "artifact_id": job.get("artifact_id", ""),
                        "artifact_path": job.get("artifact_path", ""),
                        "claim_ids": job.get("claim_ids", []),
                        "path": path,
                    })
                    if limit and len(selected) >= limit:
                        break
        return {"ok": True, "processed": len(selected), "failed": 0, "dry_run": True, "items": selected, "status": status}


def render_human(status):
    counts = status["counts"]
    print(
        "settlement-audit: "
        f"{counts.get('pending', 0)} pending, "
        f"{status.get('active_leases', 0)} running, "
        f"{counts.get('failed', 0)} failed "
        f"(capacity {status.get('capacity', 0)}/{status.get('concurrency', 1)})"
    )


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("mode", nargs="?", choices=("status", "process"), default="process")
    parser.add_argument("--kdir", default=os.environ.get("KDIR_DEFAULT", ""))
    parser.add_argument("--role", default="settlement-audit")
    parser.add_argument("--concurrency", type=int, default=1)
    parser.add_argument("--max-jobs", "--limit", dest="max_jobs", type=int, default=1)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--stale-after", type=float, default=900)
    parser.add_argument("--heartbeat-interval", type=float, default=5)
    parser.add_argument("--worker-id", default="")
    parser.add_argument("--now", default="")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("-h", "--help", action="store_true")
    args, audit_args = parser.parse_known_args()

    if args.help:
        print("Usage: settlement-queue-process.sh [status|process] [--kdir PATH] [--json]", file=sys.stderr)
        return 0
    if not args.kdir:
        print("[settlement-queue] Error: --kdir is required when lore resolve is unavailable", file=sys.stderr)
        return 1
    if not Path(args.kdir).is_dir():
        print(f"[settlement-queue] Error: knowledge directory not found: {args.kdir}", file=sys.stderr)
        return 1

    global AUDIT_ARGS
    AUDIT_ARGS = audit_args
    if AUDIT_ARGS and AUDIT_ARGS[0] == "--":
        AUDIT_ARGS = AUDIT_ARGS[1:]

    queue = Queue(
        args.kdir,
        args.role,
        args.concurrency,
        args.stale_after,
        args.worker_id,
        args.now,
        os.environ.get("SCRIPT_DIR", ""),
    )

    if args.mode == "status":
        with queue.locked():
            status = queue.status_locked()
        if args.json:
            print(json.dumps(status, sort_keys=True))
        else:
            render_human(status)
        return 0

    max_jobs = 1 if args.once else max(1, args.max_jobs)
    if args.dry_run:
        output = queue.dry_run(max_jobs)
        if args.json:
            print(json.dumps(output, sort_keys=True))
        else:
            print(f"[settlement-queue] dry-run processed={output['processed']}")
        return 0

    results = []
    for _ in range(max_jobs):
        result = queue.process_once(max(0.1, args.heartbeat_interval))
        results.append(result)
        if not result.get("processed"):
            break
        if result.get("status") != "completed":
            break

    with queue.locked():
        status = queue.status_locked()
    output = {"ok": True, "results": results, "processed": sum(1 for r in results if r.get("processed")), "status": status}
    if args.json:
        print(json.dumps(output, sort_keys=True))
    else:
        for result in results:
            if result.get("processed"):
                print(f"[settlement-queue] {result['request_id']}: {result['status']} ({result['exit_code']})")
            else:
                print(f"[settlement-queue] idle: {result.get('reason', 'empty')}")
        render_human(status)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PYEOF
