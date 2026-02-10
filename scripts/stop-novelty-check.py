#!/usr/bin/env python3
"""Stop hook: detect novel, uncaptured insights via dual-criteria AND gate.

Command-type Stop hook that replaces the expensive agent-type evaluator.
Uses heuristic pattern matching + FTS5 novelty scoring to identify
reactive discoveries worth capturing.

Input: JSON on stdin (Stop hook format -- includes transcript_path, stop_hook_active)
Output: JSON on stdout with decision:"block" if novel insights detected AND session is substantial.
        Otherwise exit 0 silently (allow stop).

Design decisions:
- D1: Strict dual-criteria AND gate (both FTS5 novelty AND heuristic pattern must fire)
- D2: Writes _pending_captures/ directory directly -- no new SessionStart hook needed
- D3: Curation handles duplicates, not heavy hook-time dedup
- D4: Agent evaluates candidates at first turn (same pattern as _pending_digest.md)
"""

import hashlib
import json
import os
import re
import sys

# Shared transcript infrastructure
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from transcript import parse_transcript, count_tool_uses, has_recent_capture, resolve_knowledge_dir, fail_open


# ---------------------------------------------------------------------------
# Heuristic patterns -- regex-based detection of reactive triggers
# ---------------------------------------------------------------------------

# Trigger 1: Self-correction / expectation violation
SELF_CORRECTION_RE = re.compile(
    r"\b(?:"
    r"actually[,\s]|"
    r"I was wrong|"
    r"it turns out|"
    r"unexpectedly|"
    r"contrary to (?:what )?(?:I |we )?expected|"
    r"I (?:initially )?(?:assumed|thought|expected) .{0,60}(?:but|however|instead)|"
    r"(?:this|that) (?:actually|really) (?:is|was|does|did)|"
    r"correction:|"
    r"my mistake|"
    r"I stand corrected|"
    r"not what I expected"
    r")\b",
    re.IGNORECASE,
)

# Trigger 2: Debugging root cause
DEBUG_ROOT_CAUSE_RE = re.compile(
    r"\b(?:"
    r"root cause|"
    r"the (?:real|actual|underlying) (?:issue|problem|cause|reason)|"
    r"traced (?:it |this )?(?:back )?to|"
    r"the bug (?:is|was) (?:actually |really )?(?:in|caused|due)|"
    r"(?:found|discovered|identified) the (?:source|origin|cause)|"
    r"turns out the (?:error|issue|problem|bug)"
    r")\b",
    re.IGNORECASE,
)

# Trigger 3: Design decision with rationale
DESIGN_DECISION_RE = re.compile(
    r"\b(?:"
    r"(?:we |I )?chose .{0,40} because|"
    r"the (?:trade-?off|tradeoff) (?:is|here|between)|"
    r"(?:we |I )?(?:decided|opted) (?:to |for |against ).{0,40}(?:because|since|as |due)|"
    r"(?:rejected|ruled out|avoided) .{0,40}(?:because|since|due|in favor)|"
    r"design decision:|"
    r"the rationale (?:is|for|behind)"
    r")\b",
    re.IGNORECASE,
)

# Trigger 4: User correction
USER_CORRECTION_RE = re.compile(
    r"\b(?:"
    r"(?:no|nope|not quite|that'?s (?:not |in)?correct|wrong)|"
    r"(?:actually|instead)[,\s].{0,30}(?:should|need|must|use)|"
    r"you (?:should|need to|must) (?:actually |instead )|"
    r"(?:don'?t|do not) .{0,20}(?:like that|that way)"
    r")\b",
    re.IGNORECASE,
)

# Trigger 5: Gotcha / pitfall
GOTCHA_RE = re.compile(
    r"\b(?:"
    r"(?:watch out|be (?:careful|aware)|heads up|gotcha|caveat|pitfall|footgun)|"
    r"(?:edge case|corner case|special case)[:\s]|"
    r"(?:non-?obvious|subtle|tricky|surprising) (?:behavior|issue|bug|interaction|detail)|"
    r"workaround[:\s]|"
    r"(?:silently |quietly )?(?:fails|breaks|ignores|drops|swallows)"
    r")\b",
    re.IGNORECASE,
)

# All heuristic patterns with labels
HEURISTIC_PATTERNS = [
    ("self-correction", SELF_CORRECTION_RE),
    ("debug-root-cause", DEBUG_ROOT_CAUSE_RE),
    ("design-decision", DESIGN_DECISION_RE),
    ("gotcha", GOTCHA_RE),
]

# User-role patterns (only checked in user messages)
USER_PATTERNS = [
    ("user-correction", USER_CORRECTION_RE),
]


# ---------------------------------------------------------------------------
# Heuristic pattern scan
# ---------------------------------------------------------------------------

def _has_system_reminder(text_blocks):
    """Check if any text block contains a <system-reminder> tag."""
    return any("<system-reminder>" in t for t in text_blocks)


def scan_heuristics(messages):
    """Scan messages for heuristic trigger patterns.

    Excludes messages containing <system-reminder> tags (coordination noise)
    and tool_result messages from USER_PATTERNS matching (teammate output,
    not user corrections).

    Returns list of dicts: {index, role, trigger, matched_text}
    """
    hits = []

    for msg in messages:
        full_text = "\n".join(msg["text_blocks"])
        if not full_text.strip():
            continue

        # Skip messages with system-reminder tags — not real conversation
        if _has_system_reminder(msg["text_blocks"]):
            continue

        if msg["role"] == "assistant":
            for label, pattern in HEURISTIC_PATTERNS:
                match = pattern.search(full_text)
                if match:
                    # Extract surrounding context (up to 120 chars around match)
                    start = max(0, match.start() - 60)
                    end = min(len(full_text), match.end() + 60)
                    context = full_text[start:end].strip()
                    hits.append({
                        "index": msg["index"],
                        "role": msg["role"],
                        "trigger": label,
                        "matched_text": context,
                    })

        elif msg["role"] == "user":
            # Skip tool_result messages — they contain teammate output,
            # not user corrections
            if msg.get("is_tool_result", False):
                continue
            for label, pattern in USER_PATTERNS:
                match = pattern.search(full_text)
                if match:
                    start = max(0, match.start() - 60)
                    end = min(len(full_text), match.end() + 60)
                    context = full_text[start:end].strip()
                    hits.append({
                        "index": msg["index"],
                        "role": msg["role"],
                        "trigger": label,
                        "matched_text": context,
                    })

    return hits


# ---------------------------------------------------------------------------
# FTS5 novelty scoring
# ---------------------------------------------------------------------------

# Phrases to exclude from novelty queries (too generic)
STOP_PHRASES = frozenset({
    "the", "and", "for", "that", "this", "with", "from", "are", "was",
    "but", "not", "you", "all", "can", "had", "her", "one", "our",
    "let", "now", "will", "just", "file", "code", "line", "run",
    "make", "use", "get", "set", "add", "new", "also", "like",
})

# Minimum phrase length to query FTS5
MIN_PHRASE_LEN = 3
# Maximum number of phrases to search
MAX_PHRASES = 15


def extract_key_phrases(messages, last_n=20):
    """Extract meaningful phrases from the last N assistant text blocks.

    Returns list of (phrase, message_index) tuples.
    """
    # Collect last N assistant messages
    assistant_msgs = [m for m in messages if m["role"] == "assistant" and m["text_blocks"]]
    recent = assistant_msgs[-last_n:] if len(assistant_msgs) > last_n else assistant_msgs

    phrases = []

    for msg in recent:
        full_text = "\n".join(msg["text_blocks"])

        # Extract noun-phrase-like chunks: sequences of capitalized words or
        # technical terms (contains hyphen, underscore, dot)
        # Pattern: 2-5 consecutive "interesting" words
        for match in re.finditer(
            r"(?<![#\[])(?:[A-Z][a-z]+(?:\s+[A-Z][a-z]+){1,4}|"
            r"[a-z_]+(?:[-_.][a-z_]+)+)",
            full_text,
        ):
            phrase = match.group(0).strip()
            words = phrase.split()
            # Skip if all words are stop words or phrase is too short
            if all(w.lower() in STOP_PHRASES for w in words):
                continue
            if len(phrase) < MIN_PHRASE_LEN:
                continue
            phrases.append((phrase, msg["index"]))

        # Also extract quoted terms and backtick terms
        for match in re.finditer(r'["`]([^"`]{4,60})["`]', full_text):
            term = match.group(1).strip()
            if len(term) >= MIN_PHRASE_LEN and not all(
                w.lower() in STOP_PHRASES for w in term.split()
            ):
                phrases.append((term, msg["index"]))

    # Deduplicate by phrase (keep first occurrence), limit total
    seen = set()
    unique = []
    for phrase, idx in phrases:
        key = phrase.lower()
        if key not in seen:
            seen.add(key)
            unique.append((phrase, idx))
    return unique[:MAX_PHRASES]


def score_novelty(knowledge_dir, phrases):
    """Query FTS5 for each phrase, flag those without strong matches as novel.

    Returns list of dicts: {phrase, message_index, is_novel, best_score}
    """
    if not phrases:
        return []

    # Import Searcher from pk_search.py in the same directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, script_dir)
    try:
        from pk_search import Searcher
    except ImportError:
        # If pk_search is not available, treat all phrases as novel
        return [
            {"phrase": p, "message_index": idx, "is_novel": True, "best_score": 0.0}
            for p, idx in phrases
        ]
    finally:
        sys.path.pop(0)

    searcher = Searcher(knowledge_dir)
    results = []

    for phrase, msg_idx in phrases:
        try:
            hits = searcher.search(phrase, limit=1, threshold=0.0)
        except Exception:
            # FTS5 error -- treat as novel
            results.append({
                "phrase": phrase,
                "message_index": msg_idx,
                "is_novel": True,
                "best_score": 0.0,
            })
            continue

        if not hits:
            # No results at all -- novel
            results.append({
                "phrase": phrase,
                "message_index": msg_idx,
                "is_novel": True,
                "best_score": 0.0,
            })
        else:
            best = hits[0]["score"]
            # Score is negative; more negative = stronger match.
            # If best match is weak (score > -1.0), the phrase is novel.
            is_novel = best > -1.0
            results.append({
                "phrase": phrase,
                "message_index": msg_idx,
                "is_novel": is_novel,
                "best_score": best,
            })

    return results


# ---------------------------------------------------------------------------
# AND gate: co-location check
# ---------------------------------------------------------------------------

REGION_WINDOW = 5  # message indices


def and_gate(heuristic_hits, novelty_results):
    """Apply dual-criteria AND gate: both heuristic + novel phrase in same region.

    A "region" is defined as +/- REGION_WINDOW message indices.

    Returns list of candidate dicts ready for _pending_captures/:
        {trigger, matched_text, novel_phrase, heuristic_index, novelty_index}
    """
    novel_items = [r for r in novelty_results if r["is_novel"]]
    if not novel_items or not heuristic_hits:
        return []

    candidates = []
    used_heuristics = set()
    used_novel = set()

    for hit in heuristic_hits:
        h_idx = hit["index"]
        for novel in novel_items:
            n_idx = novel["message_index"]
            if abs(h_idx - n_idx) <= REGION_WINDOW:
                # Co-located -- this is a candidate
                h_key = (hit["index"], hit["trigger"])
                n_key = novel["phrase"]
                if h_key not in used_heuristics and n_key not in used_novel:
                    used_heuristics.add(h_key)
                    used_novel.add(n_key)
                    candidates.append({
                        "trigger": hit["trigger"],
                        "matched_text": hit["matched_text"],
                        "novel_phrase": novel["phrase"],
                        "heuristic_index": h_idx,
                        "novelty_index": n_idx,
                    })

    # Limit to 5 candidates max (same as old agent prompt)
    return candidates[:5]


# ---------------------------------------------------------------------------
# Write _pending_captures/ directory with individual candidate files
# ---------------------------------------------------------------------------

def candidate_hash(candidate):
    """Return a 12-char hex hash for a candidate, based on trigger + matched_text."""
    key = candidate["trigger"] + candidate["matched_text"]
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:12]


def write_pending_captures(knowledge_dir, candidates):
    """Write individual candidate files into _pending_captures/ directory.

    Each candidate gets its own file named {sha256(trigger+matched_text)[:12]}.md.
    This makes writes idempotent: the same candidate always produces the same
    filename, so re-running the hook with identical candidates is a harmless
    overwrite. The agent processes and deletes files individually at first turn.
    """
    pending_dir = os.path.join(knowledge_dir, "_pending_captures")

    try:
        os.makedirs(pending_dir, exist_ok=True)
    except OSError:
        return  # best-effort

    for c in candidates:
        filename = f"{candidate_hash(c)}.md"
        filepath = os.path.join(pending_dir, filename)

        lines = [
            f"# Capture Candidate: {c['trigger']}",
            "",
            f"**Trigger:** {c['trigger']}",
            f"**Context:** {c['matched_text']}",
            f"**Novel phrase:** {c['novel_phrase']}",
            f"**Transcript region:** messages {c['heuristic_index']}-{c['novelty_index']}",
            "",
            "**Evaluate:** Does this meet the capture gate? (Reusable, Non-obvious, Stable, High-confidence)",
            "",
        ]

        try:
            with open(filepath, "w", encoding="utf-8") as f:
                f.write("\n".join(lines))
        except OSError:
            continue  # best-effort, try remaining candidates


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    try:
        hook_input = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, Exception):
        sys.exit(0)

    # Guard 1: Prevent infinite loops
    if hook_input.get("stop_hook_active", False):
        sys.exit(0)

    transcript_path = hook_input.get("transcript_path", "")
    if not transcript_path or not os.path.exists(transcript_path):
        sys.exit(0)

    # Parse transcript
    messages = parse_transcript(transcript_path)
    if not messages:
        sys.exit(0)

    # Guard 2: Skip trivial sessions (fewer than 5 tool uses)
    tool_use_count = count_tool_uses(messages)
    if tool_use_count < 5:
        sys.exit(0)

    # Guard 3: Lightweight dedup -- if captures already ran this session,
    # we still proceed but note it (curation handles true dedup per D3)
    already_captured = has_recent_capture(messages)

    # Resolve knowledge directory
    knowledge_dir = resolve_knowledge_dir()
    if not knowledge_dir or not os.path.isdir(knowledge_dir):
        sys.exit(0)

    # Guard 4: If _pending_captures/ already has files from a previous run,
    # skip the entire scan -- avoids re-blocking when candidates exist but
    # haven't been reviewed yet (false-positive loop prevention)
    pending_dir = os.path.join(knowledge_dir, "_pending_captures")
    if os.path.isdir(pending_dir) and any(
        f.endswith(".md") for f in os.listdir(pending_dir)
    ):
        sys.exit(0)

    # Heuristic pattern scan
    heuristic_hits = scan_heuristics(messages)
    if not heuristic_hits:
        sys.exit(0)

    # FTS5 novelty scoring
    phrases = extract_key_phrases(messages)
    novelty_results = score_novelty(knowledge_dir, phrases)

    # AND gate: both criteria must fire in the same region
    candidates = and_gate(heuristic_hits, novelty_results)
    if not candidates:
        sys.exit(0)

    # If captures already ran and we only have weak candidates, skip
    if already_captured and len(candidates) <= 1:
        sys.exit(0)

    # Write individual candidate files for agent evaluation at next session start
    write_pending_captures(knowledge_dir, candidates)

    # Decision: block only if session is substantial (>10 tool uses)
    # This avoids interrupting quick sessions
    if tool_use_count > 10:
        reason_parts = [
            f"Detected {len(candidates)} potential uncaptured insight(s):",
        ]
        for c in candidates:
            reason_parts.append(
                f"  - [{c['trigger']}] near \"{c['novel_phrase']}\" "
                f"(messages {c['heuristic_index']}-{c['novelty_index']})"
            )
        reason_parts.append("")
        reason_parts.append(
            "Review _pending_captures/ in the knowledge store and run "
            "`lore capture` for any valid insights, or dismiss if not worth keeping."
        )

        json.dump(
            {"decision": "block", "reason": "\n".join(reason_parts)},
            sys.stdout,
        )
    else:
        # Substantial enough for candidates but not for blocking --
        # _pending_captures/ was still written for next session
        sys.exit(0)


if __name__ == "__main__":
    fail_open(main)()
