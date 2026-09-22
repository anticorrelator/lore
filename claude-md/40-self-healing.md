## Self-Healing

- Regenerate missing `_index.md` or `_manifest.json` when encountered
- Correct contradicted entries when you encounter the relevant topic during normal work — `lore correct <entry>`, in that turn, not noted for later
- Consolidate duplicates when noticed
- Use `/memory heal` for full structural repair

The form that lands first time:

```bash
lore correct <entry-path> --file <absolute-path> --line-range <N-M> --exact-snippet "<verbatim>" \
  --rationale "<why the code falsifies the entry>" --claim-text "<the entry's assertion>" \
  --falsifier "<what would disprove your reading>" \
  --superseded-text "<entry text being replaced>" --replacement-text "<what it becomes>" \
  --confidence <high|medium|low> --evidence-scope <single-callsite|multi-callsite|systemic> \
  --claim-scale <implementation|subsystem|architecture|abstract>
```

`--source` defaults to interactive and `--work-item` is optional, so a bare session files one. Exit 3 means the evidence cannot carry a correction — confidence below high, or one call site against a claim above implementation scale — and nothing was written: re-run with `--dispute --dispute-note "<what you saw and why you did not correct>"` in place of the replacement flags, leaving a dated marker for the next agent whose context can settle it. Either way the trust ledger records a grounded contradiction. An entry that is wrong is corrected; one that is merely unneeded is retired (`lore retire`).

## Resolve Knowledge Path

To find the knowledge directory for the current project:
```bash
lore resolve
```
