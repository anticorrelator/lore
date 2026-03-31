### Cross-Lens Synthesis

When multiple lenses run against the same PR, their findings must be synthesized before presentation or posting. This section defines the rules for identifying compound findings, elevating severity, and deduplicating overlapping observations.

#### Compound findings

A **compound finding** exists when two or more lenses flag the same location (same `file` and `line` values, or overlapping line ranges within 3 lines). Compound findings are stronger signals than any individual lens finding — independent analytical perspectives converging on the same code is meaningful.

**Identification rule:** Group findings by `file`. Within each file, findings whose `line` values are within 3 lines of each other are candidates for compounding. Two or more candidate findings from different lenses form a compound finding.

**Presentation:** Compound findings are presented as a single consolidated finding with:
- All contributing lens IDs listed (e.g., `[correctness, security]`)
- The highest severity among the contributing findings (see elevation table below)
- A merged body that preserves each lens's distinct observation under a labeled sub-section, including the grounding (concrete scenario, misuse, or failure consequence) from each contributing finding — grounding must not be dropped during merging

#### Severity elevation table

When findings compound, severity may elevate. The resulting severity is the maximum of the individual severities, with one additional rule: two or more `suggestion`-level findings from different lenses elevate to `blocking`.

| Contributing severities | Result |
|------------------------|--------|
| Any `blocking` | `blocking` |
| 2+ `suggestion` from different lenses | `blocking` |
| 1 `suggestion` + 1+ `question` | `suggestion` |
| All `question` | `question` |

**Rationale:** A single lens calling something a suggestion may reflect a judgment call. Two independent lenses independently flagging the same location as worth changing is a strong enough signal to block.

#### Deduplication criteria

Findings from different lenses may overlap without being at the exact same location. Deduplication prevents redundant review comments.

**Deduplicate when ALL of the following are true:**
1. Same `file`
2. Same or overlapping `line` (within 3 lines)
3. Same `severity`
4. The `title` or `body` describes the same underlying concern (not just the same location — two lenses may flag the same line for different reasons)

**When deduplicating:** Keep the finding with the more detailed `body`. Add the other lens's ID to the attribution. If the bodies address genuinely different concerns at the same location, do NOT deduplicate — instead, create a compound finding.

**The distinction:** Compounding means "different lenses see different problems at the same spot" (elevate severity). Deduplication means "different lenses see the same problem at the same spot" (merge into one).

