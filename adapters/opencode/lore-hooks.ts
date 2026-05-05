/**
 * lore-hooks.ts — OpenCode plugin adapter for Lore lifecycle events.
 *
 * Maps OpenCode native plugin events onto the nine Lore lifecycle event
 * names defined in adapters/hooks/README.md (T24's dispatch contract):
 *
 *   session_start  user_prompt  pre_tool  post_tool  permission_request
 *   pre_compact    stop         session_end          task_completed
 *
 * For every lifecycle event the plugin either invokes the matching Lore
 * handler script in ~/.lore/scripts/<name> (per T24 checklist item 6,
 * stable script paths) and translates the script's exit code / stdout
 * into the OpenCode plugin runtime's return shape, or — when no native
 * OpenCode event maps cleanly — emits the `unsupported` sentinel and
 * defers to the orchestration adapter (adapters/agents/README.md, T31)
 * for fallback handling.
 *
 * Capability levels for each Lore event come from
 * adapters/capabilities.json frameworks.opencode.capabilities.<cap>.support
 * (worker-2's T2 cells, all `partial` or `fallback` until T30's bats
 * smoke proves no adapter-introduced divergence). The plugin reads them
 * at boot via resolveSupport() and surfaces a `[lore] degraded:` stderr
 * line on every dispatch when the cell is `partial` or `fallback`, per
 * T24 checklist item 4.
 *
 * Native event sources (per adapters/capabilities-evidence.md):
 *   session.created / session.updated   — opencode-session-start-hook
 *   session.idle    / session.status    — opencode-stop-hook
 *   message.updated                     — opencode-stop-hook
 *   tool.execute.before / .after        — opencode-tool-hooks
 *   permission.asked / .replied         — opencode-permission-hooks
 *
 * Lore events without a native equivalent (returned as `unsupported`):
 *   pre_compact     — no PreCompact in OpenCode plugin event list;
 *                     fallback uses SessionStart bookend per T24 mapping
 *   task_completed  — no subagent-completion blocking event; fallback
 *                     to lead-side validator per adapters/agents/README.md
 *
 * Smoke output: invoking the bundled CLI entrypoint (`node lore-hooks.ts
 * --smoke`) prints, for the active framework, every Lore lifecycle event
 * paired with its support level and (if applicable) the OpenCode native
 * event name it routes through. Required by T24 checklist item 5.
 *
 * Cross-references:
 *   adapters/hooks/README.md  — dispatch contract, blocking matrix,
 *                               per-harness signaling protocols
 *   adapters/agents/README.md — orchestration adapter contract, T31
 *   adapters/capabilities.json — frameworks.opencode.capabilities cells
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
 * Shape of `~/.lore/config/framework.json` for the fields the adapter
 * consumes. Mirrors `userFrameworkConfig` in tui/internal/config/framework.go
 * and the resolution order documented on `framework_capability` in
 * scripts/lib.sh.
 */
interface FrameworkUserConfig {
  framework?: string;
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
 * Native OpenCode event name(s) that fire each Lore event. Empty array
 * means no native equivalent — plugin returns `unsupported`.
 */
const NATIVE_EVENT_SOURCES: Record<LoreEvent, readonly string[]> = {
  session_start: ["session.created"],
  user_prompt: ["message.updated"],
  pre_tool: ["tool.execute.before"],
  post_tool: ["tool.execute.after"],
  permission_request: ["permission.asked"],
  pre_compact: [], // no native — fallback path documented in T24
  stop: ["session.idle"],
  session_end: ["session.status"],
  task_completed: [], // no native — orchestration-adapter fallback (T31)
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
  stop: "stop-novelty-check.py",      // chains to check-plan-persistence.py
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
  const configFile = path.join(dataRoot, "config", "framework.json");
  try {
    const raw = fs.readFileSync(configFile, "utf-8");
    const cfg = JSON.parse(raw) as FrameworkUserConfig;
    return cfg.capability_overrides ?? {};
  } catch {
    return {};
  }
}

/**
 * Resolve the per-event support level using the contract documented on
 * `framework_capability` in scripts/lib.sh: user overrides at
 * `~/.lore/config/framework.json:.capability_overrides.<cap>` win over
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
 */
function spawnHandler(scriptName: string, env: NodeJS.ProcessEnv): Promise<DispatchResult> {
  return new Promise((resolve) => {
    const dataRoot = process.env.LORE_DATA_DIR || path.join(os.homedir(), ".lore");
    const scriptPath = path.join(dataRoot, "scripts", scriptName);
    const interpreter = scriptName.endsWith(".py") ? "python3" : "bash";

    const child = spawn(interpreter, [scriptPath], {
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => { stdout += d.toString(); });
    child.stderr.on("data", (d) => { stderr += d.toString(); });
    child.on("error", (err) => {
      resolve({ outcome: "error", reason: String(err), stderr });
    });
    child.on("close", (code) => {
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
 * is a no-op; on `partial` / `fallback` it logs a degraded-status line
 * to stderr per T24 checklist item 4.
 */
export async function dispatch(
  event: LoreEvent,
  payload: Record<string, unknown> = {},
): Promise<DispatchResult> {
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
  });

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

/**
 * Translate a DispatchResult into the OpenCode plugin runtime's return
 * shape. Per adapters/hooks/README.md "OpenCode plugin returns" table:
 *   allow / notify / unsupported → undefined (or { allow: true })
 *   deny                          → { allow: false, reason }
 *   error                         → throw
 */
export function toPluginReturn(result: DispatchResult): PluginReturn | undefined {
  switch (result.outcome) {
    case "allow":
    case "notify":
    case "unsupported":
      return undefined;
    case "deny":
      return { allow: false, reason: result.reason ?? "blocked by lore handler" };
    case "error":
      throw new Error(result.reason ?? "lore handler failed");
  }
}

// ---------------------------------------------------------------------------
// Plugin entrypoint
// ---------------------------------------------------------------------------

/**
 * The OpenCode plugin object. Each native event handler maps onto the
 * matching Lore lifecycle dispatch. The exact function-name shape is
 * owned by the OpenCode plugin SDK; this module exports the handlers
 * as named functions so the plugin shell can wire them however the SDK
 * expects (default-export object, named exports, or class-based).
 *
 * If the OpenCode SDK shape changes, the field names below are the
 * single point of update — the dispatch logic above is SDK-agnostic.
 */
export const plugin = {
  "session.created": async (payload: Record<string, unknown>) =>
    toPluginReturn(await dispatch("session_start", payload)),

  "session.idle": async (payload: Record<string, unknown>) =>
    toPluginReturn(await dispatch("stop", payload)),

  "session.status": async (payload: Record<string, unknown>) => {
    const status = (payload as { status?: string }).status;
    if (status === "ended" || status === "cleared") {
      return toPluginReturn(await dispatch("session_end", payload));
    }
    return undefined;
  },

  "message.updated": async (payload: Record<string, unknown>) =>
    toPluginReturn(await dispatch("user_prompt", payload)),

  "tool.execute.before": async (payload: Record<string, unknown>) =>
    toPluginReturn(await dispatch("pre_tool", payload)),

  "tool.execute.after": async (payload: Record<string, unknown>) =>
    toPluginReturn(await dispatch("post_tool", payload)),

  "permission.asked": async (payload: Record<string, unknown>) =>
    toPluginReturn(await dispatch("permission_request", payload)),
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
 * Invoke as: `node lore-hooks.ts --smoke` (after a TS->JS compilation
 * step) or via `tsx` / `ts-node` in development.
 */
export function smoke(): void {
  const support = resolveSupport();
  const rows: string[] = [];
  rows.push("opencode hook adapter — Lore lifecycle support matrix");
  rows.push("");
  for (const event of Object.keys(CAPABILITY_KEY) as LoreEvent[]) {
    const sources = NATIVE_EVENT_SOURCES[event];
    const native = sources.length === 0 ? "(unsupported — orchestration fallback)" : sources.join(", ");
    rows.push(`  ${event.padEnd(20)} ${support[event].padEnd(10)} ${native}`);
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
