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
from collections import defaultdict

# Shared transcript infrastructure
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from transcript import parse_transcript, extract_file_paths, count_tool_uses, has_recent_capture, resolve_knowledge_dir, fail_open


# ---------------------------------------------------------------------------
# Configuration loading with fallback to hardcoded defaults
# ---------------------------------------------------------------------------

DEFAULTS = {
    # Core thresholds
    "novelty_threshold": -1.0,
    "region_window": 5,
    "max_candidates": 5,
    "max_phrases": 15,
    "min_tool_uses": 5,
    "max_tool_uses": 10,
    # Structural signal thresholds
    "investigation_window": 10,
    "iterative_debug_window": 15,
    "test_fix_window": 20,
    "synthesis_char_threshold": 500,
    "synthesis_tool_threshold": 5,
    "file_context_window": 10,
    "debug_context_window": 10,
    "debug_context_chars": 800,
}


def load_config():
    """Load capture-config.json with fallback to hardcoded defaults.

    Resolution order:
    1. ~/.lore/config/capture-config.json (if exists and valid)
    2. Hardcoded DEFAULTS

    With no config file, returns DEFAULTS unchanged.
    With partial config, overridden fields use config values, others use defaults.
    With invalid config (malformed JSON, wrong types), falls back to all defaults
    and logs a warning to stderr.

    Returns:
        dict with all keys from DEFAULTS, values overridden by config where present.
    """
    config = dict(DEFAULTS)

    config_path = os.path.expanduser("~/.lore/config/capture-config.json")
    if not os.path.isfile(config_path):
        return config

    try:
        with open(config_path, "r", encoding="utf-8") as f:
            raw = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(
            f"[hook] stop-novelty-check: invalid capture-config.json, using defaults: {e}",
            file=sys.stderr,
        )
        return config

    if not isinstance(raw, dict):
        print(
            "[hook] stop-novelty-check: capture-config.json is not a JSON object, using defaults",
            file=sys.stderr,
        )
        return config

    # Flatten nested groups ("core" and "structural_signals") into top-level keys
    flat = {}
    for group_key in ("core", "structural_signals"):
        group = raw.get(group_key)
        if isinstance(group, dict):
            flat.update(group)
    # Also merge any top-level keys (supports flat config format)
    for key, val in raw.items():
        if key not in ("core", "structural_signals", "adaptive"):
            flat[key] = val

    # Merge recognized keys with type validation
    for key, default_val in DEFAULTS.items():
        if key in flat:
            val = flat[key]
            if isinstance(val, (int, float)) and isinstance(default_val, (int, float)):
                config[key] = type(default_val)(val)
            else:
                print(
                    f"[hook] stop-novelty-check: invalid type for '{key}' in config, using default",
                    file=sys.stderr,
                )

    # Read adaptive flag (boolean, default false)
    adaptive = raw.get("adaptive", False)
    config["adaptive"] = bool(adaptive) if isinstance(adaptive, bool) else False

    return config


def read_store_stats(knowledge_dir):
    """Read store statistics from _manifest.json.

    Returns the entry count from the manifest, or None if the manifest
    is missing, corrupt, or has an unexpected structure.

    Args:
        knowledge_dir: path to the knowledge store directory

    Returns:
        int or None: number of entries in the knowledge store
    """
    manifest_path = os.path.join(knowledge_dir, "_manifest.json")
    if not os.path.isfile(manifest_path):
        return None

    try:
        with open(manifest_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(
            f"[hook] stop-novelty-check: failed to read _manifest.json: {e}",
            file=sys.stderr,
        )
        return None

    if not isinstance(data, dict):
        return None

    entries = data.get("entries")
    if not isinstance(entries, list):
        return None

    return len(entries)


def adapt_threshold(config, entry_count):
    """Adjust novelty threshold based on store maturity when adaptive mode is enabled.

    When adaptive is false (default), returns the base threshold unchanged.
    When adaptive is true, maps entry count to a threshold:
        - Young store (< 50 entries): -0.5 (looser, capture more)
        - Mature store (> 200 entries): -1.5 (tighter, capture less)
        - Default range (50-200): linear interpolation from -0.5 to -1.5
        - None entry_count: fall back to base threshold

    Args:
        config: config dict from load_config() (must include 'adaptive' and 'novelty_threshold')
        entry_count: number of entries in the knowledge store (int or None)

    Returns:
        float: the novelty threshold to use
    """
    base = config["novelty_threshold"]

    if not config.get("adaptive", False):
        return base

    if entry_count is None:
        return base

    if entry_count < 50:
        return -0.5
    elif entry_count > 200:
        return -1.5
    else:
        # Linear interpolation: 50 entries -> -0.5, 200 entries -> -1.5
        t = (entry_count - 50) / 150.0
        return -0.5 + t * (-1.5 - (-0.5))


def compute_adaptive_threshold(knowledge_dir, base_threshold):
    """Convenience wrapper: read store stats and compute adaptive threshold.

    Args:
        knowledge_dir: path to the knowledge store directory
        base_threshold: the configured base novelty threshold

    Returns:
        float: the novelty threshold to use
    """
    config = {"novelty_threshold": base_threshold, "adaptive": True}
    entry_count = read_store_stats(knowledge_dir)
    return adapt_threshold(config, entry_count)


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
    r"turns out the (?:error|issue|problem|bug)|"
    r"(?:failure|error|crash|bug) (?:is |was )?caused by|"
    r"(?:issue|problem|bug) stems from|"
    r"the problem is that|"
    r"caused by (?:a|an|the)\b|"
    r"due to a bug in"
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
                    # Extract surrounding context (up to 400 chars around match)
                    start = max(0, match.start() - 200)
                    end = min(len(full_text), match.end() + 200)
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
                    start = max(0, match.start() - 200)
                    end = min(len(full_text), match.end() + 200)
                    context = full_text[start:end].strip()
                    hits.append({
                        "index": msg["index"],
                        "role": msg["role"],
                        "trigger": label,
                        "matched_text": context,
                    })

    return hits


def scan_structural_signals(messages, transcript_path="", config=None):
    """Detect structural patterns that signal debugging or investigation sessions.

    Detects four signal types based on tool_use sequences rather than phrasing:
      - structural-investigation: ≥3 Read/Grep/Bash within investigation_window messages then Edit
      - structural-iterative-debug: same file path in ≥2 Reads within iterative_debug_window messages
      - structural-test-fix: Bash→Edit→Bash within test_fix_window messages
      - structural-synthesis: >synthesis_char_threshold char assistant message after ≥synthesis_tool_threshold tool_use messages

    Returns list of dicts: {index, role, trigger, matched_text}
    Same format as scan_heuristics() so results can be merged into heuristic_hits.

    Args:
        messages: list of parsed message dicts from parse_transcript()
        transcript_path: path to transcript file (needed for file-path signals)
        config: configuration dict (uses DEFAULTS if None)
    """
    if config is None:
        config = DEFAULTS
    investigation_window = config["investigation_window"]
    iterative_debug_window = config["iterative_debug_window"]
    test_fix_window = config["test_fix_window"]
    synthesis_char_threshold = config["synthesis_char_threshold"]
    synthesis_tool_threshold = config["synthesis_tool_threshold"]
    hits = []
    msg_by_index = {m["index"]: m for m in messages}

    # Tools that indicate reading/investigating
    INVESTIGATION_TOOLS = frozenset({"Read", "Grep", "Glob", "Bash"})
    EDIT_TOOLS = frozenset({"Edit", "Write"})
    READ_TOOLS = frozenset({"Read"})

    # --- Signal 1: Investigation-then-fix ---
    # ≥3 Read/Grep/Bash within investigation_window messages followed by Edit
    indices = [m["index"] for m in messages if m["has_tool_use"]]
    for i, idx in enumerate(indices):
        msg = msg_by_index[idx]
        if not (EDIT_TOOLS & set(msg["tool_names"])):
            continue
        # This message has an Edit — look back investigation_window messages for ≥3 investigation tools
        window_start = idx - investigation_window
        invest_count = sum(
            1 for j in indices
            if window_start <= j < idx
            and INVESTIGATION_TOOLS & set(msg_by_index[j]["tool_names"])
        )
        if invest_count >= 3:
            hits.append({
                "index": idx,
                "role": "assistant",
                "trigger": "structural-investigation",
                "matched_text": (
                    f"Edit after {invest_count} investigation tools "
                    f"in messages {window_start}-{idx}"
                ),
            })

    # --- Signal 2: Iterative debugging — same file in ≥2 Reads within iterative_debug_window messages ---
    if transcript_path:
        file_reads = extract_file_paths(transcript_path)
        # Group by file path, collect (path, msg_idx) pairs for Read-type tools only
        # extract_file_paths returns all FILE_PATH_TOOLS; filter to Read only
        # We can't easily distinguish Read vs Edit from extract_file_paths alone,
        # so use the raw approach: find file paths appearing ≥2x within iterative_debug_window
        path_indices = defaultdict(list)
        for path, msg_idx in file_reads:
            # Only count if the message at msg_idx used Read (not just any file tool)
            msg = msg_by_index.get(msg_idx)
            if msg and READ_TOOLS & set(msg["tool_names"]):
                path_indices[path].append(msg_idx)

        for path, read_indices in path_indices.items():
            read_indices.sort()
            for i in range(len(read_indices)):
                # Check if any later read is within iterative_debug_window messages
                for j in range(i + 1, len(read_indices)):
                    if read_indices[j] - read_indices[i] <= iterative_debug_window:
                        hits.append({
                            "index": read_indices[j],
                            "role": "assistant",
                            "trigger": "structural-iterative-debug",
                            "matched_text": (
                                f"File '{path}' read ≥2 times "
                                f"(messages {read_indices[i]}, {read_indices[j]})"
                            ),
                        })
                        break  # one hit per file is enough

    # --- Signal 3: Test-fix cycle — Bash→Edit→Bash within test_fix_window messages ---
    tool_seq = [
        (m["index"], m["tool_names"])
        for m in messages
        if m["has_tool_use"] and m["tool_names"]
    ]
    for i, (bash_idx1, names1) in enumerate(tool_seq):
        if "Bash" not in names1:
            continue
        for j in range(i + 1, len(tool_seq)):
            edit_idx, names2 = tool_seq[j]
            if edit_idx - bash_idx1 > test_fix_window:
                break
            if not (EDIT_TOOLS & set(names2)):
                continue
            # Found a Bash then Edit — look for another Bash after
            for k in range(j + 1, len(tool_seq)):
                bash_idx2, names3 = tool_seq[k]
                if bash_idx2 - bash_idx1 > test_fix_window:
                    break
                if "Bash" in names3:
                    hits.append({
                        "index": bash_idx2,
                        "role": "assistant",
                        "trigger": "structural-test-fix",
                        "matched_text": (
                            f"Bash→Edit→Bash cycle "
                            f"(messages {bash_idx1}, {edit_idx}, {bash_idx2})"
                        ),
                    })
                    break
            break

    # --- Signal 4: Synthesis moment — >synthesis_char_threshold char assistant message after ≥synthesis_tool_threshold tool_use msgs ---
    tool_use_msgs = [m for m in messages if m["has_tool_use"]]
    tool_use_indices = set(m["index"] for m in tool_use_msgs)

    for msg in messages:
        if msg["role"] != "assistant":
            continue
        full_text = "\n".join(msg["text_blocks"])
        if len(full_text) <= synthesis_char_threshold:
            continue
        # Count tool_use messages in the 10 messages before this one
        prior_tool_count = sum(
            1 for j in range(max(0, msg["index"] - 10), msg["index"])
            if j in tool_use_indices
        )
        if prior_tool_count >= synthesis_tool_threshold:
            snippet = full_text[:120].strip()
            hits.append({
                "index": msg["index"],
                "role": "assistant",
                "trigger": "structural-synthesis",
                "matched_text": (
                    f"Long synthesis message ({len(full_text)} chars) "
                    f"after {prior_tool_count} tool calls: {snippet}…"
                ),
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


def extract_key_phrases(messages, last_n=20, config=None):
    """Extract meaningful phrases from the last N assistant text blocks.

    Returns list of (phrase, message_index) tuples.
    """
    if config is None:
        config = DEFAULTS
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
    return unique[:config["max_phrases"]]


def score_novelty(knowledge_dir, phrases, config=None):
    """Query FTS5 for each phrase, flag those without strong matches as novel.

    Returns list of dicts: {phrase, message_index, is_novel, best_score}
    """
    if config is None:
        config = DEFAULTS
    novelty_threshold = config["novelty_threshold"]
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
            # If best match is weak (score > threshold), the phrase is novel.
            is_novel = best > novelty_threshold
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

def and_gate(heuristic_hits, novelty_results, config=None):
    """Apply dual-criteria AND gate: both heuristic + novel phrase in same region.

    A "region" is defined as +/- region_window message indices.

    Returns list of candidate dicts ready for _pending_captures/:
        {trigger, matched_text, novel_phrase, heuristic_index, novelty_index}
    """
    if config is None:
        config = DEFAULTS
    region_window = config["region_window"]
    max_candidates = config["max_candidates"]
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
            if abs(h_idx - n_idx) <= region_window:
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

    return candidates[:max_candidates]


# ---------------------------------------------------------------------------
# Related file extraction
# ---------------------------------------------------------------------------

def extract_related_files(transcript_path, heuristic_index, config=None):
    """Extract file paths from tool_use blocks near a heuristic hit.

    Collects file paths from tool_use blocks within +/- file_context_window
    message indices of `heuristic_index`. Deduplicates and returns a list
    of file paths sorted by first appearance.

    Args:
        transcript_path: path to the JSONL transcript file
        heuristic_index: message index of the heuristic match
        config: configuration dict (uses DEFAULTS if None)

    Returns:
        list of unique file path strings, in order of first appearance
    """
    if config is None:
        config = DEFAULTS
    file_context_window = config["file_context_window"]

    all_paths = extract_file_paths(transcript_path)
    lo = heuristic_index - file_context_window
    hi = heuristic_index + file_context_window

    seen = set()
    related = []
    for path, msg_idx in all_paths:
        if lo <= msg_idx <= hi and path not in seen:
            seen.add(path)
            related.append(path)
    return related


# ---------------------------------------------------------------------------
# Debug context extraction
# ---------------------------------------------------------------------------

def extract_debug_context(messages, heuristic_index, config=None):
    """Extract expanded context for a debug-root-cause heuristic hit.

    Scans backward (and forward) from `heuristic_index` to collect up to
    ~debug_context_chars of assistant text surrounding the match. Also collects any
    co-located heuristic hits within +/- debug_context_window message indices.

    Returns a structured string block with the investigation chain:
        - Expanded assistant text around the match (up to ~debug_context_chars)
        - Co-located heuristic hits (other triggers firing nearby)

    Args:
        messages: list of parsed message dicts from parse_transcript()
        heuristic_index: message index of the debug-root-cause match
        config: configuration dict (uses DEFAULTS if None)

    Returns:
        str: formatted investigation chain context block
    """
    if config is None:
        config = DEFAULTS
    debug_context_window = config["debug_context_window"]
    debug_context_chars = config["debug_context_chars"]

    # Build index -> message map for quick lookup
    msg_by_index = {m["index"]: m for m in messages}

    # Collect assistant text in a window around the heuristic hit
    lo = heuristic_index - debug_context_window
    hi = heuristic_index + debug_context_window

    # Gather assistant messages in window, ordered by index
    window_msgs = [
        m for m in messages
        if lo <= m["index"] <= hi and m["role"] == "assistant" and m["text_blocks"]
    ]
    window_msgs.sort(key=lambda m: m["index"])

    # Build expanded text, prioritizing messages closest to heuristic hit
    # Start with the heuristic message itself, then extend backward/forward
    text_parts = []
    total_chars = 0
    hit_msg = msg_by_index.get(heuristic_index)
    if hit_msg and hit_msg["text_blocks"]:
        hit_text = "\n".join(hit_msg["text_blocks"])
        text_parts.append((heuristic_index, hit_text))
        total_chars += len(hit_text)

    # Extend with adjacent messages until budget is reached
    before = sorted(
        [m for m in window_msgs if m["index"] < heuristic_index],
        key=lambda m: m["index"],
        reverse=True,  # closest first
    )
    after = sorted(
        [m for m in window_msgs if m["index"] > heuristic_index],
        key=lambda m: m["index"],
    )

    for msg in before:
        if total_chars >= debug_context_chars:
            break
        t = "\n".join(msg["text_blocks"])
        text_parts.insert(0, (msg["index"], t))
        total_chars += len(t)

    for msg in after:
        if total_chars >= debug_context_chars:
            break
        t = "\n".join(msg["text_blocks"])
        text_parts.append((msg["index"], t))
        total_chars += len(t)

    # Concatenate ordered text, truncating to budget
    combined = "\n\n".join(t for _, t in sorted(text_parts, key=lambda x: x[0]))
    if len(combined) > debug_context_chars:
        combined = combined[:debug_context_chars].rstrip() + "…"

    # Collect co-located heuristic hits (other patterns firing in the window)
    co_hits = []
    for m in window_msgs:
        if m["index"] == heuristic_index:
            continue
        full_text = "\n".join(m["text_blocks"])
        for label, pattern in HEURISTIC_PATTERNS:
            match = pattern.search(full_text)
            if match:
                start = max(0, match.start() - 40)
                end = min(len(full_text), match.end() + 40)
                snippet = full_text[start:end].strip()
                co_hits.append(f"[{label}] (msg {m['index']}): {snippet}")
                break  # one hit per message is enough

    # Format the structured context block
    lines = ["**Investigation chain:**", combined]
    if co_hits:
        lines.append("")
        lines.append("**Co-located signals:**")
        lines.extend(f"- {h}" for h in co_hits)

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Write _pending_captures/ directory with individual candidate files
# ---------------------------------------------------------------------------

def candidate_hash(candidate):
    """Return a 12-char hex hash for a candidate, based on trigger + matched_text."""
    key = candidate["trigger"] + candidate["matched_text"]
    return hashlib.sha256(key.encode("utf-8")).hexdigest()[:12]


def write_pending_captures(knowledge_dir, candidates, transcript_path="", messages=None, config=None):
    """Write individual candidate files into _pending_captures/ directory.

    Each candidate gets its own file named {sha256(trigger+matched_text)[:12]}.md.
    This makes writes idempotent: the same candidate always produces the same
    filename, so re-running the hook with identical candidates is a harmless
    overwrite. The agent processes and deletes files individually at first turn.

    When transcript_path is provided, each candidate file includes a
    **Related files:** field listing file paths from tool_use blocks
    within +/- FILE_CONTEXT_WINDOW indices of the heuristic hit.

    When messages is provided and the candidate trigger is "debug-root-cause",
    an expanded **Investigation chain:** block (~800 chars) replaces the
    standard 120-char **Context:** excerpt.
    """
    pending_dir = os.path.join(knowledge_dir, "_pending_captures")

    try:
        os.makedirs(pending_dir, exist_ok=True)
    except OSError:
        return  # best-effort

    for c in candidates:
        filename = f"{candidate_hash(c)}.md"
        filepath = os.path.join(pending_dir, filename)

        # Extract related files from transcript if path is available
        related_files = []
        if transcript_path:
            related_files = extract_related_files(transcript_path, c["heuristic_index"], config=config)

        # For debug-root-cause with messages, emit expanded debug-narrative format
        is_debug = c["trigger"] == "debug-root-cause" and messages
        display_trigger = "debug-narrative" if is_debug else c["trigger"]

        lines = [
            f"# Capture Candidate: {display_trigger}",
            "",
            f"**Trigger:** {display_trigger}",
            f"**Context:** {c['matched_text']}",
        ]

        if is_debug:
            debug_ctx = extract_debug_context(messages, c["heuristic_index"], config=config)
            lines += [
                f"**Narrative context:**",
                "",
                debug_ctx,
                "",
            ]

        lines += [
            f"**Novel phrase:** {c['novel_phrase']}",
            f"**Transcript region:** messages {c['heuristic_index']}-{c['novelty_index']}",
            f"**Related files:** {', '.join(related_files) if related_files else 'none'}",
            "",
            "**Evaluate:** Does this meet the capture gate? (Reusable, Non-obvious, Stable, High-confidence)",
            "",
            "**Synthesis check:** Does this insight combine information from multiple sources "
            "(files, sessions, or components), or could it be read from a single file? "
            "(Synthesis = high loading priority, single-source = searchable tier)",
            "",
        ]

        # Trigger-specific evaluation guidance
        if c["trigger"] == "design-decision":
            lines.extend([
                "**Design rationale priority:** This candidate was flagged as a design decision. "
                "Capture the *why* — the rationale behind the choice — not just *what* was chosen. "
                "A statement explaining why a choice was made is more valuable than describing what "
                "was chosen; the 'what' is recoverable from code, the 'why' is not. If both a "
                "rationale and a factual observation are present, prefer the rationale.",
                "",
            ])

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
    except (json.JSONDecodeError, Exception) as e:
        print(f"[hook] stop-novelty-check: Failed to parse hook input: {e}", file=sys.stderr)
        sys.exit(0)

    # Guard 1: Prevent infinite loops
    if hook_input.get("stop_hook_active", False):
        sys.exit(0)

    transcript_path = hook_input.get("transcript_path", "")
    if not transcript_path or not os.path.exists(transcript_path):
        sys.exit(0)

    # Load configuration with fallback to defaults
    config = load_config()

    # Parse transcript
    messages = parse_transcript(transcript_path)
    if not messages:
        sys.exit(0)

    # Guard 2: Skip trivial sessions (fewer than min_tool_uses tool uses)
    tool_use_count = count_tool_uses(messages)
    if tool_use_count < config["min_tool_uses"]:
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

    # Adaptive threshold: adjust novelty_threshold based on store maturity
    if config.get("adaptive", False):
        base_threshold = config["novelty_threshold"]
        entry_count = read_store_stats(knowledge_dir)
        config["novelty_threshold"] = adapt_threshold(config, entry_count)
        if config["novelty_threshold"] != base_threshold:
            count_str = str(entry_count) if entry_count is not None else "unknown"
            print(
                f"[novelty] adaptive threshold: {config['novelty_threshold']} "
                f"(store: {count_str} entries)",
                file=sys.stderr,
            )

    # Heuristic pattern scan (regex + structural)
    heuristic_hits = scan_heuristics(messages)
    structural_hits = scan_structural_signals(messages, transcript_path=transcript_path, config=config)
    heuristic_hits = heuristic_hits + structural_hits
    if not heuristic_hits:
        sys.exit(0)

    # FTS5 novelty scoring
    phrases = extract_key_phrases(messages, config=config)
    novelty_results = score_novelty(knowledge_dir, phrases, config=config)

    # AND gate: both criteria must fire in the same region
    candidates = and_gate(heuristic_hits, novelty_results, config=config)
    if not candidates:
        sys.exit(0)

    # If captures already ran and we only have weak candidates, skip
    if already_captured and len(candidates) <= 1:
        sys.exit(0)

    # Write individual candidate files for agent evaluation at next session start
    write_pending_captures(knowledge_dir, candidates, transcript_path=transcript_path, messages=messages, config=config)

    # Decision: block only if session is substantial (>max_tool_uses tool uses)
    # This avoids interrupting quick sessions
    if tool_use_count > config["max_tool_uses"]:
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
    try:
        fail_open(main)()
    except Exception as e:
        print(f"[hook] stop-novelty-check: {e}", file=sys.stderr)
        sys.exit(0)
