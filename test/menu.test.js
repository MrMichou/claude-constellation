// Tests for bin/constellation-menu: keys are piped on stdin, and a fake awesome-client on PATH
// records the Lua it is asked to run and answers a fixed state.
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { tmpHome, ROOT } from "./helpers.js";

const MENU = path.join(ROOT, "bin", "constellation-menu");
const UP = "\x1b[A", DOWN = "\x1b[B", LEFT = "\x1b[D", RIGHT = "\x1b[C";

describe("constellation-menu", () => {
  let h, bin, log;
  beforeEach(() => {
    h = tmpHome();
    bin = path.join(h.home, "bin");
    log = path.join(h.home, "calls.log");
    fs.mkdirSync(bin);
    setAnswer("kanban|false|auto|false|auto|gpu|constellation,lanes,kanban,zen");
  });
  afterEach(() => h.cleanup());

  function setAnswer(answer) {
    fs.writeFileSync(path.join(bin, "awesome-client"),
      `#!/bin/sh\nprintf '%s\\n---\\n' "$1" >> '${log}'\necho '   string "${answer}"'\n`, { mode: 0o755 });
  }
  const calls = () => fs.readFileSync(log, "utf8").split("\n---\n").filter(Boolean);

  function menu(keys) {
    return new Promise((resolve) => {
      const child = spawn(process.execPath, [MENU], {
        env: { ...process.env, HOME: h.home, PATH: `${bin}:${process.env.PATH}` },
        stdio: ["pipe", "pipe", "pipe"],
      });
      let stderr = "";
      child.stderr.on("data", (d) => (stderr += d));
      child.on("close", (code) => resolve({ code, stderr }));
      child.stdin.end(keys);
    });
  }

  it("reads the state first, then quits on q without changing anything", async () => {
    const r = await menu("q");
    expect(r.code).toBe(0);
    expect(calls()).toHaveLength(1);
    expect(calls()[0]).toContain("cc.layout()");
    expect(calls()[0]).not.toMatch(/cc\.set_(off|layout|eco|backend)\('\w/);
  });

  it("steps the layout through the list Awesome reports, both ways and wrapping", async () => {
    await menu(`${DOWN}${RIGHT}q`);
    await menu(`${DOWN}${RIGHT}${RIGHT}q`); // the fake answer stays on kanban: zen again
    await menu(`${DOWN}${LEFT}q`);
    const sets = calls().map((c) => c.match(/cc\.set_layout\('(\w+)'\)/)?.[1]).filter(Boolean);
    expect(sets).toEqual(["zen", "zen", "zen", "lanes"]);
  });

  it("switches the layer, eco mode and backend", async () => {
    await menu(`${RIGHT}${DOWN}${DOWN}${RIGHT}${DOWN}${LEFT}q`);
    const all = calls().join("\n");
    expect(all).toContain("cc.set_off('off')");
    expect(all).toContain("cc.set_eco('on')");
    expect(all).toContain("cc.set_backend('cpu')");
  });

  it("polls Promview and locks the screen from their lines", async () => {
    await menu(`5\r7\r`);
    const all = calls().join("\n");
    expect(all).toContain("cc.promview_refresh()");
    expect(all).toContain("cc.lock()");
  });

  it("wraps from the first line to Quit", async () => {
    const r = await menu(`${UP}\r`);
    expect(r.code).toBe(0);
    expect(calls()).toHaveLength(1);
  });

  it("fails with the module's error when it isn't loaded", async () => {
    setAnswer("error: module not loaded");
    const r = await menu("q");
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("constellation-menu: module not loaded");
  });
});
