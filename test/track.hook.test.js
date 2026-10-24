// End-to-end tests of hooks/track.js as Claude Code runs it: event in argv, JSON on stdin,
// state written to $HOME/.claude/constellation/<sid>.json.
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { tmpHome, runNode, readJson, exists, TRACK } from "./helpers.js";

describe("track.js hook", () => {
  let h;
  beforeEach(() => { h = tmpHome(); });
  afterEach(() => h.cleanup());

  const hook = (event, payload) => runNode(TRACK, [event], { home: h.home, stdin: payload });
  const stateFile = (sid) => path.join(h.dataDir, sid + ".json");
  const state = (sid = "s1") => readJson(stateFile(sid));
  const pre = (tool_name, tool_input, sid = "s1") =>
    hook("pre", { session_id: sid, cwd: "/work/proj", tool_name, tool_input });

  it("start registers the session as idle before its first prompt", async () => {
    const r = await hook("start", { session_id: "s1", cwd: "/work/my-proj" });
    expect(r.code).toBe(0);
    expect(state()).toMatchObject({ sid: "s1", project: "my-proj", state: "idle", history: [] });
  });

  it("start on a resumed session keeps its state, history and timeline", async () => {
    await pre("Read", { file_path: "/a.txt" });
    await hook("stop", { session_id: "s1" });
    const before = state();
    await hook("start", { session_id: "s1" }); // resume: no cwd in the payload
    const after = state();
    expect(after).toMatchObject({ project: "proj", state: "done" });
    expect(after.history).toEqual(before.history);
    expect(after.timeline).toEqual(before.timeline);
    expect(after.ts).toBeGreaterThanOrEqual(before.ts);
  });

  it("keeps the data dir and session files private to the user", async () => {
    await pre("Bash", { command: "curl -H 'Authorization: x'" });
    expect(fs.statSync(h.dataDir).mode & 0o777).toBe(0o700);
    expect(fs.statSync(stateFile("s1")).mode & 0o777).toBe(0o600);
  });

  it("prompt marks the session as thinking and records the project", async () => {
    const r = await hook("prompt", { session_id: "s1", cwd: "/work/my-proj" });
    expect(r.code).toBe(0);
    expect(state()).toMatchObject({ sid: "s1", project: "my-proj", state: "thinking" });
    expect(typeof state().ts).toBe("number");
  });

  it("pre records the tool, its kind and target, and appends to history", async () => {
    await pre("Bash", { command: "cargo test" });
    expect(state()).toMatchObject({ state: "tool", tool: "Bash", kind: "shell", target: "cargo test" });
    expect(state().history).toHaveLength(1);
    expect(state().history[0]).toMatchObject({ tool: "Bash", kind: "shell", target: "cargo test" });
  });

  it("caps history at the 10 most recent calls", async () => {
    for (let i = 0; i < 12; i++) await pre("Grep", { pattern: "p" + i });
    const hist = state().history;
    expect(hist).toHaveLength(10);
    expect(hist[0].target).toBe("p2");
    expect(hist[9].target).toBe("p11");
  });

  it("records each call on the timeline and closes it on post or the next call", async () => {
    await pre("Read", { file_path: "/a.txt" });
    expect(state().timeline).toHaveLength(1);
    expect(state().timeline[0].e).toBeUndefined();
    await hook("post", { session_id: "s1" });
    await pre("Bash", { command: "ls" });
    await pre("Grep", { pattern: "x" });
    const tl = state().timeline;
    expect(tl.map((e) => e.k)).toEqual(["file", "shell", "search"]);
    for (const e of tl.slice(0, 2)) expect(e.e).toBeGreaterThanOrEqual(e.s);
    expect(tl[2].e).toBeUndefined();
  });

  it("keeps a call open while it waits for a permission", async () => {
    await pre("Bash", { command: "rm -rf build" });
    await hook("permreq", { session_id: "s1" });
    expect(state().timeline[0].e).toBeUndefined();
    await hook("stop", { session_id: "s1" });
    expect(state().timeline[0].e).toBeGreaterThanOrEqual(state().timeline[0].s);
  });

  it("drops timeline entries older than 30 minutes", async () => {
    const old = Date.now() / 1000 - 31 * 60;
    fs.mkdirSync(h.dataDir, { recursive: true });
    fs.writeFileSync(stateFile("s1"), JSON.stringify({ timeline: [{ k: "file", s: old, e: old + 1 }] }));
    await pre("Bash", { command: "ls" });
    expect(state().timeline.map((e) => e.k)).toEqual(["shell"]);
  });

  it("post goes back to thinking and keeps tool fields", async () => {
    await pre("Read", { file_path: "/a.txt" });
    await hook("post", { session_id: "s1" });
    expect(state()).toMatchObject({ state: "thinking", tool: "Read", target: "/a.txt" });
  });

  it.each([
    ["Claude needs your permission to use Bash", "permission"],
    ["Please approve this action", "permission"],
    ["Claude is waiting for your input", "waiting"],
  ])("notify %j -> %s", async (message, expected) => {
    await hook("notify", { session_id: "s1", message });
    expect(state().state).toBe(expected);
  });

  it("permreq marks a pending permission, stop marks done", async () => {
    await hook("permreq", { session_id: "s1" });
    expect(state().state).toBe("permission");
    await hook("stop", { session_id: "s1" });
    expect(state().state).toBe("done");
  });

  it("end deletes the session file", async () => {
    await hook("prompt", { session_id: "s1" });
    expect(exists(stateFile("s1"))).toBe(true);
    await hook("end", { session_id: "s1" });
    expect(exists(stateFile("s1"))).toBe(false);
  });

  it("keeps the previous project when cwd is missing", async () => {
    await hook("prompt", { session_id: "s1", cwd: "/work/first" });
    await hook("stop", { session_id: "s1" });
    expect(state().project).toBe("first");
  });

  it("sanitizes the session id so it cannot escape the data dir", async () => {
    await hook("prompt", { session_id: "../../evil/../x" });
    expect(fs.readdirSync(h.dataDir)).toEqual(["....evil..x.json"]);
    expect(exists(path.join(h.home, "x.json"))).toBe(false);
  });

  it.each([
    ["no session id", "prompt", { cwd: "/x" }],
    ["an unknown event", "bogus", { session_id: "s1" }],
  ])("writes nothing for %s", async (_, event, payload) => {
    const r = await hook(event, payload);
    expect(r.code).toBe(0);
    expect(exists(h.dataDir)).toBe(false);
  });

  it("never fails the hook on invalid JSON", async () => {
    const r = await runNode(TRACK, ["prompt"], { home: h.home, stdin: "{not json" });
    expect(r.code).toBe(0);
    expect(r.stderr).toBe("");
  });

  it("recovers from a corrupt state file", async () => {
    fs.mkdirSync(h.dataDir, { recursive: true });
    fs.writeFileSync(stateFile("s1"), "garbage");
    await pre("Bash", { command: "ls" });
    expect(state()).toMatchObject({ state: "tool", history: [{ target: "ls" }] });
  });

  it("leaves no temp file behind (atomic write)", async () => {
    await hook("prompt", { session_id: "s1" });
    expect(fs.readdirSync(h.dataDir)).toEqual(["s1.json"]);
  });

  describe("parallel calls and subagents (same session id)", () => {
    const call = (event, id, tool_name, tool_input, cwd = "/work/proj") =>
      hook(event, { session_id: "s1", cwd, tool_use_id: id, tool_name, tool_input });

    it("keeps the project when a subagent runs in a worktree", async () => {
      await hook("prompt", { session_id: "s1", cwd: "/work/proj" });
      await call("pre", "t1", "Bash", { command: "ls" }, "/work/proj/.claude/worktrees/agent-ae2b");
      await call("pre", "t2", "Bash", { command: "ls" }, "/work/proj/.claude/worktrees/agent-ae2b/lib");
      expect(state().project).toBe("proj");
    });

    it("repairs a name taken from a worktree by an older hook", async () => {
      fs.mkdirSync(h.dataDir, { recursive: true });
      fs.writeFileSync(stateFile("s1"), JSON.stringify({ sid: "s1", project: "agent-ae2b" }));
      await call("pre", "t1", "Bash", { command: "ls" }, "/work/proj/.claude/worktrees/agent-ae2b");
      expect(state().project).toBe("proj");
    });

    it("names a session started in a worktree after its repo", async () => {
      await hook("start", { session_id: "s1", cwd: "/work/proj/.claude/worktrees/agent-1" });
      expect(state().project).toBe("proj");
    });

    it("closes only the finished call and stays on the one still running", async () => {
      await call("pre", "a", "Agent", { subagent_type: "Explore" });
      await call("pre", "b", "Read", { file_path: "/x/a.txt" });
      await call("pre", "c", "Grep", { pattern: "foo" });
      await call("post", "c");
      let tl = state().timeline;
      expect(tl.map((e) => e.e === undefined)).toEqual([true, true, false]);
      expect(state()).toMatchObject({ state: "tool", tool: "Read", target: "/x/a.txt" });
      await call("post", "b");
      expect(state()).toMatchObject({ state: "tool", tool: "Agent", kind: "agent" });
      await call("post", "a");
      tl = state().timeline;
      expect(tl.every((e) => e.e >= e.s)).toBe(true);
      expect(state().state).toBe("thinking");
    });

    it("still names a running call that has left the 10-call history", async () => {
      await call("pre", "long", "Bash", { command: "npm test" });
      for (let i = 0; i < 12; i++) {
        await call("pre", "q" + i, "Grep", { pattern: "p" + i });
        await call("post", "q" + i);
      }
      expect(state().history.map((x) => x.target)).not.toContain("npm test");
      expect(state()).toMatchObject({ state: "tool", tool: "Bash", kind: "shell", target: "npm test" });
    });

    it("keeps the label only while the call runs", async () => {
      await call("pre", "a", "Read", { file_path: "/x/a.txt" });
      expect(state().timeline[0]).toMatchObject({ id: "a", t: "Read", g: "/x/a.txt" });
      await call("post", "a");
      expect(state().timeline[0]).not.toHaveProperty("t");
      expect(state().timeline[0]).not.toHaveProperty("g");
    });

    it("stop closes calls whose post never came", async () => {
      await call("pre", "a", "Bash", { command: "sleep 9" });
      await hook("stop", { session_id: "s1" });
      expect(state().timeline[0].e).toBeGreaterThanOrEqual(state().timeline[0].s);
    });
  });

  describe("shared-resource links", () => {
    it("records tmux sessions and files another session may share", async () => {
      await pre("Bash", { command: "P=0:0; tmux send-keys -t $P ls Enter" });
      await pre("Edit", { file_path: "/srv/deploy.yml" });
      const links = state().links;
      expect(links["tmux:0"]).toMatchObject({ kind: "shell", label: "tmux 0" });
      expect(links["file:/srv/deploy.yml"]).toMatchObject({ kind: "file", label: "deploy.yml" });
    });

    it("refreshes the timestamp of a reused resource", async () => {
      await pre("Bash", { command: "tmux send-keys -t 0:0 a" });
      const first = state().links["tmux:0"].ts;
      await new Promise((r) => setTimeout(r, 20));
      await pre("Bash", { command: "tmux send-keys -t 0:0 b" });
      expect(state().links["tmux:0"].ts).toBeGreaterThan(first);
    });

    it("drops links older than one hour", async () => {
      fs.mkdirSync(h.dataDir, { recursive: true });
      const old = Date.now() / 1000 - 3700;
      fs.writeFileSync(stateFile("s1"), JSON.stringify({
        sid: "s1", links: { "tmux:old": { kind: "shell", label: "tmux old", ts: old } },
      }));
      await pre("Bash", { command: "tmux send-keys -t new:0 x" });
      expect(Object.keys(state().links)).toEqual(["tmux:new"]);
    });

    it("keeps at most the 20 most recent links", async () => {
      fs.mkdirSync(h.dataDir, { recursive: true });
      const now = Date.now() / 1000;
      const links = {};
      for (let i = 0; i < 25; i++) links["file:/f" + i] = { kind: "file", label: "f" + i, ts: now - 100 + i };
      fs.writeFileSync(stateFile("s1"), JSON.stringify({ sid: "s1", links }));
      await pre("Read", { file_path: "/newest" });
      const keys = Object.keys(state().links);
      expect(keys).toHaveLength(20);
      expect(keys[0]).toBe("file:/newest");
      expect(keys).not.toContain("file:/f0");
    });
  });
});
