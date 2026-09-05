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

For a blocked session, read the modal title and options, choose the intended response, and use `lore session answer` with an expectation copied from that observation. The answer verb rechecks its own input boundary. An old peek is evidence of what was seen then, not permission to answer a changed dialog.

## Watcher behavior

The watcher interprets activity independently of input eligibility and reconciles historical park events with current state. Periodic observation catches sessions whose relevant journal edge was missed. A failed observation remains visible as uncertainty and does not silently terminate periodic wakes.

Quiet windows still end in coordinator wakes. The default window remains 600 seconds. These turns preserve the established monitoring cadence; cache retention depends on the actual provider behavior and is not a correctness condition for watching.

Installed watchers retain pending wake payloads until explicit receipt. Wake identifiers distinguish redelivery from a new event. Receiving the same identifier twice is safe; it does not authorize repeating instructions to a worker. Read and acknowledge a durable wake with `lore coordinate status --wake-id <id>`. The command returns its saved payload alongside the board and acknowledges after successful output. Acknowledgment establishes receipt, not completion of the action the wake suggests.

Harness wake capabilities remain explicit. An asynchronous hook can wake an idle coordinator; a synchronous continuation has different scheduling behavior; a harness with no continuation channel requires its supported caller-driven watch loop. Persisting a notification does not create a missing harness delivery channel.
