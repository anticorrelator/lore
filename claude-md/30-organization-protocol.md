## Organization Protocol

When prompted at session start (inbox has pending items), run `/memory organize`:
- Present a brief 1-line summary of each pending entry before filing
- File all entries into correct category files, merge with existing content, deduplicate
- Add `[[backlinks]]` to cross-reference related entries
- Update `_index.md` and run `update-manifest.sh`
- If the user objects to any entry ("drop the 3rd one", "that's wrong"), remove it immediately
- May restructure taxonomy (split files, create domain files) when it improves organization

**Safety valve:** If `_inbox.md` exceeds ~10 entries mid-session, prompt inline organization.
