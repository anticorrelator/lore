#!/usr/bin/env python3
"""retro-export-collect-retros.py — collect redacted retro/behavioral journal entries since <since_iso>.

Usage: retro-export-collect-retros.py <journal.jsonl> <since_iso>

Emits a JSON array of redacted retro records on stdout. Each record:
  {
    retro_id, window_id, template_ids, redacted_retro_prose,
    behavioral_health, local_suggestions
  }

Redaction contract (multi-user-evolution-design.md §9):
  - Strip `context` (may contain slug paths or work-item references).
  - Strip `work-item` (slug path, identity leak).
  - Keep `observation` prose (agent-authored narrative).
  - Keep `scores` (numeric dimension scores, window_state, tripped_checks).
  - Heuristically scrub slug-like tokens from observation prose:
    any bare word matching the slug regex `[a-z0-9][a-z0-9-]{6,}` followed
    by a `/` or `:` is replaced with `<redacted>`. This is conservative —
    it will miss some leaks and over-redact some legitimate words — but
    catches the most common footguns (pasted file paths, [[work:...]]
    backlinks).

local_suggestions are extracted from retro-evolution role entries: each
carries a template_id, proposal_summary, and (if present) cell-id
references in the supporting_cell_ids field.
"""
import hashlib
import json
import re
import sys
from datetime import datetime

SLUG_RE = re.compile(r"\b([a-z0-9]+(?:-[a-z0-9]+){1,})([:/])")
BACKLINK_RE = re.compile(r"\[\[[^\]]+\]\]")


def parse_iso(s):
    if not s:
        return None
    try:
        s = s.replace("Z", "+00:00")
        return datetime.fromisoformat(s)
    except Exception:
        return None


def redact_prose(text):
    if not isinstance(text, str):
        return text
    text = BACKLINK_RE.sub("[[redacted]]", text)
    text = SLUG_RE.sub(lambda m: "<redacted>" + m.group(2), text)
    return text


def main():
    if len(sys.argv) != 3:
        print("Usage: retro-export-collect-retros.py <journal.jsonl> <since_iso>", file=sys.stderr)
        sys.exit(2)

    journal_path, since_iso = sys.argv[1], sys.argv[2]
    since_dt = parse_iso(since_iso)

    retros_by_window = {}
    suggestions_by_window = {}

    try:
        with open(journal_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(entry, dict):
                    continue

                role = entry.get("role", "")
                if role not in ("retro", "retro-behavioral-health", "retro-evolution"):
                    continue

                ts = parse_iso(entry.get("timestamp"))
                if since_dt and ts and ts < since_dt:
                    continue

                context = entry.get("context", "") or ""
                # Use the context slug (e.g., "retro: <slug>") as a grouping
                # key so one retro cycle's entries aggregate together. The
                # slug itself does not leave the machine — only its hash.
                window_key = hashlib.sha256(context.encode("utf-8")).hexdigest()[:16]

                if role == "retro-evolution":
                    sug = suggestions_by_window.setdefault(window_key, [])
                    obs = entry.get("observation", "")
                    # retro-evolution observations are structured:
                    # "Target: <file> | Change type: <type> | ...
                    target_match = re.search(r"Target:\s*([^|]+)", obs)
                    change_match = re.search(r"Change type:\s*([^|]+)", obs)
                    sug.append({
                        "template_id": target_match.group(1).strip() if target_match else None,
                        "change_type": change_match.group(1).strip() if change_match else None,
                        "proposal_summary": redact_prose(obs),
                        "supporting_cell_ids": [],
                    })
                    continue

                r = retros_by_window.setdefault(window_key, {
                    "retro_id": window_key,
                    "window_id": "unknown",
                    "template_ids": [],
                    "redacted_retro_prose": "",
                    "behavioral_health": [],
                    "scores": None,
                    "window_state": None,
                    "tripped_checks": [],
                })

                obs = entry.get("observation", "")
                scores = entry.get("scores") or {}

                if role == "retro":
                    r["redacted_retro_prose"] = redact_prose(obs)
                    r["scores"] = {k: v for k, v in scores.items() if isinstance(v, (int, float, str, list))}
                    r["window_state"] = scores.get("window_state")
                    r["tripped_checks"] = scores.get("tripped_checks") or []
                elif role == "retro-behavioral-health":
                    # Behavioral-health observation is "Checks: <selection> | C<n>: <answer> | ..."
                    # Keep the answers, strip slug-like tokens.
                    r["behavioral_health"].append({
                        "answer_summary": redact_prose(obs),
                    })

    except FileNotFoundError:
        print("[]")
        return

    out = []
    for window_key, r in retros_by_window.items():
        r["local_suggestions"] = suggestions_by_window.get(window_key, [])
        out.append(r)

    print(json.dumps(out))


if __name__ == "__main__":
    main()
