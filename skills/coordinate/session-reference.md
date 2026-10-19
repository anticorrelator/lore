# Session verb reference — disclosed from skills/coordinate/SKILL.md

What a verb's `--help` does not say: how the verbs relate, what a refusal means for the seat, and the calibrations behind the skill's rules. Flags and exit codes are in each verb's `--help`.

## Knowledge packets

```bash
lore packet build --work-item <slug> --role <role> --caller coordinator --topic "<assignment>" --scale-set <scales>
lore packet synthesize <packet-id> --by coordinator --drop <path> "<why>" --add <path> "<why>"
```

`build` returns a candidate set; its status object describes assembly, not whether the context answers the assignment. A vague `--topic` retrieves unrelated entries, so write the real topic and pass `--seeds`. Synthesize before the packet travels: drop what the receiver should not carry and add what retrieval missed, one reason each. Synthesis happens once per pull, only delivered paths can be dropped, and only undelivered entries can be added. `position-bind` refuses an unsynthesized packet unless its builder recorded a `synthesis_waiver`.

Hand on the pointer, not the bodies: `--packet <id>` on `lore session start`, or `lore dispatch guidance --short --packet <id>` for a harness-native spawn.

## Managed sessions

```bash
lore session start <item> --workspace <source-checkout> --context <brief> --packet <packet-id> --key <dispatch-id> --json
```

This starts the store's host if it is not running, seeds the item's source checkout if none is declared, and refuses a conflicting one. It also allocates a session-owned worktree and returns a durable handle for `send`, `answer`, `peek`, `wait`, `inspect`, `attach` and `close`. The handle survives a host restart. Retrying with an identical key joins the same start; a changed brief or model under that key refuses; no key starts a new worker. A human may `attach` without taking over the session's lifecycle.

A worker finishes by landing its report (`lore coordinate report <item> --report-id <id>`, body on stdin), then running `lore session close --self --reason protocol_terminus`. Say both in the brief. A `delivery-uncertain` refusal means an input crossed a crash with no provable outcome; inspect the worker, because the input is never replayed. Contract: [docs/session-manager.md](../../docs/session-manager.md).

The guidance floor rides every managed brief. For harness-native spawns, prepend the complete stdout of `lore dispatch guidance` before every launch and retry. Parallelism runs through sessions and subagents, not stacked Skill calls.

## Request placement

The store's session host claims every request in the store, and `lore session request` starts it when none is running. Each request runs in one checkout of that store:
- A slugged request runs in its item's `source_checkout`. Seed it with `lore work source-checkout <slug>` from inside that checkout.
- A slugless request names its checkout with `--prefer-dir <path>` or `--prefer-cwd`. Inside a session, `--prefer-cwd` means the session's source checkout, not its worktree.

A refusal names its repair; read it before retrying. The request file is deleted on every terminal path, so the journal's `requested` row is the record.

Seat-owned trees (below) cannot host worker sessions. Hosted workers get a session-owned worktree from the store host.

## Worktrees and dispositions

A session's guard identity (`tui/internal/worktree/guard.go`) records the worktree's paths, the generation it started from and its target ref. Every spawn, adoption, publish and cleanup revalidates it and fails closed on a mismatch. `teardown-pending` keeps ownership while a process's death is unresolved.

At close, a session's result is `published`, `worktree_quarantined` or `restore_refused`. Publish fast-forwards the destination only when its HEAD is the allocation base and both trees are clean, and it adds a `worktree_published` row naming the destination; anything else quarantines. Refusal or quarantine leaves the destination byte-for-byte unchanged and keeps the result under a durable result ref/patch. Quarantine preserves content, not the physical directory, so a quarantined result is integration work for the seat even after its directory is gone. A session whose worktree, Git directory and source checkout are all missing on this machine (a store copied from elsewhere) is retired once with a `repository_gone` reason rather than retried.

Hosted Claude Code sessions run under a session-scoped write allowlist at the tool call (`scripts/guard-session-worktree-writes.sh`). It allows the session's own checkout, the store outside the worktree namespaces, and the temp dir, and journals a refused write as `worktree_write_refused`. It reads structured file paths only, so check a cross-checkout edit made through the shell rather than assume the fence caught it.

## Seat-allocated trees

`lore coordinate worktree` is the sole manager of seat-allocated stream trees. Allocation authority stays with the dispatching seat: a mutating subagent runs only in a tree allocated to its seat and never allocates. An item-backed worker session gets its tree from the store host instead, and read-only agents need none. Lifecycle: `reserved → bound → active|recovered → quiescent → reconciling → cleanup_due → removed`. Release is removal, and a failed removal returns to `reconciling`, so re-driving the release is the retry. A 900-second lease held by the session or seat protects the tree, and a live owner protects it at any age. Reconciliation freezes an immutable source manifest and an integrated manifest before cleanup. A removal that cannot be proven stays `cleanup_blocked`, and the stream is not done until it is proven: path absence, Git-registry absence (`git worktree list --porcelain`), and branch/ref disposition.

Integrate on the stable control checkout. Merge or cherry-pick the stream's commits and verify with the project's pre-push gate (`lore search --preferences "pre-push gate"`), not the stream's targeted runs. Record the SHA and the counts in the ledger. On conflict, abort and record the paths. The seat decides the composition where existing contracts settle it, the worker makes source edits in its own tree, and an anchor or directive change escalates. Run watchers and seat control from the stable checkout, never from a stream tree.

## Steering

`send` works mid-generation on every current harness. It refuses when a modal is up or the composer already holds text, and `--wait` reports the outcome; a timed-out send may still land.

`answer <slug> --option <N> --expect <literal>` acts only while the live screen still shows that numbered modal with your expected text; otherwise it refuses before writing a key. Keys are never replayed, so read a timeout as unknown and peek. A `standing_decisions.modal_answers` entry may pre-authorize one exact modal signature.

`close` is full-discretion and journals everything. A failed close moves the guard to `teardown-pending` and keeps the registry row while the process may still write.

## Events, wait and peek

`lore session events --since <cursor>` ends with a `{"next_cursor": N}` row. Cursors are opaque, so store them verbatim. `--cursor-only` baselines without replay. To measure a teardown, take the baseline before closing.

`lore session wait <slug>` matches the exact slug (`--work-item` adds the item's derived `<item>--w<n>` workers) and stops by default on the actionable set: `closed`, `close_failed`, `orphaned`, `terminus_reached`, `needs_input`, `modal_blocked`, `restore_refused`, `worktree_quarantined`. Exit 4 is a reader failure, never a timeout.

`lore session peek <handle> --summary --json` returns the current observation: activity, authority and matcher evidence. `ready` means a message can be accepted, including mid-turn. `unknown` is a limit of observation, so read the screen. An idle composer is not task completion.

## Arm and watch

`lore arc open` arms the standing eye unless `--no-watcher` is passed; `lore coordinate arm` is the manual override. It needs `--install` or `--render`, plus `--owner-pid` (the long-lived harness process, not a subshell) or `--owner-tmux`. On Claude Code the entry is a `Stop` hook with `asyncRewake` whose timeout exceeds the watch window. The window ends itself with an exit-2 wake, and a timeout kill is silent and never re-arms. That holds in interactive sessions only: headless `claude -p` runs hooks synchronously. Codex and OpenCode have no async re-wake, so the seat opens each window itself. Branch on the capability in `adapters/capabilities.json`, not the framework name.

Entries are scoped to store, owner and arcs, and install into `.claude/settings.local.json` by default. Hosted Claude workers in the same repository's worktrees load that file too, so the entry also fires at their turn ends; it exits as `foreign` in the window log, and that is expected. Disarm is idempotent, and one wake from the window already running is expected afterwards. `lore arc close` disarms an entry scoped only to the closing arc. If the first expected wake never arrives, read `_coordination/arm-window-<identity>.log`.

`lore coordinate watch` follows the journal and also reconciles live sessions every 15 s, so a missed journal edge still surfaces. `--arc <slug>` scopes it to the arc's members and their `<item>--w<n>` workers. A durable wake keeps its `wake_id` until `lore coordinate status --wake-id <id>` acknowledges it; redelivery is not a new event. A just-spawned session in pre-submit startup reads like a park and is not one, so compare the wake's event time to the spawn time. `--full-evidence --receipt-only` expands a compact wake.

Tiers: `confirmed` is a fresh idle or blocked state, actionable on sight. `advisory` names why no strict signature matched: evidence that is unavailable, unknown, stale or superseded. `quiet` is the heartbeat. Authority names what the verdict rests on: `hook-row`, `screen-signature`, `runtime`, `observation`, `owner-handle` or `none`. A wrong screen verdict on an idle session is signature drift; keep the screen and refresh the fixture rather than retry the read.

## The evidence spine

`lore work show <slug> --json` returns the item's `evidence`: plan revision, per-criterion results with freshness, sealed reviews, packets and sources. `lore plan revise <slug>` publishes a revision; `--decision-for <revision-id>` records a decision (anchor coverage; dispatch, wait, or reuse a review) without one. `lore criteria run <slug> <task-id> <criterion-id>` executes a declared criterion and writes its row. `lore plan review prepare` freezes a review's input, and `lore plan review seal` publishes its judgment.

## Arc close

`lore arc close` records the closure and disarms arc-scoped watchers. The cost tally comes from the journal's `closed` events; sessions still running at close, and streams a human started, are not in it. If a retro over the arc reported health as degraded or not computable, say so at close. Write anything for the owner from the ledger and the artifacts, not from memory of the conversation.

## Calibrations

The incidents behind the skill's rules. Status: **in skill** (prose carries it) or **mechanized** (a verb enforces it). A row leaves when its rule becomes stance or a verb takes it over.

- **07-16.** A plan amended after finalization stalled the next implement session → run `lore work regen-tasks` in the same act. *In skill.*
- **08-11.** Protocol text never quotes the human; rules are written in the skill's own voice. *In skill.*
- **08-13.** A rung-2 worker ran `lore impl start` on a spec-less item and parked → rung-1/2 briefs say which ceremony they omit. *In skill.*
- **08-17.** A weekend of quiet wakes against a human-gated board → disarm when the board is wholly human-gated. *In skill.*
- **08-20.** Dispatches inherited an earlier arc's framework override → an override needs a live, ledgered reason per dispatch. Underfilled items are mis-sizing, just like over-ceremony. *In skill.*
- **08-26.** Delegated specs made needless architecture decisions → the seat holds conceptual integrity, and rung-3 specs carry a strawman. *In skill.*
- **09-01 to 09-03.** Owner: the seat may take a stream over, and make small confident corrections directly → hard edge 2 is a judgment with a test. *In skill.*
- **09-04.** The coordination panel's rows were unreadable cold → the Step cell is a plain headline, and each closure appends to `digest.md`. A "comments minimal" preference failed to travel → preferences travel as the test that checks them, and the seat reads a few instances back at close. *In skill.*
- **09-05.** A wake for a just-finalized spec was read as a park → compare the event time to the spawn time. *In reference* (§ Arm and watch). The skill had grown to 8,400 words → rewritten as stance, hard edges and vocabulary, with mechanics moved here. *In skill.* Evidence: [[work:ceremony-ladder-route-symmetry]].
- **09-06.** `/remember` closes every arc, at every size. *In skill.*
- **10-01.** CI failed after local verification on 58% of PRs with a PR-caused failure → `/pr-create` rebases, runs the pre-push gate and watches CI; integration uses the same gate. *In skill.* Evidence: Phoenix store `_work/datagen-per-app-projects/worker-reports/ci-failure-investigation-r1.md`.
- **10-19.** A live shakedown ran real workers through the background host. Hosted workers load the source checkout's `.claude/settings.local.json` → the armed entry fires at their turn ends and exits as `foreign`. *In reference* (§ Arm and watch). Evidence: [[work:live-shakedown-hook-reported-lifecycle-on-real-cla]].

Mechanized rows that have left this list (model on every spawn, role-routed framework and model, identity-scoped watcher entries, publish only by fast-forward, the composer-band steer gate) are in git history and their work items.
