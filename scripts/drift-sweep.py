#!/usr/bin/env python3
"""drift-sweep: detect committed-entry drift against each entry's captured_at_sha.

Walks `status: current` code-anchored knowledge entries (conventions/, gotchas/,
architecture/ by default), and for each `related_file` git-classifies the file
against the entry's exact `captured_at_sha` baseline:

  - unchanged : file present at baseline and HEAD, blob identical
  - changed   : file content at HEAD differs from baseline (includes the
                baseline-absent / HEAD-present case — a conservative re-audit)
  - vanished  : present at baseline, absent at HEAD
  - unresolved: absent at both, or not resolvable as a repo-root-relative path

An entry is *drifted* when any related_file is `changed` or `vanished`.
`unresolved` files are report-only and never by themselves mark an entry drifted.

With --include-unaudited, the sweep also plans enqueues for `status: current`
entries whose footer says `confidence: unaudited` — never-audited claims that
need no git baseline (a missing/unresolvable captured_at_sha only disables
drift classification, not eligibility). An unaudited entry whose commons
settlement item already has a completed run with a real gate verdict
(verified/unverified/contradicted) is suppressed and reported with
`already_settled: true`; the drift arm ignores that suppression because a new
code change is a new audit question. --unaudited-only additionally suppresses
enqueues for purely-drifted entries (drift is still classified and reported).

This planner performs NO writes. It emits, for each scoped entry, a JSON plan row
on stdout describing the drift decision plus the synthesized commons producer-row
payload (claim, falsifier, related_files, scale, entry_path, claim_id). The
orchestrator (drift-sweep.sh) is the only component that calls the writer scripts.

Drift baseline is the entry's `captured_at_sha`, NOT its `learned` date — this is
what distinguishes drift-sweep from staleness-scan.py (age-since-review).

Usage:
    drift-sweep.py <knowledge_dir> [--repo-root PATH] [--category NAME]... [--json]
                   [--include-unaudited] [--unaudited-only] [--work-item SLUG]

With --json, emits a single JSON object {"entries": [...], ...}. Without --json,
emits one plan row per line as compact JSON (the orchestrator consumes this).
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


# Code-anchored categories: entries here carry related_files that name source
# artifacts a git baseline can be computed against. principles/ and abstract
# no-anchor categories are excluded — there is nothing to re-check.
DEFAULT_CATEGORIES = ("conventions", "gotchas", "architecture")
SKIP_FILES = {
    "_inbox.md", "_index.md", "_meta.md", "_meta.json", "_index.json",
    "_self_test_results.md", "_manifest.json",
}

DRIFT_CLASSES = ("unchanged", "changed", "vanished", "unresolved")

# Footer is a single HTML comment whose body is pipe-delimited `key: value`
# pairs. Mirrors update-manifest.sh's parser: split the comment body on '|',
# then prefix-match each part. Multi-value fields (related_files, scale) split
# on ',' into lists per scale-field-in-html-metadata-footer.
_META_RE = re.compile(r"<!--\s*(.*?)\s*-->", re.DOTALL)


def collect_entry_files(knowledge_dir: str, categories: tuple[str, ...]) -> list[str]:
    results: list[str] = []
    for cat in categories:
        cat_path = os.path.join(knowledge_dir, cat)
        if not os.path.isdir(cat_path):
            continue
        for root, dirs, files in os.walk(cat_path):
            dirs[:] = [d for d in dirs if not d.startswith("_") and d != "__pycache__"]
            for fname in sorted(files):
                if not fname.endswith(".md") or fname in SKIP_FILES:
                    continue
                results.append(os.path.join(root, fname))
    return sorted(results)


def parse_footer(text: str) -> dict:
    """Extract the footer fields drift-sweep needs.

    Returns related_files (list), scale (list), captured_at_sha (str|None),
    status (str|None), confidence (str|None). related_files and scale are
    comma-split into lists; a consumer that treats them as single strings
    silently corrupts multi-value entries (47 use scale=architecture,subsystem;
    64 use subsystem,implementation).
    """
    out: dict = {
        "related_files": [],
        "scale": [],
        "captured_at_sha": None,
        "status": None,
        "confidence": None,
    }
    m = _META_RE.search(text)
    if not m:
        return out
    for part in m.group(1).split("|"):
        part = part.strip()
        if part.startswith("related-files:") or part.startswith("related_files:"):
            rf = part.split(":", 1)[1].strip()
            out["related_files"] = [r.strip() for r in rf.split(",") if r.strip()]
        elif part.startswith("scale:"):
            sc = part.split(":", 1)[1].strip()
            out["scale"] = [s.strip() for s in sc.split(",") if s.strip()]
        elif part.startswith("captured_at_sha:"):
            out["captured_at_sha"] = part.split(":", 1)[1].strip() or None
        elif part.startswith("status:"):
            out["status"] = part.split(":", 1)[1].strip() or None
        elif part.startswith("confidence:"):
            # `confidence_advances:` does not match this prefix — the char
            # after "confidence" there is "_", not ":".
            out["confidence"] = part.split(":", 1)[1].strip() or None
    return out


def extract_claim(text: str) -> tuple[str | None, str | None]:
    """Return (claim, falsifier) synthesized from the entry body.

    claim = H1 heading text + first non-empty body paragraph (in document order),
    joined as one string. Returns (None, ...) when either the H1 or the lead
    paragraph cannot be extracted — the caller treats that as `unparseable` and
    never enqueues (no claim fabrication).

    falsifier = the entry's own `Falsifier:`-prefixed prose (it may appear inline
    within the lead paragraph in promoted entries), else None — the caller
    substitutes the deterministic fallback.
    """
    # Strip the footer comment so its text never bleeds into the lead paragraph.
    body = _META_RE.sub("", text)
    lines = body.splitlines()

    heading = None
    idx = 0
    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped:
            continue
        m = re.match(r"^#\s+(.*\S)\s*$", stripped)
        if m:
            heading = m.group(1).strip()
            idx = i + 1
        break  # first non-empty line decides; H1 must be the lead line
    if not heading:
        return None, None

    # First non-empty paragraph after the H1.
    para_lines: list[str] = []
    started = False
    for line in lines[idx:]:
        if line.strip():
            started = True
            para_lines.append(line.strip())
        elif started:
            break
    paragraph = " ".join(para_lines).strip()
    if not paragraph:
        return None, None

    claim = f"{heading} {paragraph}".strip()

    falsifier = None
    fm = re.search(r"Falsifier:\s*(.+)$", paragraph)
    if fm:
        falsifier = fm.group(1).strip() or None

    return claim, falsifier


# Gate verdicts that settle a claim. Deliberately stricter than the settlement
# processor's TERMINAL run statuses: failed/blocked runs must stay re-reachable,
# so only a completed run with one of these verdicts suppresses the unaudited arm.
REAL_VERDICTS = ("verified", "unverified", "contradicted")


def commons_item_id(work_item: str, claim_id: str) -> str:
    """Settlement queue identity for a commons item — must mirror
    settlement-processor.py::item_id (sha256 over kind:work_item:source_id)."""
    digest = hashlib.sha256(f"commons:{work_item}:{claim_id}".encode()).hexdigest()[:20]
    return f"commons-{digest}"


def load_settled_item_ids(knowledge_dir: str) -> set[str]:
    """item_ids of non-invalidated completed runs carrying a real gate verdict.

    Read-only dedupe against the audit substrate: the sweep uses this to avoid
    re-enqueueing claims the gate already settled — it never makes verdicts.
    """
    runs_dir = Path(knowledge_dir) / "_settlement" / "runs"
    out: set[str] = set()
    if not runs_dir.is_dir():
        return out
    for path in sorted(runs_dir.glob("*.json")):
        try:
            run = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(run, dict):
            continue
        if run.get("invalidated_at") or run.get("invalidated"):
            continue
        if run.get("status") != "completed":
            continue
        verdict = run.get("verdict") if isinstance(run.get("verdict"), dict) else {}
        if verdict.get("verdict") not in REAL_VERDICTS:
            continue
        if run.get("item_id"):
            out.add(str(run["item_id"]))
    return out


def slugify_path(rel_path: str) -> str:
    """Deterministic slug from the store-relative entry path.

    Drives the synthesized claim_id `drift-<slug>` so re-runs mint the same id
    and the settlement queue dedupes on it. Stable for a fixed path.
    """
    base = re.sub(r"\.md$", "", rel_path)
    base = re.sub(r"[^a-zA-Z0-9]+", "-", base).strip("-").lower()
    if len(base) > 80:
        # Keep a readable prefix plus a hash tail so distinct long paths that
        # share an 80-char prefix do not collide on the same claim_id.
        digest = hashlib.sha256(rel_path.encode()).hexdigest()[:8]
        base = f"{base[:71]}-{digest}"
    return base


def resolve_repo_rel(rf: str, repo_root: str) -> str | None:
    """Map a related_file value to a repo-root-relative path, or None if it
    falls outside the repo.

    related_files appear in three forms: repo-relative (`scripts/x.sh`),
    absolute-inside-repo (`/abs/repo/scripts/x.sh`), and absolute-outside-repo
    (`/abs/elsewhere/...`). git pathspecs need a repo-relative form; an
    outside-repo path has no git baseline and resolves to None (→ unresolved).
    """
    repo_root_abs = os.path.abspath(repo_root)
    if os.path.isabs(rf):
        abs_path = os.path.abspath(rf)
    else:
        abs_path = os.path.abspath(os.path.join(repo_root_abs, rf))
    try:
        if os.path.commonpath([repo_root_abs, abs_path]) != repo_root_abs:
            return None
    except ValueError:
        # commonpath raises when paths are on different drives/roots.
        return None
    rel = os.path.relpath(abs_path, repo_root_abs)
    if rel.startswith(".."):
        return None
    return rel


def git_blob_id(repo_root: str, ref: str, rel_path: str) -> str | None:
    """Return the git blob object id for rel_path at ref, or None if absent there.

    `git rev-parse <ref>:<path>` prints the blob id when the path exists in that
    tree and exits non-zero (with a "Path ... does not exist" stderr) when it
    does not. We distinguish absent (None) from operational failure by checking
    only for the path-absent signature; any other non-zero exit is re-raised.
    """
    spec = f"{ref}:{rel_path}"
    result = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", spec],
        capture_output=True, text=True, cwd=repo_root, timeout=30,
    )
    if result.returncode == 0:
        return result.stdout.strip() or None
    return None


def classify_file(repo_root: str, sha: str, head: str, rf: str) -> dict:
    """Classify one related_file against the captured_at_sha baseline."""
    rel = resolve_repo_rel(rf, repo_root)
    if rel is None:
        return {"path": rf, "drift_class": "unresolved", "reason": "outside repo root"}

    base_blob = git_blob_id(repo_root, sha, rel)
    head_blob = git_blob_id(repo_root, head, rel)

    if head_blob is None:
        if base_blob is None:
            return {"path": rf, "drift_class": "unresolved", "reason": "absent at baseline and HEAD"}
        return {"path": rf, "drift_class": "vanished"}
    if base_blob is None:
        # Present at HEAD but not at the baseline tree: the cited file did not
        # exist when the claim was captured. Treat as changed (conservative
        # re-audit) rather than unchanged.
        return {"path": rf, "drift_class": "changed", "reason": "baseline-absent, HEAD-present"}
    if base_blob == head_blob:
        return {"path": rf, "drift_class": "unchanged"}
    return {"path": rf, "drift_class": "changed"}


def git_head(repo_root: str) -> str:
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        capture_output=True, text=True, cwd=repo_root, timeout=30,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git rev-parse HEAD failed in {repo_root}: {result.stderr.strip()}")
    return result.stdout.strip()


def sha_resolvable(repo_root: str, sha: str) -> bool:
    result = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", f"{sha}^{{commit}}"],
        capture_output=True, text=True, cwd=repo_root, timeout=30,
    )
    return result.returncode == 0


def plan_entry(knowledge_dir: str, repo_root: str, head: str, abs_path: str, *,
               include_unaudited: bool = False, unaudited_only: bool = False,
               settled_ids: set[str] | None = None,
               work_item: str | None = None) -> dict:
    """Build the drift plan row for one entry. Never writes."""
    rel_path = os.path.relpath(abs_path, knowledge_dir)
    text = Path(abs_path).read_text(encoding="utf-8", errors="replace")
    footer = parse_footer(text)

    row: dict = {
        "entry_path": rel_path,
        "status": footer["status"],
        "confidence": footer["confidence"],
        "captured_at_sha": footer["captured_at_sha"],
        "scale": footer["scale"],
        "related_files": footer["related_files"],
        "files": [],
        "drifted": False,
        "producer_row": "skipped",
        "enqueue": "skipped",
    }

    # Scope gates — skipped entries carry a reason, not an error.
    if footer["status"] != "current":
        row["skip_reason"] = f"status is {footer['status']!r}, not current"
        return row
    if not footer["related_files"]:
        row["skip_reason"] = "no related_files"
        return row

    # The unaudited arm audits never-audited current claims; it needs no git
    # baseline, so a missing/unresolvable captured_at_sha only disables drift
    # classification for such entries instead of skipping them outright.
    unaudited_candidate = include_unaudited and footer["confidence"] == "unaudited"

    drift_skip = None
    if not footer["captured_at_sha"]:
        drift_skip = "missing captured_at_sha"
    elif not sha_resolvable(repo_root, footer["captured_at_sha"]):
        # The baseline commit is not in this checkout — we cannot compute drift.
        # Report-only; not an operational failure of the sweep.
        drift_skip = f"captured_at_sha not resolvable in repo: {footer['captured_at_sha']}"

    if drift_skip and not unaudited_candidate:
        row["skip_reason"] = drift_skip
        return row

    drifted = False
    if drift_skip:
        row["drift_check"] = "skipped"
        row["drift_skip_reason"] = drift_skip
    else:
        files = [classify_file(repo_root, footer["captured_at_sha"], head, rf)
                 for rf in footer["related_files"]]
        row["files"] = files
        drifted = any(f["drift_class"] in ("changed", "vanished") for f in files)
        row["drifted"] = drifted

    claim_id = f"drift-{slugify_path(rel_path)}"

    # Unaudited arm, suppressed when a completed run already settled this exact
    # commons item with a real verdict: the arm's premise is "never audited",
    # which a recorded verdict falsifies. The drift arm ignores the suppression
    # — a new code change is a new audit question.
    unaudited_arm = False
    if unaudited_candidate:
        if settled_ids and commons_item_id(work_item or "", claim_id) in settled_ids:
            row["already_settled"] = True
        else:
            unaudited_arm = True

    arms = []
    if drifted and not unaudited_only:
        arms.append("drift")
    if unaudited_arm:
        arms.append("unaudited")
    if not arms:
        return row

    # Synthesize the commons producer-row payload from the entry. claim and
    # related_files come from the entry verbatim; an unparseable entry is
    # reported and never enqueued (no claim fabrication).
    claim, falsifier = extract_claim(text)
    if claim is None:
        row["producer_row"] = "skipped"
        row["enqueue"] = "skipped"
        row["unparseable"] = True
        row["skip_reason"] = "no H1 or lead paragraph to synthesize a claim"
        return row

    if not falsifier:
        if "drift" in arms:
            falsifier = (
                "entry claim no longer matches cited code at HEAD; re-verify against "
                + ", ".join(footer["related_files"])
            )
        else:
            # Unaudited-arm wording must not assert a code change that didn't
            # happen — the entry may be byte-identical to its baseline.
            falsifier = (
                "promoted claim has never been independently audited; verify against "
                + ", ".join(footer["related_files"])
                + " at HEAD"
            )
    scale = footer["scale"] or ["subsystem"]

    row["claim_id"] = claim_id
    row["enqueue_reason"] = "+".join(arms)
    row["synthesized_payload"] = {
        "claim_id": claim_id,
        "claim": claim,
        "falsifier": falsifier,
        "scale": ",".join(scale),
        "related_files": footer["related_files"],
        "entry_path": rel_path,
        "captured_at_sha": footer["captured_at_sha"],
    }
    return row


def run(knowledge_dir: str, repo_root: str, categories: tuple[str, ...], *,
        include_unaudited: bool = False, unaudited_only: bool = False,
        work_item: str | None = None) -> dict:
    knowledge_dir = os.path.abspath(knowledge_dir)
    repo_root = os.path.abspath(repo_root)
    if not os.path.isdir(os.path.join(repo_root, ".git")):
        raise RuntimeError(f"repo root is not a git repository: {repo_root}")
    head = git_head(repo_root)

    settled_ids = load_settled_item_ids(knowledge_dir) if include_unaudited else set()

    rows = [plan_entry(knowledge_dir, repo_root, head, p,
                       include_unaudited=include_unaudited,
                       unaudited_only=unaudited_only,
                       settled_ids=settled_ids,
                       work_item=work_item)
            for p in collect_entry_files(knowledge_dir, categories)]

    drifted = [r for r in rows if r.get("drifted")]
    return {
        "knowledge_dir": knowledge_dir,
        "repo_root": repo_root,
        "head": head,
        "categories": list(categories),
        "include_unaudited": include_unaudited,
        "unaudited_only": unaudited_only,
        "scanned": len(rows),
        "drifted_count": len(drifted),
        "unaudited_enqueue_count": sum(
            1 for r in rows if "unaudited" in (r.get("enqueue_reason") or "")),
        "already_settled_count": sum(1 for r in rows if r.get("already_settled")),
        "entries": rows,
    }


def main() -> int:
    ap = argparse.ArgumentParser(prog="drift-sweep.py")
    ap.add_argument("knowledge_dir", help="Path to the knowledge store directory")
    ap.add_argument("--repo-root", default=None,
                    help="Source repo root for git baseline checks (default: cwd)")
    ap.add_argument("--category", action="append", default=[],
                    help="Restrict to a category (repeatable; default: conventions, gotchas, architecture)")
    ap.add_argument("--json", action="store_true",
                    help="Emit one JSON report object; default emits one plan row per line")
    ap.add_argument("--include-unaudited", action="store_true",
                    help="Also plan enqueues for status:current confidence:unaudited entries")
    ap.add_argument("--unaudited-only", action="store_true",
                    help="Implies --include-unaudited; suppress enqueues for purely-drifted entries")
    ap.add_argument("--work-item", default=None,
                    help="Work item slug owning synthesized commons items "
                         "(required with --include-unaudited; used for already-settled dedupe)")
    args = ap.parse_args()

    if args.unaudited_only:
        args.include_unaudited = True
    if args.include_unaudited and not args.work_item:
        ap.error("--work-item is required with --include-unaudited/--unaudited-only")

    categories = tuple(args.category) if args.category else DEFAULT_CATEGORIES
    repo_root = os.path.abspath(args.repo_root) if args.repo_root else os.getcwd()

    try:
        report = run(args.knowledge_dir, repo_root, categories,
                     include_unaudited=args.include_unaudited,
                     unaudited_only=args.unaudited_only,
                     work_item=args.work_item)
    except (RuntimeError, subprocess.TimeoutExpired, subprocess.SubprocessError, OSError) as exc:
        print(f"[drift-sweep] operational failure: {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(report, sort_keys=True))
    else:
        for row in report["entries"]:
            print(json.dumps(row, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
