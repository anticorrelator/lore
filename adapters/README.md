# Adapters

Lore runs from two language sides that must agree on every config-resolution
question:

- `scripts/lib.sh` — bash side, sourced by every shell helper, hook, and
  the CLI dispatch in `cli/lore`.
- `tui/internal/config/config.go` — Go side, used by the TUI for in-process
  decisions (which binary to spawn, what flags to pass, which model to
  request).

The bash side is the primary surface (most lore code is shell), but the Go
TUI must reach the same answer for every shared question — otherwise the
TUI launches subprocesses with different config than the shell helpers see.
This document is the **dual-implementation contract**: a closed list of
helpers that exist on both sides, the JSON shapes they read, the
precedence ladder they walk, and the parity-test expectation enforced by
`tests/frameworks/harness_args.bats` (T12).

Adding a helper to one side without the other is a contract violation:
the next bats parity run is expected to fail.

---

## Files in this directory

| File | Owner | Purpose |
|---|---|---|
| `capabilities.json` | T2 | Static capability profile per harness; lore code branches on capability support, not framework name (D1). |
| `capabilities-evidence.md` | T1 | Dated vendor-doc evidence backing every non-`none` capability cell (D8). |
| `roles.json` | T3 | Closed agent-role registry; `resolve_model_for_role <role>` consults this list before per-repo / user role→model bindings (D10). |
| `README.md` | T11 | This document. |

Subdirectories that ship later in the migration:

| Path | Phase | Purpose |
|---|---|---|
| `adapters/hooks/` | Phase 3 | Per-harness hook installers (claude-code.sh, opencode/lore-hooks.ts, codex/hooks.sh) and the dispatch contract README. |
| `adapters/agents/` | Phase 4 | Per-harness orchestration adapters (claude-code.sh, opencode.sh, codex.sh) plus completion-enforcement degradation modes. |
| `adapters/transcripts/` | Phase 5 | Transcript/session providers (claude-code.py, opencode.py, codex.py) for digest, plan-persistence, ceremony-detection, and novelty review. |

---

## Persisted config files (the inputs)

The dual-implementation helpers all consume the same on-disk files written
by `install.sh` and the migration helpers. Both sides MUST read the same
files in the same precedence order.

| File | Writer | Schema |
|---|---|---|
| `$LORE_DATA_DIR/config/framework.json` | `install.sh` (T4), edited via `cli/lore framework set-*` (T61) | `{"version": 1, "framework": "<id>", "capability_overrides": {<cap>: <support_level>, ...}, "role_bindings": {<role>: <model>, ...}}` |
| `$LORE_DATA_DIR/config/harness-args.json` | `install.sh` (T4) and `migrate_claude_args_to_harness_args` (T8) | `{"version": 1, "_deprecated_legacy_source"?: "<path>", "<framework-id>": {"args": ["..."]}, ...}` |
| `$LORE_DATA_DIR/config/claude.json` | (legacy; left in place as historical record) | `{"args": ["..."]}`. Read on first run, migrated into `harness-args.json["claude-code"].args`, then never read again. |
| `adapters/capabilities.json` | committed in repo (T2) | See file header for full schema. |
| `adapters/roles.json` | committed in repo (T3) | See file header for full schema. |

`$LORE_DATA_DIR` defaults to `~/.lore` and may be overridden via the
`LORE_DATA_DIR` env var on both sides. The Go side resolves
`os.Getenv("LORE_DATA_DIR")` then falls back to
`filepath.Join(home, ".lore")`; the bash side uses
`${LORE_DATA_DIR:-$HOME/.lore}`. The two MUST agree byte-for-byte.

---

## Dual-implementation helpers

Every helper named below exists on both sides. The Go and bash names differ
by convention (Go: PascalCase exported, bash: snake_case). The contract is
**identical inputs produce identical outputs** for a given config snapshot.

The "Status" column tracks per-task delivery. Cells marked `pending` mean
the helper exists on one side but not the other yet, and the dual-impl
contract is intentionally violated until the named task ships. Workers MUST
NOT add a one-sided helper without a tracking task that schedules the
parity restoration.

### load_harness_args / LoadHarnessArgs

| Side | Symbol | File:line |
|---|---|---|
| bash | `load_harness_args` | `scripts/lib.sh:431` |
| Go | `LoadHarnessArgs` | T10 — `tui/internal/config/config.go` (pending) |

**Signature:** `load_harness_args [framework]` / `LoadHarnessArgs(framework string) []string`. The argument is optional/empty-string-default; when absent, both sides resolve the active framework via the `resolve_active_framework` helper.

**Precedence ladder (must match exactly):**

1. `LORE_HARNESS_ARGS` env var (JSON array). Applies regardless of framework.
2. `LORE_CLAUDE_ARGS` env var (JSON array). Honored only when the resolved framework is `claude-code`; logs a one-shot deprecation notice.
3. `$LORE_DATA_DIR/config/harness-args.json` `[<framework>].args` (canonical multi-harness shape).
4. `$LORE_DATA_DIR/config/claude.json` `.args` (legacy; honored only when framework is `claude-code`. The `migrate_claude_args_to_harness_args` helper runs before step 3 so first-read migrates).
5. Built-in default: `--dangerously-skip-permissions` for `claude-code`; empty slice for any other framework (the flag is Anthropic-specific).

**Output:** ordered list of CLI args. The bash side prints one arg per line so the caller can `mapfile -t HARNESS_ARGS < <(load_harness_args)`; the Go side returns `[]string`.

**Parity test (T12):** Seed a temp `$LORE_DATA_DIR` with each row of the precedence ladder, then call both `load_harness_args claude-code` and `LoadHarnessArgs("claude-code")`. The two outputs MUST be element-wise equal. Repeat for `opencode` and `codex`.

**Deprecated alias:** `load_claude_args` (bash) and `LoadClaudeConfig` (Go) remain as one-shot-warning shims that delegate to the harness-args helper with framework `"claude-code"`. They read no other framework slot. Remove one release after every caller has migrated.

### migrate_claude_args_to_harness_args / MigrateClaudeArgsToHarnessArgs

| Side | Symbol | File:line |
|---|---|---|
| bash | `migrate_claude_args_to_harness_args` | `scripts/lib.sh:390` |
| Go | `MigrateClaudeArgsToHarnessArgs` | T10 — `tui/internal/config/config.go` (pending) |

**Signature:** `migrate_claude_args_to_harness_args` / `MigrateClaudeArgsToHarnessArgs() error`. No arguments — both sides discover paths via `$LORE_DATA_DIR`.

**Idempotent four-gate early-return:** returns silently when (a) `harness-args.json` already exists, (b) `claude.json` is missing, (c) jq is unavailable (bash only; Go uses encoding/json), or (d) `claude.json` does not have an `.args` array.

**Atomic write:** `harness-args.json` MUST be written via a `tmp + mv` sequence so concurrent readers never see a half-written file. The bash side uses `jq ... > $new.tmp && mv $new.tmp $new`; the Go side must use `os.CreateTemp` + `os.Rename` in the same parent directory.

**Migration shape:**

```json
{
  "version": 1,
  "_deprecated_legacy_source": "/path/to/legacy/claude.json",
  "claude-code": { "args": [...legacy args verbatim...] }
}
```

**Parity test (T12):** Seed a temp `$LORE_DATA_DIR` with a legacy `claude.json` only. Run the bash helper, capture the resulting `harness-args.json`. Reset, run the Go helper, capture again. Both files MUST parse to the same JSON object under `sort_keys` canonicalization (semantic equality). Byte equality is not asserted because `jq` preserves filter-emission order while Go's `json.MarshalIndent` sorts keys alphabetically — a noisy difference without semantic consequence. If a future caller needs byte-equal output, T10's `MigrateClaudeArgsToHarnessArgs` should switch to a manual key-ordered writer to match jq's order.

### resolve_active_framework / ResolveActiveFramework

| Side | Symbol | File:line |
|---|---|---|
| bash | `resolve_active_framework` | `scripts/lib.sh:522` |
| Go | `ResolveActiveFramework` | T10 — `tui/internal/config/config.go` (pending) |

**Signature:** zero args. Returns the active framework id on stdout / as a `(string, error)` pair.

**Precedence ladder:**

1. `LORE_FRAMEWORK` env var (any non-empty value, validated against the shipped `capabilities.json` frameworks set).
2. `$LORE_DATA_DIR/config/framework.json` `.framework`.
3. Built-in default: `"claude-code"`.

**Validation:** the resolved id MUST appear as a key under `adapters/capabilities.json[.frameworks]`. An unknown framework name is rejected with a non-zero exit / non-nil error and a stderr / wrapped-error message naming the source. Resolution NEVER silently routes to a default for an explicit-but-bogus value (per "don't reintroduce defaults" feedback).

**Parity test (T12):** Seed a temp `$LORE_DATA_DIR` with each row of the ladder. Both sides MUST return the same framework id; for the bogus-id case, both MUST return non-zero exit / non-nil error.

### framework_capability / FrameworkCapability

| Side | Symbol | File:line |
|---|---|---|
| bash | `framework_capability` | `scripts/lib.sh:563` |
| Go | `FrameworkCapability` | T10 — `tui/internal/config/config.go` (pending) |

**Signature:** `framework_capability <capability>` / `FrameworkCapability(cap string) (string, error)`. Returns the support level (`full`, `partial`, `fallback`, `none`).

**Precedence ladder:**

1. `$LORE_DATA_DIR/config/framework.json` `.capability_overrides.<cap>` (operator override seeded by install.sh).
2. `adapters/capabilities.json` `.frameworks.<active>.capabilities.<cap>.support` (static profile, where `<active>` comes from `resolve_active_framework`).
3. Fallback: `"none"`.

**Parity test (T12):** For every (framework, capability) pair, both sides return the same support level. Override rows in `framework.json` apply on both sides identically.

### framework_model_routing_shape / FrameworkModelRoutingShape

| Side | Symbol | File:line |
|---|---|---|
| bash | `framework_model_routing_shape` | `scripts/lib.sh:609` |
| Go | `FrameworkModelRoutingShape` | T10 — `tui/internal/config/config.go` (pending) |

**Signature:** zero args. Returns `"single"` or `"multi"`.

**Source:** `adapters/capabilities.json` `.frameworks.<active>.model_routing.shape`. No env override; no per-repo override. The shape is a property of the harness, not user preference — operators who disagree must file a capability override on a different field.

**Parity test (T12):** Both sides return identical shapes for each shipped framework.

### resolve_model_for_role / ResolveModelForRole

| Side | Symbol | File:line |
|---|---|---|
| bash | `resolve_model_for_role` | `scripts/lib.sh:637` |
| Go | `ResolveModelForRole` | T10 — `tui/internal/config/config.go` (pending) |

**Signature:** `resolve_model_for_role <role>` / `ResolveModelForRole(role string) (string, error)`.

**Precedence ladder:**

1. `LORE_MODEL_FOR_<ROLE>` env var (uppercased role name; e.g. `LORE_MODEL_FOR_LEAD`).
2. `$KDIR/.lore.config` per-repo `[model.role]` table (when present; consumed by `parse_lore_config`).
3. `$LORE_DATA_DIR/config/framework.json` `.role_bindings.<role>` (user-level binding).
4. Harness default for `model_routing=single` harnesses (collapse the role map to one binding).
5. `adapters/roles.json` `.default_role` fallback (typically `"default"`).

**Validation:** if `framework_model_routing_shape == "single"` and the resolved binding names a provider the harness cannot serve, both sides return non-zero / non-nil with a remediation message naming the conflict (`tests/frameworks/roles.bats` T14 verifies). Unknown role names are rejected at lookup time.

**Parity test (T12):** For every role in `adapters/roles.json`, both sides return the same model id under identical config snapshots. Both sides reject the same role-binding-vs-routing conflicts.

### resolve_harness_install_path / ResolveHarnessInstallPath

| Side | Symbol | File:line |
|---|---|---|
| bash | `resolve_harness_install_path` | `scripts/lib.sh:705` |
| Go | `ResolveHarnessInstallPath` | T7 — `tui/internal/config/config.go` (in_progress) |

**Signature:** `resolve_harness_install_path <kind>` / `ResolveHarnessInstallPath(kind string) (string, error)`.

**Closed kind set:** `instructions`, `skills`, `agents`, `settings`, `teams`, `ephemeral_plans`. Any other kind is a programming error and both sides MUST reject it with a non-zero exit / non-nil error; do NOT silently fall back to a "best-guess" path.

**Source:** `adapters/capabilities.json` `.frameworks.<active>.install_paths.<kind>` (a sidecar manifest added by T7). When the harness has no path for that kind, both sides return the literal string `"unsupported"` and exit 0 — absence is a stable answer, not an error.

**Parity test (T12):** For every (framework, kind) pair, both sides return the same absolute path or both return `"unsupported"`. No filesystem creation; the helper is a path resolver, not a directory factory.

### harness_path_or_empty / HarnessPathOrEmpty

| Side | Symbol | File:line |
|---|---|---|
| bash | `harness_path_or_empty` | `scripts/lib.sh:745` |
| Go | `HarnessPathOrEmpty` | T71 — `tui/internal/config/framework.go:225` |

**Signature:** `harness_path_or_empty <kind>` / `HarnessPathOrEmpty(kind string) string`.

**Relationship to `resolve_harness_install_path`:** convenience wrapper for the dominant call shape — *"give me the path, or an empty string if this harness has no surface for X"*. Identical kind set; lookup mechanics delegate to `resolve_harness_install_path` internally.

**Output:**
- Resolved absolute path on supported kinds (exit 0 / non-empty return).
- Empty string when the kind is `unsupported` on the active harness.
- Empty string when `resolve_harness_install_path` would have errored (unknown kind, missing capabilities.json, no install_paths block, no framework config — all collapse to the same "no path here" signal).

**Why this exists as a peer:** the underlying helper distinguishes three states (path / unsupported / error). Most callers — load-work.sh, status.sh, doctor.sh, agent-toggle/{enable,disable}.sh — treat the latter two identically. Encoding the union in a one-line wrapper removes 4–6 lines of `if RES=$(...); then [[ != unsupported ]] ...; fi` boilerplate per call site, and makes the helper safe inside `set -e` shells (SessionStart hooks) without an `if`-gate. Callers that need to distinguish unsupported from error must use `resolve_harness_install_path` directly.

**Parity test (T12):** Same (framework, kind) matrix as `resolve_harness_install_path`. Both sides return identical strings — empty for unsupported AND for error, the resolved path for supported.

### resolve_agent_template / ResolveAgentTemplate

| Side | Symbol | File:line |
|---|---|---|
| bash | `resolve_agent_template` | `scripts/lib.sh:759` |
| Go | `ResolveAgentTemplate` | T7 — `tui/internal/config/config.go` (in_progress) |

**Signature:** `resolve_agent_template <agent-name>` / `ResolveAgentTemplate(name string) (string, error)`. Returns the absolute path to the agent .md template.

**Source:** `<repo>/agents/<name>.md` is the canonical location; symlinked into the harness's agents install path by `install.sh`. Both sides return the canonical path so the same file is read regardless of which install location is in scope.

**Parity test (T12):** For every agent name shipped under `agents/`, both sides return the same path.

---

## Adding a new dual-impl helper

1. **Bash first.** Implement in `scripts/lib.sh`, keep the docstring above the function with a `Mirrors config.<GoName>() in tui/internal/config/config.go (T<N>).` line.
2. **Go second.** Add the matching exported function to `tui/internal/config/config.go`.
3. **Both at once if practical.** If the work spans phases, ship the bash side first, file the Go-side task with the matching `T<N>` reference, and add a row to the table above with the Go-side cell marked `pending — T<N>`.
4. **Add a parity test in T12.** Until the bats parity test exists for the new helper, the contract is unverified. Failing to add the test is a violation.
5. **No silent defaults.** Where this contract specifies an error path, both sides MUST surface the error. Reintroducing a "fall back to claude-code" or "fall back to a hard-coded path" violates the design (per "don't reintroduce defaults" feedback in MEMORY.md).

---

## Why dual-impl rather than IPC

The TUI is a long-lived Go process; shelling out to `bash -c 'load_harness_args'` for every config read would impose 30-50ms of subprocess startup per call, multiplied across the panel-render cycle. The dual-impl design pays the maintenance cost (every helper exists twice) for steady-state TUI responsiveness.

The parity test in T12 is the safety net: it catches drift before it ships rather than waiting for a bug report.

---

## Failure modes the contract guards against

- **Bash and Go disagree on the active framework.** Result: TUI launches `claude` while the spec/implement scripts write to `harness-args.json[opencode].args` — silent split-brain. Guard: `resolve_active_framework` parity test.
- **Bash and Go disagree on the harness-args precedence.** Result: `LORE_HARNESS_ARGS` env var works in bash callers but not from the TUI. Guard: `load_harness_args` parity test with each ladder row.
- **Bash and Go disagree on whether a capability is `full`, `partial`, `fallback`, or `none`.** Result: a skill that requires `full` task_completed_hook gates differently in shell-launched vs TUI-launched runs. Guard: `framework_capability` parity test.
- **One side silently invents a path that the other side does not.** Result: writes go to a directory the other side can't see. Guard: `resolve_harness_install_path` returns `"unsupported"` for missing kinds, never a guessed path.
