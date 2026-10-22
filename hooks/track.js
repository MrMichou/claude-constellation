#!/usr/bin/env node
// Claude Code hook: records, per session, what the session is doing and which resources
// it touches, for the AwesomeWM desktop "constellation".
// Writes ~/.claude/constellation/<session_id>.json atomically, under a lock: a session's hooks
// run concurrently (parallel tool calls, subagents fanning out) and would otherwise overwrite
// each other's updates. Never fails the hook.
// Subagents (SubagentStart/Stop, and tool events carrying agent_id) are tracked per session
// under `agents`, so the renderer can draw them as mini nodes around their session.
// Usage: node track.js <start|prompt|pre|post|notify|permreq|stop|substart|substop|end>

const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = path.join(os.homedir(), ".claude", "constellation");
const HISTORY_MAX = 10;
const LINKS_MAX = 20; // shared-resource keys kept per session
const LINK_TTL = 3600; // seconds a shared resource stays linkable
const AGENTS_MAX = 64; // subagents kept per session (big workflows fan out to dozens)
const AGENT_HISTORY_MAX = 4;
const AGENT_DONE_KEEP = 60; // seconds a finished subagent stays (the renderer fades it out)
const AGENT_LOST = 30 * 60; // seconds without events before a running subagent is dropped
const PENDING_MAX = 16; // Agent tool calls waiting for their SubagentStart
const PENDING_TTL = 600;
// Tools a subagent uses to talk to its parent, not resources worth an orbit.
const INTERNAL_TOOLS = new Set(["SubagentHandback"]);
const LOCK_WAIT = 3000; // ms to wait for the lock before writing anyway
const LOCK_STALE = 2000; // ms after which a lock left by a killed hook is broken
const TIMELINE_TTL = 1800; // seconds of tool calls kept for the swimlanes layout
const TIMELINE_MAX = 200;

function shortPath(f) {
  if (!f) return "";
  const home = os.homedir();
  const s = f.startsWith(home) ? "~" + f.slice(home.length) : f;
  const parts = s.split("/").filter(Boolean);
  return parts.length > 2 ? "…/" + parts.slice(-2).join("/") : s;
}

const clip = (s, n) => {
  s = String(s || "").split("\n")[0].trim();
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
};

// { kind, target }: kind buckets tools by resource type, target is a short label.
function describeTool(t, input) {
  const i = input || {};
  if (t.startsWith("mcp__")) {
    const [, server, method] = t.split("__");
    return { kind: "mcp", target: clip(`${server}:${method || ""}`, 40) };
  }
  switch (t) {
    case "Read": case "Edit": case "Write": case "MultiEdit": case "NotebookEdit":
      return { kind: "file", target: shortPath(i.file_path || i.notebook_path) };
    case "Bash":
      return { kind: "shell", target: clip(i.command, 40) };
    case "Grep": case "Glob":
      return { kind: "search", target: clip(i.pattern, 40) };
    case "WebFetch": {
      let host = "";
      try { host = new URL(i.url).hostname; } catch {}
      return { kind: "web", target: host || clip(i.url, 40) };
    }
    case "WebSearch":
      return { kind: "web", target: clip(i.query, 40) };
    case "Task": case "Agent":
      return { kind: "agent", target: clip(i.subagent_type || i.description, 40) };
    default:
      return { kind: "other", target: clip(t, 40) };
  }
}

// tmux sessions a shell command drives: the `-t` target of each `tmux ...` invocation, with
// `$P` resolved from `P=0:0` or from a `for P in 0:0.0 0:0.1` loop earlier in the command.
// Only segments that start with `tmux` count, so text merely mentioning tmux is ignored.
function tmuxSessions(cmd) {
  const vars = {};
  for (const m of cmd.matchAll(/(?:^|[\s;&(])([A-Za-z_]\w*)=(['"]?)([^\s;'"&|)]+)\2/g)) vars[m[1]] = [m[3]];
  for (const m of cmd.matchAll(/\bfor\s+([A-Za-z_]\w*)\s+in\s+([^;\n]+)/g)) vars[m[1]] = m[2].trim().split(/\s+/);
  const out = new Set();
  const add = (target) => {
    const ref = target.match(/^\$\{?(\w+)\}?$/);
    for (const v of ref ? vars[ref[1]] || [] : [target]) {
      const sess = v.replace(/^['"=]+|['"]+$/g, "").split(":")[0];
      if (/^[\w.-]+$/.test(sess)) out.add(sess);
    }
  };
  for (const seg of cmd.split(/;|&&|\|\||\||\n|\bdo\b/)) {
    if (!/^\s*(?:[A-Za-z_]\w*=\S*\s+)*tmux\s/.test(seg)) continue;
    for (const m of seg.matchAll(/\s-t\s*(['"]?)([^\s'"]+)\1/g)) add(m[2]);
  }
  return [...out];
}

// Resources another session may share, as { key, kind, label }: the same file, or the same
// tmux session driven via send-keys/capture-pane. The renderer links sessions sharing a key.
function linkKeys(t, input) {
  const i = input || {};
  const f = i.file_path || i.notebook_path;
  if (f && ["Read", "Edit", "Write", "MultiEdit", "NotebookEdit"].includes(t)) {
    return [{ key: "file:" + f, kind: "file", label: path.basename(f) }];
  }
  if (t === "Bash" && /\btmux\b/.test(i.command || "")) {
    return tmuxSessions(i.command).map((s) => ({ key: "tmux:" + s, kind: "shell", label: "tmux " + s }));
  }
  return [];
}

const cleanId = (v) => String(v || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64);

// Drops finished and lost subagents, then the oldest ones past AGENTS_MAX.
function pruneAgents(agents, now) {
  const kept = Object.entries(agents).filter(([, a]) =>
    now - a.ts < (a.state === "done" ? AGENT_DONE_KEEP : AGENT_LOST));
  kept.sort(([, a], [, b]) => b.ts - a.ts);
  return Object.fromEntries(kept.slice(0, AGENTS_MAX));
}

// Applies a subagent's event to its entry; false when there is nothing to record.
function agentEvent(s, event, p, now) {
  const id = cleanId(p.agent_id);
  let a = s.agents[id];
  if (!a) {
    // SubagentStop also fires for Claude Code's internal agents (prompt suggestions, /btw),
    // which never had a SubagentStart: ignore those.
    if (event === "substop") return false;
    const type = clip(p.agent_type || "agent", 40);
    // Label it with the description of the oldest pending Agent call of the same type.
    const i = s.pending.findIndex((q) => q.type === type);
    const label = i >= 0 ? s.pending.splice(i, 1)[0].label : "";
    a = { type, label, state: "thinking", tool: "", kind: "", target: "", history: [], started: now };
    s.agents[id] = a;
  }
  // A finished subagent only comes back through SubagentStart (resumed); late events are noise.
  if (a.state === "done" && event !== "substart") return false;
  a.ts = now;
  switch (event) {
    case "substart": if (a.state === "done") a.state = "thinking"; break; // resumed
    case "substop": a.state = "done"; break;
    case "pre": {
      const t = p.tool_name || "";
      if (INTERNAL_TOOLS.has(t)) break;
      const d = describeTool(t, p.tool_input);
      Object.assign(a, { state: "tool", tool: t, kind: d.kind, target: d.target });
      a.history.push({ kind: d.kind, target: d.target, ts: now });
      a.history = a.history.slice(-AGENT_HISTORY_MAX);
      break;
    }
    case "post": a.state = "thinking"; break;
    case "permreq": a.state = "permission"; break;
    case "notify": a.state = /permission|approve|allow/i.test(p.message || "") ? "permission" : "waiting"; break;
    default: return false;
  }
  return true;
}

function addLinks(s, t, input, now) {
  for (const l of linkKeys(t, input)) s.links[l.key] = { kind: l.kind, label: l.label, ts: now };
  s.links = Object.fromEntries(Object.entries(s.links)
    .filter(([, l]) => now - l.ts < LINK_TTL)
    .sort(([, a], [, b]) => b.ts - a.ts)
    .slice(0, LINKS_MAX));
}

const pause = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

// Runs fn while holding <file>.lock (created exclusively). Gives up waiting after LOCK_WAIT
// and runs fn anyway: a lost update beats a hook that stalls Claude Code.
function withLock(file, fn) {
  const lock = file + ".lock";
  const deadline = Date.now() + LOCK_WAIT;
  let fd = null;
  while (fd === null) {
    try {
      fd = fs.openSync(lock, "wx");
    } catch (e) {
      if (Date.now() > deadline) break;
      // No data dir yet: create it (another hook may be doing the same) and retry the lock.
      if (e.code === "ENOENT") { try { fs.mkdirSync(dir, { recursive: true }); } catch {} continue; }
      if (e.code !== "EEXIST") break;
      try {
        if (Date.now() - fs.statSync(lock).mtimeMs > LOCK_STALE) { fs.rmSync(lock, { force: true }); continue; }
      } catch {}
      pause(2 + Math.random() * 8);
    }
  }
  try {
    return fn();
  } finally {
    if (fd !== null) {
      fs.closeSync(fd);
      fs.rmSync(lock, { force: true });
    }
  }
}

const EVENTS = new Set(["start", "prompt", "pre", "post", "notify", "permreq", "stop", "substart", "substop", "end"]);

function run(event, p) {
  const sid = cleanId(p.session_id);
  if (!sid || !EVENTS.has(event)) return;
  const file = path.join(dir, sid + ".json");
  withLock(file, () => update(event, p, sid, file));
}

function update(event, p, sid, file) {
  if (event === "end") {
    fs.rmSync(file, { force: true });
    return;
  }

  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(file, "utf8")); } catch {}

  const now = Date.now() / 1000;
  const s = {
    sid,
    project: p.cwd ? path.basename(p.cwd) : prev.project || "",
    state: prev.state || "idle",
    tool: prev.tool || "",
    kind: prev.kind || "",
    target: prev.target || "",
    history: prev.history || [],
    links: prev.links || {},
    agents: prev.agents || {},
    pending: (prev.pending || []).filter((q) => now - q.ts < PENDING_TTL),
    since: prev.since || now, // when the session's own state last changed
    // Tool calls as { k: kind, s: start, e: end }; `e` is missing while the call runs.
    timeline: prev.timeline || [],
    ts: now,
  };
  // A subagent's events update its mini node, never the session's own state; the files it
  // touches still count for links with other sessions.
  if (event === "substart" || event === "substop" || (p.agent_id && event !== "prompt" && event !== "stop")) {
    if (!agentEvent(s, event, p, now)) return;
    if (event === "pre") addLinks(s, p.tool_name || "", p.tool_input, now);
    s.agents = pruneAgents(s.agents, now);
    return write(file, s);
  }

  // The running call ends with its post, the next call or the turn (the session's own, not a
  // subagent's); a permission prompt or a notification happens during the call, so it stays open.
  const open = s.timeline.at(-1);
  if (open && open.e === undefined && !["permreq", "notify"].includes(event)) open.e = now;

  const before = s.state;
  switch (event) {
    case "start": break; // registers the session as idle so it shows before its first prompt
    case "prompt": s.state = "thinking"; break;
    case "pre": {
      const t = p.tool_name || "";
      const d = describeTool(t, p.tool_input);
      Object.assign(s, { state: "tool", tool: t, kind: d.kind, target: d.target });
      s.history.push({ tool: t, kind: d.kind, target: d.target, ts: now });
      s.history = s.history.slice(-HISTORY_MAX);
      s.timeline.push({ k: d.kind, s: now });
      s.timeline = s.timeline.filter((e) => now - e.s < TIMELINE_TTL).slice(-TIMELINE_MAX);
      addLinks(s, t, p.tool_input, now);
      if (t === "Agent" || t === "Task") {
        const i = p.tool_input || {};
        s.pending.push({ type: clip(i.subagent_type || "general-purpose", 40), label: clip(i.description, 40), ts: now });
        s.pending = s.pending.slice(-PENDING_MAX);
      }
      break;
    }
    case "post": s.state = "thinking"; break;
    case "notify": {
      const m = String(p.message || "").toLowerCase();
      s.state = /permission|approve|allow/.test(m) ? "permission" : "waiting";
      break;
    }
    case "permreq": s.state = "permission"; break;
    case "stop": s.state = "done"; break;
    default: return;
  }
  if (s.state !== before) s.since = now;
  s.agents = pruneAgents(s.agents, now);
  write(file, s);
}

function write(file, s) {
  fs.mkdirSync(dir, { recursive: true });
  const tmp = file + "." + process.pid + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(s));
  fs.renameSync(tmp, file);
}

if (require.main === module) {
  const event = process.argv[2] || "";
  let raw = "";
  process.stdin.on("data", (d) => (raw += d));
  process.stdin.on("end", () => {
    try { run(event, JSON.parse(raw || "{}")); } catch {}
  });
} else {
  module.exports = { shortPath, clip, describeTool, tmuxSessions, linkKeys, pruneAgents, withLock };
}
