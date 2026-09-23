## Organization Protocol

Captures are filed automatically by `lore capture` — no manual inbox-to-category step is needed.

Quality is kept where the judgment is cheapest, which is almost always the turn that holds the context:
- The capturing session titles its entry and settles any similar entry capture reports (see Capture Protocol).
- A session that finds an entry contradicted corrects it, and one that finds an entry no longer earning its place retires it (see Self-Healing).

None of this waits for a periodic pass, so no session suggests one — not after a run of captures, and not for a duplicate it could settle itself.

`/memory curate` and `/renormalize` remain for work the in-band checks don't reach:
- duplicate pairs among older entries
- medium-confidence entries awaiting verification
- entries anchored to files that have since been deleted
- structural reorganization

Both run when the owner chooses. `lore curate` shows what either would find.
