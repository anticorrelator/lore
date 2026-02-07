---
name: memory
description: Manage the per-project knowledge store — organize inbox, add entries, search, view, and heal
user_invocable: true
argument_description: "[command] [args] — organize | add <category> <title> | search <query> | view [category] | heal | init"
---

# /memory Skill

Manages the per-project knowledge store.

## Resolve the Knowledge Path

First, resolve the knowledge directory:
```bash
bash ~/.lore/scripts/resolve-repo.sh
```

## Commands

Parse the user's arguments to determine which command to run. If no arguments are given, decide the appropriate action from context (e.g., if inbox has items, organize; otherwise show the index).

### `/memory organize`

Process the inbox (Pass 2 operation):

1. Read `_inbox.md` from the knowledge directory
2. If empty (no `## [` entries), report "Inbox is empty — nothing to organize" and stop
3. For each entry, present a **1-line summary** to the user:
   ```
   Pending inbox entries:
   1. [workflows] GraphQL schema rebuild requires tox command after Python changes
   2. [gotchas] Symlink removal needed before type checking
   3. [domains/evaluators] Evaluators use template-method pattern with BaseEvaluator
   ```
4. File each entry into the appropriate category file:
   - Read the target category file
   - Append a new `### Heading` entry in the organized format:
     ```markdown
     ### Brief Descriptive Title
     Concrete insight in 1-5 sentences. Cross-reference with [[backlinks]].
     See also: [[related-file]], [[domains/topic]].
     <!-- learned: YYYY-MM-DD | confidence: high|medium|low | source: code-exploration -->
     ```
   - If a domain file doesn't exist yet, create it with a `# Topic` header and add it to `_index.md`
   - Deduplicate: if a similar entry already exists, merge or skip
   - Add `[[backlinks]]` to cross-reference related entries in other files
5. Clear `_inbox.md` (keep the header, remove all entries)
6. Update `_index.md` if new domain files were created
7. Run `bash ~/.lore/scripts/update-manifest.sh`
8. Report what was filed: "Organized 3 entries: 1 to workflows, 1 to gotchas, 1 to domains/evaluators"

**User veto:** If the user objects to any entry ("drop the 3rd one", "that's wrong"), remove it from the inbox without filing.

### `/memory add <category> <title>`

Quick-add directly to a category file (bypasses inbox):

1. Resolve knowledge directory
2. If the category file doesn't exist, create it (and update index for domain files)
3. Prompt the user for the insight content, or use any content they provided after the title
4. Append entry in organized format with `### <title>` heading
5. Run `bash ~/.lore/scripts/update-manifest.sh`

### `/memory search <query>`

Search the knowledge store:

1. Run `bash ~/.lore/scripts/search-knowledge.sh "<query>"`
2. For the top matches, read the relevant sections and present a summary
3. Include any unfiled inbox matches

### `/memory view [category]`

View knowledge:

- No argument: Read and display `_index.md`
- With category: Read and display the specified category file (e.g., `workflows.md`, `domains/evaluators.md`)
- Special: `view inbox` shows `_inbox.md`

### `/memory heal`

Full structural repair:

1. Resolve knowledge directory
2. Check for missing files: `_index.md`, `_manifest.json`, `domains/` directory
3. Regenerate `_index.md` by scanning all `.md` files and their `[[backlink]]` patterns
4. Run `bash ~/.lore/scripts/update-manifest.sh`
5. Check for empty category files (only header, no entries) — note but don't delete them
6. Check for entries with `confidence: low` older than 90 days — flag for review
7. Look for duplicate entries across files — report them
8. Run `python3 ~/.lore/scripts/pk_search.py check-links` to scan for broken `[[backlinks]]` — report any that reference missing files or headings
9. Check active plans for staleness: if `notes.md` mtime is >14 days old, flag as stale
10. Report all findings and repairs

### `/memory init`

Initialize knowledge store for current project:

1. Run `bash ~/.lore/scripts/init-repo.sh`
2. Report the created path and structure
