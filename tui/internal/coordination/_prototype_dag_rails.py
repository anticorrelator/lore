#!/usr/bin/env python3
# PROTOTYPE — THROWAWAY. Not production. Delete freely.
#
# Question: does git-log-graph-style rail rendering of a coordination arc's
# step ledger read well at real arc sizes (3-8 streams)?
#
# Rules under test:
#   - Kahn topo sort, ties broken by ledger declaration order
#   - lowest-free-lane rail assignment (first child reuses parent's lane)
#   - status glyphs for the pinned vocabulary, unknown statuses verbatim
#   - dangling deps and cycles rendered as explicit warnings, never crashes
#
# Run: python3 tui/internal/coordination/_prototype_dag_rails.py

# ---------------------------------------------------------------- fixtures

# Real arc: trust-orientation-rework (declaration order is ledger append order)
REAL = [
    # (stream_id, label, depends_on, status, tree)
    ("1", "fix session-start delivery race", [], "done", "writer"),
    ("2", "capture settlement experiment", [], "done", "writer"),
    ("6", "capture hardening: sibling-store refusal", [], "done", "writer"),
    ("3", "/spec full: orientation rewrite", ["2"], "done", "writer"),
    ("7", "implement rewrite; STOP at owner gate", ["3"], "in-flight", "writer"),
    ("8", "age-gate transient modal wakes", [], "done", "writer"),
    ("4", "vocabulary sweep: courtroom register", ["3"], "pending", "writer"),
    ("5", "protocol-layer sorting", ["3"], "pending", "read-only"),
]

MINIMAL = [
    ("S1", "spec auth", [], "done", "writer"),
    ("S2", "impl auth", ["S1"], "blocked-on-input", "writer"),
    ("S3", "integrate", ["S1", "S2"], "pending", "writer"),
]

# Adversarial: dangling dep, cycle, unknown status, dropped, diamond fan-in
ADVERSARIAL = [
    ("a", "schema", [], "done", "writer"),
    ("b", "left leg", ["a"], "in-flight", "writer"),
    ("c", "right leg", ["a"], "blocked-on:b", "writer"),
    ("d", "diamond join", ["b", "c"], "pending", "writer"),
    ("e", "refers to ghost", ["zz"], "pending", "writer"),
    ("f", "abandoned path", ["a"], "dropped", "writer"),
    ("g", "novel status", [], "parked-for-review", "read-only"),
    ("x", "cycle one", ["y"], "pending", "writer"),
    ("y", "cycle two", ["x"], "pending", "writer"),
]

# Wide fan-out stress: one root, five dependents, then a join
WIDE = [
    ("root", "walking skeleton", [], "done", "writer"),
    ("w1", "worker one", ["root"], "done", "writer"),
    ("w2", "worker two", ["root"], "in-flight", "writer"),
    ("w3", "worker three", ["root"], "in-flight", "writer"),
    ("w4", "worker four", ["root"], "pending", "writer"),
    ("w5", "worker five", ["root"], "blocked-on-input", "writer"),
    ("join", "assemble + verify", ["w1", "w2", "w3", "w4", "w5"], "pending", "writer"),
]

# ---------------------------------------------------------------- glyphs

GLYPHS = {
    "done": "✓",
    "in-flight": "●",
    "pending": "○",
    "blocked-on-input": "▲",
    "dropped": "✕",
}
# blocked-on:<ref> handled specially; unknown statuses render verbatim.


def status_cell(status):
    if status in GLYPHS:
        return GLYPHS[status], status
    if status.startswith("blocked-on:"):
        return "◈", status  # ref shown in text column
    return "?", status + " (?)"  # unknown vocabulary: verbatim + marker


# ---------------------------------------------------------------- topo

def toposort(rows):
    """Kahn with declaration-order tie-break. Returns (order, dangling, cyclic)."""
    ids = [r[0] for r in rows]
    byid = {r[0]: r for r in rows}
    dangling = {}  # node -> [missing refs]
    deps = {}
    for sid, _, dd, _, _ in rows:
        good = [d for d in dd if d in byid]
        missing = [d for d in dd if d not in byid]
        if missing:
            dangling[sid] = missing
        deps[sid] = good
    indeg = {sid: len(deps[sid]) for sid in ids}
    children = {sid: [] for sid in ids}
    for sid in ids:
        for d in deps[sid]:
            children[d].append(sid)
    order = []
    ready = [sid for sid in ids if indeg[sid] == 0]  # declaration order
    while ready:
        n = ready.pop(0)
        order.append(n)
        for c in children[n]:
            indeg[c] -= 1
            if indeg[c] == 0:
                # insert preserving declaration order among ready
                ready.append(c)
                ready.sort(key=ids.index)
    cyclic = [sid for sid in ids if sid not in order]
    # deterministic cycle break: append cyclic nodes in declaration order,
    # dropping the back-edges that keep them cyclic
    order += cyclic
    return order, deps, children, dangling, set(cyclic)


# ---------------------------------------------------------------- variant A: rails

def render_rails(rows, cell_w=2):
    ids = [r[0] for r in rows]
    byid = {r[0]: r for r in rows}
    order, deps, children, dangling, cyclic = toposort(rows)
    lanes = []  # lane i -> target node id or None
    out = []
    for n in order:
        sid, label, dd, status, tree = byid[n]
        incoming = [i for i, t in enumerate(lanes) if t == n]
        if incoming:
            col = min(incoming)
        else:
            col = next((i for i, t in enumerate(lanes) if t is None), len(lanes))
            if col == len(lanes):
                lanes.append(None)
        # free incoming lanes
        for i in incoming:
            lanes[i] = None
        # spawn lanes for children (skip back-edges into already-placed nodes)
        kids = [c for c in children.get(n, []) if c not in order[: order.index(n) + 1]]
        spawned = []
        for k, c in enumerate(kids):
            if k == 0 and lanes[col] is None:
                lanes[col] = c
                continue  # first child reuses node's lane: no visual spawn needed
            j = next((i for i, t in enumerate(lanes) if t is None), len(lanes))
            if j == len(lanes):
                lanes.append(None)
            lanes[j] = c
            spawned.append(j)
        # ---- draw the row
        width = len(lanes)
        cells = []
        glyph, stat_txt = status_cell(status)
        touched = set(incoming) | set(spawned) | {col}
        lo, hi = (min(touched), max(touched)) if touched else (col, col)
        for i in range(width):
            if i == col:
                cells.append(glyph)
            elif i in incoming:
                cells.append("╯" if i > col else "╰")
            elif i in spawned:
                cells.append("╮" if i > col else "╭")
            elif lo < i < hi:
                cells.append("┿" if lanes[i] is not None or any(
                    t == n for t in lanes) else "─")
                # pass-through lane crossed by a horizontal run
                if lanes[i] is not None:
                    cells[-1] = "┿"
                else:
                    cells[-1] = "─"
            elif lanes[i] is not None:
                cells.append("│")
            else:
                cells.append(" ")
        # horizontal fill between cells on the merge/spawn span
        line = ""
        for i, ch in enumerate(cells):
            line += ch
            if i + 1 < len(cells):
                line += "─" if lo <= i < hi and not (ch == " " and cells[i + 1] == " ") and (lo < i + 1 <= hi or lo <= i < hi) and (min(lo, col) <= i < max(hi, col)) else " "
        gutter_w = max(2 * len(lanes) - 1, 8)
        line = line.ljust(gutter_w)
        badges = []
        if sid in dangling:
            badges.append("⚠ dep?" + ",".join(dangling[sid]))
        if sid in cyclic:
            badges.append("⟳ cycle")
        ro = " ·ro" if tree == "read-only" else ""
        badge_s = ("  " + " ".join(badges)) if badges else ""
        out.append(f" {line}  {sid:<5} {label:<38} {stat_txt}{ro}{badge_s}")
    return "\n".join(out)


# ---------------------------------------------------------------- variant B: no rails, waits-text

def render_flat(rows):
    byid = {r[0]: r for r in rows}
    order, deps, children, dangling, cyclic = toposort(rows)
    out = []
    for n in order:
        sid, label, dd, status, tree = byid[n]
        glyph, stat_txt = status_cell(status)
        unresolved = [d for d in deps[sid] if byid[d][3] != "done"]
        waits = f"  waits: {', '.join(unresolved)}" if unresolved else ""
        badges = []
        if sid in dangling:
            badges.append("⚠ dep?" + ",".join(dangling[sid]))
        if sid in cyclic:
            badges.append("⟳ cycle")
        ro = " ·ro" if tree == "read-only" else ""
        badge_s = ("  " + " ".join(badges)) if badges else ""
        depth = 0
        seen, frontier = set(), list(deps[sid])
        while frontier:
            depth += 1
            nxt = []
            for d in frontier:
                if d in seen or d not in byid:
                    continue
                seen.add(d)
                nxt += deps.get(d, [])
            frontier = nxt
        indent = "  " * depth
        out.append(f" {indent}{glyph} {sid:<5} {label:<38} {stat_txt}{ro}{waits}{badge_s}")
    return "\n".join(out)


# ---------------------------------------------------------------- main

FIXTURES = [("REAL: trust-orientation-rework (8 streams)", REAL),
            ("MINIMAL (3 streams)", MINIMAL),
            ("ADVERSARIAL (dangling/cycle/unknown/dropped/diamond)", ADVERSARIAL),
            ("WIDE FAN-OUT (1 root -> 5 -> join)", WIDE)]

if __name__ == "__main__":
    for name, fx in FIXTURES:
        print("=" * 78)
        print(name)
        print("=" * 78)
        print("--- variant A: rails (git-log-graph gutter) ---")
        print(render_rails(fx))
        print()
        print("--- variant B: depth-indent + waits-text (no rails) ---")
        print(render_flat(fx))
        print()
