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
- **Release tooling**: `make release` cuts the changelog, bumps the version and tags; pushing the tag publishes a GitHub release with these notes and a slim tarball.
