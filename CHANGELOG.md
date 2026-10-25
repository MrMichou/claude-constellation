# Changelog

All notable changes to claude-constellation are documented here. This project follows
[Semantic Versioning](https://semver.org/). Add entries under [Unreleased] as you go;
`make release V=<patch|minor|major|X.Y.Z>` moves them under the new version.

## [Unreleased]

### Added
- **Eco mode** (`constellation-eco [toggle|on|off|auto]`, or `set_eco()`): nothing moves, not even the Clawd emotes, and one frame a second follows the sessions; about 3% of a CPU core instead of 10% with a working session. `auto`, the default, turns it on while on battery (instead of the 8 fps freeze), and the lock screen follows the same choice. `install.js` links the new command.
- **No redraws while a window covers the whole wallpaper** (maximised, fullscreen, or alone in a tiled layout); the animation resumes when it moves away.
- **Promview alerts in the HUD.** With a url in `~/.config/claude-constellation/promview.conf` (or `PROMVIEW_URL`), the hud layout polls a [Promview](https://github.com/cropalato/promview) server with `curl` in the background and turns the desktop left of the sessions into a board behind the windows: the count per severity in large type, and one card per alert name (count, newest age, instances), most severe first; the last alerts stay, dimmed, while the server can't be reached. The lock screen shows the same board, through a cache file the desktop layer keeps up to date. For a server that requires OIDC, `constellation-promview-login` signs in through the browser like the Promview desktop client and keeps the session token in the keyring (`secret-tool`); the HUD says "sign in needed" when it expires.

### Fixed
- **Sessions with subagents** (which share the parent's session id):
  - the node keeps its project name instead of taking the subagent's worktree (`agent-<id>`);
  - parallel tool calls are tracked by `tool_use_id`, so each call ends with its own result and the node stays on a call that is still running (named even once it has left the 10-call history) instead of going back to *thinking*.
- **Failed tool calls** end on `PostToolUseFailure` (rerun `node install.js` to add the hook) instead of staying open until the end of the turn.

### Security
- **vitest 2.1 → 5.0** (dev only): clears the `npm audit` advisories in vitest, vite, esbuild and tinypool. JS tests now run on Node 22/24/26 (vitest 5 needs Node ≥ 22.12); the hook itself is unchanged.
- **Private session files**: `~/.claude/constellation/` is created `0700` and session files are written `0600`, since they hold the start of shell commands.
- **Lock-screen image** goes to the per-user runtime dir (GLib, falls back to `~/.cache`) instead of `/tmp` when `XDG_RUNTIME_DIR` is unset.
- **Installer** quotes the node and hook paths in the hook commands, so a checkout path with spaces works.

## [0.1.0] - 2026-10-23

### Added
- **Animated AwesomeWM wallpaper.** Every active Claude Code session is a glowing node on a `type = "desktop"` wibox, pulsing with its state (thinking, tool, pending permission, done/idle); its last 10 targets (files, shell, search, web, MCP, agents) orbit as colour-coded satellites, with a pulse along the link on every tool call. Inactive sessions dim after 10 min and hide after 3 h.
- **Clawd emotes** per session state (thinking, typing, listening, birthday, sleeping), as in claude-status-bar.
- **Links between sessions** that used the same file or drove the same tmux session within the last half hour, drawn as labelled curves ("⇄ tmux 0", "⇄ deploy.yml").
- **Battery mode.** On battery only the Clawd emotes stay animated and redraws are capped at 8 fps; `ON_BATTERY = "off"` hides the layer.
- **Lock screen.** `lock()` runs the animated constellation as an xsecurelock saver in private mode (no paths, commands or current tool); `snapshot()` falls back to a still image for i3lock.
- **Installer** (`node install.js [--uninstall]`): idempotent hook merge into `~/.claude/settings.json` with a backup, plus the module symlink.
- **README demos** rendered offline by the real renderer (`demo/record.sh`).
- **Tests and CI**: vitest suites for the hook and installer, busted specs for the renderer and saver, luacheck, and a GitHub Actions workflow (Node 18/20/22, Lua 5.4 in an Arch container).
- **Release tooling**: `make release` cuts the changelog, bumps the version and tags; pushing the tag publishes a GitHub release with these notes and a slim tarball.
- **Layouts.** The same sessions can be drawn nine ways: constellation (default), lanes (tool calls over the last 20 minutes), cards, resources (shared files and tmux sessions in the middle), and kanban, radar, strip, hud and popup, which put the session that needs you first. Nodes glide between layouts; every layout hides paths and commands on the lock screen.
- **`constellation-layout [next|prev|<layout>]`** switches layouts in the running Awesome (linked into `~/.local/bin` by the installer), as does `set_layout()` from a key binding; the choice is remembered and used by the lock screen.
- **Tool-call timeline** in the session files (30 minutes), used by the lanes, radar and strip layouts.
- **GPU or CPU rendering, GPU first.** With `auto` (default) the layer draws on the GPU when a graphics driver is bound to a DRM card, straight onto the X surface with glows and sprites kept as X pixmaps (6 sessions at 1920×1080 on an NVIDIA GTX 1650 Ti: constellation 10.5 → 4.1 ms per frame, 3.4 → 2.6 ms on average over the nine layouts); otherwise, or after a failed GPU frame, it draws into an in-memory image and copies it once. Rechecked every second; `set_backend("auto"|"gpu"|"cpu")` forces one, remembered and shared with the lock screen.
- **Idle and already-running sessions show up**: the hook runs from `SessionStart`, and sessions with no hook file yet are read from Claude Code's registry (`~/.claude/sessions`).

### Changed
- **Cheaper frames**: glows are cached surfaces, label widths are memoised, satellites and links are computed once per reload, and session files are only parsed when they change (~13.5 → ~5.3 ms per 1920×1080 frame). The animation timer stops while no session is shown or the layer is hidden.

### Fixed
- **Lock-screen saver** runs under whichever Lua can load lgi (lua5.4, lua5.3, lua5.5, lua, luajit, lua5.1), instead of dying when lgi is only installed for Lua 5.3; the layouts stay compatible with Lua 5.1/LuaJIT.
