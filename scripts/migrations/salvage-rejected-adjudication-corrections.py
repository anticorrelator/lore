#!/usr/bin/env python3
"""Land the thirteen judge corrections that never reached their entries.

Thirteen audit runs recorded a `rejected` verdict together with the corrected
text. Downstream, the executor filtered verdict rows on a judge name the audit
had stopped emitting, so every one of those corrections was dropped. The rows
themselves survived: each sits in a `_work/**/verdicts/*.jsonl` file with its
correction text intact.

This migration reads those rows and lands each correction on its entry through
`apply-correction.sh`, the sole mutator for commons entries. It authorizes with
`--allow-peer-verification`, whose authority is the caller's own evidence —
there is no settlement run record to consult, and none is needed.

Each member ends in one of three states, recorded in a durable manifest:

  corrected       the superseded claim was present verbatim and was replaced
  disputed        it was not, so the judge's prose lands as a dated marker the
                  next reader of the entry will see
  already-current the entry already states what the judge said it should, and
                  says so verbatim at a recorded anchor

`already-current` is a terminal disposition, not a skip. It is also not
assertable: a member only reaches it when the text in ALREADY_CURRENT below is
found in the entry body at run time. When that text is absent the member falls
through to the correct-or-dispute fork like any other.

Historical entry paths resolve only through the ledger's own
`provenance-migration` events. The store's git history is not evidence about
where an entry lives now.

Re-running is safe. Every correction and dispute identity derives from the
adjudication event id, and `apply-correction.sh` recognizes its own prior
write, so a second run reports every member as already resolved and touches no
entry.

`_settlement/` and every `verdicts/*.jsonl` are read-only input here. Nothing
in this file opens either for writing.

Usage:
    salvage-rejected-adjudication-corrections.py [--kdir PATH] [--dry-run] [--json]
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
from datetime import datetime, timezone

WORK_ITEM = "remove-settlement-pipeline-community-driven-verifi"
MANIFEST_NAME = "salvage-manifest.json"
SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_DIR = os.path.dirname(SCRIPTS_DIR)

# The forked judge name the executor's filter did not recognize. Every verdict
# row in this cohort carries it.
JUDGE = "correctness-gate-assertion"

# The ledger event and the verdict row that produced it are written by separate
# steps, so their timestamps can differ by a second. Requiring byte equality
# here would drop a member for the same reason the executor dropped thirteen.
JOIN_TOLERANCE_SECONDS = 120

# Per member, the exact span of the entry the judge's correction supersedes and
# the text that replaces it. Derived by reading each entry against its judge
# correction; `apply-correction.sh` refuses any span it cannot match verbatim,
# and that refusal routes the member to a dispute marker instead.
REPAIRS: dict[str, dict[str, str]] = {
    "meta-footer-pipe-delimited-no-command-values": {
        "superseded": (
            "parsed by split(\"|\") in drift-sweep.py parse_meta; any field whose value may "
            "contain '|' (shell commands, regexes, URLs with pipes) must be persisted in "
            "producer-row JSONL sidecars, never in the footer — a pipe in a footer value "
            "silently corrupts parsing of all subsequent META fields."
        ),
        "replacement": (
            "parsed by split(\"|\") in drift-sweep.py parse_footer; any field whose value may "
            "contain '|' (shell commands, regexes, URLs with pipes) must be persisted in "
            "producer-row JSONL sidecars, never in the footer — a pipe in a footer value "
            "silently splits that value into extra tokens, truncating or spoofing the field, "
            "though each token is prefix-matched independently so well-formed later fields "
            "still parse."
        ),
    },
    "csai-obs-01": {
        "superseded": (
            "The lore repo has exactly two production substrate write archetypes and every new "
            "substrate should pick one per surface, never mix:"
        ),
        "replacement": (
            "The lore repo has two production substrate write archetypes and every new "
            "substrate should pick one per surface — though one file can carry both when each "
            "has its own sanctioned writer, as task-claims.jsonl does with the appender "
            "evidence-append.sh and the row-rewriting updater evidence-update.sh:"
        ),
    },
    "cped-obs-01": {
        "superseded": (
            "Knowledge-delivery telemetry in lore is one sink with four independent writers: "
            "_meta/retrieval-log.jsonl receives session-load, search, prefetch, and "
            "manifest_load records, each written fail-open by its own surface with a "
            "heterogeneous shape; the shared render/budget core (pk_retrieval.py) does zero "
            "logging, so no single chokepoint exists to instrument — and the final hop, a lead "
            "pasting resolved context into a worker prompt, is an LLM action no script observes."
        ),
        "replacement": (
            "Knowledge-delivery telemetry in lore spans two sinks: _meta/retrieval-log.jsonl "
            "receives session-load, search, prefetch, and manifest_load records from four "
            "independent writers, each written fail-open by its own surface with a "
            "heterogeneous shape, and _packets/packets.jsonl receives context-packet delivery "
            "records through packet-append.sh; the shared render/budget core (pk_retrieval.py) "
            "does zero logging, so no single chokepoint exists to instrument — and the final "
            "hop, a lead pasting resolved context into a worker prompt, is observed post hoc by "
            "packet-assess.py through the Packet-id marker those prompts carry."
        ),
    },
    "judge-line-anchor-jitter-breaks-overlap-gates": {
        "superseded": (
            "reproduce omission content reliably but derive line-number anchors with multi-line "
            "jitter (and historical captures can themselves be arithmetically off), so"
        ),
        "replacement": (
            "mostly return covered-silence rather than reproducing omission content — 6 of 7 "
            "replays emitted no omission at all, and the one that did shifted its anchor from "
            "the historical 365-369 to 372-372 — so"
        ),
    },
    "durable-mutation-and-journal-in-one-cmd": {
        "superseded": (
            "pair each durable queue/state mutation with its journal append inside a single Cmd "
            "goroutine so the append can never precede the state it records, without extra "
            "cross-Cmd coordination."
        ),
        "replacement": (
            "pair a durable queue/state mutation with its journal append inside a single Cmd "
            "goroutine wherever the two would otherwise be batched concurrently, so the append "
            "can never precede the state it records without extra cross-Cmd coordination. "
            "Queue-tick transitions are the exception: queueTickCmd completes and returns its "
            "result first, and separate journalCmds record it afterwards."
        ),
    },
    "smir-t3-harness-injection-contract-divergence": {
        "superseded": (
            "codex splits CR/LF (LF=newline, CR=submit) while raw LF is also newline-only on "
            "claude-code and opencode;"
        ),
        "replacement": (
            "codex splits CR/LF (LF=newline, CR=submit) and raw LF is newline-only on "
            "claude-code and codex but not on opencode, whose newline sequence is Alt+Enter / "
            "ESC CR (0x1b 0x0d) and whose raw-LF behavior was never probed;"
        ),
    },
    "pnu-write-boundary-gate-vs-internal-lifecycle-caller": {
        "superseded": (
            "archive-project.sh's status flip executes exactly when the project is the "
            "label-only archived identity the describe gate rejects, so internal lifecycle "
            "mutations should go through a shared lib helper that writes in place rather than "
            "shelling through the gated verb."
        ),
        "replacement": (
            "archive-project.sh's status flip runs only when a project record already exists, so "
            "it is skipped for the label-only archived identity the describe gate rejects — but "
            "internal lifecycle mutations should still go through a shared lib helper that "
            "writes in place rather than shelling through the gated verb, because "
            "describe-project.sh would create a record (violating archive's rule against "
            "registering a project just to mark it archived) and set_project_record_status "
            "no-ops when no record exists."
        ),
    },
    "tsv-obs-reachability-index-membership": {
        "superseded": (
            "TUI session reachability is bound to work-item index membership: panels are keyed "
            "by session identity (sessionPanels/localSessions hold derived-slug and slugless "
            "keys), but the only route to a panel runs through currentSessionPanel() <- "
            "m.list.CurrentSlug() <- rows built solely from _index.json work items — so any "
            "session whose identity is not an index-row slug (derived <slug>--wN workers, "
            "slugless chats) is structurally unreachable, not merely un-badged, and badge work "
            "cannot fix it."
        ),
        "replacement": (
            "TUI session reachability is not bound to work-item index membership alone: panels "
            "are keyed by session identity (sessionPanels/localSessions hold derived-slug and "
            "slugless keys), and one route runs through currentSessionPanel() <- "
            "m.list.CurrentSlug() <- rows built solely from _index.json work items, which by "
            "itself reaches no session whose identity is not an index-row slug (derived "
            "<slug>--wN workers, slugless chats) — but a second first-class route does: the "
            "stateSessions workspace resolves currentSessionsPanel() <- "
            "sessionsList.CurrentSession() -> m.sessionPanels[row.PanelKey] over rows "
            "buildSessionRows assembles from the session-registry union of instances, pending, "
            "and claimed, so those sessions are reachable independent of index-row membership."
        ),
    },
    "capabilities-evidence-scan-is-hand-maintained": {
        "superseded": (
            "adding an evidence pointer anywhere new requires extending both copies or the "
            "unused-evidence check rejects it."
        ),
        "replacement": (
            "adding a newly indexed evidence id consumed only at an unenumerated JSON location "
            "requires extending both copies or the unused-evidence check rejects it, while a "
            "new pointer reusing an already-consumed id needs no extractor change."
        ),
    },
    "collection-list-cursor-does-not-skip-section-headers": {
        "superseded": (
            "Only CursorToFirstItem and CurrentID treat headers specially (CurrentID returns "
            "\"\" on a header)."
        ),
        "replacement": (
            "Only CursorToFirstItem, CurrentID, and emitCursorChange treat headers specially "
            "(CurrentID returns \"\" on a header; emitCursorChange fires its callback only for a "
            "non-header row carrying an ID)."
        ),
    },
    "lore-tui-production-code-may-not-write-parent-stderr": {
        "superseded": "AST-walks every non-test .go file under tui/ (exempting main.go and cmd/)",
        "replacement": (
            "AST-walks every non-test .go file under tui/ (exempting main.go, top-level cmd/ "
            "packages, and internal/config/cmd/parity-harness/main.go)"
        ),
    },
}

# Members whose entry already states what the judge said it should — repaired by
# a later editor before this salvage ran. Nothing is taken on trust: `anchor`
# must appear in the entry body, and the source at `file`:`line_range` must still
# read exactly `snippet`, or the member rejoins the correct-or-dispute fork. The
# source anchor is the code the judge cited, so the resulting ledger row is a
# grounded verification rather than an assertion that the entry looks fine.
ALREADY_CURRENT: dict[str, dict[str, str]] = {
    "tmux-spec-stale-rows-recovery-manifest": {
        "anchor": (
            "one TUI claims it by atomic rename, handles or reattaches its sessions, then "
            "deletes the claimed corpse row"
        ),
        "file": "tui/internal/session/adopt.go",
        "line_range": "86-94",
        "snippet": (
            "func DeleteClaim(claimPath string) error {\n"
            "\tif claimPath == \"\" {\n"
            "\t\treturn nil\n"
            "\t}\n"
            "\terr := os.Remove(claimPath)\n"
            "\tif os.IsNotExist(err) {\n"
            "\t\treturn nil\n"
            "\t}\n"
            "\treturn err"
        ),
        "rationale": (
            "The judge reported that a reaper does exist — startup adoption claims a dead-PID "
            "row and deletes the corpse. The entry says exactly that now, so the correction "
            "landed by another route before this salvage ran."
        ),
    },
    "session-substrate-kind-agnostic-below-enqueue-gate": {
        "anchor": (
            "the closed set spec|implement|chat|worker is asserted only at the bash enqueue gate"
        ),
        "file": "scripts/session-request.sh",
        "line_range": "168-171",
        "snippet": (
            "case \"$TYPE\" in\n"
            "  spec|implement|chat|worker) ;;\n"
            "  \"\") fail \"missing required field: --type (one of spec, implement, chat, worker)\" ;;\n"
            "  *) fail \"invalid --type: '$TYPE' (must be one of spec, implement, chat, worker)\" ;;"
        ),
        "rationale": (
            "The judge reported the closed set has four members, not three. The entry names all "
            "four now, so the correction landed by another route before this salvage ran."
        ),
    },
}


def _load_trust_compute():
    """Import trust-compute.py for its published provenance-migration resolver."""
    path = os.path.join(SCRIPTS_DIR, "trust-compute.py")
    spec = importlib.util.spec_from_file_location("trust_compute", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def read_jsonl(path: str) -> list[dict]:
    rows = []
    if not os.path.isfile(path):
        return rows
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(row, dict):
                rows.append(row)
    return rows


def parse_ts(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def verdict_files(kdir: str) -> list[str]:
    """Every judge verdict file, active and archived. Read-only for this run."""
    found = []
    for dirpath, _dirnames, filenames in os.walk(os.path.join(kdir, "_work")):
        if os.path.basename(dirpath) != "verdicts":
            continue
        for name in filenames:
            if name.endswith(".jsonl"):
                found.append(os.path.join(dirpath, name))
    return sorted(found)


def index_verdicts(kdir: str) -> dict[str, list[dict]]:
    """Judge verdicts for this judge, keyed by claim id."""
    index: dict[str, list[dict]] = {}
    for path in verdict_files(kdir):
        with open(path, encoding="utf-8") as fh:
            for lineno, line in enumerate(fh, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    block = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(block, dict) or block.get("judge") != JUDGE:
                    continue
                for verdict in block.get("verdicts") or []:
                    claim_id = verdict.get("claim_id")
                    if not claim_id:
                        continue
                    index.setdefault(claim_id, []).append({
                        "file": path,
                        "line": lineno,
                        "artifact_id": block.get("artifact_id"),
                        "judge_run_at": block.get("judge_run_at"),
                        "judge_template_version": block.get("judge_template_version"),
                        "verdict": verdict.get("verdict"),
                        "correction": verdict.get("correction") or "",
                        "evidence": verdict.get("evidence") or "",
                    })
    return index


def match_verdict(event: dict, candidates: list[dict]) -> tuple[dict | None, int | None]:
    """The verdict row that produced this adjudication, and their clock skew.

    The pair is identified by claim id and run time, but the two timestamps are
    written by different steps and can disagree by a second, so the nearest
    candidate inside the tolerance wins rather than an exact match.
    """
    observed = parse_ts(event.get("observed_at"))
    best: dict | None = None
    best_delta: int | None = None
    for candidate in candidates:
        if not candidate["correction"]:
            continue
        run_at = parse_ts(candidate["judge_run_at"])
        if observed is None or run_at is None:
            continue
        delta = int(abs((run_at - observed).total_seconds()))
        if delta > JOIN_TOLERANCE_SECONDS:
            continue
        key = (delta, candidate["file"], candidate["line"])
        if best is None or key < (best_delta, best["file"], best["line"]):
            best, best_delta = candidate, delta
    return best, best_delta


def build_cohort(kdir: str, trust_compute) -> tuple[list[dict], list[dict]]:
    """The salvage roster, joined to the verdict rows, plus what fell outside it.

    Membership is the enumerated roster below, not "every rejected adjudication
    in the ledger". This cohort is a closed historical set — the corrections an
    executor's judge-name filter dropped — and the ledger is a live file other
    sessions append to. A predicate that reads the whole ledger would adopt a
    fresh adjudication the moment some other session's judge wrote one, and
    settle an entry whose own session is still working on it. Anything rejected
    but off-roster is reported untouched so it stays visible.
    """
    ledger = read_jsonl(os.path.join(kdir, "_trust", "trust-events.jsonl"))
    migrations = trust_compute._build_migrations(ledger, [])
    index = index_verdicts(kdir)
    roster = set(REPAIRS) | set(ALREADY_CURRENT)

    cohort = []
    off_roster = []
    for row in ledger:
        if row.get("event") != "adjudication":
            continue
        payload = row.get("payload") or {}
        if payload.get("verdict") != "rejected":
            continue
        if payload.get("claim_id") not in roster:
            off_roster.append({
                "claim_id": payload.get("claim_id"),
                "adjudication_event_id": row.get("event_id"),
                "observed_at": row.get("observed_at"),
                "entry_path_recorded": row.get("entry_path"),
                "note": "outside this salvage's roster; left untouched for its own session to resolve",
            })
            continue
        recorded = row.get("entry_path") or ""
        resolved, warning = trust_compute.resolve_entry_key(recorded, migrations)
        verdict, skew = match_verdict(row, index.get(payload.get("claim_id"), []))
        cohort.append({
            "adjudication_event_id": row.get("event_id"),
            "claim_id": payload.get("claim_id"),
            "run_id": payload.get("run_id"),
            "observed_at": row.get("observed_at"),
            "entry_path_recorded": recorded,
            "entry_path_resolved": resolved,
            "path_resolution": "provenance-migration" if resolved != recorded else "unmigrated",
            "path_warning": warning,
            "verdict": verdict,
            "join_skew_seconds": skew,
        })
    return (
        sorted(cohort, key=lambda m: (m["observed_at"] or "", m["claim_id"] or "")),
        sorted(off_roster, key=lambda m: (m["observed_at"] or "", m["claim_id"] or "")),
    )


def entry_body(kdir: str, rel_path: str) -> str | None:
    abs_path = os.path.join(kdir, rel_path)
    if not os.path.isfile(abs_path):
        return None
    try:
        return open(abs_path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        return None


def evidence_text(member: dict) -> str:
    """The judge's own evidence, which already opens with a file:line anchor."""
    evidence = (member["verdict"]["evidence"] or "").strip()
    return evidence or f"{member['entry_path_resolved']} — recorded by {JUDGE}"


def dispute_note(member: dict) -> str:
    observed = (member["observed_at"] or "")[:10]
    correction = member["verdict"]["correction"].strip().rstrip(".")
    return (
        f"A judge reading this entry against the code on {observed} found it contradicted: "
        f"{correction}. That correction was recorded but never reached the entry, and the claim "
        f"it would replace is no longer present here word for word, so it has not been rewritten."
    )


def run(cmd: list[str]) -> tuple[int, str, str]:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc.returncode, proc.stdout, proc.stderr


def append_trust_event(kdir: str, args: list[str], dry_run: bool) -> str:
    """Append one ledger row through the sole writer.

    A duplicate event_id is a silent no-op there, so re-running this migration
    heals a partial ledger write instead of double-counting the entry.
    """
    if dry_run:
        return "dry-run"
    cmd = ["bash", os.path.join(SCRIPTS_DIR, "trust-event-append.sh"), "--kdir", kdir, "--json"] + args
    code, out, err = run(cmd)
    if code != 0:
        raise RuntimeError(f"trust-event-append failed: {err.strip() or out.strip()}")
    try:
        return "appended" if json.loads(out).get("appended") else "deduped"
    except json.JSONDecodeError:
        return "appended"


def recorded_correction(body: str, correction_id: str) -> dict | None:
    """The corrections[] item apply-correction.sh wrote, read back off the entry.

    The ledger row has to carry the same before/after hashes and status the
    entry records, so they are read from the entry rather than recomputed.
    """
    import re
    blocks = list(re.finditer(r"<!--(.*?)-->", body, re.DOTALL))
    if not blocks:
        return None
    array = re.search(r"\|\s*corrections:\s*(\[.*?\])\s*(?:\||-->|$)", blocks[-1].group(1), re.DOTALL)
    if not array:
        return None
    try:
        items = json.loads(array.group(1))
    except (json.JSONDecodeError, TypeError):
        return None
    for item in items:
        if isinstance(item, dict) and item.get("correction_id") == correction_id:
            return item
    return None


def source_reads(repo_dir: str, rel_path: str, line_range: str, expected: str) -> bool:
    """Whether the cited source still reads exactly as recorded."""
    path = os.path.join(repo_dir, rel_path)
    if not os.path.isfile(path):
        return False
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except (OSError, UnicodeDecodeError):
        return False
    try:
        start, end = (int(part) for part in line_range.split("-"))
    except ValueError:
        return False
    if start < 1 or end > len(lines) or start > end:
        return False
    return "\n".join(lines[start - 1:end]) == expected


def _scan_result(out: str, prefix: str, id_prefix: str) -> tuple[str | None, str]:
    """Pull the result and the durable id out of the mutator's report."""
    found_id: str | None = None
    action = "dry-run"
    for line in out.splitlines():
        if not line.startswith(prefix):
            continue
        for token in line.replace(":", " ").split():
            if token.startswith("result="):
                action = token.split("=", 1)[1]
            elif "=" in token and token.split("=", 1)[1].startswith(id_prefix):
                found_id = token.split("=", 1)[1]
            elif token.startswith(id_prefix):
                found_id = token
    return found_id, action


def apply_repair(kdir: str, member: dict, repair: dict, date_str: str, dry_run: bool):
    """Replace the superseded claim in place. Exit 2 means the span is gone."""
    cmd = [
        "bash", os.path.join(SCRIPTS_DIR, "apply-correction.sh"),
        "--entry", os.path.join(kdir, member["entry_path_resolved"]),
        "--observation-id", member["adjudication_event_id"],
        "--verdict-source", "peer-verification",
        "--allow-peer-verification",
        "--evidence", evidence_text(member),
        "--superseded-text", repair["superseded"],
        "--replacement-text", repair["replacement"],
        "--date", date_str,
        "--kdir", kdir,
    ]
    if dry_run:
        cmd.append("--dry-run")
    code, out, err = run(cmd)
    if code == 2:
        return None, None, err.strip()
    if code != 0:
        raise RuntimeError(
            f"correction mutator failed for {member['entry_path_resolved']}: {err.strip()}"
        )
    correction_id, action = _scan_result(out, "[peer-correction]", "corr-")
    if correction_id is None:
        correction_id, action = _scan_result(out, "[dry-run]", "corr-")
    return correction_id, action, None


def apply_dispute(kdir: str, member: dict, date_str: str, dry_run: bool):
    """Land the judge's prose as a dated marker the next reader will see."""
    cmd = [
        "bash", os.path.join(SCRIPTS_DIR, "apply-correction.sh"),
        "--dispute",
        "--entry", os.path.join(kdir, member["entry_path_resolved"]),
        "--observation-id", member["adjudication_event_id"],
        "--verdict-source", "peer-verification",
        "--allow-peer-verification",
        "--evidence", evidence_text(member),
        "--dispute-note", dispute_note(member),
        "--reported-by", JUDGE,
        "--date", date_str,
        "--kdir", kdir,
    ]
    artifact_id = member["verdict"].get("artifact_id")
    if artifact_id:
        cmd += ["--work-item", artifact_id]
    if dry_run:
        cmd.append("--dry-run")
    code, out, err = run(cmd)
    if code != 0:
        raise RuntimeError(
            f"dispute mutator failed for {member['entry_path_resolved']}: {err.strip()}"
        )
    return _scan_result(out, "[dispute]", "disp-") if not dry_run else \
        _scan_result(out, "[dry-run][dispute]", "disp-")


def record_correction_event(kdir: str, member: dict, correction_id: str, dry_run: bool) -> str:
    """Say in the ledger that this adjudication's repair landed.

    apply-correction.sh writes the entry and its footer but appends no ledger
    row, so without this the repair is invisible to anyone querying the ledger
    for which rejected adjudications were resolved — which is the same
    disappearance this salvage exists to undo.
    """
    body = entry_body(kdir, member["entry_path_resolved"])
    item = recorded_correction(body or "", correction_id)
    if item is None:
        raise RuntimeError(
            f"no corrections[] item for {correction_id} on {member['entry_path_resolved']}"
        )
    return append_trust_event(kdir, [
        "--event", "correction",
        "--entry-path", member["entry_path_resolved"],
        "--source", "apply-correction",
        "--correction-id", correction_id,
        # The adjudication is the observation this repair discharges.
        "--verification-event-id", member["adjudication_event_id"],
        "--claim-id", member["claim_id"],
        "--correction-date", str(item.get("date") or ""),
        "--before-sha256", str(item.get("before_sha256") or ""),
        "--after-sha256", str(item.get("after_sha256") or ""),
        "--prior-status", str(item.get("prior_status") or "current"),
        "--result-status", "corrected",
        "--work-item", WORK_ITEM,
    ], dry_run)


def record_already_current_event(kdir: str, member: dict, spec: dict, dry_run: bool) -> str:
    """Say in the ledger that the entry holds against the code the judge cited.

    Deliberately not a correction event: this migration changed nothing here, and
    claiming a repair it did not make would be the same unfalsifiable record the
    salvage is undoing. The claim id ties the row to the adjudication.
    """
    return append_trust_event(kdir, [
        "--event", "consumption-verification",
        "--entry-path", member["entry_path_resolved"],
        "--source", "worker",
        "--disposition", "held",
        "--file", os.path.join(REPO_DIR, spec["file"]),
        "--line-range", spec["line_range"],
        "--exact-snippet", spec["snippet"],
        "--claim-id", member["claim_id"],
        "--work-item", WORK_ITEM,
        "--protocol-slot", "implement-step-3",
        "--producer-role", "worker",
        "--rationale", (
            f"{spec['rationale']} Adjudication {member['adjudication_event_id']} is discharged "
            f"by the entry's own text: \"{spec['anchor']}\""
        ),
    ], dry_run)


def settle(kdir: str, member: dict, date_str: str, dry_run: bool) -> dict:
    """Give one cohort member its terminal disposition and its ledger row."""
    resolved = member["entry_path_resolved"]
    body = entry_body(kdir, resolved)
    if body is None:
        return {
            "disposition": "unresolved",
            "branch": "entry-missing",
            "owner_ref": None,
            "entry_effect": "none",
            "ledger_event": "none",
            "last_run": "none",
            "detail": f"resolved entry does not exist: {resolved}",
        }
    if member["verdict"] is None:
        return {
            "disposition": "unresolved",
            "branch": "no-verdict-row",
            "owner_ref": None,
            "entry_effect": "none",
            "ledger_event": "none",
            "last_run": "none",
            "detail": "no verdict row carrying correction text joined this adjudication",
        }

    spec = ALREADY_CURRENT.get(member["claim_id"])
    if spec and spec["anchor"] in body:
        if source_reads(REPO_DIR, spec["file"], spec["line_range"], spec["snippet"]):
            ledger = record_already_current_event(kdir, member, spec, dry_run)
            return {
                "disposition": "already-current",
                "branch": "entry-states-correction",
                "owner_ref": None,
                "entry_effect": "unchanged",
                "ledger_event": f"consumption-verification/held ({ledger})",
                "last_run": "none",
                "detail": (
                    f"entry already carries the corrected claim at: \"{spec['anchor']}\"; "
                    f"verified against {spec['file']}:{spec['line_range']}"
                ),
            }

    repair = REPAIRS.get(member["claim_id"])
    if repair is not None:
        correction_id, action, refusal = apply_repair(kdir, member, repair, date_str, dry_run)
        if refusal is None:
            ledger = record_correction_event(kdir, member, correction_id, dry_run) \
                if correction_id else "skipped"
            return {
                "disposition": "corrected",
                "branch": "superseded-text-matched",
                "owner_ref": correction_id,
                "entry_effect": "claim-replaced-in-place",
                "ledger_event": f"correction ({ledger})",
                "last_run": action,
                "detail": None,
            }
        dispute_id, action = apply_dispute(kdir, member, date_str, dry_run)
        return {
            "disposition": "disputed",
            "branch": "superseded-text-absent",
            "owner_ref": dispute_id,
            "entry_effect": "dispute-marker-added",
            "ledger_event": "none (marker lives on the entry)",
            "last_run": action,
            "detail": refusal,
        }

    dispute_id, action = apply_dispute(kdir, member, date_str, dry_run)
    return {
        "disposition": "disputed",
        "branch": "no-substring-pair-derivable",
        "owner_ref": dispute_id,
        "entry_effect": "dispute-marker-added",
        "ledger_event": "none (marker lives on the entry)",
        "last_run": action,
        "detail": "the judge's correction is prose about the claim, not a replaceable span",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--kdir", help="knowledge store root (default: lore resolve)")
    parser.add_argument("--dry-run", action="store_true", help="decide but write nothing")
    parser.add_argument("--json", action="store_true", help="print the manifest to stdout")
    args = parser.parse_args()

    kdir = args.kdir
    if not kdir:
        code, out, err = run(["bash", os.path.join(SCRIPTS_DIR, "resolve-repo.sh")])
        if code != 0:
            print(f"[salvage] cannot resolve knowledge store: {err.strip()}", file=sys.stderr)
            return 1
        kdir = out.strip()
    kdir = os.path.abspath(kdir)
    if not os.path.isdir(kdir):
        print(f"[salvage] knowledge store not found: {kdir}", file=sys.stderr)
        return 1

    trust_compute = _load_trust_compute()
    now = datetime.now(timezone.utc)
    generated_at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    date_str = now.strftime("%Y-%m-%d")

    cohort, off_roster = build_cohort(kdir, trust_compute)
    terminal = {"corrected", "disputed", "already-current"}
    counts = {name: 0 for name in sorted(terminal)}
    members = []
    for member in cohort:
        outcome = settle(kdir, member, date_str, args.dry_run)
        if outcome["disposition"] in counts:
            counts[outcome["disposition"]] += 1
        verdict = member["verdict"] or {}
        members.append({
            "claim_id": member["claim_id"],
            "adjudication_event_id": member["adjudication_event_id"],
            "run_id": member["run_id"],
            "observed_at": member["observed_at"],
            "verdict_file": os.path.relpath(verdict["file"], kdir) if verdict else None,
            "verdict_line": verdict.get("line"),
            "verdict_judge_run_at": verdict.get("judge_run_at"),
            "join_skew_seconds": member["join_skew_seconds"],
            "correction_chars": len(verdict.get("correction") or ""),
            "entry_path_recorded": member["entry_path_recorded"],
            "entry_path_resolved": member["entry_path_resolved"],
            "path_resolution": member["path_resolution"],
            "path_warning": member["path_warning"],
            "disposition": outcome["disposition"],
            "branch": outcome["branch"],
            "owner_ref": outcome["owner_ref"],
            # What the salvage did to the entry — a durable statement about the
            # substrate, true on every run. `last_run` is the transient one.
            "entry_effect": outcome["entry_effect"],
            "ledger_event": outcome["ledger_event"],
            "last_run": outcome["last_run"],
            "detail": outcome["detail"],
        })

    unresolved = sum(1 for m in members if m["disposition"] not in terminal)
    manifest = {
        "schema_version": 1,
        "work_item": WORK_ITEM,
        "generated_at": generated_at,
        "dry_run": args.dry_run,
        "cohort_size": len(members),
        "dispositions": counts,
        "unresolved": unresolved,
        "judge": JUDGE,
        "read_only_inputs": ["_settlement/**", "_work/**/verdicts/*.jsonl"],
        "members": members,
        "off_roster_rejected_adjudications": off_roster,
    }

    manifest_path = os.path.join(kdir, "_work", WORK_ITEM, MANIFEST_NAME)
    if not args.dry_run:
        os.makedirs(os.path.dirname(manifest_path), exist_ok=True)
        with open(manifest_path, "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=2, ensure_ascii=False)
            fh.write("\n")

    if args.json:
        print(json.dumps(manifest, indent=2, ensure_ascii=False))
    else:
        prefix = "[salvage][dry-run]" if args.dry_run else "[salvage]"
        summary = ", ".join(f"{count} {name}" for name, count in counts.items())
        print(f"{prefix} {len(members)} rejected adjudications: {summary}")
        if unresolved:
            print(f"{prefix} {unresolved} unresolved — see the manifest", file=sys.stderr)
        if not args.dry_run:
            print(f"{prefix} manifest: {os.path.relpath(manifest_path, kdir)}")

    return 1 if unresolved else 0


if __name__ == "__main__":
    sys.exit(main())
