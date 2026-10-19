/**
 * lore-session-lifecycle — an OpenCode TUI plugin that journals a lore-hosted
 * session's own turn edges through scripts/session-lifecycle-hook.sh.
 *
 * OpenCode 2.x runs TUI plugins inside the TUI process. In a lore-hosted pane
 * that process is the pane's first process, whether the TUI uses OpenCode's
 * shared background service or a private server, so this is where the session
 * can speak for itself. Server plugins run in the server instead, which is
 * either a process shared by every OpenCode client on the machine or a child
 * of the TUI.
 *
 * The plugin listens to the client's live event stream and hands one payload
 * per edge to the shared hook script, which maps it through
 * frameworks.opencode.session_lifecycle_hooks in adapters/capabilities.json.
 * Turn events (session.execution.*) count only for the root session the pane
 * shows; a subagent runs as a child session in the same process and finishes
 * many times inside one turn. Dialog events (permission.*, form.*) count for
 * that session or any subagent under it, because a subagent's dialog holds the
 * whole session. Events for other sessions the stream carries are ignored.
 *
 * The hook runs as `bash <hook> opencode`, spawned directly so that the hook's
 * parent is this process: for an environment-borne channel the hook accepts a
 * row only from the outermost process carrying the session's generation, and a
 * nested OpenCode started from a tool shell inherits the same environment.
 *
 * Nothing here can stop or slow the session: the hook is detached from the
 * event loop, every failure is swallowed, and the host's screen observation
 * keeps reporting the session when no row lands. The plugin does nothing when
 * LORE_AGENT_DISABLED=1 or when the pane carries no session identity.
 *
 * Options: `hook` overrides the script path, which otherwise resolves to
 * ../../../scripts/session-lifecycle-hook.sh beside this file.
 */

import { spawn } from "node:child_process";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

type EventData = Record<string, any> | undefined;

/** The client events this plugin forwards, as OpenCode 2.x names them. */
const EVENTS = [
  "session.execution.started",
  "session.execution.succeeded",
  "session.execution.interrupted",
  "session.execution.failed",
  "permission.asked",
  "permission.replied",
  "form.created",
  "form.replied",
  "form.cancelled",
] as const;

/** Events about one session's own turn, as opposed to a dialog inside it. */
const TURN_EVENTS = new Set<string>([
  "session.execution.started",
  "session.execution.succeeded",
  "session.execution.interrupted",
  "session.execution.failed",
]);

function hookPath(options: Record<string, unknown> | undefined): string {
  if (typeof options?.hook === "string" && options.hook.length > 0) return options.hook;
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..", "..", "scripts", "session-lifecycle-hook.sh");
}

function sessionOf(type: string, data: EventData): string | undefined {
  const id = type === "form.created" ? data?.form?.sessionID : data?.sessionID;
  return typeof id === "string" && id.length > 0 ? id : undefined;
}

function payloadOf(type: string, data: EventData, sessionID: string): Record<string, string> {
  const payload: Record<string, string> = { hook_event_name: type, session_id: sessionID };
  if (type === "permission.asked" && typeof data?.action === "string") payload.tool_name = data.action;
  if (type === "session.execution.failed") {
    const message = data?.error?.message ?? data?.error?.name;
    if (typeof message === "string") payload.error = message;
  }
  if (type === "session.execution.interrupted" && typeof data?.reason === "string") payload.reason = data.reason;
  return payload;
}

function report(hook: string, payload: Record<string, string>): void {
  try {
    const child = spawn("bash", [hook, "opencode"], { stdio: ["pipe", "ignore", "ignore"], env: process.env });
    child.on("error", () => {});
    child.stdin?.on("error", () => {});
    child.stdin?.end(JSON.stringify(payload));
    child.unref();
  } catch {
    // No row; the screen observation still reports the session.
  }
}

export default {
  id: "lore.session-lifecycle",
  setup(api: any) {
    const env = process.env;
    if (env.LORE_AGENT_DISABLED === "1" || !env.LORE_SESSION_SLUG || !env.LORE_SESSION_GENERATION) return;
    const hook = hookPath(api.options);
    const rootOf = (sessionID: string): string => {
      try {
        const root = api.data.session.root(sessionID);
        return typeof root === "string" && root.length > 0 ? root : sessionID;
      } catch {
        return sessionID;
      }
    };
    const shownRoot = (): string | undefined => {
      const route = api.ui.router.current();
      return route?.type === "session" && typeof route.sessionID === "string" ? rootOf(route.sessionID) : undefined;
    };
    const unsubscribe: Array<() => void> = [];
    for (const type of EVENTS) {
      try {
        unsubscribe.push(api.data.on(type, (event: { data?: EventData }) => {
          try {
            const sessionID = sessionOf(type, event?.data);
            const shown = shownRoot();
            if (!sessionID || !shown) return;
            const own = TURN_EVENTS.has(type) ? sessionID === shown : rootOf(sessionID) === shown;
            if (own) report(hook, payloadOf(type, event?.data, sessionID));
          } catch {
            // A malformed event writes nothing.
          }
        }));
      } catch {
        // An event this OpenCode does not publish is skipped.
      }
    }
    return () => {
      for (const off of unsubscribe.reverse()) {
        try {
          off();
        } catch {
          // Already unsubscribed.
        }
      }
    };
  },
};
