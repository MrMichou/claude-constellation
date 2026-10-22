# Changelog

All notable changes to claude-constellation are documented here. This project follows
[Semantic Versioning](https://semver.org/). Add entries under [Unreleased] as you go;
`make release V=<patch|minor|major|X.Y.Z>` moves them under the new version.

## [Unreleased]

### Added
- **Animated AwesomeWM wallpaper.** Every active Claude Code session is a glowing node on a `type = "desktop"` wibox, pulsing with its state (thinking, tool, pending permission, done/idle); its last 10 targets (files, shell, search, web, MCP, agents) orbit as colour-coded satellites, with a pulse along the link on every tool call. Inactive sessions dim after 10 min and hide after 3 h.
- **Clawd emotes** per session state (thinking, typing, listening, birthday, sleeping), as in claude-status-bar.
- **Links between sessions** that used the same file or drove the same tmux session within the last half hour, drawn as labelled curves ("⇄ tmux 0", "⇄ deploy.yml").
- **Battery mode.** On battery only the Clawd emotes stay animated and redraws are capped at 8 fps; `ON_BATTERY = "off"` hides the layer.
- **Lock screen.** `lock()` runs the animated constellation as an xsecurelock saver in private mode (no paths, commands or current tool); `snapshot()` falls back to a still image for i3lock.
- **Installer** (`node install.js [--uninstall]`): idempotent hook merge into `~/.claude/settings.json` with a backup, plus the module symlink.
- **README demos** rendered offline by the real renderer (`demo/record.sh`).
- **Tests and CI**: vitest suites for the hook and installer, busted specs for the renderer and saver, luacheck, and a GitHub Actions workflow (Node 18/20/22, Lua 5.4 in an Arch container).
- **Subagents as mini Clawds.** Each subagent circles its session, labelled with its Agent call's description: running during a tool call, walking while thinking, listening on a permission, partying then fading once done. Past 6 running subagents they are grouped by type ("general-purpose ×10"), and past 6 groups the smallest merge into "+k agents". The hook now listens to `SubagentStart`/`SubagentStop` (re-run `node install.js`) and routes tool events carrying `agent_id` to the subagent instead of the session.
- **End-to-end test** (`e2e/run.sh`, `make test-e2e`), also run in CI: installer, then the installed hook commands fed a subagent fan-out, then every layout drawn from the resulting files under Lua 5.4, 5.1 and LuaJIT.
- **`workflow` demo scenario** (`demo/record.sh subagents`): a big multi-agent fan-out, rendered to `docs/subagents.gif`.
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
