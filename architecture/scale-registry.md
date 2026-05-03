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
can be updated without touching any entry file. The `label_history` array
preserves prior label vocabularies so entries stamped with an older
`scale_registry_version` can render under the vocabulary that was active when
they were captured.

### 1.1 Capture-time pinning convention

The `scale_registry_version` field in an entry's META block records the
**registry version active when the entry was captured** — it is a historical
record, not a mirror of the current registry. It is written once at capture
and never bulk-rewritten when the registry bumps. This is the same shape as
the sibling `captured_at_branch` / `captured_at_sha` / `captured_at_merge_base_sha`
fields.

Implication: after a registry bump, the corpus will hold a mix of versions
(e.g., older entries stamped `1`, newer entries stamped `2`). This is correct.
A "drift" between the stamp on existing entries and the live registry version
is intended — the stamp is the lookup key into `label_history`, which is what
allows old entries to render under the vocabulary that existed when they were
captured.

If you need to surface the live registry version, read it from
`scripts/scale-registry.json` directly. Do not infer it from entry stamps.

> **Schema-example caveat:** the JSON snippets below illustrate the registry
> *shape* using the original v1 vocabulary (`implementation`, `subsystem`,
> `architectural`). The live registry has since advanced — see
> `scripts/scale-registry.json` for the current state. The worked examples
> remain as the documented record of the v1→v2 migration shape.

---

## 2. Schema reference

```json
{
  "version": 1,
  "scales": [
    {"id": "implementation", "label": "implementation", "ordinal": 1, "aliases": []},
    {"id": "subsystem",      "label": "subsystem",      "ordinal": 2, "aliases": []},
    {"id": "architectural",  "label": "architectural",  "ordinal": 3, "aliases": []}
  ],
  "labels": {
    "implementation": "implementation",
    "subsystem": "subsystem",
    "architectural": "architectural"
  },
  "label_history": []
}
```

**Fields:**

| Field | Description |
|---|---|
| `version` | Integer, monotonically increasing with each structural change |
| `scales[].id` | Immutable opaque identifier |
| `scales[].label` | Current human-readable label (mirrors `labels` map) |
| `scales[].ordinal` | Ordering integer; lower = narrower scope |
| `scales[].aliases` | Alternative ids accepted by the CLI (empty at v1) |
| `labels` | Flat id→label map; what CLIs and prompts render today |
| `label_history` | Append-only log of prior `labels` snapshots, one entry per version bump |

**`label_history` entry format:**

```json
{
  "version": 1,
  "replaced_at": "2026-04-23T06:35:02Z",
  "labels": { "...": "..." }
}
```

`version` is the registry version in which the snapshot was active *before*
the bump. The reader CLI resolves `get-label --version N <id>` by finding the
first history entry whose `version > N` and reading from that snapshot. If no
such entry exists, the current labels map applies.

---

## 3. Upward extension protocol

Upward extension adds a new scale **above the current maximum**. This is a
structural change: do it when a new category of cross-repo or system-level
insight is recognized that genuinely exceeds the scope of `architectural`.

**Steps:**

1. **Append** the new scale entry to `scales` with the next ordinal and a new
   id. The new id must be stable and descriptive.

2. **Bump** `version` (e.g., 1 → 2).

3. **Snapshot** the current `labels` map into `label_history`:
   ```json
   {
     "version": 1,
     "replaced_at": "<ISO-8601 timestamp>",
     "labels": { "<copy of current labels map>" }
   }
   ```

4. **Update** the `labels` map: add the new id; optionally relabel existing
   ids for clarity. Relabeling is appropriate when the new scale changes the
   relative meaning of an existing label (see worked example below).

5. **Update** downstream consumers structurally:
   - Work-item scope defaults (if the new scale is added to the scope enum)
   - Matrix offsets in `scale-compute.sh` (if the new scale is a valid output)
   - Adjacency is derived automatically from ordinal order by `scale-registry.sh`

6. **No entry files are touched.** Existing entries retain their captured ids.
   Display surfaces render under the new `labels` map. Entries with a stored
   `scale_registry_version` can render under their captured-at vocabulary via
   the `label_history` lookup.

7. **No full-corpus rescale required** unless `lore analyze concordance` or
   `/memory renormalize` disagreement-detection flags specific entries as
   misclassified.

---

## 4. Worked example: adding `global` above `architectural`

**Scenario:** cross-repository insights emerge that span multiple repos. A new
scale `global` is needed above `architectural`. Because `architectural` now
refers to single-repo architecture (not the broader global scope), its label
is updated to `architectural (single-repo)` to avoid ambiguity.

**Before (version 1):**

```json
{
  "version": 1,
  "scales": [
    {"id": "implementation", "label": "implementation", "ordinal": 1, "aliases": []},
    {"id": "subsystem",      "label": "subsystem",      "ordinal": 2, "aliases": []},
    {"id": "architectural",  "label": "architectural",  "ordinal": 3, "aliases": []}
  ],
  "labels": {
    "implementation": "implementation",
    "subsystem": "subsystem",
    "architectural": "architectural"
  },
  "label_history": []
}
```

**After (version 2):**

```json
{
  "version": 2,
  "scales": [
    {"id": "implementation", "label": "implementation",          "ordinal": 1, "aliases": []},
    {"id": "subsystem",      "label": "subsystem",               "ordinal": 2, "aliases": []},
    {"id": "architectural",  "label": "architectural (single-repo)", "ordinal": 3, "aliases": []},
    {"id": "global",         "label": "global",                  "ordinal": 4, "aliases": []}
  ],
  "labels": {
    "implementation": "implementation",
    "subsystem": "subsystem",
    "architectural": "architectural (single-repo)",
    "global": "global"
  },
  "label_history": [
    {
      "version": 1,
      "replaced_at": "2026-04-23T06:35:02Z",
      "labels": {
        "implementation": "implementation",
        "subsystem": "subsystem",
        "architectural": "architectural"
      }
    }
  ]
}
```

**Effect on existing entries:** entries captured at `scale_registry_version: 1`
with `scale: "architectural"` still resolve correctly. A display surface
calling `lore scale registry get-label --version 1 architectural` returns
`"architectural"` (from the v1 snapshot in `label_history`). Surfaces that
always render from the current labels map show `"architectural (single-repo)"`
for the same id.

**Effect on adjacency:** `lore scale registry get-adjacency architectural`
now returns `subsystem\nglobal` (derived from ordinals 2 and 4).

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

3. **Snapshot** the current `labels` map into `label_history` (same format as
   upward extension).

4. **Update** the `labels` map: add the new id; optionally relabel the prior
   minimum for symmetry. Relabeling is appropriate when the new scale clarifies
   what the prior minimum actually covers (see worked example below).

5. **Consider marking the prior minimum as a broad alias** for the new scale
   via `aliases` on the new scale entry. This lets legacy entries stamped with
   the old minimum id continue to resolve, while making clear that the new id
   is the more precise designation. Only add an alias if the old id genuinely
   overlaps the new one's scope.

6. **Update** downstream consumers structurally:
   - Clamp floor in `scale-compute.sh` (if the new scale is a valid output)
   - Matrix offsets if the new scale participates in role × slot pairs
   - Adjacency is derived automatically from ordinal order

7. **No entry files are touched.** Existing entries retain their captured ids.
   Renormalize may *lazily* propose `rescale` for entries it audits that appear
   misclassified — no mandatory full-corpus pass.

---

## 6. Worked example: adding `function-local` below `implementation`

**Scenario:** single-function observations accumulate that are too granular to
be meaningful at module scope. A new scale `function-local` is added below
`implementation`. Because `implementation` now specifically refers to module-
level scope, its label is updated to `implementation (module)` for symmetry.

**Before (version 1):**

```json
{
  "version": 1,
  "scales": [
    {"id": "implementation", "label": "implementation", "ordinal": 1, "aliases": []},
    {"id": "subsystem",      "label": "subsystem",      "ordinal": 2, "aliases": []},
    {"id": "architectural",  "label": "architectural",  "ordinal": 3, "aliases": []}
  ],
  "labels": {
    "implementation": "implementation",
    "subsystem": "subsystem",
    "architectural": "architectural"
  },
  "label_history": []
}
```

**After (version 2):**

```json
{
  "version": 2,
  "scales": [
    {"id": "function-local", "label": "function-local",          "ordinal": 0, "aliases": []},
    {"id": "implementation", "label": "implementation (module)", "ordinal": 1, "aliases": []},
    {"id": "subsystem",      "label": "subsystem",               "ordinal": 2, "aliases": []},
    {"id": "architectural",  "label": "architectural",           "ordinal": 3, "aliases": []}
  ],
  "labels": {
    "function-local": "function-local",
    "implementation": "implementation (module)",
    "subsystem": "subsystem",
    "architectural": "architectural"
  },
  "label_history": [
    {
      "version": 1,
      "replaced_at": "2026-04-23T06:35:02Z",
      "labels": {
        "implementation": "implementation",
        "subsystem": "subsystem",
        "architectural": "architectural"
      }
    }
  ]
}
```

**Effect on existing entries:** entries captured at `scale_registry_version: 1`
with `scale: "implementation"` still resolve correctly. A display surface
calling `lore scale registry get-label --version 1 implementation` returns
`"implementation"` (from the v1 snapshot). Surfaces rendering from current
labels show `"implementation (module)"` for the same id.

**Effect on adjacency:** `lore scale registry get-adjacency implementation`
now returns `function-local\nsubsystem` (ordinals 0 and 2). The new
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
