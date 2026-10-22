// End-to-end tests of hooks/track.js for subagents, with payloads shaped like the ones Claude
// Code 2.1 sends: tool events from a subagent carry the parent's session_id plus agent_id and
// agent_type, the Agent call returns right after SubagentStart, and the subagent hands its
// result back through an internal SubagentHandback tool before SubagentStop.
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import path from "node:path";
import { createRequire } from "node:module";
import { tmpHome, runNode, readJson, exists, TRACK } from "./helpers.js";

const { pruneAgents } = createRequire(import.meta.url)(TRACK);

describe("track.js subagents", () => {
  let h;
  beforeEach(() => { h = tmpHome(); });
  afterEach(() => h.cleanup());

  const hook = (event, payload) => runNode(TRACK, [event], { home: h.home, stdin: { session_id: "s1", ...payload } });
  const state = () => readJson(path.join(h.dataDir, "s1.json"));
  const spawnAgent = async (id, type, description) => {
    await hook("pre", { tool_name: "Agent", tool_input: { subagent_type: type, description, prompt: "…" } });
    await hook("substart", { agent_id: id, agent_type: type });
    await hook("post", { tool_name: "Agent" });
  };
  const sub = (event, id, extra = {}) => hook(event, { agent_id: id, agent_type: "Explore", ...extra });

  it("SubagentStart adds a thinking subagent labelled with its Agent call's description", async () => {
    await spawnAgent("a1", "Explore", "map the imports");
    const s = state();
    expect(s.agents.a1).toMatchObject({ type: "Explore", label: "map the imports", state: "thinking" });
    expect(s.pending).toEqual([]);
    expect(s.state).toBe("thinking"); // the session's own post
  });

  it("pairs descriptions with the subagent of the same type, oldest first", async () => {
    await hook("pre", { tool_name: "Agent", tool_input: { subagent_type: "Plan", description: "plan it" } });
    await hook("pre", { tool_name: "Agent", tool_input: { description: "do it" } }); // general-purpose
    await hook("substart", { agent_id: "g", agent_type: "general-purpose" });
    await hook("substart", { agent_id: "p", agent_type: "Plan" });
    expect(state().agents.g.label).toBe("do it");
    expect(state().agents.p.label).toBe("plan it");
  });

  it("routes a subagent's tool calls to its entry, not to the session", async () => {
    await spawnAgent("a1", "Explore", "look");
    await hook("stop", {}); // the session ends its turn while the subagent works
    await sub("pre", "a1", { tool_name: "Read", tool_input: { file_path: "/w/a.txt" } });
    const s = state();
    expect(s.state).toBe("done");
    expect(s.history.map((x) => x.tool)).toEqual(["Agent"]);
    expect(s.agents.a1).toMatchObject({ state: "tool", tool: "Read", kind: "file", target: "/w/a.txt" });
    expect(s.links["file:/w/a.txt"]).toMatchObject({ kind: "file", label: "a.txt" }); // still linkable
    await sub("post", "a1", { tool_name: "Read" });
    expect(state().agents.a1.state).toBe("thinking");
  });

  it("keeps the 4 latest targets per subagent and ignores SubagentHandback", async () => {
    await spawnAgent("a1", "Explore", "look");
    for (let i = 0; i < 6; i++) await sub("pre", "a1", { tool_name: "Grep", tool_input: { pattern: "p" + i } });
    await sub("pre", "a1", { tool_name: "SubagentHandback", tool_input: { message: "done" } });
    const a = state().agents.a1;
    expect(a.history.map((x) => x.target)).toEqual(["p2", "p3", "p4", "p5"]);
    expect(a.tool).toBe("Grep");
  });

  it("marks permissions on the subagent", async () => {
    await spawnAgent("a1", "Explore", "look");
    await sub("permreq", "a1", { tool_name: "Bash" });
    expect(state().agents.a1.state).toBe("permission");
    expect(state().state).toBe("thinking");
  });

  it("SubagentStop marks it done; later events are ignored until it is resumed", async () => {
    await spawnAgent("a1", "Explore", "look");
    await sub("substop", "a1");
    expect(state().agents.a1.state).toBe("done");
    await sub("post", "a1", { tool_name: "Read" });
    expect(state().agents.a1.state).toBe("done");
    await sub("substart", "a1");
    expect(state().agents.a1.state).toBe("thinking");
  });

  it("ignores SubagentStop from internal agents that never started", async () => {
    await hook("substop", { agent_id: "suggest", agent_type: "" });
    expect(exists(path.join(h.dataDir, "s1.json"))).toBe(false);
  });

  it("tracks a subagent whose SubagentStart was missed", async () => {
    await sub("pre", "late", { tool_name: "Bash", tool_input: { command: "ls" } });
    expect(state().agents.late).toMatchObject({ type: "Explore", state: "tool", target: "ls" });
  });

  it("subagent events don't restart the session's done party", async () => {
    await spawnAgent("a1", "Explore", "look");
    await hook("stop", {});
    const since = state().since;
    await new Promise((r) => setTimeout(r, 20));
    await sub("pre", "a1", { tool_name: "Read", tool_input: { file_path: "/x" } });
    expect(state().since).toBe(since);
    expect(state().ts).toBeGreaterThan(since);
  });
});

describe("pruneAgents", () => {
  const now = 10_000;
  const agent = (state, age) => ({ state, ts: now - age });

  it("drops finished subagents after a minute and silent running ones after 30 min", () => {
    const out = pruneAgents({
      fresh: agent("done", 10), old: agent("done", 61),
      busy: agent("tool", 29 * 60), lost: agent("thinking", 31 * 60),
    }, now);
    expect(Object.keys(out).sort()).toEqual(["busy", "fresh"]);
  });

  it("keeps the 64 most recent of a big fan-out", () => {
    const many = {};
    for (let i = 0; i < 80; i++) many["a" + i] = agent("tool", 80 - i);
    const out = pruneAgents(many, now);
    expect(Object.keys(out)).toHaveLength(64);
    expect(out.a79).toBeDefined();
    expect(out.a0).toBeUndefined();
  });
});
