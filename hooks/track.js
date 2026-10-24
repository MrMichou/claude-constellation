#!/usr/bin/env node
// Claude Code hook: records, per session, what the session is doing and which resources
// it touches, for the AwesomeWM desktop "constellation".
// Writes ~/.claude/constellation/<session_id>.json atomically. Never fails the hook.
// Usage: node track.js <start|prompt|pre|post|notify|permreq|stop|end>

const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = path.join(os.homedir(), ".claude", "constellation");
const HISTORY_MAX = 10;
const LINKS_MAX = 20; // shared-resource keys kept per session
const LINK_TTL = 3600; // seconds a shared resource stays linkable
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

function run(event, p) {
  const sid = String(p.session_id || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64);
  if (!sid) return;
  const file = path.join(dir, sid + ".json");

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
    // Tool calls as { k: kind, s: start, e: end }; `e` is missing while the call runs.
    timeline: prev.timeline || [],
    ts: now,
  };
  // The running call ends with its post, the next call or the turn; a permission prompt or a
  // notification happens during the call, so it stays open.
  const open = s.timeline.at(-1);
  if (open && open.e === undefined && !["permreq", "notify"].includes(event)) open.e = now;

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
      for (const l of linkKeys(t, p.tool_input)) s.links[l.key] = { kind: l.kind, label: l.label, ts: now };
      s.links = Object.fromEntries(Object.entries(s.links)
        .filter(([, l]) => now - l.ts < LINK_TTL)
        .sort(([, a], [, b]) => b.ts - a.ts)
        .slice(0, LINKS_MAX));
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
  module.exports = { shortPath, clip, describeTool, tmuxSessions, linkKeys };
}
