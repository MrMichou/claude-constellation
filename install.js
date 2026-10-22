#!/usr/bin/env node
// Installs claude-constellation:
//  - merges the tracking hooks into ~/.claude/settings.json (idempotent, backup kept)
//  - symlinks the AwesomeWM module to ~/.config/awesome/ui/desktop/claude_constellation
// Usage: node install.js [--uninstall]

const fs = require("fs");
const os = require("os");
const path = require("path");

const home = os.homedir();
const uninstall = process.argv.includes("--uninstall");
const track = path.join(__dirname, "hooks", "track.js");
const settingsPath = path.join(home, ".claude", "settings.json");
const linkDir = path.join(home, ".config", "awesome", "ui", "desktop");
const link = path.join(linkDir, "claude_constellation");

const EVENTS = {
  UserPromptSubmit: "prompt",
  PreToolUse: "pre",
  PostToolUse: "post",
  Notification: "notify",
  PermissionRequest: "permreq",
  Stop: "stop",
  SubagentStart: "substart",
  SubagentStop: "substop",
  SessionEnd: "end",
};
// Our hooks, from this checkout or any other clone/worktree of claude-constellation: replacing
// them all keeps a second checkout from leaving an older track.js running alongside.
const OURS = /claude-constellation[^\s/]*\/hooks\/track\.js\b/;
const ours = (cmd) => (cmd || "").includes(track) || OURS.test(cmd || "");
const MATCHER = new Set(["PreToolUse", "PostToolUse", "PermissionRequest", "SubagentStart", "SubagentStop"]);

// A fresh machine may have no settings.json yet: start from {} (and keep a backup otherwise).
let settings = {};
if (fs.existsSync(settingsPath)) {
  settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  fs.copyFileSync(settingsPath, settingsPath + ".bak-constellation");
} else {
  fs.mkdirSync(path.dirname(settingsPath), { recursive: true });
}
settings.hooks = settings.hooks || {};

for (const [evt, arg] of Object.entries(EVENTS)) {
  const entries = (settings.hooks[evt] || [])
    .map((e) => ({ ...e, hooks: (e.hooks || []).filter((h) => !ours(h.command)) }))
    .filter((e) => e.hooks.length > 0);
  if (!uninstall) {
    const entry = { hooks: [{ type: "command", command: `${process.execPath} ${track} ${arg}` }] };
    if (MATCHER.has(evt)) entry.matcher = "*";
    entries.push(entry);
  }
  if (entries.length) settings.hooks[evt] = entries; else delete settings.hooks[evt];
}
fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
console.log(`${uninstall ? "Removed" : "Installed"} hooks in ${settingsPath}`);

fs.rmSync(link, { force: true });
if (!uninstall) {
  fs.mkdirSync(linkDir, { recursive: true });
  fs.symlinkSync(path.join(__dirname, "awesome", "claude_constellation"), link);
  console.log(`Linked ${link}`);
  console.log('Add to rc.lua: pcall(require, "ui.desktop.claude_constellation")');
}
