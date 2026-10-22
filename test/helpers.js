// Shared test helpers. The hook and installer are CLI entry-points that read/write under
// $HOME; we run the real scripts in a subprocess with HOME pointed at a throwaway dir, so
// nothing touches the real ~/.claude or ~/.config.
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = path.join(__dirname, "..");
export const TRACK = path.join(ROOT, "hooks", "track.js");
export const INSTALL = path.join(ROOT, "install.js");

// Isolated fake HOME: { home, dataDir, settings, cleanup }.
export function tmpHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "constellation-test-"));
  return {
    home,
    dataDir: path.join(home, ".claude", "constellation"),
    settings: path.join(home, ".claude", "settings.json"),
    cleanup: () => fs.rmSync(home, { recursive: true, force: true }),
  };
}

// Run a node script with argv, a stdin payload (object -> JSON) and HOME=home.
export function runNode(script, args, { home, stdin = "" } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [script, ...args], {
      env: { ...process.env, HOME: home },
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "", stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", reject);
    child.on("close", (code) => resolve({ code, stdout, stderr }));
    child.stdin.end(typeof stdin === "string" ? stdin : JSON.stringify(stdin));
  });
}

export const readJson = (f) => JSON.parse(fs.readFileSync(f, "utf8"));
export const exists = (f) => fs.existsSync(f);
