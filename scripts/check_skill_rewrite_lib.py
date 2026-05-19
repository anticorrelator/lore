#!/usr/bin/env python3
"""Helper for check-skill-rewrite.sh — parses per-skill audit tables, derives
the preserve-trace snippet list, and validates rewrite-log coverage.

Three subcommands match the three checks in check-skill-rewrite.sh:

  preserve-snippets <audit.md>
      Emit the preserve-trace snippet set to stdout, one JSON object per line.
      Each record: {"row_id", "kind", "snippet", "skip_reason"} where:
        - kind ∈ {"stance_phrase", "canonical_inline", "canonical_link_only"}
        - snippet is the substring the wrapper must locate in the rewritten
          SKILL.md (empty when kind == "canonical_link_only"). Snippets are
          emitted in audit-table form — light normalization (described below)
          is applied at match time on BOTH the probe and the rewritten file
          before comparison.
        - skip_reason is non-empty only on link-only rows; the wrapper emits a
          stderr warning and the row is skipped from the failure list.

      Normalization at match time (applied symmetrically to probe and target):
        - Trailing `...` on the probe is stripped (audit-side truncation marker)
        - Markdown emphasis runs (`**...**`, `*...*`, `_..._`) are stripped
          to their interior text
        - Unicode dashes (en-dash, em-dash) collapse to ASCII `-`
      No curly-quote normalization is performed (per work-item constraints).

  match-probe <rewritten.md>
      Read JSON probe records on stdin (one per line, as emitted by
      preserve-snippets) and print one TAB-separated line per probe that
      does NOT match the rewritten file:
        <row_id>\t<kind>\t<flattened probe>
      Empty stdout means every probe matched. This subcommand exists so the
      bash wrapper can delegate the normalization+match logic to one place.

  default-disposition <primary_category> <flags> <failure_vocab_role>
      Print the default disposition the routing rules assign to the given
      (primary, flags, role) triple — used by check (c) to decide whether a
      row's applied_disposition needs an explanatory note. Output is one
      token on stdout ({preserve_verbatim, preserve_or_tighten,
      collapse_to_canonical, delete_candidate, handoff_review, ambiguous}).
      "ambiguous" is returned for the cat-5 unique-illustration branch
      (rewrite-time judgment call); the validator treats any disposition as
      default on cat-5 rows.

  sidecar-targets <rewrite-log.md>
      Emit a TAB-separated row_id → relative-sidecar-path map for every
      `moved_to_sidecar` row in the disposition log. Used by the bash
      wrapper to route check (a) substring matches for those rows to the
      named sidecar file instead of the rewritten SKILL.md. Empty stdout
      means no sidecar rows are present (legacy behavior applies — every
      probe is matched against the rewritten SKILL.md).

  validate-rewrite-log <audit.md> <rewrite-log.md> <link-only-rows.json>
      Check (c). Emit one issue per stdout line; exit 0 with no output when
      coverage is clean. <link-only-rows.json> is a JSON array of row_ids the
      preserve-trace check downgraded to warnings (those rows must appear in
      the disposition log).

The audit parser handles all 12 in-corpus audits with one set of rules — no
skill-by-skill special cases. Pipes inside backtick-delimited code and inside
straight double quotes are tolerated by tracking quote/code-fence state during
the split.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


# --- Audit table parsing ---------------------------------------------------

AUDIT_COLUMNS = [
    "row_id",
    "anchor",
    "primary_category",
    "flags",
    "classification_note",
    "voice_register",
    "failure_vocab_role",
    "site_class",
    "excerpt_or_link",
    "stance_phrase",
    "canonical_site",
    "prior_audit_ref",
]


@dataclass
class AuditRow:
    row_id: str
    anchor: str
    primary_category: str
    flags: str
    classification_note: str
    voice_register: str
    failure_vocab_role: str
    site_class: str
    excerpt_or_link: str
    stance_phrase: str
    canonical_site: str
    prior_audit_ref: str


def _split_pipe_row(line: str) -> list[str]:
    """Split a markdown table row on `|`, treating backtick-quoted spans and
    straight-double-quoted spans as opaque (their internal pipes do not split).

    Both backtick and double-quote contexts treat the delimiter as a toggle:
    encountering an unescaped delimiter while inside flips the state. Newlines
    aren't possible since the caller passes a single line.
    """
    parts: list[str] = []
    buf: list[str] = []
    in_backtick = False
    in_dquote = False
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == "`" and not in_dquote:
            in_backtick = not in_backtick
            buf.append(ch)
        elif ch == '"' and not in_backtick:
            in_dquote = not in_dquote
            buf.append(ch)
        elif ch == "|" and not in_backtick and not in_dquote:
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
        i += 1
    parts.append("".join(buf))
    return parts


def _strip_cell(cell: str) -> str:
    return cell.strip()


def parse_audit_rows(audit_path: Path) -> list[AuditRow]:
    """Read the ## Rows table from a per-skill audit file and return one
    AuditRow per data row. Raises ValueError if the table is missing or
    columns don't line up.
    """
    text = audit_path.read_text(encoding="utf-8")
    lines = text.splitlines()

    # Locate the data table by header signature. The audit format puts a
    # `## Rows` heading just above the header line; we anchor on the header
    # rather than the heading so the parser stays robust to incidental
    # heading-text edits.
    header_idx = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith("|") and "row_id" in stripped and "anchor" in stripped:
            header_idx = i
            break
    if header_idx is None:
        raise ValueError(f"no audit row table found in {audit_path}")

    header_cells = [_strip_cell(c) for c in _split_pipe_row(lines[header_idx])]
    # _split_pipe_row produces empty leading/trailing cells around the | borders.
    header_cells = [c for c in header_cells if c != ""]
    if header_cells != AUDIT_COLUMNS:
        raise ValueError(
            f"audit header in {audit_path} does not match expected schema. "
            f"Got {header_cells!r}; expected {AUDIT_COLUMNS!r}"
        )

    # Skip the separator row immediately below (the |---|---|... line).
    rows: list[AuditRow] = []
    i = header_idx + 2
    excerpt_idx = AUDIT_COLUMNS.index("excerpt_or_link")
    while i < len(lines):
        line = lines[i]
        if not line.strip().startswith("|"):
            # First non-table line terminates the rows section.
            break
        cells_raw = _split_pipe_row(line)
        cells = _trim_border_empties(cells_raw)
        if len(cells) > len(AUDIT_COLUMNS):
            # Audit rows occasionally contain unquoted/unbacked bare pipes
            # inside an excerpt cell (e.g. `(printf | write-execution-log.sh)`).
            # Markdown-table-strict, this would be an authoring mistake, but
            # the corpus has them. Re-merge the surplus cells back into the
            # excerpt_or_link column so the row stays parseable.
            surplus = len(cells) - len(AUDIT_COLUMNS)
            merged = "|".join(cells[excerpt_idx : excerpt_idx + 1 + surplus])
            cells = (
                cells[:excerpt_idx]
                + [merged]
                + cells[excerpt_idx + 1 + surplus :]
            )
        if len(cells) != len(AUDIT_COLUMNS):
            raise ValueError(
                f"row at {audit_path}:{i+1} has {len(cells)} cells, "
                f"expected {len(AUDIT_COLUMNS)}: {line!r}"
            )
        rows.append(AuditRow(**dict(zip(AUDIT_COLUMNS, cells))))
        i += 1
    return rows


def _trim_border_empties(cells: list[str]) -> list[str]:
    """Drop the empty cells produced by leading/trailing pipes. Keep interior
    empty cells intact — they signal genuinely empty audit columns.
    """
    stripped = [_strip_cell(c) for c in cells]
    if stripped and stripped[0] == "":
        stripped = stripped[1:]
    if stripped and stripped[-1] == "":
        stripped = stripped[:-1]
    return stripped


# --- Preserve-trace derivation --------------------------------------------

# Matches a path-with-line-range reference like skills/retro/SKILL.md:42-49
# or skills/retro/SKILL.md:42. The path segment allows letters, digits, dot,
# slash, underscore, and dash — wide enough for all audit citations seen.
PATH_LINERANGE_RE = re.compile(r"[A-Za-z0-9_./-]+:\d+(?:-\d+)?")

# Matches a "...verbatim..." double-quoted span. Non-greedy across the line so
# back-to-back quoted spans (e.g. `"foo" + "bar"`) each surface separately.
QUOTED_SPAN_RE = re.compile(r'"([^"]+)"')

# Backtick-delimited code spans. We mask these out before stripping markdown
# emphasis so identifiers carrying internal underscores (e.g. `_meta.json`,
# `intent_anchor`, `REMAINING_COUNT`) do not get partially eaten by the
# `_foo_` italic regex when they happen to sit between other underscores in
# the surrounding prose. Markdown itself does not render emphasis inside
# code spans; the normalizer matches that behavior.
_BACKTICK_SPAN_RE = re.compile(r"`[^`\n]*`")
_CODE_PLACEHOLDER_PREFIX = "\x02CODE"
_CODE_PLACEHOLDER_SUFFIX = "\x02"

# Markdown emphasis runs we strip during match-time normalization. We strip
# bold first (`**x**`) so the inner asterisks of `***x***` (italic+bold) also
# fall away after a second pass over single-asterisk italic. Underscores get
# the same treatment so `_foo_` collapses to `foo`.
_EMPHASIS_PATTERNS = [
    re.compile(r"\*\*([^*]+?)\*\*"),
    re.compile(r"\*([^*]+?)\*"),
    re.compile(r"__([^_]+?)__"),
    re.compile(r"_([^_]+?)_"),
]

# Unicode dashes we collapse to ASCII hyphen. The audit corpus normalizes
# en/em dashes in stance phrases and citation strings; the source SKILL.md
# files mostly use the Unicode glyphs. Without this collapse, every probe
# carrying a numeric range or an em-dash interjection would falsely miss.
_DASH_TRANSLATION = str.maketrans({"–": "-", "—": "-", "−": "-"})


def normalize_for_match(text: str) -> str:
    """Apply the symmetric normalization the verifier uses when comparing a
    preserve probe against the rewritten SKILL.md. Idempotent.

    The normalizations exist to bridge audit-side transcription choices and
    the source's actual markdown — they do not relax preserve_verbatim
    semantics for the *human reader* who can still see the rewritten file.

      - Unicode dashes collapse to ASCII `-` (the audit corpus normalizes
        en/em dashes; the source uses the Unicode glyphs).
      - Markdown emphasis runs strip to their interior (the audit author
        often quoted `**bold**` as `bold` in stance_phrase).
      - Single/double/backtick quote glyphs collapse to a single placeholder
        so quote-style transcription drift ('foo' vs "foo") matches.
      - Internal whitespace runs (including the audit's `\\n` escape used in
        place of real newlines) collapse to a single space; the comparison
        operates on the *prose*, not the layout.
    """
    s = text.translate(_DASH_TRANSLATION)
    # Translate the audit-side `\n` / `\t` escape into whitespace before the
    # whitespace-collapse step. We do this in raw-string form because Python
    # source loads them already-interpreted; the audit table contains the
    # literal two-character backslash-n sequence.
    s = s.replace("\\n", " ").replace("\\t", " ")
    # Mask backtick-delimited code spans so the emphasis regexes below cannot
    # eat underscores or asterisks that belong to identifiers. We restore
    # them after the emphasis pass.
    code_spans: list[str] = []

    def _stash_code(m: re.Match) -> str:
        code_spans.append(m.group(0))
        return f"{_CODE_PLACEHOLDER_PREFIX}{len(code_spans) - 1}{_CODE_PLACEHOLDER_SUFFIX}"

    s = _BACKTICK_SPAN_RE.sub(_stash_code, s)
    for _ in range(2):
        for pat in _EMPHASIS_PATTERNS:
            s = pat.sub(lambda m: m.group(1), s)
    for i, span in enumerate(code_spans):
        s = s.replace(
            f"{_CODE_PLACEHOLDER_PREFIX}{i}{_CODE_PLACEHOLDER_SUFFIX}", span
        )
    # Collapse quote glyphs to a single sentinel so the substring match is
    # quote-style-agnostic. We pick a character that does not appear in
    # natural prose to keep `foo"bar` distinguishable from `foobar`.
    s = re.sub(r"[\"'`]", "\x01", s)
    # Collapse runs of whitespace (spaces, tabs, real newlines) into one
    # space so layout differences (line wraps, indentation) don't defeat
    # the substring search.
    s = re.sub(r"\s+", " ", s)
    return s.strip()


def _strip_truncation(snippet: str) -> str:
    """Strip the trailing `...` marker (with optional preceding whitespace)
    the audit corpus uses to denote truncated excerpts. Without this, a
    truncated probe like 'You are a grounding evaluation agent...' fails to
    match the un-truncated source prose."""
    s = snippet.rstrip()
    if s.endswith("..."):
        s = s[:-3].rstrip()
    return s


# Mid-snippet `...` elision marker used by the audit corpus when an excerpt
# was abbreviated for readability. The verifier treats internal `...` as a
# segment break: split the probe on it and require each non-empty segment
# to appear in the rewritten file in order, with arbitrary text between
# segments. Trailing `...` is handled by `_strip_truncation` upstream.
_MID_ELLIPSIS_RE = re.compile(r"\.{3,}")


def _probe_matches(probe_norm: str, rewritten_norm: str) -> bool:
    """True when the normalized probe is present in the normalized rewritten
    text. Handles internal `...` by splitting and matching segments in order.
    """
    if "..." not in probe_norm:
        return probe_norm in rewritten_norm
    segments = [seg.strip() for seg in _MID_ELLIPSIS_RE.split(probe_norm)]
    segments = [seg for seg in segments if seg]
    if not segments:
        return False
    cursor = 0
    for seg in segments:
        idx = rewritten_norm.find(seg, cursor)
        if idx < 0:
            return False
        cursor = idx + len(seg)
    return True


def _strip_quotes(cell: str) -> str:
    """If the cell is a single double-quoted span (allowing surrounding
    whitespace), return its interior. Otherwise return the cell unchanged.
    """
    s = cell.strip()
    if len(s) >= 2 and s.startswith('"') and s.endswith('"'):
        # Confirm there is no intermediate unescaped quote that would mean
        # this is actually two concatenated spans — if so, leave as-is so
        # the caller can decide how to handle it.
        interior = s[1:-1]
        if '"' not in interior:
            return interior
    return s


def _excerpt_is_link_only(excerpt: str) -> bool:
    """True when excerpt_or_link contains no inline quoted prose, only a
    path:line_range reference (possibly with surrounding parenthetical
    description text)."""
    if not excerpt.strip():
        return False
    if QUOTED_SPAN_RE.search(excerpt):
        return False
    return bool(PATH_LINERANGE_RE.search(excerpt))


def _excerpt_inline_snippets(excerpt: str) -> list[str]:
    """Extract the inline double-quoted spans from an excerpt_or_link cell.
    Returns the longest single span — this is the substring the verifier
    requires to survive in the rewritten file. Multiple short spans on one
    row are unusual; we use the longest because it carries the most context
    and is the most discriminating grep -F probe.
    """
    spans = [m.group(1) for m in QUOTED_SPAN_RE.finditer(excerpt)]
    return spans


def derive_preserve_records(rows: Iterable[AuditRow]) -> list[dict]:
    """Walk the audit rows and emit the preserve-trace record set. See module
    docstring for record shape."""
    records: list[dict] = []
    for row in rows:
        # (1) Every non-empty stance_phrase becomes a preserve probe. The
        # audit's cat-2 rows always populate stance_phrase; rows from other
        # categories may also surface a stance phrase worth preserving.
        stance = _strip_truncation(_strip_quotes(row.stance_phrase))
        if stance:
            records.append(
                {
                    "row_id": row.row_id,
                    "kind": "stance_phrase",
                    "snippet": stance,
                    "skip_reason": "",
                }
            )

        # (2) Every canonical_definition row contributes a preserve probe
        # drawn from its excerpt_or_link cell. Inline quoted spans are
        # matched against the rewritten file; pure path:line_range references
        # emit a warning instead.
        if row.failure_vocab_role == "canonical_definition":
            excerpt = row.excerpt_or_link
            spans = _excerpt_inline_snippets(excerpt)
            if spans:
                # Use the longest span (post-truncation strip) as the
                # discriminating probe.
                probe = max((_strip_truncation(s) for s in spans), key=len)
                records.append(
                    {
                        "row_id": row.row_id,
                        "kind": "canonical_inline",
                        "snippet": probe,
                        "skip_reason": "",
                    }
                )
            elif _excerpt_is_link_only(excerpt):
                records.append(
                    {
                        "row_id": row.row_id,
                        "kind": "canonical_link_only",
                        "snippet": "",
                        "skip_reason": (
                            "canonical_definition excerpt is path:line_range only; "
                            "reviewer must sample the rewritten anchor by hand"
                        ),
                    }
                )
            # else: excerpt is empty or some other shape; nothing to probe.
    return records


# --- Default disposition routing -------------------------------------------

# Encodes the deterministic routing the rewrite-log workers apply to each
# audit row based on its (primary_category, flags, failure_vocab_role,
# canonical_site) tuple. The verifier uses this default to decide whether a
# rewrite-log row needs an explanatory note (any deviation must be
# justified). Returned tokens match the strings the rewrite-log uses in
# its applied_disposition column.

DISPOSITION_PRESERVE = "preserve_verbatim"
DISPOSITION_TIGHTEN = "preserve_or_tighten"
DISPOSITION_COLLAPSE = "collapse_to_canonical"
DISPOSITION_DELETE = "delete_candidate"
DISPOSITION_HANDOFF = "handoff_review"
DISPOSITION_SIDECAR = "moved_to_sidecar"
DISPOSITION_AMBIGUOUS = "ambiguous"  # cat-5: worker judgment, no fixed default

# Prefix on the rewrite-log's new_anchor column when applied_disposition is
# moved_to_sidecar. The substring following the prefix is the relative path
# from the rewritten SKILL.md's parent directory to the sidecar file that
# now holds the moved prose.
SIDECAR_ANCHOR_PREFIX = "SIDECAR:"


def _parse_flags(flags: str) -> set[str]:
    s = flags.strip()
    if not s:
        return set()
    return {p.strip() for p in s.split(",") if p.strip()}


def default_disposition(
    primary_category: str, flags: str, failure_vocab_role: str
) -> str:
    pc = primary_category.strip()
    role = failure_vocab_role.strip()
    flag_set = _parse_flags(flags)

    if pc == "2":
        return DISPOSITION_PRESERVE
    if role == "canonical_definition":
        return DISPOSITION_PRESERVE
    if role == "invocation":
        # Pattern A/B/C routing for empty-canonical-site rows. The validator
        # only has the audit row, so "canonical_site populated" is checked
        # by the caller (it knows the canonical_site column); here we
        # encode the empty-canonical-site branch by default and let the
        # caller override to collapse_to_canonical when it sees a value.
        if pc in {"1", "3", "4"} and flag_set == {"4"}:
            return DISPOSITION_TIGHTEN  # Pattern A
        if pc == "4" and flag_set == {"1"}:
            return DISPOSITION_HANDOFF  # Pattern B
        if pc == "4" and flag_set == {"3"}:
            return DISPOSITION_HANDOFF  # Pattern C
        return DISPOSITION_HANDOFF  # default escalate
    if pc == "7":
        if not flag_set:
            return DISPOSITION_DELETE
        return DISPOSITION_HANDOFF
    if pc in {"1", "3", "6"}:
        return DISPOSITION_TIGHTEN
    if pc == "5":
        return DISPOSITION_AMBIGUOUS
    # Unknown category — escalate so the worker doesn't silently lose the row.
    return DISPOSITION_HANDOFF


def default_for_row(row: AuditRow) -> str:
    base = default_disposition(row.primary_category, row.flags, row.failure_vocab_role)
    if (
        base == DISPOSITION_HANDOFF
        and row.failure_vocab_role.strip() == "invocation"
        and row.canonical_site.strip()
    ):
        # Populated canonical_site overrides the empty-site default — the
        # row collapses into its named canonical site (file:line_range).
        return DISPOSITION_COLLAPSE
    if (
        base == DISPOSITION_TIGHTEN
        and row.failure_vocab_role.strip() == "invocation"
        and row.canonical_site.strip()
    ):
        # Same override — populated canonical_site always wins over the
        # pattern-A tighten fallback.
        return DISPOSITION_COLLAPSE
    return base


# --- Rewrite-log validation (check (c)) -----------------------------------

# Pattern matches a rewrite-log disposition row. Columns:
#   row_id | applied_disposition | new_anchor_or_DELETED_or_MERGED | note
# We accept extra surrounding whitespace and require the row to start with
# a pipe so we don't accidentally pick up alignment separators.
LOG_ROW_HEADER_RE = re.compile(r"\|\s*row_id\s*\|\s*applied_disposition\s*\|")


@dataclass
class LogRow:
    row_id: str
    applied_disposition: str
    new_anchor: str
    note: str
    source_line: int = 0


def parse_rewrite_log(log_path: Path) -> list[LogRow]:
    text = log_path.read_text(encoding="utf-8")
    lines = text.splitlines()
    header_idx = None
    for i, line in enumerate(lines):
        if LOG_ROW_HEADER_RE.search(line):
            header_idx = i
            break
    if header_idx is None:
        raise ValueError(
            f"no disposition table found in {log_path} "
            "(expected a row beginning '| row_id | applied_disposition | ...')"
        )

    out: list[LogRow] = []
    i = header_idx + 2  # skip separator
    while i < len(lines):
        line = lines[i]
        if not line.strip().startswith("|"):
            break
        cells = _trim_border_empties(_split_pipe_row(line))
        if len(cells) < 4:
            raise ValueError(
                f"rewrite-log row at {log_path}:{i+1} has only {len(cells)} cells "
                f"(expected 4): {line!r}"
            )
        # Skip the markdown alignment separator if a stray one appears mid-table.
        if all(re.fullmatch(r":?-+:?", c.strip()) for c in cells):
            i += 1
            continue
        # Skip placeholder rows whose row_id is a literal `<...>` template token.
        if cells[0].startswith("<") and cells[0].endswith(">"):
            i += 1
            continue
        out.append(
            LogRow(
                row_id=cells[0],
                applied_disposition=cells[1],
                new_anchor=cells[2],
                note=cells[3],
                source_line=i + 1,
            )
        )
        i += 1
    return out


def validate_rewrite_log(
    audit_rows: list[AuditRow],
    log_rows: list[LogRow],
    link_only_row_ids: list[str],
) -> list[str]:
    """Run check (c). Return a list of human-readable issue strings; empty
    list means coverage is clean."""
    issues: list[str] = []

    audit_ids = [r.row_id for r in audit_rows]
    audit_id_set = set(audit_ids)

    # 1. Every audit row_id appears exactly once.
    log_counts: dict[str, int] = {}
    for lr in log_rows:
        log_counts[lr.row_id] = log_counts.get(lr.row_id, 0) + 1
    missing = [rid for rid in audit_ids if rid not in log_counts]
    for rid in missing:
        issues.append(f"missing from rewrite-log: {rid}")
    duplicated = sorted(rid for rid, n in log_counts.items() if n > 1)
    for rid in duplicated:
        issues.append(f"duplicated in rewrite-log ({log_counts[rid]}x): {rid}")
    extras = sorted(rid for rid in log_counts if rid not in audit_id_set)
    for rid in extras:
        issues.append(f"rewrite-log row_id not in audit: {rid}")

    # Index log rows by row_id for the remaining checks (first occurrence wins;
    # duplicates were already reported above).
    log_by_id: dict[str, LogRow] = {}
    for lr in log_rows:
        log_by_id.setdefault(lr.row_id, lr)
    audit_by_id = {r.row_id: r for r in audit_rows}

    # 2. handoff_review rows must carry a non-empty note.
    for rid, lr in log_by_id.items():
        if lr.applied_disposition == DISPOSITION_HANDOFF and _is_empty_note(lr.note):
            issues.append(
                f"handoff_review row missing note: {rid} "
                f"(rewrite-log line {lr.source_line})"
            )

    # 2b. moved_to_sidecar rows must carry a non-empty note (the
    #     on-demand load condition) AND new_anchor must be SIDECAR:<path>.
    for rid, lr in log_by_id.items():
        if lr.applied_disposition != DISPOSITION_SIDECAR:
            continue
        if _is_empty_note(lr.note):
            issues.append(
                f"moved_to_sidecar row missing note (on-demand load condition required): {rid} "
                f"(rewrite-log line {lr.source_line})"
            )
        anchor = lr.new_anchor.strip()
        if not anchor.startswith(SIDECAR_ANCHOR_PREFIX):
            issues.append(
                f"moved_to_sidecar row new_anchor missing '{SIDECAR_ANCHOR_PREFIX}' prefix: {rid} "
                f"(got {anchor!r}, rewrite-log line {lr.source_line})"
            )
        else:
            rel = anchor[len(SIDECAR_ANCHOR_PREFIX):].strip()
            if not rel:
                issues.append(
                    f"moved_to_sidecar row new_anchor missing relative path after "
                    f"'{SIDECAR_ANCHOR_PREFIX}': {rid} (rewrite-log line {lr.source_line})"
                )

    # 3. Any row whose applied_disposition diverges from the default for
    #    its (primary, flags, role, canonical_site) tuple must carry a note.
    for rid, lr in log_by_id.items():
        audit_row = audit_by_id.get(rid)
        if audit_row is None:
            continue
        default = default_for_row(audit_row)
        if default == DISPOSITION_AMBIGUOUS:
            continue  # cat-5: any disposition is treated as default
        if lr.applied_disposition != default and _is_empty_note(lr.note):
            issues.append(
                f"divergent disposition without note: {rid} "
                f"(applied={lr.applied_disposition}, default={default}, "
                f"rewrite-log line {lr.source_line})"
            )

    # 4. Every check-(a)-link-only row must appear in the disposition log.
    #    (Already covered by check 1 if the row is wholly absent, but we
    #    surface the specific reason here so reviewers know which rows fell
    #    into the path:line_range warning bucket.)
    for rid in link_only_row_ids:
        if rid not in log_by_id:
            issues.append(
                f"path:line_range-only canonical row not accounted for in "
                f"rewrite-log: {rid}"
            )

    return issues


def _is_empty_note(note: str) -> bool:
    s = note.strip().lower()
    return s in {"", "none", "n/a", "na", "-", "—"}


# --- CLI dispatch ----------------------------------------------------------


def _cmd_preserve_snippets(args: list[str]) -> int:
    if len(args) != 1:
        print("usage: preserve-snippets <audit.md>", file=sys.stderr)
        return 2
    audit_path = Path(args[0])
    rows = parse_audit_rows(audit_path)
    records = derive_preserve_records(rows)
    for rec in records:
        sys.stdout.write(json.dumps(rec, ensure_ascii=False) + "\n")
    return 0


def _cmd_match_probe(args: list[str]) -> int:
    if len(args) != 1:
        print("usage: match-probe <rewritten.md>", file=sys.stderr)
        return 2
    rewritten_path = Path(args[0])
    rewritten = rewritten_path.read_text(encoding="utf-8")
    rewritten_norm = normalize_for_match(rewritten)
    missing = 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        if rec.get("kind") == "canonical_link_only":
            continue
        probe = rec.get("snippet", "")
        if not probe:
            continue
        probe_norm = normalize_for_match(probe)
        if _probe_matches(probe_norm, rewritten_norm):
            continue
        flat = probe.replace("\n", " ").replace("\r", " ")
        if len(flat) > 200:
            flat = flat[:197] + "..."
        sys.stdout.write(f"{rec['row_id']}\t{rec.get('kind','')}\t{flat}\n")
        missing += 1
    return 0  # exit code is wrapper-controlled — non-empty stdout signals failure


def _cmd_default_disposition(args: list[str]) -> int:
    if len(args) != 3:
        print(
            "usage: default-disposition <primary_category> <flags> <failure_vocab_role>",
            file=sys.stderr,
        )
        return 2
    print(default_disposition(args[0], args[1], args[2]))
    return 0


def _cmd_sidecar_targets(args: list[str]) -> int:
    """Emit the row_id → sidecar relative-path map for moved_to_sidecar rows.

    One TAB-separated line per row: <row_id>\t<relative-path>. The wrapper
    uses this map to route check (a) substring matches for those row_ids to
    the named sidecar file instead of the rewritten SKILL.md. Empty stdout
    means the rewrite-log carries no moved_to_sidecar rows — the legacy
    code path (every probe matched against the rewritten SKILL.md) applies.
    """
    if len(args) != 1:
        print("usage: sidecar-targets <rewrite-log.md>", file=sys.stderr)
        return 2
    log_rows = parse_rewrite_log(Path(args[0]))
    for lr in log_rows:
        if lr.applied_disposition != DISPOSITION_SIDECAR:
            continue
        anchor = lr.new_anchor.strip()
        if not anchor.startswith(SIDECAR_ANCHOR_PREFIX):
            continue
        rel = anchor[len(SIDECAR_ANCHOR_PREFIX):].strip()
        if not rel:
            continue
        sys.stdout.write(f"{lr.row_id}\t{rel}\n")
    return 0


def _cmd_validate_rewrite_log(args: list[str]) -> int:
    if len(args) != 3:
        print(
            "usage: validate-rewrite-log <audit.md> <rewrite-log.md> <link-only-rows.json>",
            file=sys.stderr,
        )
        return 2
    audit_path = Path(args[0])
    log_path = Path(args[1])
    link_only = json.loads(Path(args[2]).read_text(encoding="utf-8"))
    if not isinstance(link_only, list):
        print(
            "link-only-rows.json must contain a JSON array of row_id strings",
            file=sys.stderr,
        )
        return 2
    audit_rows = parse_audit_rows(audit_path)
    log_rows = parse_rewrite_log(log_path)
    issues = validate_rewrite_log(audit_rows, log_rows, link_only)
    for issue in issues:
        print(issue)
    return 1 if issues else 0


COMMANDS = {
    "preserve-snippets": _cmd_preserve_snippets,
    "match-probe": _cmd_match_probe,
    "default-disposition": _cmd_default_disposition,
    "sidecar-targets": _cmd_sidecar_targets,
    "validate-rewrite-log": _cmd_validate_rewrite_log,
}


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] in {"-h", "--help"}:
        print("usage: check_skill_rewrite_lib.py <subcommand> [args...]", file=sys.stderr)
        print("subcommands: " + ", ".join(sorted(COMMANDS)), file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd not in COMMANDS:
        print(f"unknown subcommand: {cmd}", file=sys.stderr)
        return 2
    return COMMANDS[cmd](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
