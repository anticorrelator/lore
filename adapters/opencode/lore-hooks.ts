/**
 * lore-hooks.ts — OpenCode plugin adapter for Lore lifecycle events (T26).
 *
 * Maps OpenCode native plugin events onto the nine Lore lifecycle event
 * names defined in adapters/hooks/README.md (T24's dispatch contract):
 *
 *   session_start  user_prompt  pre_tool  post_tool  permission_request
 *   pre_compact    stop         session_end          task_completed
 *
 * For every lifecycle event the plugin (a) invokes the matching Lore
 * handler script in ~/.lore/scripts/<name> (per T24 checklist item 6,
 * stable script paths) and translates the script's exit code / stdout
 * into an OpenCode outcome, AND (b) appends a single JSON event row to
 * the per-session accumulator at ~/.lore/sessions/opencode/<session-id>.jsonl.
 * The accumulator is the agreed contract surface with
 * adapters/transcripts/opencode.py (T51) — one event per line,
 * append-only, no rewrites; opencode.py walks the file in arrival order
 * to synthesize the transcript view that other Lore consumers
 * (extract-session-digest, stop-novelty-check, etc.) normally read from
 * Claude Code's JSONL transcript.
 *
 * Plugin shape (OpenCode 2.x). OpenCode's server loads every plain file in
 * ~/.config/opencode/plugins and requires its default export to be
 * `{ id, setup(ctx) }` (or `{ id, effect }`); the pre-2.0 object keyed by
 * event names is rejected with "Plugin must export a default definition
 * with an id and an effect or setup function". The plugin runs in the
 * server process — the machine's shared background service, or the private
 * server a `--standalone` TUI starts — never in the TUI. `setup` subscribes
 * to `ctx.event` and registers hooks with `ctx.tool.hook`,
 * `ctx.session.hook` and `ctx.permission.hook`. A hook mutates the payload
 * it is handed; a hook that throws fails the whole turn, so refusals set
 * `effect: "deny"` in the permission `evaluate` hook instead, which the
 * tool reports as a denied permission.
 *
 * Per-event evidence-gated classification (Phase 3 D8 rule). Each row
 * names the capabilities.json cell consumed and the evidence anchor in
 * adapters/capabilities-evidence.md that grounds the support level.
 * Workers MUST NOT promote a cell beyond what the evidence supports;
 * uncertain or experimental vendor behavior stays at `partial` /
 * `fallback` with explicit degraded status (Phase 3 objective).
 *
 *   event              support     native source(s) on 2.x          evidence
 *   ---------------    --------    -----------------------------    -------------------------------
 *   session_start      partial     event session.created            opencode-session-start-hook
 *   user_prompt        partial     session hook prompt              opencode-tool-hooks (proxy)
 *   pre_tool           partial     permission hook evaluate (edit)  opencode-tool-hooks
 *   post_tool          partial     tool hook execute.after          opencode-tool-hooks
 *   permission_request partial     event permission.asked           opencode-permission-hooks
 *   pre_compact        fallback    event session.compaction.started opencode-pre-compact-hook
 *   stop               partial     event session.execution.*        opencode-stop-hook
 *   session_end        partial     event session.deleted            opencode-stop-hook
 *   task_completed     fallback    (no native event)                opencode-task-completed-hook
 *                                  (lead-side validator per adapters/agents/README.md T31)
 *
 * pre_tool's handler, guard-work-writes.sh, guards file writes. Every
 * OpenCode tool that writes a file (write, edit, patch) asks the `edit`
 * permission for each path before touching disk, so the guard runs in the
 * permission `evaluate` hook for that action and denies there; the tool
 * hooks only record the call for the accumulator.
 *
 * Smoke output: invoking the bundled CLI entrypoint (`tsx lore-hooks.ts
 * --smoke` or equivalent) prints, for the active framework, every Lore
 * lifecycle event paired with its support level and (if applicable) the
 * OpenCode native event name it routes through. Required by T24
 * checklist item 5; verified by tests/frameworks/hooks.bats.
 *
 * Cross-references:
 *   adapters/hooks/README.md  — dispatch contract, blocking matrix,
 *                               per-harness signaling protocols
 *   adapters/agents/README.md — orchestration adapter contract (T31)
 *   adapters/capabilities.json — frameworks.opencode.capabilities cells
 *   adapters/capabilities-evidence.md — opencode-* anchor block
 *   adapters/transcripts/opencode.py — accumulator file consumer (T51)
 *   gotchas/hooks/hook-system-gotchas.md — exit-code-vs-JSON footgun
 *                                          (Claude Code-specific; OpenCode
 *                                          plugins don't have the same
 *                                          asymmetry but the adapter
 *                                          translates outcomes equivalently)
 */

import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/**
 * The closed set of Lore lifecycle event names. New events MUST be added
 * here, in scripts/lib.sh, in adapters/hooks/README.md, and in the bash /
 * Codex / Claude Code adapters together.
 */
export type LoreEvent =
  | "session_start"
  | "user_prompt"
  | "pre_tool"
  | "post_tool"
  | "permission_request"
  | "pre_compact"
  | "stop"
  | "session_end"
  | "task_completed";

/** Per T24 dispatch outcomes. */
export type LoreOutcome = "allow" | "deny" | "notify" | "unsupported" | "error";

/** OpenCode plugin runtime return shape — the wire form callers expect. */
export interface PluginReturn {
  /** When false, OpenCode blocks the operation and surfaces `reason`. */
  allow?: boolean;
  /** Required when allow=false. */
  reason?: string;
}

/** Result of dispatching a single event through this plugin. */
export interface DispatchResult {
  outcome: LoreOutcome;
  reason?: string;
  /** stderr captured from the lore handler script (informational). */
  stderr?: string;
}

/** Support cell read from adapters/capabilities.json. */
export type SupportLevel = "full" | "partial" | "fallback" | "none";

interface CapabilitiesShape {
  frameworks: Record<
    string,
    {
      capabilities: Record<string, { support: SupportLevel; notes?: string }>;
    }
  >;
}

/**
 * Shape of `~/.lore/config/settings.json` for the fields the adapter consumes.
 * Mirrors the resolution order documented on `framework_capability` in
 * scripts/lib.sh.
 */
interface LoreSettingsConfig {
  capability_overrides?: Record<string, SupportLevel>;
}

// ---------------------------------------------------------------------------
// Constants — closed mappings
// ---------------------------------------------------------------------------

/**
 * Capability-cell key consumed per Lore event. user_prompt + post_tool +
 * pre_tool all proxy onto `tool_hooks` per T24's "user_prompt proxy
 * mapping" rationale.
 */
const CAPABILITY_KEY: Record<LoreEvent, string> = {
  session_start: "session_start_hook",
  user_prompt: "tool_hooks",
  pre_tool: "tool_hooks",
  post_tool: "tool_hooks",
  permission_request: "permission_hooks",
  pre_compact: "pre_compact_hook",
  stop: "stop_hook",
  session_end: "stop_hook",
  task_completed: "task_completed_hook",
};

/**
 * Native OpenCode 2.x source(s) that fire each Lore event: an event on
 * `ctx.event`, or a hook registered on the plugin context. Empty array
 * means no native equivalent — plugin returns `unsupported`.
 *
 * 2.x publishes neither `session.idle` nor `session.status` on the event
 * stream; a turn ends with one of the `session.execution.*` events.
 * `session.compaction.started` is published by the 2.x server, but no
 * live run has compacted yet, so pre_compact stays `fallback` per the
 * opencode-pre-compact-hook evidence anchor.
 */
const NATIVE_EVENT_SOURCES: Record<LoreEvent, readonly string[]> = {
  session_start: ["session.created"],
  user_prompt: ["session hook prompt"],
  pre_tool: ["permission hook evaluate (edit)"],
  post_tool: ["tool hook execute.after"],
  permission_request: ["permission.asked"],
  pre_compact: ["session.compaction.started"],
  stop: ["session.execution.succeeded", "session.execution.interrupted", "session.execution.failed"],
  session_end: ["session.deleted"],
  task_completed: [], // no native — orchestration-adapter fallback (T31)
};

/** Event-stream types that dispatch a Lore event, from NATIVE_EVENT_SOURCES. */
const EVENT_DISPATCH: Readonly<Record<string, LoreEvent>> = {
  "session.created": "session_start",
  "permission.asked": "permission_request",
  "session.compaction.started": "pre_compact",
  "session.execution.succeeded": "stop",
  "session.execution.interrupted": "stop",
  "session.execution.failed": "stop",
  "session.deleted": "session_end",
};

/**
 * Lore handler script for each event — the script invoked when the cell
 * supports the event. Paths are stable `~/.lore/scripts/<name>` per
 * T24 checklist item 6.
 *
 * Some events (post_tool, session_end) currently have no Lore handler;
 * the plugin emits a notify outcome without spawning a subprocess.
 */
const HANDLER_SCRIPT: Record<LoreEvent, string | null> = {
  session_start: "load-knowledge.sh", // also loads work + threads via SessionStart chain
  user_prompt: null,                  // no handler today; reserved
  pre_tool: "guard-work-writes.sh",
  post_tool: null,                    // no handler today; reserved
  permission_request: null,           // no handler today; reserved
  pre_compact: "pre-compact.sh",
  stop: null,                         // no handler today; check-plan-persistence.py retired 2026-05-26
  session_end: "pre-compact.sh",      // matcher=clear semantics
  task_completed: "task-completed-capture-check.sh",
};

/**
 * Events that may legitimately return `deny` per T24's blocking matrix.
 * Everything else translates `deny` to `error` before forwarding.
 */
const DENY_ALLOWED: ReadonlySet<LoreEvent> = new Set<LoreEvent>([
  "user_prompt",
  "pre_tool",
  "permission_request",
  "task_completed",
]);

/**
 * OpenCode 2.x's native subagent tool is `subagent` (the pre-2.0 `task`),
 * and it asks the `subagent` permission before it launches, so matching
 * that exact name is a definite condition. Its plugin contract does not yet
 * provide probe-backed prompt-field and blocking semantics for that launch,
 * however. Fail closed on the known launch instead of guessing at aliases or
 * rewriting an unverified payload shape. The validated adapter/session path
 * remains available on every harness.
 */
export const NATIVE_TASK_GUIDANCE_REASON =
  "Native OpenCode task launch is unavailable because its dispatch-guidance prompt contract is unverified. Run 'lore dispatch guidance' and launch through the Lore orchestration adapter or worker session.";

export function refuseUnverifiedNativeTask(
  payload: Record<string, unknown>,
): PluginReturn | undefined {
  if (payload.tool === "subagent") {
    return { allow: false, reason: NATIVE_TASK_GUIDANCE_REASON };
  }
  return undefined;
}

// ---------------------------------------------------------------------------
// Session accumulator — contract surface with adapters/transcripts/opencode.py
// ---------------------------------------------------------------------------

/**
 * Resolve the per-session accumulator path. The directory is created
 * lazily on first write. Mirrors `_accumulator_path` in
 * adapters/transcripts/opencode.py — the two MUST agree on the path
 * shape `<LORE_DATA_DIR>/sessions/opencode/<session-id>.jsonl` or the
 * provider stub silently sees an empty transcript.
 */
function accumulatorPath(sessionId: string): string {
  const dataRoot = process.env.LORE_DATA_DIR || path.join(os.homedir(), ".lore");
  return path.join(dataRoot, "sessions", "opencode", `${sessionId}.jsonl`);
}

/**
 * Append one event row to the per-session accumulator. The row is the
 * raw OpenCode event payload with `type`, `session_id`, and `timestamp`
 * promoted to top-level fields so the transcript provider can index
 * them without parsing nested structures.
 *
 * Append-only invariant: one event = one line, no rewriting. The
 * provider stub depends on this for `read_raw_lines` index alignment
 * (see adapters/transcripts/opencode.py docstring).
 *
 * Errors are logged to stderr and swallowed — accumulator failure must
 * not break the harness's own event-bus delivery, since the transcript
 * is informational rather than authoritative for opencode runs.
 */
function appendAccumulatorEvent(
  sessionId: string,
  type: string,
  payload: Record<string, unknown>,
): void {
  if (!sessionId) {
    return;
  }
  const file = accumulatorPath(sessionId);
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const row = {
      type,
      session_id: sessionId,
      timestamp: new Date().toISOString(),
      ...payload,
    };
    fs.appendFileSync(file, JSON.stringify(row) + "\n", { encoding: "utf-8" });
  } catch (err) {
    process.stderr.write(`[lore] accumulator write failed for ${type}: ${String(err)}\n`);
  }
}

/**
 * Best-effort session-id extraction from the raw OpenCode event payload.
 * Different events surface the id under different keys (top-level
 * `sessionID`, nested `session.id`, `message.sessionID`, etc.); we
 * try the documented shapes in order and return the empty string when
 * none of them match — `appendAccumulatorEvent` then no-ops.
 */
function extractSessionId(payload: Record<string, unknown>): string {
  const candidates: unknown[] = [
    (payload as { sessionID?: unknown }).sessionID,
    (payload as { session_id?: unknown }).session_id,
    (payload as { sessionId?: unknown }).sessionId,
    (payload as { session?: { id?: unknown } }).session?.id,
    (payload as { message?: { sessionID?: unknown } }).message?.sessionID,
    (payload as { message?: { session_id?: unknown } }).message?.session_id,
  ];
  for (const c of candidates) {
    if (typeof c === "string" && c.length > 0) {
      return c;
    }
  }
  return "";
}

// ---------------------------------------------------------------------------
// Capability resolution
// ---------------------------------------------------------------------------

/**
 * Resolve the lore repo root by walking the install symlink chain at
 * ~/.lore/scripts -> <repo>/scripts (matches scripts/lib.sh and the Go
 * loreRepoDir() helper).
 */
function resolveLoreRepoDir(): string {
  const dataRoot = process.env.LORE_DATA_DIR || path.join(os.homedir(), ".lore");
  const scriptsLink = path.join(dataRoot, "scripts");
  try {
    const target = fs.realpathSync(scriptsLink);
    return path.dirname(target);
  } catch {
    // Fall through; capability lookup will degrade to "none" silently.
    return "";
  }
}

let cachedSupport: Record<LoreEvent, SupportLevel> | null = null;

function loadUserOverrides(): Record<string, SupportLevel> {
  const dataRoot = process.env.LORE_DATA_DIR || path.join(os.homedir(), ".lore");
  const configFile = path.join(dataRoot, "config", "settings.json");
  try {
    const raw = fs.readFileSync(configFile, "utf-8");
    const cfg = JSON.parse(raw) as LoreSettingsConfig;
    return cfg.capability_overrides ?? {};
  } catch {
    return {};
  }
}

/**
 * Resolve the per-event support level using the contract documented on
 * `framework_capability` in scripts/lib.sh: user overrides at
 * `~/.lore/config/settings.json:.capability_overrides.<cap>` win over
 * the static profile in `adapters/capabilities.json`. Cells that fail to
 * load fall back to "none" so the dispatch path emits `unsupported`
 * rather than silently invoking handlers that may not be wired.
 *
 * This is the TypeScript mirror of bash `framework_capability` for the
 * opencode-only event subset; it intentionally does not reach for the
 * Go-side helper because the Go mirror is a known T10-pending stub.
 */
export function resolveSupport(): Record<LoreEvent, SupportLevel> {
  if (cachedSupport) return cachedSupport;

  const out: Record<LoreEvent, SupportLevel> = {} as Record<LoreEvent, SupportLevel>;
  const repoDir = resolveLoreRepoDir();
  let caps: CapabilitiesShape | null = null;

  if (repoDir) {
    try {
      const raw = fs.readFileSync(path.join(repoDir, "adapters", "capabilities.json"), "utf-8");
      caps = JSON.parse(raw) as CapabilitiesShape;
    } catch {
      caps = null;
    }
  }

  const overrides = loadUserOverrides();
  const profile = caps?.frameworks?.opencode?.capabilities ?? {};
  for (const event of Object.keys(CAPABILITY_KEY) as LoreEvent[]) {
    const cap = CAPABILITY_KEY[event];
    const override = overrides[cap];
    if (override) {
      out[event] = override;
      continue;
    }
    out[event] = profile[cap]?.support ?? "none";
  }

  cachedSupport = out;
  return out;
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

/**
 * Spawn a Lore handler script and translate exit/stdout/stderr into a
 * DispatchResult. Mirrors the bash adapters' invocation pattern but
 * runs in-process via node:child_process.spawn.
 *
 * - exit 0 + empty stdout decision → "allow" or "notify" (caller decides)
 * - exit 0 + `{"decision":"approve"}` JSON on stdout → "allow"
 * - exit 0 + `{"decision":"block","reason":...}` JSON on stdout → "deny"
 * - exit 2 (TaskCompleted-style) → "deny" with stderr feedback
 * - any other non-zero exit → "error"
 *
 * `stdin` is written to the handler's standard input, which is then closed,
 * so a handler with a stdin contract (guard-work-writes.sh reads the
 * PreToolUse JSON) sees its input and every other handler sees EOF. A
 * handler still running after HANDLER_TIMEOUT_MS is killed and reported as
 * "error": pre_tool runs inside a permission check that holds the tool call.
 */
const HANDLER_TIMEOUT_MS = 30_000;

function spawnHandler(scriptName: string, env: NodeJS.ProcessEnv, stdin = ""): Promise<DispatchResult> {
  return new Promise((resolve) => {
    const dataRoot = process.env.LORE_DATA_DIR || path.join(os.homedir(), ".lore");
    const scriptPath = path.join(dataRoot, "scripts", scriptName);
    const interpreter = scriptName.endsWith(".py") ? "python3" : "bash";

    // This plugin is itself the OpenCode runtime boundary. Pin child scripts to
    // opencode so a later install for another harness does not make OpenCode
    // handlers read the wrong capability profile from settings.json.
    const child = spawn(interpreter, [scriptPath], {
      env: { ...process.env, ...env, LORE_FRAMEWORK: "opencode" },
      stdio: ["pipe", "pipe", "pipe"],
    });
    const timer = setTimeout(() => child.kill("SIGKILL"), HANDLER_TIMEOUT_MS);
    child.stdin.on("error", () => {});
    child.stdin.end(stdin);

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => { stdout += d.toString(); });
    child.stderr.on("data", (d) => { stderr += d.toString(); });
    child.on("error", (err) => {
      clearTimeout(timer);
      resolve({ outcome: "error", reason: String(err), stderr });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      const trimmed = stdout.trim();
      if (code === 0) {
        if (trimmed.startsWith("{")) {
          try {
            const decision = JSON.parse(trimmed) as { decision?: string; reason?: string };
            if (decision.decision === "block") {
              resolve({ outcome: "deny", reason: decision.reason, stderr });
              return;
            }
          } catch {
            // Non-JSON stdout on exit 0 → notify (informational).
          }
        }
        resolve({ outcome: "notify", stderr });
        return;
      }
      if (code === 2) {
        // TaskCompleted protocol: exit 2 + stderr feedback = deny.
        resolve({ outcome: "deny", reason: stderr.trim() || "blocked by lore handler", stderr });
        return;
      }
      resolve({
        outcome: "error",
        reason: `${scriptName} exited ${code}`,
        stderr,
      });
    });
  });
}

/**
 * Dispatch a single Lore lifecycle event. The OpenCode plugin handlers
 * call this from their event callbacks. On `unsupported` the function
 * is a no-op (other than the accumulator write); on `partial` /
 * `fallback` it logs a degraded-status line to stderr per T24
 * checklist item 4.
 *
 * The accumulator write to ~/.lore/sessions/opencode/<sid>.jsonl
 * happens regardless of capability gating — the transcript provider
 * needs every event the harness fires, even ones with no Lore handler
 * (post_tool, message.updated for tool_result, etc.). Capability gating
 * controls whether a Lore handler script runs, not whether the event
 * is captured for downstream consumers.
 *
 * `rawEventName` is the native OpenCode event type (e.g.
 * "session.created"). When omitted, the accumulator records the Lore
 * event name instead — useful for synthetic dispatches but loses the
 * harness-native shape that opencode.py expects.
 *
 * `stdin` is the handler's standard input (see spawnHandler).
 */
export async function dispatch(
  event: LoreEvent,
  payload: Record<string, unknown> = {},
  rawEventName?: string,
  stdin?: string,
): Promise<DispatchResult> {
  // Capture to the accumulator first so transcript consumers see the
  // event even when the lore handler is gated off.
  const sessionId = extractSessionId(payload);
  if (sessionId) {
    appendAccumulatorEvent(sessionId, rawEventName ?? event, payload);
  }

  const support = resolveSupport()[event];

  // Honor capability gate (T24 item 2): "none" → unsupported immediately.
  if (support === "none") {
    process.stderr.write(`[lore] unsupported event: ${event}\n`);
    return { outcome: "unsupported" };
  }

  // Surface degraded status (T24 item 4).
  if (support === "partial" || support === "fallback") {
    const fallbackMech = NATIVE_EVENT_SOURCES[event].length === 0
      ? "orchestration adapter (T31)"
      : NATIVE_EVENT_SOURCES[event].join(",");
    process.stderr.write(
      `[lore] degraded: ${event} via ${fallbackMech} (capability=${support})\n`,
    );
  }

  // No native event mapping → unsupported (caller's fallback handles it).
  if (NATIVE_EVENT_SOURCES[event].length === 0) {
    return { outcome: "unsupported" };
  }

  // No handler script wired for this event → notify (event observed,
  // no decision to make).
  const script = HANDLER_SCRIPT[event];
  if (!script) {
    return { outcome: "notify" };
  }

  // Spawn the handler. Pass the payload as LORE_HOOK_PAYLOAD env var
  // so handlers can opt into reading it without forcing a stdin
  // contract on every script.
  const result = await spawnHandler(script, {
    LORE_HOOK_EVENT: event,
    LORE_HOOK_PAYLOAD: JSON.stringify(payload ?? {}),
  }, stdin);

  // Enforce T24's blocking matrix: deny is only allowed for the four
  // events in DENY_ALLOWED. Translate to error otherwise.
  if (result.outcome === "deny" && !DENY_ALLOWED.has(event)) {
    process.stderr.write(
      `[lore] contract violation: deny on non-blockable event ${event}\n`,
    );
    return { outcome: "error", reason: `non-blockable event ${event} returned deny` };
  }

  return result;
}

// ---------------------------------------------------------------------------
// Plugin entrypoint
// ---------------------------------------------------------------------------

/**
 * The slice of OpenCode 2.x's server plugin context this adapter uses. Each
 * hook registrar hands its callback a mutable payload; the callback's
 * return value is ignored.
 */
interface OpenCodeEvent {
  id?: string;
  type?: string;
  data?: Record<string, unknown>;
}

interface PermissionEvaluation {
  sessionID?: string;
  agent?: string;
  action: string;
  resources: string[];
  effect: "allow" | "ask" | "deny";
  message?: string;
}

interface OpenCodePluginContext {
  location?: { directory?: string };
  event: { subscribe(): AsyncIterable<OpenCodeEvent> };
  tool: { hook(name: string, fn: (payload: Record<string, unknown>) => unknown): Promise<unknown> };
  session: { hook(name: string, fn: (payload: Record<string, unknown>) => unknown): Promise<unknown> };
  permission: { hook(name: "evaluate", fn: (payload: PermissionEvaluation) => unknown): Promise<unknown> };
}

/**
 * Event ids already dispatched. OpenCode runs a server plugin once per
 * project location it serves, and every instance may see the same event, so
 * the first instance to see an event dispatches it. Bounded to the most
 * recent ids.
 */
const DISPATCHED_EVENTS = new Set<string>();

function firstSighting(id: string | undefined): boolean {
  if (!id) return true;
  if (DISPATCHED_EVENTS.has(id)) return false;
  DISPATCHED_EVENTS.add(id);
  if (DISPATCHED_EVENTS.size > 1000) {
    DISPATCHED_EVENTS.delete(DISPATCHED_EVENTS.values().next().value as string);
  }
  return true;
}

/** Record a dispatch failure without failing the OpenCode turn that fired it. */
function report(result: DispatchResult, event: LoreEvent): void {
  if (result.outcome === "error") {
    process.stderr.write(`[lore] ${event} handler failed: ${result.reason ?? "unknown error"}\n`);
  }
}

/**
 * The OpenCode 2.x plugin definition. Every native source passes its
 * OpenCode name as the third dispatch argument so the per-session
 * accumulator records the harness-native event type —
 * adapters/transcripts/opencode.py reads it back as event["type"]. Tool and
 * prompt rows are written in the shape opencode.py parses (`tool.name` /
 * `tool.input`, `message.role` / `message.content`).
 *
 * Nothing here throws into OpenCode: a hook that throws fails the turn, so
 * handler errors are reported on stderr and the operation proceeds.
 * Refusals use the permission `evaluate` hook.
 */
export const plugin = {
  id: "lore.hooks",
  async setup(ctx: OpenCodePluginContext) {
    const directory = ctx.location?.directory ?? process.cwd();
    let open = true;

    void (async () => {
      for await (const event of ctx.event.subscribe()) {
        if (!open) return;
        const loreEvent = event.type ? EVENT_DISPATCH[event.type] : undefined;
        if (!loreEvent || !firstSighting(event.id)) continue;
        report(await dispatch(loreEvent, event.data ?? {}, event.type), loreEvent);
      }
    })().catch((err) => {
      process.stderr.write(`[lore] event subscription ended: ${String(err)}\n`);
    });

    await ctx.session.hook("prompt", async (payload) => {
      const prompt = payload.prompt as { text?: unknown } | undefined;
      const row = {
        sessionID: payload.sessionID,
        message: { role: "user", content: [{ type: "text", text: typeof prompt?.text === "string" ? prompt.text : "" }] },
      };
      report(await dispatch("user_prompt", row, "message.updated"), "user_prompt");
    });

    await ctx.tool.hook("execute.before", (payload) => {
      const sessionId = extractSessionId(payload);
      if (sessionId) {
        appendAccumulatorEvent(sessionId, "tool.execute.before", {
          tool: { name: payload.tool, input: payload.input },
          call_id: payload.id,
          agent: payload.agent,
        });
      }
    });

    await ctx.tool.hook("execute.after", async (payload) => {
      const row = {
        sessionID: payload.sessionID,
        tool: { name: payload.tool, input: payload.input },
        call_id: payload.id,
        status: payload.status,
      };
      report(await dispatch("post_tool", row, "tool.execute.after"), "post_tool");
    });

    await ctx.permission.hook("evaluate", async (evaluation) => {
      if (evaluation.effect === "deny") return;
      const nativeTaskRefusal = refuseUnverifiedNativeTask({ tool: evaluation.action });
      if (nativeTaskRefusal) {
        evaluation.effect = "deny";
        evaluation.message = nativeTaskRefusal.reason;
        return;
      }
      if (evaluation.action !== "edit") return;
      // guard-work-writes.sh reads Claude Code's PreToolUse shape and
      // treats every file-writing tool alike, so each path the edit
      // permission covers is checked as a Write.
      for (const resource of evaluation.resources) {
        const filePath = path.isAbsolute(resource) ? resource : path.resolve(directory, resource);
        const input = JSON.stringify({
          hook_event_name: "PreToolUse",
          session_id: evaluation.sessionID ?? "",
          tool_name: "Write",
          tool_input: { file_path: filePath },
        });
        // Not the evaluation itself: its metadata holds the whole diff, which
        // could overflow the handler's environment (LORE_HOOK_PAYLOAD).
        const row = {
          sessionID: evaluation.sessionID,
          agent: evaluation.agent,
          action: evaluation.action,
          resources: evaluation.resources,
          file_path: filePath,
        };
        const result = await dispatch("pre_tool", row, "permission.evaluate", input);
        report(result, "pre_tool");
        if (result.outcome === "deny") {
          evaluation.effect = "deny";
          evaluation.message = result.reason ?? "blocked by lore handler";
          return;
        }
      }
    });

    return () => {
      open = false;
    };
  },
};

export default plugin;

// ---------------------------------------------------------------------------
// Smoke command
// ---------------------------------------------------------------------------

/**
 * Print a one-line-per-Lore-event matrix showing support level and
 * the OpenCode native event(s) each one routes through. Required by
 * T24 checklist item 5: "Each adapter MUST expose a smoke subcommand".
 *
 * Output format is parsed by tests/frameworks/hooks.bats — each event
 * row begins with two leading spaces, the event name padded to 20,
 * then the support level token (full|partial|fallback|none). The bats
 * test asserts `<event>[whitespace]+<expected_support>` matches per
 * row. Do not change the column shape without updating the regex in
 * `opencode smoke support levels match capabilities.json` (currently
 * skipped pending TS runtime, but the contract is real).
 *
 * Invoke as: `tsx adapters/opencode/lore-hooks.ts --smoke` or
 * `bun run adapters/opencode/lore-hooks.ts --smoke`.
 */
export function smoke(): void {
  const support = resolveSupport();
  const rows: string[] = [];
  rows.push("[opencode hook adapter smoke]");
  rows.push("  active framework: opencode");
  rows.push(`  accumulator dir:  ${path.dirname(accumulatorPath("<session-id>"))}`);
  rows.push("");
  rows.push("  Lore event           Support   Native OpenCode event");
  rows.push("  -------------------- --------- ----------------------------------------");
  for (const event of Object.keys(CAPABILITY_KEY) as LoreEvent[]) {
    const sources = NATIVE_EVENT_SOURCES[event];
    const native = sources.length === 0
      ? "(no native — orchestration adapter fallback)"
      : sources.join(", ");
    rows.push(`  ${event.padEnd(20)} ${support[event].padEnd(9)} ${native}`);
  }
  process.stdout.write(rows.join("\n") + "\n");
}

// Invoke smoke when run directly with --smoke. The OpenCode plugin
// runtime never passes --smoke when importing this module, so a simple
// argv check is sufficient and avoids ESM/CJS entrypoint-detection
// gymnastics. If --smoke flag handling needs to coexist with future
// plugin-runtime CLI flags, swap to `process.argv[1]?.endsWith("lore-hooks.ts")`
// or similar entrypoint guard.
if (process.argv.includes("--smoke")) {
  smoke();
}
