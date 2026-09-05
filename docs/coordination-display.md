# Coordination display reads

The coordination view reads a committed operational snapshot. Board rows,
attention, activity, and selected events share its store identity and generation.
Full `coordinate status` remains an explicit evidence inspection and stays
read-only unless a wake receipt is requested.

`lore coordinate read --kdir PATH --json` reads the committed display.
`--refresh` attempts nonblocking maintenance; `--reconcile` requests metadata
reconciliation and one journal batch; `--rebuild` discards derived SQLite state
and starts recovery. `--arc SLUG` requests historical detail. Repeat maintenance
while coverage reports catching up. No display snapshot establishes current code
freshness or authorizes a dispatch.

The disposable files live under `_coordination`: `display.sqlite3` holds source
fingerprints, member event summaries, and cursors; `display.json` is its atomic
export. `display-archive.json` has a separate identity and loads only when archives
are revealed or that identity changes. Deleting derived state does not change
canonical sources. Readers retain their previous display during rebuild or error.

Same-store windows share a nonblocking updater lease and a five-second refresh
clock. Store identity is the resolved knowledge directory, including through
symlinks. Warm TUI reads launch no subprocess. Background maintenance has a
separate host limit of two and oldest-request-first retry admission; abandoned
admission tickets expire after 30 seconds. Cheap reads never wait for either
background maintenance or the expensive evidence-process pool.

A maintenance pass consumes at most 256 KiB of journal bytes and 128 metadata
records during reconciliation. Metadata discovery periodically lists directory
names; it does not read historical ledger/document bodies. Sweeps retain their
position across processes. Active summaries remain global regardless of the
viewport. Selected-detail requests drain oldest first, eight per pass; the
export retains up to 64 historical selections. Large visible active sets still
cost proportionally to their operational state. Revealing an archive catalog
costs proportionally to that catalog once per change identity.

Metadata reconciliation starts every 30 seconds, and can take multiple passes.
Direct edits to active or selected sources are observed on maintenance; edits
elsewhere converge through reconciliation. Coverage reports the last observation,
last completed reconciliation, sweep progress, journal positions, and diagnostics.
An absent timestamp is unknown. Reading an old export does not refresh those times.

Journal cursors bind to file identity. Replacement, truncation, and same-size
rewrites start a new source epoch. Partial rows remain uncovered until terminated;
oversized rows advance a bounded pending buffer and become diagnosed gaps when
complete. Invalid typed events are excluded individually with persistent byte
positions. Each member retains its last eight events in source order and its
maximum valid timestamp independently; adding membership exposes prior events.
Matching both `slug` and `links.work_item` does not duplicate an event.

The canonical journal is append-only. Changing an already consumed prefix while
growing the same inode violates that contract and requires `--rebuild`; ordinary
maintenance does not verify prefix integrity or rescan that history. Reconciliation
is source observation, not a continuous file watcher. A stopped updater leaves an
explicitly stale view until another window or explicit maintenance resumes it.
