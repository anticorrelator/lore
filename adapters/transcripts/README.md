# Lore Transcript Provider Contract

This file is the canonical reference for how Lore's capture, digest,
novelty, and ceremony-detection scripts read session artifacts across
harnesses. Every adapter under `adapters/transcripts/` consumes this
contract.

> **Status:** Phase 5 contract — per-harness session artifact
> enumeration (T46), digest field requirements (T47), plan-
> persistence + TaskCompleted requirements (T48), and ceremony-
> detection requirements (T49) are settled. Phase 6 — novelty-
> review provider requirements (T56) — is also settled and reuses
> the Phase 5 surface without new provider operations. Per-harness
> provider implementations land in T50 (claude-code), T51 (opencode
> + codex stubs), with consumer migrations T52-T54, T57. Until those
> land, the only fully-wired transcript path is the legacy in-tree
> `scripts/transcript.py` JSONL parser used by
> `extract-session-digest.py`, `check-plan-persistence.py`,
> `stop-novelty-check.py`, and `probabilistic-audit-trigger.py` —
> which is hardcoded to Claude Code's transcript format and is the
> baseline this provider abstraction supersedes.

## Why this provider exists (D5)

Capture quality depends on session artifacts: digest extraction needs
the previous session's tool-use sequence, novelty detection needs
agent prose, plan-persistence needs the most recent assistant turn,
and ceremony detection needs the SlashCommand tool-use history. All
four of those scripts currently parse Claude Code's JSONL format
directly. **D5 from the multi-framework-agent-support plan:** add a
provider boundary so adapters translate harness-native session state
into the schema the consumer scripts already expect, without forking
the consumers.

The provider boundary's load-bearing property is *capture quality
preservation* — a harness whose artifact format cannot supply a given
field MUST mark its provider stub as permanently degraded for that
field rather than synthesizing a plausible-looking value. Synthesized
values would silently pollute the knowledge commons.

## Per-Harness Session Artifacts (T46)

The table below enumerates the session artifacts each harness exposes
today, with retrieval dates pinned to the evidence ids in
[`adapters/capabilities-evidence.md`](../capabilities-evidence.md).
Cells in **bold** mark the load-bearing artifact each provider
implementation reads.

### Claude Code

| Aspect                      | Value                                                                                                       |
|-----------------------------|-------------------------------------------------------------------------------------------------------------|
| **Primary artifact**        | **JSONL transcript at `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`**                            |
| Hook payload field          | `transcript_path` — present on SessionStart, Stop, PreCompact, SessionEnd, PreToolUse, PostToolUse hooks    |
| Per-line shape              | `{"message": {"role": "user"\|"assistant", "content": [<block>, ...]}, ...}`                              |
| Content block types         | `text` (`block.text`), `tool_use` (`block.name`, `block.input`), `tool_result` (`block.content`)            |
| Tool-input fields parsed    | `file_path`, `pattern` (Read/Edit/Write/Glob); `command` (Bash); `prompt` + tool name pairs (SlashCommand) |
| Identifying session id      | basename of `<session-uuid>.jsonl`; Claude Code does not surface the id separately in hook payloads        |
| Cross-session continuity    | One JSONL per session; `extract-session-digest.py` resolves the *previous* session by mtime within the encoded-cwd directory |
| Capability cell             | `transcript_provider=full` (evidence: `claude-code-transcript-provider`)                                    |
| Provider implementation     | `adapters/transcripts/claude-code.py` (T50) — wraps the existing `scripts/transcript.py`                    |

### OpenCode

| Aspect                      | Value                                                                                                       |
|-----------------------------|-------------------------------------------------------------------------------------------------------------|
| **Primary artifact**        | **Plugin runtime session state via `message.updated`, `session.updated`, `session.diff` events**           |
| Hook payload field          | _no equivalent of `transcript_path`_ — plugins receive event objects, not file paths                        |
| Per-event shape             | OpenCode plugin SDK objects (TypeScript); see [`adapters/opencode/lore-hooks.ts`](../opencode/lore-hooks.ts) for the captured shape |
| Persistence mechanism       | Plugin runtime persists session state on disk (location vendor-specified; not a stable user-facing path)   |
| Cross-event accumulation    | Plugin must accumulate `message.updated` events into a transcript-shaped buffer; the buffer is *the* artifact a Lore consumer can read |
| Tool-input fields available | `tool.execute.before` / `tool.execute.after` carry tool name + serialized input; format differs from Claude tool_use blocks (T51 stub translates) |
| Identifying session id      | OpenCode session uuid (passed in plugin event payloads)                                                     |
| Cross-session continuity    | _degraded_ — no documented "list previous session by mtime" surface; previous-session digest in T47 must rely on a Lore-side persistence layer (write event accumulator to `~/.lore/sessions/<harness>/<session-id>.jsonl` at end-of-turn) |
| Capability cell             | `transcript_provider=partial` (evidence: `opencode-transcript-provider`) — translates available fields, reports degraded for missing ones |
| Provider implementation     | `adapters/transcripts/opencode.py` (T51) — stub that reads the Lore-side accumulator file plus live event subscription |

### Codex

| Aspect                      | Value                                                                                                       |
|-----------------------------|-------------------------------------------------------------------------------------------------------------|
| **Primary artifact**        | **Session rollout files written to disk by default; reloaded via `codex exec resume [SESSION_ID]`**         |
| Hook payload field          | _no equivalent of `transcript_path`_ — Codex hook payloads carry session id but not a path; provider derives the rollout path from session id |
| Per-line shape              | Codex-specific (vendor-documented format; differs from Claude JSONL)                                        |
| Persistence mechanism       | Vendor-managed rollout file; opt-out via `--ephemeral` (not the default)                                    |
| Tool-input fields available | Codex hook payloads carry tool name + structured input on `PreToolUse` / `PostToolUse` (April 2026 hooks); rollout file replays the same structure |
| Identifying session id      | Codex session id from hook payload (UUID-shaped)                                                            |
| Cross-session continuity    | Native — `codex exec resume` is the documented surface (rollout file by default); previous-session digest in T47 uses the rollout file directly |
| Capability cell             | `transcript_provider=partial` (evidence: `codex-transcript-provider`) — translates available fields, reports degraded for missing ones |
| Provider implementation     | `adapters/transcripts/codex.py` (T51) — stub that reads rollout files + `codex exec resume` output         |

### Frameworks with no usable session artifacts

If a future harness exposes neither a transcript file nor a plugin
event stream sufficient to reconstruct one, its provider MUST be
shipped as a permanent-degraded stub with capability cell
`transcript_provider=none`. The capture/digest/novelty/ceremony
consumer scripts are required (per §"Consumer behavior on degraded
support" below) to emit a one-line degraded notice and exit 0
without taking the consumed action.

No closed-set framework today selects `none` — claude-code is `full`,
opencode and codex are both `partial`. The `none` row is documented
here so future adapter implementors faced with an artifact-less
harness do not invent a synthesized-transcript fallback.

## Provider Interface (Closed Set)

Every adapter exposes a closed set of read operations. The shape is
identical across adapters; the implementation language is Python
(matches the existing `scripts/transcript.py` consumers). The four
operations below are the **minimum** every provider MUST expose; T47
extends the set with three additional operations the digest consumer
requires (`read_raw_lines`, `session_metadata`, `previous_session_path`
semantics) — the full operation table is in §"Provider interface —
extended operation set (T47)" below.

| Operation                  | Inputs                                | Outputs                                                                                              |
|----------------------------|---------------------------------------|------------------------------------------------------------------------------------------------------|
| `parse_transcript`         | session_id or path                    | list of normalized message dicts (see schema below) or `[]` on degraded/missing artifact            |
| `extract_file_paths`       | session_id or path                    | list of `(file_path, message_index)` tuples drawn from tool_use blocks; `[]` on degraded            |
| `previous_session_path`    | cwd                                   | path to the second-most-recent prior session for that cwd by mtime, or `None` if cross-session continuity is unavailable |
| `provider_status`          | (no inputs)                           | one of: `full` / `partial` / `unavailable`, plus a one-line human-readable degraded reason          |

`parse_transcript` and `extract_file_paths` MUST return the same
normalized shape regardless of harness — the consumer scripts
(`extract-session-digest.py`, `check-plan-persistence.py`,
`stop-novelty-check.py`, `probabilistic-audit-trigger.py`) read this
shape directly.

### Normalized message dict schema

Every entry in the list returned by `parse_transcript` is a Python
dict with exactly these keys:

```python
{
    "index": int,                      # 0-based position in the transcript
    "role": "user" | "assistant" | "",  # speaker; empty when adapter cannot determine
    "text_blocks": list[str],          # all text content joined per-block
    "has_tool_use": bool,              # whether the message invokes any tool
    "is_tool_result": bool,            # whether the message carries a tool_result block
    "tool_names": list[str],           # tool names invoked, in order
}
```

The schema is closed: adding a field requires a contract bump and a
coordinated update of every consumer. Adapters that cannot supply a
field MUST emit the documented sentinel value (empty string for
`role`, empty list for `text_blocks` / `tool_names`, `False` for
booleans) — never `None`, never a synthesized placeholder.

## Consumer behavior on degraded support

Per the Phase 5 verification gate ("digest/capture commands fail with
a clear degraded-capability message when the active harness lacks a
transcript provider"), every consumer script MUST honor the
provider's `provider_status` return value before invoking the
consumed action:

| `provider_status`  | Consumer behavior                                                                                       |
|--------------------|---------------------------------------------------------------------------------------------------------|
| `full`             | Proceed normally; consumer reads the parsed messages and runs its full logic.                          |
| `partial`          | Proceed in degraded mode: consumer runs whatever logic the supplied fields support and emits a one-line `[lore] degraded: <consumer> via transcript_provider=partial (missing: <fields>)` stderr notice. |
| `unavailable`      | Emit `[lore] degraded: <consumer> via transcript_provider=unavailable; skipping` on stderr and exit 0 without taking the consumed action. Do NOT invent a fallback path.            |

The exit-0 contract on `unavailable` is load-bearing: these scripts
fire from hooks where a non-zero exit can interrupt the user's
session. Silent skip with stderr observability matches the
informational-feedback-style convention (degraded ≠ failed).

## Per-Consumer Field Requirements

The four consumer scripts have different field requirements. The
table below names the *minimum* fields each consumer reads from the
normalized message dict; any provider that cannot supply the listed
fields for a given consumer MUST report `partial` with that consumer
named in the degraded-fields list. Detailed inventories for each
consumer land in the follow-up tasks listed.

| Consumer                            | Minimum fields read                                                | Detailed inventory |
|-------------------------------------|--------------------------------------------------------------------|--------------------|
| `extract-session-digest.py`         | full normalized schema + raw-line scan + session metadata + `previous_session_path` (see T47 below) | §"Digest provider requirements" below (T47) |
| `check-plan-persistence.py`         | `tool_use_timestamps` for builtin-plan-mode tool name + a per-harness `builtin_plan_mode_tool` config value (see T48 below) | §"Plan-persistence provider requirements" below (T48) |
| `task-completed-capture-check.sh`   | _no transcript read_ — operates on its own stdin payload; T53 migration is a teams-path migration only | §"TaskCompleted provider requirements" below (T48) |
| `probabilistic-audit-trigger.py`    | reverse iteration over `parse_transcript` + SlashCommand tool-use shape + per-harness `slash_command_tool` config (see T49 below) | §"Ceremony-detection provider requirements" below (T49) |
| `stop-novelty-check.py`             | full schema + `extract_file_paths` for related-files; uses no new provider operations beyond Phase 5 (see T56 below) | §"Novelty-review provider requirements" below (T56) |

### Digest provider requirements (T47)

`scripts/extract-session-digest.py` consumes more than the closed
four-operation surface above — it needs (a) the *previous* session's
artifact (not the current one), (b) raw-line access for windowed
debugging-evidence extraction, and (c) two pieces of session metadata
not in the normalized message-dict schema. The provider boundary
keeps the consumer harness-agnostic, but each provider MUST surface
the fields below or report `partial` with a named gap.

#### 1. Previous-session selection

The digest extractor's first step is "find the second-most-recent
JSONL for this cwd"
([`scripts/extract-session-digest.py:276-288`](https://github.com/anticorrelator/lore/blob/main/scripts/extract-session-digest.py#L276)):

```python
def find_previous_session_file(project_dir):
    jsonl_files = list(project_dir.glob('*.jsonl'))
    if len(jsonl_files) <= 1:
        return None
    jsonl_files.sort(key=lambda f: f.stat().st_mtime, reverse=True)
    return jsonl_files[1]  # second most recent
```

This is the load-bearing semantics that `previous_session_path` MUST
preserve: **second-most-recent** by mtime, not most-recent (the
most-recent IS the current session at SessionStart hook time).
Adapters that cannot return "second-most-recent" without ambiguity
(e.g., OpenCode where session events are not atomically written to
discrete files) MUST return `None` and report `partial` for digest;
the consumer skips with the documented stderr notice rather than
running on the current session.

| Harness     | `previous_session_path` semantics                                                                |
|-------------|--------------------------------------------------------------------------------------------------|
| claude-code | `~/.claude/projects/<encoded-cwd>/*.jsonl` sorted by mtime desc, return index 1                 |
| opencode    | `None` + `partial` report (no atomic per-session file; T57's accumulator design TBD)            |
| codex       | Codex rollout directory listing sorted by mtime desc, return index 1 (same shape as claude-code) |

The OpenCode `None` result is a permanent partial-degradation rather
than a fixable gap — the digest extractor's "what just happened
*previously*" semantics presume per-session file atomicity. T57
(stop-novelty-check.py migration) is the task that decides whether
an alternative event-accumulator file format can recover this surface
on opencode.

#### 2. Raw-line access for windowed debugging extraction

`scan_for_debugging`
([`extract-session-digest.py:209-240`](https://github.com/anticorrelator/lore/blob/main/scripts/extract-session-digest.py#L209))
and `extract_debug_evidence`
([`extract-session-digest.py:128-206`](https://github.com/anticorrelator/lore/blob/main/scripts/extract-session-digest.py#L128))
both operate on the raw JSONL line list — not the parsed message
dicts — because they need *positional adjacency* (a 3-line window
around debug-pattern matches) to pull out the `tool_result` excerpts
that explain a debugging session.

Adapters MUST therefore expose a fifth operation:

| Operation             | Inputs        | Outputs                                                                               |
|-----------------------|---------------|---------------------------------------------------------------------------------------|
| `read_raw_lines`      | session_id or path | list of strings (one per JSONL line) for adapters whose artifact is line-delimited; for non-line-delimited harnesses (opencode plugin events): a synthesized list where each element is a serialized JSON event in the same order as `parse_transcript`'s `index` field |

Window-based scanning over `read_raw_lines` requires that line index
N in the raw list correspond to message index N in `parse_transcript`
output. This is the **alignment invariant** — if a provider's
`read_raw_lines[i]` does not parse to the same message as
`parse_transcript()[i]`, the digest extractor's debug-evidence
extraction silently mis-attributes assistant text to the wrong tool
call. Providers that cannot guarantee alignment MUST report
`partial`, name `read_raw_lines` in the degraded-fields list, and
the consumer skips debug-evidence extraction (proceeds with
basic digest).

| Harness     | `read_raw_lines` shape                                                                                       |
|-------------|--------------------------------------------------------------------------------------------------------------|
| claude-code | exact JSONL lines from the artifact file; alignment trivially holds (`parse_transcript` reads the same lines) |
| opencode    | synthesized list of JSON-serialized event objects from the Lore-side accumulator; alignment held by accumulator-write protocol (one event = one line, append-only) |
| codex       | synthesized list of JSON-serialized rollout entries; alignment held if rollout entries are append-only and per-event |

#### 3. Session metadata fields

Beyond the normalized message-dict schema, the digest extractor reads
two top-level fields per JSONL entry
([`extract-session-digest.py:84-90`](https://github.com/anticorrelator/lore/blob/main/scripts/extract-session-digest.py#L84)):

```python
session_id = data.get('sessionId', 'unknown')
timestamp = data.get('timestamp')
```

These are *per-line* fields in Claude's JSONL (every entry carries
its own `sessionId`/`timestamp`); the extractor only needs the values
from the first parseable entry, so `parse_transcript` MUST surface
them via a sixth operation:

| Operation             | Inputs        | Outputs                                                                               |
|-----------------------|---------------|---------------------------------------------------------------------------------------|
| `session_metadata`    | session_id or path | dict `{"session_id": str, "session_date": datetime \| None}` — values from the first parseable entry; both fields tolerate missing data with `"unknown"` / `None` sentinels |

The Phase 5 verification gate "Claude Code transcript behavior remains
unchanged behind the provider boundary" is asserted concretely here:
the `claude-code.py` provider MUST return the same `(session_id,
session_date)` pair the in-tree `parse_jsonl_file` returns today,
including the file-mtime fallback for `session_date` when `timestamp`
is absent.

| Harness     | `session_metadata` source                                                                          |
|-------------|----------------------------------------------------------------------------------------------------|
| claude-code | `data.get('sessionId')` + `data.get('timestamp')` (first parseable line); fallback: file mtime    |
| opencode    | OpenCode session uuid from plugin event payload + earliest event timestamp from accumulator       |
| codex       | Codex session id from hook payload + rollout-file first-entry timestamp                            |

#### 4. Message type discriminator

Claude's JSONL uses two top-level message-type values: `'human'` and
`'assistant'`. The digest extractor branches on this field directly
([`extract-session-digest.py:96-110`](https://github.com/anticorrelator/lore/blob/main/scripts/extract-session-digest.py#L96)),
not on the normalized schema's `role` field, because the two are
semantically distinct on Claude (top-level `type` carries the
producer-shape; `message.role` carries the speaker label).

The provider boundary collapses the distinction — adapters MUST
populate the normalized `role` field as follows:

| Source                              | Mapped `role` |
|-------------------------------------|---------------|
| Claude `type='human'`               | `"user"`     |
| Claude `type='assistant'`           | `"assistant"` |
| OpenCode plugin `message.user`      | `"user"`     |
| OpenCode plugin `message.assistant` | `"assistant"` |
| Codex rollout user entry            | `"user"`     |
| Codex rollout assistant entry       | `"assistant"` |
| Tool-result-only entries            | `""` (empty) — `is_tool_result=True` is the discriminator |

The digest extractor MUST be migrated (T52) to read the normalized
`role` field rather than the Claude-specific top-level `type` —
otherwise the provider boundary leaks a Claude-specific schema into
the consumer.

#### Summary: digest provider field requirements

To support `extract-session-digest.py`, every provider MUST supply:

- **From the closed normalized schema:** `role`, `text_blocks`,
  `has_tool_use`, `is_tool_result`, `tool_names`, `index`.
- **From `extract_file_paths`:** `(file_path, message_index)` tuples
  for Read/Edit/Write/Glob tool uses (already in the closed surface).
- **From the digest-specific extension surface:**
  `previous_session_path`, `read_raw_lines`, `session_metadata` —
  see operations table updates below.

Providers that cannot supply any of these MUST report `partial` with
the missing field named; the consumer skips the affected section
(debugging evidence, files-touched listing, or the entire digest)
rather than degrading silently.

### Provider interface — extended operation set (T47, T48)

T46's four-operation interface is a closed *minimum*; T47 added two
operations the digest consumer requires (`read_raw_lines`,
`session_metadata`); T48 added a seventh
(`tool_use_timestamps`) for the plan-persistence consumer. Adding
operations here is the schema-bump-eligible action documented in
§"Versioning". The full provider interface is:

| Operation                  | Inputs                                | Outputs                                                                                              |
|----------------------------|---------------------------------------|------------------------------------------------------------------------------------------------------|
| `parse_transcript`         | session_id or path                    | list of normalized message dicts                                                                    |
| `extract_file_paths`       | session_id or path                    | list of `(file_path, message_index)` tuples                                                          |
| `previous_session_path`    | cwd                                   | path to the second-most-recent prior session by mtime, or `None`                                    |
| `provider_status`          | (no inputs)                           | one of: `full` / `partial` / `unavailable`, plus a one-line degraded reason                         |
| `read_raw_lines`           | session_id or path                    | list of strings (one per JSONL line / serialized event), index-aligned with `parse_transcript`     |
| `session_metadata`         | session_id or path                    | `{"session_id": str, "session_date": datetime \| None}` from the first parseable entry             |
| `tool_use_timestamps`      | session_id or path, tool_name         | list of `(message_index, ISO-8601 timestamp str)` for entries whose tool_use blocks invoke `tool_name`, in transcript order |

Adapters that cannot supply `read_raw_lines` with the alignment
invariant MUST return an empty list and report `partial` with
`read_raw_lines` named in the degraded reason. Adapters that cannot
supply `session_metadata` MUST return the documented sentinels
(`"unknown"`, `None`) — never raise.

The Claude-specific `type='human'`/`type='assistant'` top-level
discriminator does NOT become a provider operation — the consumer
migration in T52 reads the normalized `role` field instead, per
§"Message type discriminator" above. Claude's `type` field maps to
`role` at provider boundary; consumers never see it.

### Plan-persistence provider requirements (T48)

`scripts/check-plan-persistence.py` is a Stop hook that detects
unpersisted use of builtin plan mode. It reads the transcript twice:
(1) a fast raw-string check for the literal `"ExitPlanMode"` substring
([`check-plan-persistence.py:39-42`](https://github.com/anticorrelator/lore/blob/main/scripts/check-plan-persistence.py#L39))
to early-exit on sessions that never touched plan mode; (2) a full
JSONL scan for the **last** ExitPlanMode tool-use entry plus its
**timestamp**, used to compare against `_work/<slug>/{plan.md,
_meta.json, notes.md}` mtimes to verify persistence happened *after*
plan mode.

The provider boundary needs to support both modes. Two requirements
beyond the T46+T47 surface:

#### 1. Tool-use entries with per-entry timestamps

`check-plan-persistence.py:46-65` walks the JSONL and pulls the
`timestamp` field from the entry that contains the
`ExitPlanMode`-named tool-use block. The normalized message-dict
schema (§"Normalized message dict schema") does not currently carry
a per-message timestamp — the digest extractor uses session-level
metadata only. Adapters MUST add a per-entry timestamp via a seventh
operation:

| Operation                  | Inputs                                | Outputs                                                                                              |
|----------------------------|---------------------------------------|------------------------------------------------------------------------------------------------------|
| `tool_use_timestamps`      | session_id or path, tool_name         | list of `(message_index, ISO-8601 timestamp str)` for entries whose tool_use blocks include the named tool, in transcript order |

Returns of an empty list mean "tool was not used in this session".
Adapters that cannot supply per-entry timestamps MUST report
`partial` with `tool_use_timestamps` named — the consumer will then
fall back to the session-end timestamp (degraded check: persistence
must follow the *session*, not the specific tool use, which has a
larger false-pass window).

| Harness     | `tool_use_timestamps` source                                                                          |
|-------------|--------------------------------------------------------------------------------------------------------|
| claude-code | `data.get('timestamp')` per JSONL entry; ISO-8601 with optional `Z` suffix                            |
| opencode    | OpenCode plugin event timestamp (per `tool.execute.before` / `message.updated` event metadata)         |
| codex       | Codex rollout entry timestamp (per-entry; format documented in capabilities-evidence.md retrieval)     |

#### 2. Builtin-plan-mode tool name (per harness)

`ExitPlanMode` is the Claude Code tool name for the builtin plan
exit. OpenCode and Codex may have analogous tool names (or may lack
the concept entirely). The hook today hardcodes the literal string
`"ExitPlanMode"`; the migration path (T53) is to read the tool name
from the active harness's capability profile rather than hardcoding.

This is **not** a provider operation but a per-harness configuration
value. The right home is `adapters/capabilities.json`, under each
framework's profile, as a `builtin_plan_mode_tool` key alongside the
existing capability cells. Frameworks without a builtin plan mode
declare `builtin_plan_mode_tool: null` and the consumer skips the
check entirely (treating it as unsupported rather than degraded).

| Harness     | `builtin_plan_mode_tool`                                                                          |
|-------------|---------------------------------------------------------------------------------------------------|
| claude-code | `"ExitPlanMode"`                                                                                  |
| opencode    | `null` (no documented equivalent — operator workflows persist plans via `/work` directly)         |
| codex       | `null` (no documented equivalent)                                                                  |

T53 is the consumer migration that wires both the
`tool_use_timestamps` operation and the `builtin_plan_mode_tool`
config lookup; T48 names the contract those wires implement.

#### 3. Knowledge-store path resolution (orthogonal to transcript provider)

`check-plan-persistence.py:80, 96-114` resolves `$KDIR/_work/` and
walks subdirectory mtimes. This is unrelated to the transcript
provider — it's the same `resolve_knowledge_dir()` path that every
Lore script consumes — but T53's migration scope includes both the
transcript-provider routing and the harness-specific
`~/.claude/teams/<team>/config.json` path resolution that
`task-completed-capture-check.sh` currently hardcodes (see below).
Listed here for completeness so T53 sees both moving parts.

### TaskCompleted provider requirements (T48)

`scripts/task-completed-capture-check.sh` does **not** read the
transcript — it operates entirely on its own stdin payload (the
TaskCompleted hook input: `team_name`, `task_description`,
`agent_name`) plus the team config file at
`~/.claude/teams/<team_name>/config.json`. Routing it through the
transcript provider would add no value because no field it reads
comes from the session transcript.

There are still two harness-coupling concerns the T53 migration MUST
address, both unrelated to the transcript provider:

#### 1. Hardcoded teams config path

`task-completed-capture-check.sh:73` reads
`$HOME/.claude/teams/$TEAM_NAME/config.json` directly. T53 routes
this through `resolve_harness_install_path teams` (the helper that
T7 added; T19 migrated agent-toggle, T29 migrated load-work, T69
migrated status). On harnesses where `teams` resolves to
`unsupported`, the hook MUST exit 0 (allow) without enforcement —
the team-completion-validation contract is moot when no team-config
surface exists.

#### 2. Per-harness team-naming convention

The hook gate fires only for `team_name` matching `impl-*` or
`spec-*` (line 63-66). This convention is stable across harnesses
because it is set by Lore's orchestration adapter
(adapters/agents/README.md §"Operation Surface" — `spawn` produces
team names following the slug rule), not by the harness. No
provider-side change needed; documented here so the T53 migration
does not accidentally generalize the prefix matching to harness-
specific names.

#### Why TaskCompleted is named in this README

It's named here because the Phase 5 plan lists it in T48 and T53
("Inventory plan-persistence + TaskCompleted provider requirements"
and "Route check-plan-persistence.py + task-completed-capture-
check.sh through providers + resolve_harness_install_path teams").
The transcript provider is not a dependency; the migration in T53
is a teams-path migration only. Future readers should not assume a
TaskCompleted entry exists in the closed transcript provider
operation table — there isn't one and there shouldn't be.

#### Summary: plan-persistence + TaskCompleted requirements

- Plan-persistence requires the seventh operation `tool_use_timestamps`
  and a per-harness `builtin_plan_mode_tool` config value in
  capabilities.json.
- TaskCompleted does NOT require the transcript provider; T53's scope
  for that hook is the `~/.claude/teams/...` → `resolve_harness_install_path
  teams` migration plus the unsupported-teams exit-0 contract.

### Ceremony-detection provider requirements (T49)

`scripts/probabilistic-audit-trigger.py` is a Stop hook that detects
recently-completed ceremony commands (`/implement`, `/spec`,
`/pr-review`, `/pr-self-review`) by scanning the transcript for the
**last** `SlashCommand` tool use whose `input.command` field begins
with one of the ceremony-name tokens
([`probabilistic-audit-trigger.py:111-146`](https://github.com/anticorrelator/lore/blob/main/scripts/probabilistic-audit-trigger.py#L111)).
When detected, the hook rolls a probability gate against
`~/.lore/config/settlement-config.json` and may dispatch
`lore audit <artifact-id>`.

The detector imposes three requirements on the transcript provider:

#### 1. Reverse iteration over messages

The detection rule is "last matching SlashCommand wins" — the hook
iterates `entries[::-1]` and returns on the first match. This is
load-bearing because a single session can contain multiple ceremony
invocations (e.g. `/spec` followed by `/implement`); only the most
recent one is what the operator just finished. Adapters MUST preserve
the message-ordering invariant in `parse_transcript`: the list MUST
be in transcript order so that reverse iteration on the consumer
side yields the most-recent invocation first.

| Harness     | Ordering source                                                                                  |
|-------------|--------------------------------------------------------------------------------------------------|
| claude-code | JSONL line order = message order (already-parsed `messages` list preserves it)                  |
| opencode    | Plugin event accumulator append-order = message order (write-side contract per T57 design)      |
| codex       | Rollout file entry order = message order                                                         |

The `parse_transcript` schema's `index` field is the canonical
ordering anchor — adapters that emit messages out of insertion order
MUST preserve `index` such that sorting by `index` yields the
on-disk order.

#### 2. SlashCommand tool-use shape

Claude Code's `SlashCommand` tool surfaces the user's slash-prefixed
command via `input.command`
([`probabilistic-audit-trigger.py:135-145`](https://github.com/anticorrelator/lore/blob/main/scripts/probabilistic-audit-trigger.py#L135)):

```python
if block.get("name") != "SlashCommand":
    continue
args = block.get("input", {}) or {}
cmd_raw = str(args.get("command") or "").strip()
if cmd_raw.startswith("/"):
    cmd_raw = cmd_raw[1:]
first_token = cmd_raw.split()[0].lower() if cmd_raw else ""
```

OpenCode and Codex do not use a tool called `SlashCommand` — they
either fire slash-commands as native UI gestures (no tool_use entry)
or surface them through different tool names. The detector's current
hardcoded `"SlashCommand"` string is Claude-specific and MUST move to
a per-harness config value:

| Harness     | `slash_command_tool`                                                                              |
|-------------|---------------------------------------------------------------------------------------------------|
| claude-code | `"SlashCommand"`                                                                                  |
| opencode    | TBD by T26 — depends on whether OpenCode plugins receive a synthetic tool_use for slash commands |
| codex       | `null` if Codex slash commands do not produce tool_use entries; ceremony detection then degrades  |

Same shape as `builtin_plan_mode_tool` (T48): a per-harness static
config value living in `adapters/capabilities.json.frameworks.<fw>.slash_command_tool`,
with `null` declaring unsupported.

#### 3. Command-text parsing contract

The detector strips a leading `/`, splits on whitespace, and lowercases
the first token. Adapters MUST surface the raw command string the user
typed, not a normalized or hash-routed form. If a harness only exposes
the resolved skill name (e.g., already-stripped of `/` and arguments),
it MUST report `partial` for `slash_command_tool` and the hook
degrades gracefully (no roll, no dispatch).

The `CEREMONY_COMMANDS` token set
(`{"implement", "pr-self-review", "pr-review", "spec"}`) is closed
and lives in the consumer script — it is **not** a per-harness config.
Lore's ceremonies are protocol-level, not harness-level; the same
token set applies regardless of active framework.

#### Summary: ceremony-detection requirements

- Reverse iteration over `parse_transcript` results (consumer-side
  pattern; the provider must preserve message ordering via the
  `index` field).
- SlashCommand tool-use detection — consumer reads `tool_names`
  + `parse_transcript` body, but the per-harness tool name MUST come
  from `adapters/capabilities.json.frameworks.<fw>.slash_command_tool`
  rather than be hardcoded.
- Command-text fidelity — providers MUST surface the user's raw
  slash-command string, not a pre-normalized form.

T54 is the consumer migration that wires both the
`slash_command_tool` config lookup and the transcript-provider
routing; T49 names the contract those wires implement. The
`builtin_plan_mode_tool` (T48) and `slash_command_tool` (T49) keys
are the only two per-harness tool-name lookups documented in this
contract — neither is a provider operation; both are
capabilities.json config values.

### Novelty-review provider requirements (T56, Phase 6)

`scripts/stop-novelty-check.py` is the largest transcript consumer
(1262 lines). It runs as a Stop hook to detect uncaptured insights
via heuristic + structural signals + FTS5 novelty scoring; on
detection, it writes `_pending_captures/<id>.md` files for first-turn
review at the next session start. Phase 6 isolates this migration
from Phase 5's narrower consumers because the read pattern is
fundamentally the same as the existing consumers — but the
analytical surface (heuristic patterns, structural signals, related-
files extraction) is large enough that a separate phase keeps the
contract clean.

Three categories of provider requirements emerge from the read of
`stop-novelty-check.py:1140-1262` (main flow) and the helpers it
imports from `scripts/transcript.py`:

#### 1. Operations covered by the existing T46+T47+T48 surface

The novelty checker's core loop reuses exactly the operations
already documented in this README — no new provider operations are
required for the read path:

| Operation                  | Read site (line range)              | Consumed via                                                     |
|----------------------------|-------------------------------------|------------------------------------------------------------------|
| `parse_transcript`         | `stop-novelty-check.py:1157`       | iterates `messages` for heuristic + structural pattern scanning   |
| `extract_file_paths`       | `stop-novelty-check.py:570, 890`   | `scan_structural_signals` + `extract_related_files` Read-tool detection |
| `provider_status`          | (called by every consumer at start) | `unavailable` → exit 0 with stderr notice (matches Phase 5 contract) |

`previous_session_path` and `session_metadata` are NOT used by the
novelty checker — it operates on the *current* session's transcript
only, never the previous one. `read_raw_lines` is also NOT used —
all detection work happens on the parsed message list. This means
the novelty checker is robust to OpenCode's `previous_session_path
= None` gap, unlike `extract-session-digest.py` (T47).

#### 2. Consumer-side helpers that move to the provider boundary

Three helpers in `scripts/transcript.py` are pure functions over the
normalized message-dict list. They read no transcript-format-
specific fields; they belong on the **provider-shipped helpers**
rather than as new operations, because every provider's
`parse_transcript` output already supports them:

| Helper                | Source                          | Inputs                              | Outputs |
|-----------------------|---------------------------------|-------------------------------------|---------|
| `count_tool_uses`     | `transcript.py:129-131`        | list of normalized message dicts    | int     |
| `has_recent_capture`  | `transcript.py:134-146`        | list of normalized message dicts    | bool    |
| `extract_text_blocks` | (proposed; today inline)        | list of normalized message dicts    | list of (index, text) — consolidates the `for m in messages: for text in m["text_blocks"]:` pattern that appears 14 times in stop-novelty-check.py |

These helpers MUST live in a shared `adapters/transcripts/_shared.py`
(or equivalent), imported by every adapter and consumer. They are
**not** provider operations — they're a thin convenience layer over
the closed normalized schema, identical in implementation across
harnesses. Documenting them as provider operations would force every
adapter to re-implement identical Python; documenting them as a
shared module preserves the "schema is closed; helpers are derived"
distinction.

T57 is the consumer migration that imports from
`adapters/transcripts/_shared` instead of `scripts/transcript`.

#### 3. Novelty-detection-specific patterns that stay in the consumer

Three novelty-checker patterns operate on the message list but are
**too domain-specific** to belong in the provider boundary or its
helpers — they encode novelty-checker policy, not transcript
semantics:

| Pattern                                | Source                                                             | Why stays in consumer                                                |
|----------------------------------------|--------------------------------------------------------------------|----------------------------------------------------------------------|
| `_is_team_session` (Agent/SendMessage detection) | `stop-novelty-check.py:1162`                                       | Tests for tool-name membership in a curated set; tied to Lore's orchestration vocabulary, not transcript shape |
| `_count_lead_tool_uses` (lead-vs-fanout split)   | `stop-novelty-check.py:1168`                                       | Filters by tool name + role pattern matching team coordination; orchestration-specific |
| `_build_team_exclusion_set`            | `stop-novelty-check.py:1204`                                       | Builds index range to exclude agent-coordination window from heuristic scan; novelty-policy-specific |
| `scan_heuristics`, `scan_structural_signals`, `score_novelty`, `and_gate` | `stop-novelty-check.py:511, 1205-1221` | Novelty-detection logic; should never see transcript format directly |

The provider boundary's job is to give these patterns *parsed
messages* and let them operate over the normalized schema; T57 is
the migration that wires them up by replacing the direct
`scripts/transcript` import with the provider call. No provider-side
changes are required to support them.

#### 4. _pending_captures write path (orthogonal to transcript provider)

`write_pending_captures` (`stop-novelty-check.py:1021`) writes
`<knowledge_dir>/_pending_captures/<id>.md` files. This path is
unrelated to the transcript provider — it's resolved via
`resolve_knowledge_dir()` (the same KDIR resolver every Lore
script consumes). Listed here for completeness so T57 sees both
moving parts.

#### Summary: novelty-review requirements

- The novelty checker's *read* path requires zero new provider
  operations beyond what T46+T47+T48 already define. It uses
  `parse_transcript` + `extract_file_paths` + `provider_status` only.
- Three consumer-side helpers (`count_tool_uses`, `has_recent_capture`,
  and a new `extract_text_blocks`) move to a shared
  `adapters/transcripts/_shared.py` module — not as provider
  operations but as a thin convenience layer over the closed
  normalized schema. T57 imports from there instead of from
  `scripts/transcript`.
- Novelty-policy patterns (`_is_team_session`, `_count_lead_tool_uses`,
  heuristic scanners, FTS5 scoring) stay in
  `scripts/stop-novelty-check.py` — they are not transcript-shape
  concerns and do not belong on the provider boundary.

The Phase 6 verification gate is therefore narrower than Phase 5's:
"`stop-novelty-check.py` runs through the transcript provider
boundary without changing detection or scoring behavior." T57 is
the lane that delivers it; the contract surface T56 documents is a
reuse-the-existing-operations claim, not a schema bump.

## Adapter Responsibilities

Every adapter (T50 claude-code, T51 opencode + codex stubs) MUST tick
the following items before it is considered Phase 5 complete.

1. **Mirror the operation set.** Every adapter file exposes exactly
   the operations listed in §"Provider interface — extended operation
   set (T47, T48)" — seven operations as of T48 (T46 minimum four +
   `read_raw_lines` + `session_metadata` from T47 + `tool_use_timestamps`
   from T48). Adding a further operation requires a schema bump to
   `adapters/capabilities.json:.version` and a coordinated rewrite of
   all three adapters.
2. **Honor the closed schema.** Returns from `parse_transcript` /
   `extract_file_paths` MUST match the normalized schema byte-for-byte
   on the field names; missing values use the documented sentinels.
3. **Report degraded honestly.** `provider_status` MUST return
   `partial` whenever any field is sentinel-only because the artifact
   format does not carry it. Returning `full` while quietly emitting
   sentinels is a contract violation.
4. **Surface degraded-mode reason.** The second return of
   `provider_status` is human-readable and surfaces the missing
   fields by name (e.g., `"role unavailable; opencode plugin events
   carry message text but not speaker label"`).
5. **No synthesized values.** Adapters MUST NOT invent file paths,
   tool names, or text content from absent fields. The capture commons
   integrity depends on never-falsified inputs; a synthesized
   `tool_names: ["Read"]` row would silently turn a Read-tool novelty
   detector into a Read-or-anything detector.

## Per-Harness Mapping (Today)

| Operation                  | claude-code (T50)                                              | opencode (T51 stub)                                              | codex (T51 stub)                                              |
|----------------------------|----------------------------------------------------------------|------------------------------------------------------------------|---------------------------------------------------------------|
| `parse_transcript`         | wraps existing `scripts/transcript.py::parse_transcript`        | reads Lore-side event accumulator file (degraded for `role` reliability) | reads Codex rollout file (degraded for tool_input field-shape) |
| `extract_file_paths`       | wraps existing `scripts/transcript.py::extract_file_paths`      | translates `tool.execute.before` events; same Read/Edit/Write/Glob filter | translates Codex `PreToolUse` payloads                        |
| `previous_session_path`    | mtime-scan within `~/.claude/projects/<encoded-cwd>/`          | _unavailable_ (no documented vendor surface; T47 may add a Lore-managed sentinel) | reads Codex rollout directory listing                         |
| `provider_status`          | `full`                                                         | `partial` (missing reliable cross-session continuity)             | `partial` (rollout file format coverage incomplete)            |

## Implementation Targets

| Adapter file                                  | Owner task | Purpose                                                              |
|-----------------------------------------------|------------|----------------------------------------------------------------------|
| `adapters/transcripts/claude-code.py`         | T50        | Reference impl. Wraps the existing `scripts/transcript.py` parser without behavior change. |
| `adapters/transcripts/opencode.py`            | T51        | Stub that reads OpenCode plugin event accumulator; reports `partial`. |
| `adapters/transcripts/codex.py`               | T51        | Stub that reads Codex rollout files; reports `partial`.              |
| `scripts/extract-session-digest.py`           | T52        | Route through provider instead of importing `scripts/transcript.py` directly. |
| `scripts/check-plan-persistence.py`           | T53        | Route through provider; respect `provider_status=unavailable` exit-0 contract. |
| `scripts/task-completed-capture-check.sh`    | T53        | Route through provider for any transcript-derived field (T48 confirms scope). |
| `scripts/probabilistic-audit-trigger.py`     | T54        | Route ceremony detection through provider; degrade to no-roll on `unavailable`. |
| `scripts/evidence-append.sh`                  | T55        | Continue functioning when the provider is degraded (does not depend on transcript fields today; verified). |
| `scripts/stop-novelty-check.py`              | T57        | Phase-6 migration; provider extension for novelty review fields.     |

## Cross-cutting touchpoints

- **D8 evidence-gating.** Every per-harness cell value
  (`full` / `partial` / `none`) MUST resolve to a dated evidence id in
  [`adapters/capabilities-evidence.md`](../capabilities-evidence.md).
  The current cells reference `claude-code-transcript-provider`,
  `opencode-transcript-provider`, `codex-transcript-provider`. When a
  harness's artifact format changes, the evidence id MUST be
  re-retrieved and the dated retrieval line updated before the cell
  value moves.
- **D5 capture quality preservation.** The provider boundary exists
  to preserve the memory loop documented in
  [[knowledge:architecture/knowledge/retrieval/three-layer-knowledge-delivery-architecture]];
  it is not a transparent passthrough that hides degradation. Per-
  consumer field requirements (T47-T49) are the input to "is the
  capture loop still wired" judgements that `/retro` and the
  scorecard pipeline depend on.
- **Closed-set framework rejection.** Adapters resolve the active
  framework via `resolve_active_framework` (lib.sh) /
  `config.ResolveActiveFramework` (Go); same closed-set rule as the
  hook adapters per [[knowledge:gotchas/hooks/hook-system-gotchas]].

## Versioning

This contract is versioned implicitly via
`adapters/capabilities.json:.version` (currently `1`). Adding an
operation, changing the message-dict schema, or introducing a new
sentinel value requires a schema bump and a coordinated rewrite of
all three adapters plus the consumer migrations in T52-T54, T57.
T47 extended the operation set from four to six (adding
`read_raw_lines` + `session_metadata` for the digest consumer); T48
extended it from six to seven (adding `tool_use_timestamps` for
plan-persistence). T49 added two per-harness config keys — neither
is a new provider operation: `builtin_plan_mode_tool` (T48) and
`slash_command_tool` (T49) live in
`adapters/capabilities.json.frameworks.<fw>.<key>`. T56 (novelty
review) follows the same schema-bump rule.
