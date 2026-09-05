from pathlib import Path


def sources(knowledge_dir):
    for source_id, dirname in (
        ("preferences-tree", "preferences"),
        ("conventions-tree", "conventions"),
        ("cross-cutting-conventions-tree", "cross-cutting-conventions"),
    ):
        root = Path(knowledge_dir) / dirname
        paths = sorted(str(p.relative_to(knowledge_dir)) for p in root.rglob("*.md")) if root.is_dir() else []
        yield source_id, str(root), paths


def population(knowledge_dir):
    return [{"label": Path(path).stem, "path": path, "source_id": source_id}
            for source_id, _, paths in sources(knowledge_dir) for path in paths]
