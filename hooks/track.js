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
const NOTES_MAX = 60; // markdown notes kept per session, for the obsi-constellation layout
const NOTES_TTL = 3 * 3600;

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

// Project shown for the session. The hook's `cwd` follows the session's `cd`s (a session
// working in <repo>/wiki would be named "wiki"), so the project root Claude Code exports as
// CLAUDE_PROJECT_DIR wins. A subagent with `isolation: "worktree"` runs in
// <repo>/.claude/worktrees/<agent-id> under the parent's session id: it still is <repo>.
function projectName(cwd, prev, root = process.env.CLAUDE_PROJECT_DIR) {
  const dir = root || cwd;
  if (!dir) return prev || "";
  return path.basename(dir.replace(/\/\.claude\/worktrees\/[^/]+(?:\/.*)?$/, ""));
}

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

// A markdown note read or edited, as { key, op }: key is its absolute path (an Obsidian vault is
// a folder of .md files), or "obsidian:<vault-relative path>" for a note reached through an
// Obsidian MCP server; op is "r" (read) or "w" (written). null for anything else.
function noteKey(t, input) {
  const i = input || {};
  if (["Read", "Edit", "Write", "MultiEdit"].includes(t)) {
    const f = i.file_path || "";
    return /\.md$/i.test(f) && path.isAbsolute(f) ? { key: f, op: t === "Read" ? "r" : "w" } : null;
  }
  if (t.startsWith("mcp__") && /obsidian/i.test(t)) {
    const f = [i.filepath, i.path, i.file, i.filename, i.note].find((v) => typeof v === "string" && v);
    if (!f || f.includes("..")) return null;
    const method = t.split("__")[2] || "";
    return { key: "obsidian:" + f, op: /write|append|patch|update|create|edit|put|replace|insert/i.test(method) ? "w" : "r" };
  }
  return null;
}

// Markdown notes a shell command touches, as [{ key, op }] like noteKey: sessions that work
// on a vault with cat/sed/grep/tee never call Read or Edit. Paths are resolved against the
// call's cwd, following the command's own `cd`s and `VAR=value` assignments. A note is written when it is the target of
// `>`/`>>`, `tee`, `sed -i` or the destination of `cp`/`mv`; read otherwise, and only if it
// exists (a `*.md` glob or a pattern is not a note). Heredoc bodies are skipped.
const BASH_NOTES_MAX = 20;
function bashNotes(cmd, cwd) {
  if (typeof cmd !== "string" || !/\.md\b/i.test(cmd)) return [];
  const home = os.homedir();
  // Drop heredoc bodies: <<EOF ... EOF, <<'EOF', <<-"EOF".
  cmd = cmd.replace(/<<-?\s*(['"]?)(\w+)\1[^\n]*\n[\s\S]*?\n\s*\2\s*(?=\n|$)/g, (m) => m.split("\n")[0]);
  let dir = cwd && path.isAbsolute(cwd) ? cwd : null;
  const out = new Map(), vars = {};
  const resolve = (f) => {
    if (f.startsWith("~/")) return path.join(home, f.slice(2));
    if (path.isAbsolute(f)) return path.normalize(f);
    return dir ? path.join(dir, f) : null;
  };
  for (const seg of cmd.split(/&&|\|\||[;|\n]/)) {
    // Words with their quotes removed (`F="a b.md"` is one word), `$VAR`/`${VAR}` replaced
    // by an earlier `VAR=value` of the command; a word with a variable left is dropped.
    let words = (seg.match(/(?:"[^"]*"|'[^']*'|[^\s"'])+/g) || []).map((w) => w.replace(/["']/g, ""));
    while (words.length && /^[A-Za-z_]\w*=/.test(words[0])) {
      const [, k, v] = words.shift().match(/^(\w+)=(.*)$/);
      vars[k] = v.replace(/\$\{?(\w+)\}?/g, (m, n) => vars[n] ?? m);
    }
    words = words.map((w) => w.replace(/\$\{?(\w+)\}?/g, (m, n) => vars[n] ?? m));
    if (!words.length) continue;
    const prog = path.basename(words[0]);
    if (prog === "cd") {
      const d = words[1] ? resolve(words[1]) : home;
      if (d) dir = d;
      continue;
    }
    if (prog === "rm") continue;
    const inPlace = prog === "sed" && words.some((w) => /^-[a-z]*i/.test(w) || w === "--in-place");
    const files = [];
    for (let k = 0; k < words.length; k++) {
      let w = words[k], redirect = false;
      const m = w.match(/^\d?>>?(.*)$/);
      if (m) { redirect = true; w = m[1] || words[++k] || ""; }
      if (!/\.md$/i.test(w) || /[$*?`{}]/.test(w)) continue;
      const f = resolve(w);
      if (f) files.push({ f, w: redirect || prog === "tee" || inPlace });
    }
    if ((prog === "cp" || prog === "mv") && files.length) files[files.length - 1].w = true;
    for (const { f, w } of files) {
      if (!w && !fs.existsSync(f)) continue;
      const op = w ? "w" : "r";
      if (!out.has(f) || op === "w") out.set(f, op);
    }
  }
  return [...out].slice(0, BASH_NOTES_MAX).map(([key, op]) => ({ key, op }));
}

// Markdown files under root modified at or after `since` (seconds): the notes a shell call
// wrote through a script (python, node...), which its command line does not tell. Bounded:
// skips .git, node_modules and hidden dirs, stops after SCAN_MAX entries, never scans $HOME
// or / themselves (a session started there would walk the whole disk).
const SCAN_MAX = 3000;
function modifiedNotes(root, since) {
  if (!root || !path.isAbsolute(root) || root === "/" || root === os.homedir()) return [];
  const out = [], stack = [root];
  let seen = 0;
  while (stack.length && seen < SCAN_MAX) {
    const d = stack.pop();
    let entries = [];
    try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch { continue; }
    for (const e of entries) {
      if (++seen > SCAN_MAX) break;
      const f = path.join(d, e.name);
      if (e.isDirectory()) {
        if (!e.name.startsWith(".") && e.name !== "node_modules") stack.push(f);
      } else if (e.isFile() && /\.md$/i.test(e.name)) {
        try { if (fs.statSync(f).mtimeMs / 1000 >= since) out.push(f); } catch {}
      }
    }
  }
  return out.slice(0, BASH_NOTES_MAX);
}

// Records the notes a tool call touches under s.notes[key] = { r, w } (last read, last write).
function addNote(s, t, input, now, cwd) {
  const n = noteKey(t, input);
  const all = t === "Bash" ? bashNotes((input || {}).command, cwd) : n ? [n] : [];
  for (const e of all) s.notes[e.key] = { ...s.notes[e.key], [e.op]: now };
  const last = (e) => Math.max(e.r || 0, e.w || 0);
  s.notes = Object.fromEntries(Object.entries(s.notes)
    .filter(([, e]) => now - last(e) < NOTES_TTL)
    .sort(([, a], [, b]) => last(b) - last(a))
    .slice(0, NOTES_MAX));
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
      fd = fs.openSync(lock, "wx", 0o600);
    } catch (e) {
      if (Date.now() > deadline) break;
      // No data dir yet: create it (another hook may be doing the same) and retry the lock.
      if (e.code === "ENOENT") { try { fs.mkdirSync(dir, { recursive: true, mode: 0o700 }); } catch {} continue; }
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
    project: projectName(p.cwd, prev.project),
    state: prev.state || "idle",
    tool: prev.tool || "",
    kind: prev.kind || "",
    target: prev.target || "",
    history: prev.history || [],
    links: prev.links || {},
    notes: prev.notes || {},
    agents: prev.agents || {},
    pending: (prev.pending || []).filter((q) => now - q.ts < PENDING_TTL),
    since: prev.since || now, // when the session's own state last changed
    // Tool calls as { k: kind, s: start, e: end, id }; `e` is missing while the call runs, and
    // a running call also keeps its { t: tool, g: target } to be shown again (see "post").
    timeline: prev.timeline || [],
    ts: now,
  };
  // A subagent's events update its mini node, never the session's own state; the files it
  // touches still count for links with other sessions.
  if (event === "substart" || event === "substop" || (p.agent_id && event !== "prompt" && event !== "stop")) {
    if (!agentEvent(s, event, p, now)) return;
    if (event === "pre") {
      addLinks(s, p.tool_name || "", p.tool_input, now);
      addNote(s, p.tool_name || "", p.tool_input, now, p.cwd);
    }
    s.agents = pruneAgents(s.agents, now);
    return write(file, s);
  }

  // Calls carry their tool_use_id: subagents run several at once, and each call ends with its
  // own post. The turn's end (stop, next prompt) closes whatever is left. A call without an id
  // (older Claude Code) ends with the next event, except a permission prompt or a notification,
  // which happen during the call.
  const id = p.tool_use_id;
  for (const e of s.timeline) {
    if (e.e !== undefined) continue;
    if (e.id ? ["stop", "prompt"].includes(event) || (event === "post" && e.id === id)
      : !["permreq", "notify"].includes(event)) {
      e.e = now;
      delete e.t; delete e.g;
    }
  }

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
      s.timeline.push({ k: d.kind, s: now, ...(id && { id, t, g: d.target }) });
      s.timeline = s.timeline.filter((e) => now - e.s < TIMELINE_TTL).slice(-TIMELINE_MAX);
      addLinks(s, t, p.tool_input, now);
      addNote(s, t, p.tool_input, now, p.cwd);
      if (t === "Agent" || t === "Task") {
        const i = p.tool_input || {};
        s.pending.push({ type: clip(i.subagent_type || "general-purpose", 40), label: clip(i.description, 40), ts: now });
        s.pending = s.pending.slice(-PENDING_MAX);
      }
      break;
    }
    case "post": {
      // Notes a shell call wrote without naming them (a script): the project's .md files
      // modified since the call started.
      const call = id && s.timeline.find((e) => e.id === id);
      if (call && (p.tool_name || call.t) === "Bash") {
        for (const f of modifiedNotes(process.env.CLAUDE_PROJECT_DIR || p.cwd, call.s - 1)) {
          s.notes[f] = { ...s.notes[f], w: now };
        }
      }
      // Another call still running (parallel subagents): show it rather than "thinking". It
      // may have left the 10-call history long ago, so its label comes from the timeline.
      const running = s.timeline.filter((e) => e.e === undefined).at(-1);
      if (!running) s.state = "thinking";
      else Object.assign(s, { state: "tool", tool: running.t || s.tool, kind: running.k, target: running.g ?? s.target });
      break;
    }
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
  // Private: session files hold the start of shell commands, which may contain secrets.
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tmp = file + "." + process.pid + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(s), { mode: 0o600 });
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
  module.exports = { shortPath, clip, describeTool, tmuxSessions, linkKeys, noteKey, bashNotes, modifiedNotes, projectName, pruneAgents, withLock };
}
