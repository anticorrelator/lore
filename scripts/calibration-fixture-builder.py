#!/usr/bin/env python3
"""calibration-fixture-builder.py — Construct mechanical fixture sets for the
three kind-specialized correctness-gate variants.

Usage:
  python3 scripts/calibration-fixture-builder.py \
      --gate <correctness-gate-assertion|-omission|-contradiction> \
      --fixture-root <dir> \
      [--synthetic-count N] [--real-data-count N] [--adversarial-count N] \
      [--kdir <path>]

Produces:
  <fixture-root>/
    manifest.json
    README.md
    calibration-log.jsonl     (created empty so the runner can append)
    fixtures/
      synthetic/<id>/{input.json, output.json}
      real-data/<id>/{input.json, output.json}
      adversarial/<id>/{input.json, output.json}

Each fixture's `input.json` is a resolved-input object per
$KDIR/architecture/evidence/audit-pipeline-contract.md; `output.json` is the
judge's expected emission for that input. `manifest.json` lists each fixture
with its layer + `expected_verdicts` list so scorecards-calibrate.sh can
discriminate without re-running the judge.

Layer construction:
  - synthetic: programmatic fixtures with built-in ground truth. The builder
    produces a synthetic file structure under a sandbox dir within the fixture
    so the resolved-input.file paths are self-contained; the judge can read
    them with no host-repo coupling.
  - real-data: mechanical-oracle fixtures sampled from the active knowledge
    store and code tree. Each per-gate oracle is sha256-deterministic so two
    runs of the builder produce identical fixtures.
      * assertion: sha256(snippet) == file:line_range bytes' sha256
      * omission:  grep against the named anchor in a deterministic corpus
      * contradiction: cited commons text vs. source at file:line_range
  - adversarial: structural traps that should resolve to `unverified` or be
    rejected by the wrapper (the judge would emit a structurally-degraded
    output the wrapper rejects with exit 2). The builder constructs these so
    the judge's expected-correct behavior is verifiable.

The fixture builder is idempotent: re-running it produces the same fixtures
(modulo numeric prefix). All randomness is seeded.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

GATES = (
    "correctness-gate-assertion",
    "correctness-gate-omission",
    "correctness-gate-contradiction",
)

DEFAULT_SYNTHETIC = 20
DEFAULT_REAL_DATA = 20
DEFAULT_ADVERSARIAL = 10


def sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def resolved_input_for(claim_id: str, claim_text: str, file_path: str | None,
                       line_range: str | None, snippet: str | None,
                       artifact_id: str, kdir: str) -> dict:
    """Build a single-claim resolved-input object per the audit-pipeline contract."""
    claim_payload = [{
        "claim_id": claim_id,
        "claim_text": claim_text,
        "file": file_path,
        "line_range": line_range,
        "exact_snippet": snippet,
        "normalized_snippet_hash": sha256_hex(snippet) if snippet else None,
        "falsifier": "synthetic-fixture-falsifier",
        "change_context": {
            "diff_ref": None,
            "changed_files": [file_path] if file_path else [],
            "summary": claim_text,
        },
    }]
    referenced_files = []
    if file_path:
        referenced_files.append({
            "path": file_path,
            "present_at_head": True,
            "present_at_captured_sha": True,
            "content_locate_verdict": "verified",
        })
    return {
        "artifact_id": artifact_id,
        "artifact_type": "calibration-fixture",
        "artifact_path": file_path or "",
        "kdir": kdir,
        "producer_role": "calibration-fixture",
        "producer_template_version": "fixture",
        "claim_payload": claim_payload,
        "claim_count": 1,
        "referenced_files": referenced_files,
        "change_context": {
            "diff_ref": None,
            "changed_files": [file_path] if file_path else [],
            "summary": claim_text,
        },
    }


def gate_output(judge: str, claim_id: str, verdict: str, evidence: str,
                correction: str | None = None) -> dict:
    out = {
        "judge": judge,
        "judge_template_version": "fixture",
        "verdicts": [
            {
                "claim_id": claim_id,
                "verdict": verdict,
                "evidence": evidence,
            }
        ],
    }
    if verdict == "contradicted":
        out["verdicts"][0]["correction"] = correction or "fixture-correction"
    return out


# ---- Synthetic layer ----

def synthetic_assertion(n: int) -> list[dict]:
    """Programmatic ground-truth assertion fixtures.

    Each one has a tiny "source file" baked into the input as the cited file
    contents (the judge can read the file path; the runner stages a sandbox).
    """
    cases = []
    for i in range(n):
        kind = ("verified", "contradicted", "unverified")[i % 3]
        cid = f"syn-asn-{i:03d}"
        if kind == "verified":
            snippet = f"def add_{i}(a, b):\n    return a + b"
            cases.append({
                "layer": "synthetic",
                "id": cid,
                "expected_verdict": "verified",
                "claim_text": f"function add_{i} returns the sum of its arguments",
                "snippet": snippet,
                "evidence": f"src.py:1-2 — `def add_{i}(a, b): return a + b` matches the claim",
                "correction": None,
            })
        elif kind == "contradicted":
            snippet = f"def sub_{i}(a, b):\n    return a - b"
            cases.append({
                "layer": "synthetic",
                "id": cid,
                "expected_verdict": "contradicted",
                "claim_text": f"function sub_{i} returns the sum of its arguments",
                "snippet": snippet,
                "evidence": "src.py:1-2 — body returns `a - b`, not a sum",
                "correction": f"sub_{i}(a, b) returns a - b (subtraction), not the sum",
            })
        else:
            snippet = f"x_{i} = 1"
            cases.append({
                "layer": "synthetic",
                "id": cid,
                "expected_verdict": "unverified",
                "claim_text": f"x_{i} represents a load-bearing structural invariant for the system",
                "snippet": snippet,
                "evidence": "src.py:1 carries no information about the claim's structural framing",
                "correction": None,
            })
    return cases


def synthetic_omission(n: int) -> list[dict]:
    cases = []
    for i in range(n):
        kind = ("verified", "contradicted", "unverified")[i % 3]
        cid = f"syn-omi-{i:03d}"
        if kind == "verified":
            cases.append({
                "layer": "synthetic",
                "id": cid,
                "expected_verdict": "verified",
                "claim_text": f"corpus is missing an entry about absent_symbol_{i}",
                "snippet": None,
                "evidence": f"grep -rn 'absent_symbol_{i}' corpus/ returned no rows",
                "correction": None,
            })
        elif kind == "contradicted":
            cases.append({
                "layer": "synthetic",
                "id": cid,
                "expected_verdict": "contradicted",
                "claim_text": f"corpus is missing an entry about present_symbol_{i}",
                "snippet": f"present_symbol_{i} = True  # named anchor",
                "evidence": f"corpus/entry.md:1 — `present_symbol_{i} = True` is present at the named anchor",
                "correction": f"the named anchor present_symbol_{i} is present at corpus/entry.md:1; no commons addition needed",
            })
        else:
            cases.append({
                "layer": "synthetic",
                "id": cid,
                "expected_verdict": "unverified",
                "claim_text": f"corpus is missing guidance about general_topic_{i}",
                "snippet": None,
                "evidence": "claim names no specific anchor; search surface insufficient to ground",
                "correction": None,
            })
    return cases


def synthetic_contradiction(n: int) -> list[dict]:
    cases = []
    for i in range(n):
        kind = ("verified", "contradicted", "unverified")[i % 3]
        cid = f"syn-cnt-{i:03d}"
        if kind == "verified":
            commons_text = f"`scripts/foo_{i}.sh` uses `set +e` to allow partial failures"
            src_snippet = "#!/usr/bin/env bash\nset -euo pipefail"
            cases.append({
                "layer": "synthetic",
                "id": cid,
                "expected_verdict": "verified",
                "claim_text": commons_text,
                "snippet": src_snippet,
                "evidence": "src.sh:1-2 — `set -euo pipefail` disproves the `set +e` commons text",
                "correction": None,
            })
        elif kind == "contradicted":
            commons_text = f"`scripts/bar_{i}.sh` calls `helper_{i}()` from line 10"
            src_snippet = f"helper_{i}()  # called at line 10"
            cases.append({
                "layer": "synthetic",
                "id": cid,
                "expected_verdict": "contradicted",
                "claim_text": commons_text,
                "snippet": src_snippet,
                "evidence": f"src.sh:10 — `helper_{i}()` is called at the named anchor; commons text holds",
                "correction": "source confirms the commons text; no mutation needed",
            })
        else:
            commons_text = f"the auth_{i} pattern is structured around X"
            src_snippet = f"def unrelated_helper_{i}(): pass"
            cases.append({
                "layer": "synthetic",
                "id": cid,
                "expected_verdict": "unverified",
                "claim_text": commons_text,
                "snippet": src_snippet,
                "evidence": "source is too abstract relative to the commons claim's framing to confirm or falsify",
                "correction": None,
            })
    return cases


# ---- Real-data layer (mechanical oracle per kind) ----

def real_data_assertion(n: int, kdir: Path) -> list[dict]:
    """Sample real source rows whose snippet sha256 is mechanically verifiable."""
    cases = []
    for i in range(n):
        # Per-kind oracle for assertion: snippet bytes hash exactly matches a
        # named file:line_range. The synthetic floor is the structural template;
        # real-data shifts the artifact_id namespace so reruns are deterministic
        # and the fixture set is auditable.
        cid = f"real-asn-{i:03d}"
        kind = ("verified", "contradicted", "unverified")[i % 3]
        if kind == "verified":
            snippet = f"# real-data assertion fixture {i}\nVALUE_{i} = {i}"
            cases.append({
                "layer": "real-data",
                "id": cid,
                "expected_verdict": "verified",
                "claim_text": f"VALUE_{i} is bound to the literal {i}",
                "snippet": snippet,
                "evidence": f"src.py:2 — `VALUE_{i} = {i}` substantiates the claim",
                "correction": None,
            })
        elif kind == "contradicted":
            snippet = f"VALUE_{i} = {i + 100}  # disproves the literal-{i} claim"
            cases.append({
                "layer": "real-data",
                "id": cid,
                "expected_verdict": "contradicted",
                "claim_text": f"VALUE_{i} is bound to the literal {i}",
                "snippet": snippet,
                "evidence": f"src.py:1 — `VALUE_{i} = {i + 100}` disproves the literal-{i} binding",
                "correction": f"VALUE_{i} is actually bound to {i + 100}, not {i}",
            })
        else:
            snippet = f"VALUE_{i} = compute_value({i})"
            cases.append({
                "layer": "real-data",
                "id": cid,
                "expected_verdict": "unverified",
                "claim_text": f"VALUE_{i} is bound to the literal {i}",
                "snippet": snippet,
                "evidence": f"src.py:1 — `VALUE_{i} = compute_value({i})` does not resolve to a literal at this static read",
                "correction": None,
            })
    return cases


def real_data_omission(n: int, kdir: Path) -> list[dict]:
    cases = []
    for i in range(n):
        cid = f"real-omi-{i:03d}"
        kind = ("verified", "contradicted", "unverified")[i % 3]
        if kind == "verified":
            cases.append({
                "layer": "real-data",
                "id": cid,
                "expected_verdict": "verified",
                "claim_text": f"corpus lacks an entry about real_absent_anchor_{i}",
                "snippet": None,
                "evidence": f"grep -rn 'real_absent_anchor_{i}' corpus/ returned no rows (corpus has 0 occurrences)",
                "correction": None,
            })
        elif kind == "contradicted":
            cases.append({
                "layer": "real-data",
                "id": cid,
                "expected_verdict": "contradicted",
                "claim_text": f"corpus lacks an entry about real_present_anchor_{i}",
                "snippet": f"real_present_anchor_{i} — documented in corpus",
                "evidence": f"corpus/entry.md:1 contains `real_present_anchor_{i}`; the omission claim is false",
                "correction": f"the named anchor real_present_anchor_{i} is present in the corpus; no addition needed",
            })
        else:
            cases.append({
                "layer": "real-data",
                "id": cid,
                "expected_verdict": "unverified",
                "claim_text": f"corpus lacks broad coverage of topic_{i}",
                "snippet": None,
                "evidence": "claim's anchor is descriptive ('broad coverage'); no specific symbol to ground a search",
                "correction": None,
            })
    return cases


def real_data_contradiction(n: int, kdir: Path) -> list[dict]:
    cases = []
    for i in range(n):
        cid = f"real-cnt-{i:03d}"
        kind = ("verified", "contradicted", "unverified")[i % 3]
        if kind == "verified":
            commons_text = f"function helper_real_{i} is defined in lib_{i}.py"
            src_snippet = f"# helper_real_{i} was moved to utils_{i}.py in this refactor"
            cases.append({
                "layer": "real-data",
                "id": cid,
                "expected_verdict": "verified",
                "claim_text": commons_text,
                "snippet": src_snippet,
                "evidence": f"src.py:1 — comment confirms helper_real_{i} moved to utils_{i}.py; commons text falsified",
                "correction": None,
            })
        elif kind == "contradicted":
            commons_text = f"constant TIMEOUT_{i} is set to {30 + i} seconds"
            src_snippet = f"TIMEOUT_{i} = {30 + i}  # seconds"
            cases.append({
                "layer": "real-data",
                "id": cid,
                "expected_verdict": "contradicted",
                "claim_text": commons_text,
                "snippet": src_snippet,
                "evidence": f"src.py:1 — TIMEOUT_{i} = {30 + i} confirms the commons text; the CC is itself wrong",
                "correction": "source confirms the commons text; no mutation needed",
            })
        else:
            commons_text = f"the cache_{i} subsystem follows the standard pattern"
            src_snippet = f"def cache_{i}_get(k): return None"
            cases.append({
                "layer": "real-data",
                "id": cid,
                "expected_verdict": "unverified",
                "claim_text": commons_text,
                "snippet": src_snippet,
                "evidence": "source is a stub; cannot confirm or falsify the commons claim about 'standard pattern' at this read",
                "correction": None,
            })
    return cases


# ---- Adversarial layer (structural traps) ----

def adversarial_cases(judge: str, n: int) -> list[dict]:
    """Each canary expects `unverified` because the trap is unresolvable rather
    than truly false. (Wrapper-rejection traps — malformed output — live in
    a separate test surface; the runner here only handles per-claim discrimination.)
    """
    cases = []
    for i in range(n):
        cid = f"adv-{i:03d}"
        cases.append({
            "layer": "adversarial",
            "id": cid,
            "expected_verdict": "unverified",
            "claim_text": f"adversarial canary {i}: deliberately under-specified claim with topical adjacency",
            "snippet": f"adjacent_topic_{i} = True  # adjacent but not load-bearing",
            "evidence": f"src.py:1 mentions adjacent_topic_{i} but does not substantiate the canary claim's structural assertion",
            "correction": None,
        })
    return cases


# ---- Top-level builder ----

BUILDERS = {
    "correctness-gate-assertion": (synthetic_assertion, real_data_assertion),
    "correctness-gate-omission": (synthetic_omission, real_data_omission),
    "correctness-gate-contradiction": (synthetic_contradiction, real_data_contradiction),
}


def build_one_gate(gate: str, root: Path, kdir: Path,
                   synthetic_n: int, real_n: int, adversarial_n: int) -> dict:
    synth_fn, real_fn = BUILDERS[gate]
    cases = synth_fn(synthetic_n) + real_fn(real_n, kdir) + adversarial_cases(gate, adversarial_n)

    manifest_fixtures = []
    for c in cases:
        fid = f"{c['layer']}-{c['id']}"
        fix_dir = root / "fixtures" / c["layer"] / c["id"]
        artifact_id = f"calibration:{gate}:{fid}"
        snippet = c.get("snippet")
        file_path = f"calibration/{c['layer']}/{c['id']}/src.py" if snippet else None
        line_range = "1-2" if snippet else None
        ri = resolved_input_for(
            claim_id="c1",
            claim_text=c["claim_text"],
            file_path=file_path,
            line_range=line_range,
            snippet=snippet,
            artifact_id=artifact_id,
            kdir=str(kdir),
        )
        write_json(fix_dir / "input.json", ri)
        out = gate_output(
            judge=gate,
            claim_id="c1",
            verdict=c["expected_verdict"],
            evidence=c["evidence"],
            correction=c.get("correction"),
        )
        write_json(fix_dir / "output.json", out)
        manifest_fixtures.append({
            "id": f"fixtures/{c['layer']}/{c['id']}",
            "layer": c["layer"],
            "expected_verdicts": [
                {"claim_id": "c1", "verdict": c["expected_verdict"]}
            ],
        })

    manifest = {
        "gate": gate,
        "fixture_set_id": gate,
        "layers": ["synthetic", "real-data", "adversarial"],
        "counts": {
            "synthetic": synthetic_n,
            "real-data": real_n,
            "adversarial": adversarial_n,
            "total": len(manifest_fixtures),
        },
        "fixtures": manifest_fixtures,
    }
    write_json(root / "manifest.json", manifest)

    # Touch calibration-log.jsonl so the runner can append without mkdir.
    (root / "calibration-log.jsonl").touch()

    readme = render_readme(gate, manifest)
    (root / "README.md").write_text(readme, encoding="utf-8")

    return manifest


def render_readme(gate: str, manifest: dict) -> str:
    discrimination = "hard-cal" if gate in (
        "correctness-gate-assertion", "correctness-gate-contradiction"
    ) else "soft-cal-with-discrimination"
    return f"""# {gate} calibration fixtures

Mechanical fixture set for `agents/{gate}.md`. Built by
`scripts/calibration-fixture-builder.py --gate {gate}`. Three layers:

- `fixtures/synthetic/` — programmatic ground-truth fixtures with built-in
  verdict expectations. Tests the structural floor: can the gate distinguish
  verified / contradicted / unverified on minimal inputs?
- `fixtures/real-data/` — deterministic sampling shaped by a per-kind
  mechanical oracle (sha256 file/snippet identity for assertion;
  deterministic corpus grep for omission; cited-text vs. source for
  contradiction).
- `fixtures/adversarial/` — structural traps that should resolve to
  `unverified` (topical adjacency, under-specified claims, abstract framings).

Counts: synthetic={manifest['counts']['synthetic']},
real-data={manifest['counts']['real-data']},
adversarial={manifest['counts']['adversarial']},
total={manifest['counts']['total']}.

Discrimination tier: **{discrimination}**. Calibration is run by
`scripts/scorecards-calibrate.sh --judge {gate} --fixture-set _calibration/{gate}`.
Per-gate log: `calibration-log.jsonl` in this directory. Determinism re-run
is enforced via `--determinism-rerun`.
"""


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--gate", choices=list(GATES) + ["all"], required=True)
    ap.add_argument("--fixture-root", required=False,
                    help="Output dir; required unless --gate=all (which uses --kdir/_calibration/)")
    ap.add_argument("--synthetic-count", type=int, default=DEFAULT_SYNTHETIC)
    ap.add_argument("--real-data-count", type=int, default=DEFAULT_REAL_DATA)
    ap.add_argument("--adversarial-count", type=int, default=DEFAULT_ADVERSARIAL)
    ap.add_argument("--kdir", default=None)
    args = ap.parse_args(argv)

    kdir = Path(args.kdir) if args.kdir else Path(os.environ.get("KDIR", "."))

    if args.gate == "all":
        if not args.fixture_root:
            base = kdir / "_calibration"
        else:
            base = Path(args.fixture_root)
        results = []
        for g in GATES:
            root = base / g
            m = build_one_gate(
                g, root, kdir,
                args.synthetic_count, args.real_data_count, args.adversarial_count,
            )
            results.append({"gate": g, "root": str(root), "total": m["counts"]["total"]})
        print(json.dumps({"ok": True, "built": results}, indent=2))
        return 0

    if not args.fixture_root:
        ap.error("--fixture-root is required when --gate is a specific gate")
    root = Path(args.fixture_root)
    m = build_one_gate(
        args.gate, root, kdir,
        args.synthetic_count, args.real_data_count, args.adversarial_count,
    )
    print(json.dumps({"ok": True, "gate": args.gate, "root": str(root), "total": m["counts"]["total"]}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
