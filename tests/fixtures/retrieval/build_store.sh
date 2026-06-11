#!/usr/bin/env bash
# build_store.sh — Build a deterministic knowledge store for retrieval golden tests.
# Usage: bash build_store.sh <target_dir>
#
# The store is the shared input for every surface covered by
# tests/test_retrieval_goldens.sh: lore search/query, prefetch-knowledge.sh,
# load-knowledge.sh, resolve-manifest.sh. Entry content uses the "widget"
# vocabulary with varied term density so BM25 ordering is stable.

set -euo pipefail

KDIR="${1:?Usage: build_store.sh <target_dir>}"

mkdir -p "$KDIR"/{architecture,conventions,gotchas,workflows,principles,preferences,domains,_meta} \
         "$KDIR/_work/fixture-item"

cat > "$KDIR/_manifest.json" << 'EOF'
{"format_version": 2, "created_at": "2026-01-01T00:00:00Z"}
EOF

# --- Knowledge entries (fixed learned dates; varied scale labels) ---

cat > "$KDIR/architecture/widget-pipeline-overview.md" << 'EOF'
# Widget Pipeline Overview

The widget pipeline has three stages: intake parses widget specs, assembly
composes widget parts, and shipping emits finished widgets. The widget
pipeline owns ordering between stages.
<!-- learned: 2025-01-15 | confidence: high | source: manual | related_files: scripts/widget.sh | template_version: fix1 | scale: architecture | scale_registry_version: 1 -->
EOF

cat > "$KDIR/conventions/widget-naming.md" << 'EOF'
# Widget Naming

Widget identifiers use kebab-case slugs. Every widget pipeline stage prefixes
its logs with the widget slug so cross-stage traces line up.
<!-- learned: 2025-02-20 | confidence: high | source: manual | related_files: scripts/widget.sh | template_version: fix1 | scale: subsystem | scale_registry_version: 1 -->
EOF

cat > "$KDIR/gotchas/widget-cache-stale.md" << 'EOF'
# Widget Cache Stale Reads

The widget assembly cache serves stale widget parts when the intake stage
rewrites a spec in place. Bust the cache key on every widget spec rewrite.
<!-- learned: 2025-03-10 | confidence: high | source: manual | related_files: scripts/widget-cache.sh | template_version: fix1 | scale: subsystem,implementation | scale_registry_version: 1 -->
EOF

cat > "$KDIR/workflows/widget-release.md" << 'EOF'
# Widget Release Steps

Run widget-release.sh --dry-run first, inspect the widget manifest diff, then
run it again without the flag to ship widgets.
<!-- learned: 2025-04-05 | confidence: medium | source: manual | related_files: scripts/widget-release.sh | template_version: fix1 | scale: implementation | scale_registry_version: 1 -->
EOF

cat > "$KDIR/principles/widget-abstraction-law.md" << 'EOF'
# Widget Abstraction Law

When multiple consumers compose the same widget primitive, policy lives in
the primitive, never per consumer. Duplicated widget policy drifts.
<!-- learned: 2025-01-30 | confidence: high | source: manual | related_files: scripts/widget.sh | template_version: fix1 | scale: abstract | scale_registry_version: 1 -->
EOF

cat > "$KDIR/conventions/widget-superseded.md" << 'EOF'
# Widget Legacy Wire Format

Widgets serialize to the v1 wire format with positional widget fields.
<!-- learned: 2024-06-01 | confidence: low | source: manual | related_files: scripts/widget.sh | template_version: fix1 | scale: subsystem | scale_registry_version: 1 | status: superseded -->
EOF

cat > "$KDIR/preferences/widget-review-preference.md" << 'EOF'
# Review Widget Diffs Stage By Stage

When reviewing widget pipeline changes, review one stage at a time and name
the stage in the review summary.
<!-- learned: 2025-05-01 | confidence: high | source: manual | related_files: scripts/widget.sh | template_version: fix1 | scale: subsystem | scale_registry_version: 1 -->
EOF

cat > "$KDIR/domains/widget-domain.md" << 'EOF'
# Widget Domain

Deep widget domain notes, lazy-loaded on demand. Widget telemetry schema and
widget retention windows live here.
<!-- learned: 2025-02-01 | confidence: high | source: manual | related_files: scripts/widget.sh | template_version: fix1 | scale: subsystem | scale_registry_version: 1 -->
EOF

# --- Work item (matched by load-knowledge context signal + resolve-manifest) ---

cat > "$KDIR/_work/fixture-item/_meta.json" << 'EOF'
{
  "title": "Widget pipeline consolidation",
  "slug": "fixture-item",
  "status": "active",
  "branch": "fixture-branch",
  "tags": ["widget", "pipeline"],
  "created_at": "2026-01-02T00:00:00Z"
}
EOF

cat > "$KDIR/_work/fixture-item/notes.md" << 'EOF'
Consolidating the widget pipeline stages.
See [[knowledge:conventions/widget-naming]] for slug rules.
EOF

cat > "$KDIR/_work/fixture-item/plan.md" << 'EOF'
# Widget pipeline consolidation

### Stage intake widget specs
### Stage assembly widget parts
EOF

cat > "$KDIR/_work/fixture-item/tasks.json" << 'EOF'
{
  "phases": [
    {
      "name": "v2 directive phase",
      "retrieval_directive": {
        "version": 2,
        "topics": [
          {
            "role": "focal",
            "topic": "widget pipeline",
            "scale_set": ["subsystem", "implementation"],
            "limit": 3
          },
          {
            "role": "adjacent",
            "topic": "widget cache",
            "scale_set": ["subsystem"],
            "limit": 2
          }
        ]
      }
    },
    {
      "name": "legacy directive phase",
      "retrieval_directive": {
        "seeds": ["widget pipeline"],
        "hop_budget": 0,
        "scale_set": ["subsystem", "implementation"]
      }
    }
  ]
}
EOF

cat > "$KDIR/_work/fixture-item/scope_pointers.jsonl" << 'EOF'
{"route_id": "r1", "protocol_slot": "implement-step-3", "source": "worker", "target_scope_hint": "widget pipeline", "payload": "Intake stage rewrites specs in place; assembly cache key must include spec hash."}
{"route_id": "r2", "protocol_slot": "spec-research", "source": "researcher", "target_scope_hint": "unrelated tooling", "payload": "Tooling concern that should not match the widget query."}
EOF
