// Tells rex-durable which conversation this pi process is on, so it can
// reopen it in its Rex tab after a restart. pi sets its process title, which
// hides its command line and environment from ps, so they are recorded here.
import { mkdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// rex-durable's M.ENV; it keeps only those names when it reads this file.
const ENV = ["FORCE_COLOR", "MAX_THINKING_TOKENS"];

const dir = join(homedir(), ".pi", "agent", "rex-durable");
const record = join(dir, `${process.pid}.json`);

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
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
        argv: ["pi", ...process.argv.slice(2)],
        env,
      }),
    );
    renameSync(`${record}.tmp`, record);
  });

  // Every other reason is followed by a session_start that rewrites the record.
  pi.on("session_shutdown", (event) => {
    if (event.reason === "quit") rmSync(record, { force: true });
  });
}
