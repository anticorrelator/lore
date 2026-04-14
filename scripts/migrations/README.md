# Migrations

This directory holds one-shot migration scripts. Each script addresses a specific data-format change, runs once per host, and is safe to delete from the tree after it has been run everywhere it needs to be. These are not part of the normal lore runtime — they exist only to bridge between format versions.

## Current scripts

- **`followup-archive.sh`** — Walks every per-repo knowledge store under `~/.lore/repos/*/*/*/` and moves follow-ups with terminal status (`reviewed`, `promoted`, `dismissed`) from `_followups/` into `_followups/_archive/`. Prints a dry-run summary and prompts before acting unless invoked with `--yes`. Idempotent: a second run finds nothing to migrate.
