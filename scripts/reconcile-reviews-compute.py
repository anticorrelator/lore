#!/usr/bin/env python3
"""reconcile-reviews-compute.py — tag self-review findings against external review findings.

Usage: reconcile-reviews-compute.py <self-lens-findings.json> <external-findings.json> <out.json>

Reads both finding sets and writes a reconciliation record to <out.json>:
  {
    generated_at, self_source, external_source,
    self_finding_count, external_finding_count,
    reconciled: [{self_finding_index, tag, matched_external_index (nullable),
                  match_reason, self_summary, external_summary}],
    coverage_miss: [{external_finding_index, reason, external_summary}]
  }

Matching heuristic:
  1. Locate match by (file, line window ±5). Exact file match required.
  2. Among location matches, pick best lens-alignment match.
  3. Tag the self-review finding:
     - confirm     — location + lens-alignment + severities agree
     - extend      — location + lens-alignment but self has strictly higher
                     severity OR strictly more body text (>=1.5x) than external
     - contradict  — location + lens-alignment but severities opposite
                     (one "blocking" and one "suggestion"/"info"/"safe"),
                     AND the finding texts suggest disagreement (contain
                     opposing verdict words). Strict — conservatism required
                     because contradiction is load-bearing for the
                     external_contradict_rate scorecard metric.
     - orthogonal  — no location match at all. Self found something external
                     didn't (or they were looking at different places).
  4. External findings with no matching self finding land in coverage_miss.

The exact_snippet / normalized_snippet_hash fields from F0 provenance work
are preferred when present — they make the match precise. When absent,
fall back to (file, line±5).
"""
import json
import re
import sys
from datetime import datetime, timezone


LINE_WINDOW = 5

# Severity ordering for "strictly higher" and "opposite" detection.
SEVERITY_RANK = {
    "blocking": 3,
    "suggestion": 2,
    "action": 2,
    "open": 1,
    "info": 1,
    "safe": 0,
    "accepted": 0,
    "deferred": 0,
    "": 1,  # missing severity treated as neutral
}

# Textual-opposite markers — crude but load-bearing: we only tag contradict
# when self and external explicitly disagree.
OPPOSITE_PAIRS = [
    ("correctly handles", "fails to handle"),
    ("correctly handles", "does not handle"),
    ("safe", "unsafe"),
    ("no issue", "is an issue"),
    ("not a bug", "is a bug"),
    ("already validated", "not validated"),
    ("already guarded", "not guarded"),
]


def parse_findings(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, dict):
        findings = data.get("findings", [])
    elif isinstance(data, list):
        findings = data
    else:
        findings = []
    for i, f in enumerate(findings):
        f["_idx"] = i
    return findings


def location_key(f):
    return (f.get("file") or "", _line_int(f.get("line") or f.get("line_range")))


def _line_int(v):
    if isinstance(v, int):
        return v
    if isinstance(v, str):
        m = re.match(r"(\d+)", v)
        if m:
            return int(m.group(1))
    return None


def lines_overlap(a, b, window=LINE_WINDOW):
    if a is None or b is None:
        return True  # treat missing line as permissive overlap (file match suffices)
    return abs(a - b) <= window


def lens_aligned(self_f, ext_f):
    """Same lens OR theme words overlap (after stripping 'lens-' prefix)."""
    sl = (self_f.get("lens") or "").lower().replace("lens-", "")
    el = (ext_f.get("lens") or "").lower().replace("lens-", "")
    if sl and el and sl == el:
        return True
    # Fall back to title word overlap — pick at least one non-stopword in common.
    st = set(_words(self_f.get("title", "")))
    et = set(_words(ext_f.get("title", "")))
    return len(st & et) >= 1


_STOPWORDS = {"a", "an", "the", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "is", "are", "be", "was", "were"}


def _words(s):
    return [w for w in re.findall(r"[a-z0-9]+", (s or "").lower()) if w not in _STOPWORDS and len(w) >= 3]


def body_len(f):
    return len((f.get("body") or "") + " " + (f.get("rationale") or "") + " " + (f.get("grounding") or ""))


def severity_rank(f):
    return SEVERITY_RANK.get((f.get("severity") or "").lower(), SEVERITY_RANK[""])


def texts_oppose(self_f, ext_f):
    self_text = (self_f.get("body", "") + " " + self_f.get("rationale", "") + " " + self_f.get("grounding", "")).lower()
    ext_text = (ext_f.get("body", "") + " " + ext_f.get("rationale", "") + " " + ext_f.get("grounding", "")).lower()
    for pos, neg in OPPOSITE_PAIRS:
        if (pos in self_text and neg in ext_text) or (neg in self_text and pos in ext_text):
            return True
    return False


def match_score(self_f, ext_f):
    """Return a score 0..100 indicating how well these findings match.
    0 = no overlap; higher = better. Location is the floor; lens+text refine."""
    sf_file = self_f.get("file") or ""
    ef_file = ext_f.get("file") or ""
    if not sf_file or sf_file != ef_file:
        return 0
    sl = _line_int(self_f.get("line") or self_f.get("line_range"))
    el = _line_int(ext_f.get("line") or ext_f.get("line_range"))
    if not lines_overlap(sl, el):
        return 0
    score = 50  # baseline for file+line match
    if lens_aligned(self_f, ext_f):
        score += 30
    # Exact snippet hash match (F0 provenance bonus)
    sh = self_f.get("normalized_snippet_hash")
    eh = ext_f.get("normalized_snippet_hash")
    if sh and eh and sh == eh:
        score += 20
    return score


def classify(self_f, ext_f):
    """Assign a tag given a matched pair. ext_f may be None (orthogonal)."""
    if ext_f is None:
        return "orthogonal", "no external finding at this location"
    sr = severity_rank(self_f)
    er = severity_rank(ext_f)
    if texts_oppose(self_f, ext_f) and abs(sr - er) >= 2:
        return "contradict", f"opposing verdicts (self severity={self_f.get('severity','?')}, external={ext_f.get('severity','?')})"
    if sr > er:
        return "extend", f"self severity higher (self={self_f.get('severity','?')} > external={ext_f.get('severity','?')})"
    if body_len(self_f) >= 1.5 * max(body_len(ext_f), 1):
        return "extend", "self finding body is substantially longer / more detailed"
    if sr == er or abs(sr - er) <= 1:
        return "confirm", f"severities aligned ({self_f.get('severity','?')})"
    return "confirm", "location + lens match"


def main():
    if len(sys.argv) != 4:
        print("Usage: reconcile-reviews-compute.py <self> <external> <out>", file=sys.stderr)
        sys.exit(2)
    self_path, ext_path, out_path = sys.argv[1:]

    self_findings = parse_findings(self_path)
    ext_findings = parse_findings(ext_path)

    # Greedy matching: for each self finding, find best-scoring external.
    # Track external indices already consumed so coverage-miss lists only
    # unmatched externals.
    matched_ext = set()
    reconciled = []
    for sf in self_findings:
        best = None
        best_score = 0
        for ef in ext_findings:
            if ef["_idx"] in matched_ext:
                continue
            s = match_score(sf, ef)
            if s > best_score:
                best_score = s
                best = ef
        if best is not None and best_score > 0:
            matched_ext.add(best["_idx"])
            tag, reason = classify(sf, best)
            reconciled.append({
                "self_finding_index": sf["_idx"],
                "tag": tag,
                "matched_external_index": best["_idx"],
                "match_score": best_score,
                "match_reason": reason,
                "self_summary": {
                    "title": sf.get("title"),
                    "file": sf.get("file"),
                    "line": sf.get("line"),
                    "lens": sf.get("lens"),
                    "severity": sf.get("severity"),
                },
                "external_summary": {
                    "title": best.get("title"),
                    "file": best.get("file"),
                    "line": best.get("line"),
                    "lens": best.get("lens"),
                    "severity": best.get("severity"),
                },
            })
        else:
            tag, reason = classify(sf, None)
            reconciled.append({
                "self_finding_index": sf["_idx"],
                "tag": tag,
                "matched_external_index": None,
                "match_score": 0,
                "match_reason": reason,
                "self_summary": {
                    "title": sf.get("title"),
                    "file": sf.get("file"),
                    "line": sf.get("line"),
                    "lens": sf.get("lens"),
                    "severity": sf.get("severity"),
                },
                "external_summary": None,
            })

    coverage_miss = []
    for ef in ext_findings:
        if ef["_idx"] in matched_ext:
            continue
        coverage_miss.append({
            "external_finding_index": ef["_idx"],
            "reason": "no self-review finding at this location",
            "external_summary": {
                "title": ef.get("title"),
                "file": ef.get("file"),
                "line": ef.get("line"),
                "lens": ef.get("lens"),
                "severity": ef.get("severity"),
            },
        })

    out = {
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "self_source": self_path,
        "external_source": ext_path,
        "self_finding_count": len(self_findings),
        "external_finding_count": len(ext_findings),
        "reconciled": reconciled,
        "coverage_miss": coverage_miss,
        "completed_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
