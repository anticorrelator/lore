# Session observation

`lore session peek <handle> --json` answers two independent questions: what the session is doing, and whether it can accept an instruction. A working session can accept queued input. An idle session is not necessarily finished with its assigned task.

Managed JSON puts the snapshot under `response`; raw session peek returns it directly. `ready` retains its input-eligibility meaning. `observation.activity` describes the current lifecycle evidence:

| Activity | Meaning |
|---|---|
| starting | A new or recovered screen has not yet settled enough to classify. |
| working | Current activity chrome identifies a running turn. |
| idle | A supported settled-turn signature identifies an idle composer. |
| blocked | A recognized interactive prompt is holding input. |
| unknown | The available evidence does not establish a lifecycle state. |
| exited | The runtime observed process exit. |

The observation includes its authority, capture time, session generation, owning instance, freshness bound, and matcher evidence. A host restart changes the instance; adopting the same surviving worker preserves its generation. Unknown or unavailable observations include the reason. Output silence, screen animation, and a visible composer alone cannot establish that a worker needs attention.

Peek returns the screen rows, framework, screen geometry, and recognized modal details. Use `--raw` for ANSI styling. The screen is the current terminal viewport, not the entire transcript. Its extent is explicit so a short screen is not mistaken for a complete response. When the result depends on work outside that screen, read the worker's saved artifact. A successful peek observes state; it never submits terminal input.

For a blocked session, read the modal title and options. When `modal.answerable` is true, choose the intended response and use `lore session answer` with an expectation copied from that observation. Otherwise use the harness's supported interaction; visible option labels do not imply numbered-answer support. The answer verb rechecks its own input boundary. An old peek is evidence of what was seen then, not permission to answer a changed dialog.

## Bounded reads

Use `lore session peek <handle> --summary --json` for current activity, input eligibility, identity, freshness, and recognized modal evidence without terminal rows. This is an observation of the current state; it does not summarize the worker's reasoning or certify task completion.

Read retained terminal history explicitly:

```bash
lore session peek <handle> --lines 100 --max-bytes 4096 --json
lore session peek <handle> --before <cursor> --lines 100 --json
```

The history object lives under `response.history` for managed sessions. It carries its source, snapshot identity, capture/expiry times, retained extent, returned rows, byte bound, truncation, and next cursor. Current lifecycle evidence stays under `response.observation` and is always read from the live screen. Older history cannot establish current activity.

Pages belong to an immutable captured snapshot so new terminal output cannot move the rows between reads. Snapshots expire after two minutes and may be evicted earlier under the bounded cache limit. The cursor is scoped to that snapshot and session; an expired, invalid, or wrong-session cursor fails explicitly. Start a new history request to obtain a fresh snapshot. History is retained scrollback, with explicit limits where the source cannot provide it; it is not a complete transcript or a permanent recording.

A page defaults to a 4KiB content budget and supports up to 16KiB and 500 requested rows. `--raw` includes styling within the page budget. Oversized or unavailable content is reported explicitly. `--summary` cannot be combined with history or raw output. Plain peek retains its existing live-viewport behavior. These reads do not submit input or scroll the user's live session.

## Watcher behavior

The watcher interprets activity independently of input eligibility and reconciles historical park events with current state. Periodic observation catches sessions whose relevant journal edge was missed. A failed observation remains visible as uncertainty and does not silently terminate periodic wakes.

Quiet windows still end in coordinator wakes. The default window remains 600 seconds. These turns preserve the established monitoring cadence; cache retention depends on the actual provider behavior and is not a correctness condition for watching.

Installed watchers retain pending wake payloads until explicit receipt. Wake identifiers distinguish redelivery from a new event. Receiving the same identifier twice is safe; it does not authorize repeating instructions to a worker. Read and acknowledge a durable wake with `lore coordinate status --wake-id <id>`. The command returns its saved payload alongside the board and acknowledges after successful output. Acknowledgment establishes receipt, not completion of the action the wake suggests.

Harness wake capabilities remain explicit. An asynchronous hook can wake an idle coordinator; a synchronous continuation has different scheduling behavior; a harness with no continuation channel requires its supported caller-driven watch loop. Persisting a notification does not create a missing harness delivery channel.

Installed durable watcher notifications use a compact presentation with an aggregate 8KiB bound. They show meaningful changes, current evidence, and explicit omitted counts, with a command for inspecting the exact saved evidence. Quiet notifications omit unchanged screen content. Full captured evidence remains in the durable record; a smaller notification is not permission to discard the evidence behind its classification.

For caller-driven compact monitoring, use `lore coordinate watch --compact --owner-pid <owner> --json`; compact mode enables durable delivery and requires an owner. `lore coordinate status --wake-id <id>` returns the compact receipt with the board. Add `--full-evidence --receipt-only` when only the saved detail is needed, without the unrelated board. The notification’s retrieval command includes the correct knowledge-store location. Both receipt reads retain the explicit acknowledgment semantics above. Legacy raw watch and non-durable wake-shaped output remain compatible.
