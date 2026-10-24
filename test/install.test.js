// Tests for install.js: merges the tracking hooks into ~/.claude/settings.json without
// touching other hooks, links the Awesome module, and undoes both with --uninstall.
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { tmpHome, runNode, readJson, exists, INSTALL, TRACK, ROOT } from "./helpers.js";

const EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification",
  "PermissionRequest", "Stop", "SessionEnd"];

describe("install.js", () => {
  let h;
  beforeEach(() => { h = tmpHome(); });
  afterEach(() => h.cleanup());

  const install = (...args) => runNode(INSTALL, args, { home: h.home });
  const link = () => path.join(h.home, ".config", "awesome", "ui", "desktop", "claude_constellation");
  const ours = (entries = []) => entries.flatMap((e) => e.hooks).filter((x) => x.command.includes(TRACK));
  const writeSettings = (s) => {
    fs.mkdirSync(path.dirname(h.settings), { recursive: true });
    fs.writeFileSync(h.settings, JSON.stringify(s));
  };

  it("works on a fresh machine without settings.json", async () => {
    const r = await install();
    expect(r.code).toBe(0);
    const hooks = readJson(h.settings).hooks;
    for (const evt of EVENTS) expect(ours(hooks[evt])).toHaveLength(1);
  });

  it("passes the right event argument and matcher", async () => {
    await install();
    const hooks = readJson(h.settings).hooks;
    expect(ours(hooks.PreToolUse)[0].command).toMatch(/track\.js' pre$/);
    expect(ours(hooks.SessionEnd)[0].command).toMatch(/track\.js' end$/);
    expect(hooks.PreToolUse.at(-1).matcher).toBe("*");
    expect(hooks.Stop.at(-1).matcher).toBeUndefined();
  });

  it("keeps other settings and hooks, and backs up the original", async () => {
    const original = {
      model: "opus",
      hooks: { Stop: [{ hooks: [{ type: "command", command: "other-tool stop" }] }] },
    };
    writeSettings(original);
    await install();
    const s = readJson(h.settings);
    expect(s.model).toBe("opus");
    expect(s.hooks.Stop.flatMap((e) => e.hooks).map((x) => x.command)).toContain("other-tool stop");
    expect(readJson(h.settings + ".bak-constellation")).toEqual(original);
  });

  it("is idempotent", async () => {
    await install();
    await install();
    const hooks = readJson(h.settings).hooks;
    for (const evt of EVENTS) expect(ours(hooks[evt])).toHaveLength(1);
  });

  it("links the Awesome module into ~/.config/awesome", async () => {
    await install();
    expect(fs.realpathSync(link())).toBe(path.join(ROOT, "awesome", "claude_constellation"));
  });

  const cmdLink = () => path.join(h.home, ".local", "bin", "constellation-layout");

  it("links the constellation-layout command into ~/.local/bin, and removes it", async () => {
    await install();
    await install(); // idempotent
    expect(fs.readlinkSync(cmdLink())).toBe(path.join(ROOT, "bin", "constellation-layout"));
    await install("--uninstall");
    expect(exists(cmdLink())).toBe(false);
  });

  it("leaves an unrelated constellation-layout command alone", async () => {
    fs.mkdirSync(path.dirname(cmdLink()), { recursive: true });
    fs.writeFileSync(cmdLink(), "#!/bin/sh\n");
    await install();
    expect(fs.lstatSync(cmdLink()).isSymbolicLink()).toBe(false);
    await install("--uninstall");
    expect(fs.readFileSync(cmdLink(), "utf8")).toBe("#!/bin/sh\n");
  });

  it("--uninstall removes only its own hooks and the link", async () => {
    writeSettings({ hooks: { Stop: [{ hooks: [{ type: "command", command: "other-tool stop" }] }] } });
    await install();
    const r = await install("--uninstall");
    expect(r.code).toBe(0);
    const hooks = readJson(h.settings).hooks;
    expect(Object.keys(hooks)).toEqual(["Stop"]);
    expect(hooks.Stop).toEqual([{ hooks: [{ type: "command", command: "other-tool stop" }] }]);
    expect(exists(link())).toBe(false);
  });
});
