# Scale Registry

The scale registry is the single source of truth for capture-scale ids, their
human-readable labels, and the ordered adjacency structure that the CLI and
prompts consume.

**Schema file:** `scripts/scale-registry.json`
**Reader CLI:** `lore scale registry <subcommand>`

---

## 1. Purpose: immutable ids, mutable labels

Scale **ids** (`implementation`, `subsystem`, `architecture`, `abstract`) are
opaque and permanent once issued. Captured entries record the id at capture
time — this reference never changes.

Scale **labels** are what CLIs, prompts, and UI surfaces render. Labels are
mutable: when the vocabulary evolves (e.g., a new scale is added above
`architecture`, making its scope narrower relative to the new top), the label
can be updated without touching any entry file. Display surfaces always render
under the current `labels` map; there is no historical-label lookup.

---

## 2. Schema reference

```json
{
  "version": 2,
  "scales": [
    {"id": "implementation", "label": "implementation", "ordinal": 1, "aliases": []},
    {"id": "subsystem",      "label": "subsystem",      "ordinal": 2, "aliases": []},
    {"id": "architecture",   "label": "architecture",   "ordinal": 3, "aliases": []},
    {"id": "abstract",       "label": "abstract",       "ordinal": 4, "aliases": []}
  ],
  "labels": {
    "implementation": "implementation",
    "subsystem": "subsystem",
    "architecture": "architecture",
    "abstract": "abstract"
  }
}
```

**Fields:**

| Field | Description |
|---|---|
| `version` | Monotonic registry-revision counter; bumps on any registry mutation (relabels today, schema-shape changes if/when they happen). No live consumer keys off this value — it exists for git-archaeology and debugging registry drift. |
| `scales[].id` | Immutable opaque identifier |
| `scales[].label` | Current human-readable label (mirrors `labels` map) |
| `scales[].ordinal` | Ordering integer; lower = narrower scope |
| `scales[].aliases` | Alternative ids accepted by the CLI |
| `labels` | Flat id→label map; what CLIs and prompts render today |

---

## 3. Upward extension protocol

Upward extension adds a new scale **above the current maximum**. This is a
structural change: do it when a new category of cross-repo or system-level
insight is recognized that genuinely exceeds the scope of `abstract`.

**Steps:**

1. **Append** the new scale entry to `scales` with the next ordinal and a new
   id. The new id must be stable and descriptive.

2. **Bump** `version`.

3. **Update** the `labels` map: add the new id; optionally relabel existing
   ids for clarity. Relabeling is appropriate when the new scale changes the
   relative meaning of an existing label (see worked example below).

4. **Update** downstream consumers structurally:
   - Work-item scope defaults (if the new scale is added to the scope enum)
   - Matrix offsets in `scale-compute.sh` (if the new scale is a valid output)
   - Adjacency is derived automatically from ordinal order by `scale-registry.sh`

5. **No entry files are touched.** Existing entries retain their captured ids.
   Display surfaces render under the new `labels` map.

6. **No full-corpus rescale required** unless `lore analyze concordance` or
   `/memory renormalize` disagreement-detection flags specific entries as
   misclassified.

---

## 4. Worked example: adding `global` above `architecture`

**Scenario:** cross-repository insights emerge that span multiple repos. A new
scale `global` is needed above `architecture`. Because `architecture` now
refers to single-repo architecture (not the broader global scope), its label
is updated to `architecture (single-repo)` to avoid ambiguity.

**Before:**

```json
{
  "version": 2,
  "scales": [
    {"id": "implementation", "label": "implementation", "ordinal": 1, "aliases": []},
    {"id": "subsystem",      "label": "subsystem",      "ordinal": 2, "aliases": []},
    {"id": "architecture",   "label": "architecture",   "ordinal": 3, "aliases": []},
    {"id": "abstract",       "label": "abstract",       "ordinal": 4, "aliases": []}
  ],
  "labels": {
    "implementation": "implementation",
    "subsystem": "subsystem",
    "architecture": "architecture",
    "abstract": "abstract"
  }
}
```

**After:**

```json
{
  "version": 3,
  "scales": [
    {"id": "implementation", "label": "implementation",                 "ordinal": 1, "aliases": []},
    {"id": "subsystem",      "label": "subsystem",                      "ordinal": 2, "aliases": []},
    {"id": "architecture",   "label": "architecture (single-repo)",     "ordinal": 3, "aliases": []},
    {"id": "abstract",       "label": "abstract",                       "ordinal": 4, "aliases": []},
    {"id": "global",         "label": "global",                         "ordinal": 5, "aliases": []}
  ],
  "labels": {
    "implementation": "implementation",
    "subsystem": "subsystem",
    "architecture": "architecture (single-repo)",
    "abstract": "abstract",
    "global": "global"
  }
}
```

**Effect on existing entries:** entries captured with `scale: "architecture"`
still resolve correctly. A display surface calling
`lore scale registry get-label architecture` returns
`"architecture (single-repo)"` from the current `labels` map.

**Effect on adjacency:** `lore scale registry get-adjacency architecture`
returns `subsystem\nabstract` (derived from ordinals 2 and 4).

---

## 5. Downward refinement protocol

Downward refinement adds a new scale **below the current minimum**. This is a
structural change: do it when a recognized category of insight is narrower than
`implementation` (e.g., a single-function observation that is too granular to
be useful at module level).

**Steps:**

1. **Prepend** the new scale entry to `scales` with the next ordinal *below*
   the current minimum (e.g., ordinal 0, or shift existing ordinals up by 1).
   The new id must be stable and descriptive.

2. **Bump** `version`.

3. **Update** the `labels` map: add the new id; optionally relabel the prior
   minimum for symmetry. Relabeling is appropriate when the new scale clarifies
   what the prior minimum actually covers (see worked example below).

4. **Consider marking the prior minimum as a broad alias** for the new scale
   via `aliases` on the new scale entry. This lets legacy entries stamped with
   the old minimum id continue to resolve, while making clear that the new id
   is the more precise designation. Only add an alias if the old id genuinely
   overlaps the new one's scope.

5. **Update** downstream consumers structurally:
   - Clamp floor in `scale-compute.sh` (if the new scale is a valid output)
   - Matrix offsets if the new scale participates in role × slot pairs
   - Adjacency is derived automatically from ordinal order

6. **No entry files are touched.** Existing entries retain their captured ids.
   Renormalize may *lazily* propose `rescale` for entries it audits that appear
   misclassified — no mandatory full-corpus pass.

---

## 6. Worked example: adding `function-local` below `implementation`

**Scenario:** single-function observations accumulate that are too granular to
be meaningful at module scope. A new scale `function-local` is added below
`implementation`. Because `implementation` now specifically refers to module-
level scope, its label is updated to `implementation (module)` for symmetry.

**Before:**

```json
{
  "version": 2,
  "scales": [
    {"id": "implementation", "label": "implementation", "ordinal": 1, "aliases": []},
    {"id": "subsystem",      "label": "subsystem",      "ordinal": 2, "aliases": []},
    {"id": "architecture",   "label": "architecture",   "ordinal": 3, "aliases": []},
    {"id": "abstract",       "label": "abstract",       "ordinal": 4, "aliases": []}
  ],
  "labels": {
    "implementation": "implementation",
    "subsystem": "subsystem",
    "architecture": "architecture",
    "abstract": "abstract"
  }
}
```

**After:**

```json
{
  "version": 3,
  "scales": [
    {"id": "function-local", "label": "function-local",          "ordinal": 0, "aliases": []},
    {"id": "implementation", "label": "implementation (module)", "ordinal": 1, "aliases": []},
    {"id": "subsystem",      "label": "subsystem",               "ordinal": 2, "aliases": []},
    {"id": "architecture",   "label": "architecture",            "ordinal": 3, "aliases": []},
    {"id": "abstract",       "label": "abstract",                "ordinal": 4, "aliases": []}
  ],
  "labels": {
    "function-local": "function-local",
    "implementation": "implementation (module)",
    "subsystem": "subsystem",
    "architecture": "architecture",
    "abstract": "abstract"
  }
}
```

**Effect on existing entries:** entries captured with `scale: "implementation"`
still resolve correctly. A display surface calling
`lore scale registry get-label implementation` returns
`"implementation (module)"` from the current `labels` map.

**Effect on adjacency:** `lore scale registry get-adjacency implementation`
returns `function-local\nsubsystem` (ordinals 0 and 2). The new
`function-local` scale has no neighbor below: `get-adjacency function-local`
returns an empty first line followed by `implementation`.

**Alias consideration:** if it is expected that the old `implementation` id
should map conceptually to `function-local` for broad legacy entries (e.g.,
single-function observations that were filed as `implementation` before the
new scale existed), add `"implementation"` to `function-local.aliases`. This
is optional and only meaningful if callers use alias resolution. The worked
example above omits aliases because the scopes are distinct enough that legacy
entries should retain their original id without reclassification.

---

*See also: `scripts/scale-compute.sh` (formula), `architecture/agents/role-slot-matrix.md` (matrix offsets).*
