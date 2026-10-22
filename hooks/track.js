#!/usr/bin/env node
// Claude Code hook: records, per session, what the session is doing and which resources
// it touches, for the AwesomeWM desktop "constellation".
// Writes ~/.claude/constellation/<session_id>.json atomically. Never fails the hook.
// Usage: node track.js <prompt|pre|post|notify|permreq|stop|end>

const fs = require("fs");
const os = require("os");
const path = require("path");

const dir = path.join(os.homedir(), ".claude", "constellation");
const event = process.argv[2] || "";
const HISTORY_MAX = 10;

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

let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  try { run(JSON.parse(raw || "{}")); } catch {}
});

function run(p) {
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
    ts: now,
  };

  switch (event) {
    case "prompt": s.state = "thinking"; break;
    case "pre": {
      const t = p.tool_name || "";
      const d = describeTool(t, p.tool_input);
      Object.assign(s, { state: "tool", tool: t, kind: d.kind, target: d.target });
      s.history.push({ tool: t, kind: d.kind, target: d.target, ts: now });
      s.history = s.history.slice(-HISTORY_MAX);
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

  fs.mkdirSync(dir, { recursive: true });
  const tmp = file + "." + process.pid + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(s));
  fs.renameSync(tmp, file);
}
