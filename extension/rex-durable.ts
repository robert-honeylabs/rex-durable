// Tells rex-durable which conversation this pi or omp process is on, so it
// can reopen it in its Rex tab after a restart. pi sets its process title,
// which hides its command line and environment from ps, so they are recorded
// here too.
import { mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

type Context = {
  hasUI?: boolean;
  sessionManager: {
    getSessionId(): string;
    getSessionFile(): string | undefined;
    getCwd(): string;
  };
};
type Host = { on(event: string, handler: (event: any, ctx: Context) => void): void };

// rex-durable's M.ENV; it keeps only those names when it reads this file.
const ENV = ["FORCE_COLOR", "MAX_THINKING_TOKENS"];

// Installed as ~/.pi/agent/extensions/rex-durable.ts or
// ~/.omp/agent/extensions/rex-durable.ts.
const agentDir = dirname(dirname(fileURLToPath(import.meta.url)));
const app = basename(dirname(agentDir)).replace(/^\./, "");
const dir = join(agentDir, "rex-durable");
const record = join(dir, `${process.pid}.json`);

export default function (pi: Host) {
  let root = false;
  const write = (_event: unknown, ctx: Context) => {
    // omp runs subagents in this process, each with its own session and no UI.
    if (ctx.hasUI !== true) return;
    root = true;
    const env = ENV.filter((name) => process.env[name] !== undefined).map(
      (name) => `${name}=${process.env[name]}`,
    );
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      `${record}.tmp`,
      JSON.stringify({
        pid: process.pid,
        sessionId: ctx.sessionManager.getSessionId(),
        sessionFile: ctx.sessionManager.getSessionFile(),
        cwd: ctx.sessionManager.getCwd(),
        argv: [app, ...process.argv.slice(2)],
        env,
      }),
    );
    renameSync(`${record}.tmp`, record);
  };
  pi.on("session_start", write);
  // omp's /new, /resume, and /fork; pi starts a new session for these instead.
  pi.on("session_switch", write);

  // pi follows every other reason with a session_start that rewrites the
  // record; omp gives no reason and shuts down only to quit.
  pi.on("session_shutdown", (event) => {
    if (root && (event?.reason ?? "quit") === "quit") rmSync(record, { force: true });
  });
}
