#!/usr/bin/env node
// Installs claude-constellation:
//  - merges the tracking hooks into ~/.claude/settings.json (idempotent, backup kept)
//  - symlinks the AwesomeWM module to ~/.config/awesome/ui/desktop/claude_constellation
//  - symlinks the `constellation-layout` and `constellation-promview-login` commands to ~/.local/bin
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
const COMMANDS = {
  "constellation-layout": "switch layouts: constellation-layout [next|lanes|cards|...]",
  "constellation-promview-login": "sign the HUD in to an OIDC Promview",
};

const EVENTS = {
  SessionStart: "start",
  UserPromptSubmit: "prompt",
  PreToolUse: "pre",
  PostToolUse: "post",
  Notification: "notify",
  PermissionRequest: "permreq",
  Stop: "stop",
  SessionEnd: "end",
};
const MATCHER = new Set(["PreToolUse", "PostToolUse", "PermissionRequest"]);

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
    .map((e) => ({ ...e, hooks: (e.hooks || []).filter((h) => !(h.command || "").includes(track)) }))
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

// A command link is only replaced or removed when it is ours: never clobber another tool.
for (const [name, what] of Object.entries(COMMANDS)) {
  const cmd = path.join(__dirname, "bin", name);
  const cmdLink = path.join(home, ".local", "bin", name);
  let cmdTarget = null;
  try { cmdTarget = fs.readlinkSync(cmdLink); } catch {}
  const cmdFree = !fs.existsSync(cmdLink) && cmdTarget === null;
  if (cmdTarget === cmd) fs.rmSync(cmdLink, { force: true });
  if (!uninstall) {
    if (cmdFree || cmdTarget === cmd) {
      fs.mkdirSync(path.dirname(cmdLink), { recursive: true });
      fs.symlinkSync(cmd, cmdLink);
      console.log(`Linked ${cmdLink} (${what})`);
    } else {
      console.log(`Skipped ${cmdLink}: it already exists and is not ours`);
    }
  }
}
