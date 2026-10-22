# claude-constellation

Animated wallpaper for AwesomeWM: every active Claude Code session shows up as a glowing node. The resources it works with (files, shell commands, searches, web, MCP servers, subagents) orbit around it.

![Four Claude Code sessions: tools running, a pending permission, a sleeping session](docs/constellation.gif)

- **Node**: pulses with the session state. Accent blue for `thinking`, the tool kind's colour for `tool`, blinking yellow for a pending permission, grey for `done`/`idle`. A session is dimmed after 10 min of inactivity and hidden after 3 h.
- **Clawd emote**: as in [claude-status-bar](https://github.com/MrMichou/claude-status-bar-awesomewm), each node shows an animated crab matching its state: *thinking*, *typing* during a tool call, *listening* while waiting for a permission, *birthday* for 30 s after a turn ends, *sleeping* when the session is idle. Artwork: [xixicc186/clawd-emotes-skill](https://github.com/xixicc186/clawd-emotes-skill).
- **Satellites**: the session's last 10 targets. Their link fades out over 5 min, and a pulse travels along the link on every tool call.
- **Links between sessions**: two sessions that used the same resource within the last half hour are joined by a labelled curve ("⇄ tmux 0", "⇄ deploy.yml") with a glow running along it. Recognised resources: the same file (Read/Edit/Write), or the same tmux session driven via `tmux … -t <target>` (including `-t $P` with `P=0:0`, or a `for p in 0:0.0 0:0.1` loop). On the lock screen, only "tmux" / "file" is shown.
- **Colours by kind**: file = blue, shell = green, search = cyan, web = magenta, agent = yellow, mcp = red.

## How it works

- `hooks/track.js` is a Claude Code hook. It runs from `SessionStart` (the session shows up idle before its first prompt) and writes `~/.claude/constellation/<session_id>.json` (state, tool, target, history) and deletes the file on `SessionEnd`.
- **Sessions already open**: `render.lua` also reads Claude Code's internal registry (`~/.claude/sessions/<pid>.json`) to show, idle, live sessions that have no hook file yet (opened before the install, or with no activity). The process must exist and its start time must match. Undocumented format: at worst these sessions don't show up, and the hooks stay the main source.
- `awesome/claude_constellation/` is the Lua module: `render.lua` draws (cairo, no Awesome dependency), `init.lua` hooks it into Awesome, `saver.lua` animates it on the lock screen. It creates a `type = "desktop"` wibox below all windows on the primary screen and draws with Cairo. It runs at 30 fps while a session is working, 8 fps otherwise.
- **On battery** (system battery `Discharging`), only the Clawd emotes stay animated: drift, pulsing, orbits and pulses are frozen, and redraws are capped at 8 fps. Set `ON_BATTERY = "off"` in `init.lua` to hide the layer entirely on battery.

## Installation

```sh
node install.js            # hooks in ~/.claude/settings.json + module symlink
# then in ~/.config/awesome/rc.lua, after beautiful.init(...) but BEFORE require("ui")
# (otherwise the desktop layer covers the bar):
#   pcall(require, "ui.desktop.claude_constellation")
echo 'awesome.restart()' | awesome-client
```

### Animated lock screen (xsecurelock)

`lock()` locks the screen on the animated constellation through [xsecurelock](https://github.com/google/xsecurelock) (`pacman -S xsecurelock`): `saver.lua` (Lua + lgi; it re-executes itself under the first of lua5.4, lua5.3, lua5.5, lua, luajit, lua5.1 that can load lgi, since on Arch `lua53-lgi` pairs with AwesomeWM) draws into the lock window with the same engine (`render.lua`) as the wallpaper, in private mode (no paths, commands or current tool, since anyone can see a locked screen) and with the same battery rule. xsecurelock stays in charge of authentication: if the saver crashes, the screen stays locked. Without xsecurelock, `lock()` falls back to a still image for i3lock (`snapshot(path, private)`).

![Lock screen: the same constellation, without labels](docs/lock.gif)

```lua
awful.key({ modkey }, "l", function()
  local ok, cc = pcall(require, "ui.desktop.claude_constellation")
  if ok and cc.lock then cc.lock() else awful.spawn({ "i3lock", "-c", "000000" }) end
end)
```

The Awesome theme colours are written to `~/.cache/claude-constellation/theme.json` so the saver, which runs outside Awesome, uses the same palette.

To uninstall: `node install.js --uninstall`, then remove the line added to `rc.lua`.

## Demos

The GIFs in `docs/` are rendered offline by the real engine (`render.lua`) from fake sessions and a simulated clock: `demo/record.sh` (lua5.4, lgi, ffmpeg) regenerates them without touching `~/.claude`. The scenario lives in `demo/record.lua`.

## Tests

```sh
npm ci && make test   # = npm test + luacheck + Lua specs
make test-docker      # luacheck + Lua specs in the CI's Arch container (no local busted/luacheck needed)
```

- `test/` (vitest): unit tests of the hook's pure helpers (tool classification, tmux target and shared-file detection, false positives) and end-to-end runs of `hooks/track.js` and `install.js` against a throwaway `$HOME`.
- `spec/` (busted, Lua 5.4 + lgi): `render.lua` session loading, battery detection on a fake `/sys/class/power_supply`, palette, labels and private mode, shared-resource links and the battery freeze, asserted through a recording cairo context, plus a real cairo frame and sprite-asset checks; `saver.lua` refuses to run without a window.
- The Lua specs run with `lua5.4` directly (`make test-lua`): Arch's `busted` binary targets Lua 5.5, where lgi does not load. Needs `lua54-lgi lua54-busted luacheck`.
- CI (`.github/workflows/ci.yml`) runs the JS tests on Node 18/20/22, luacheck, and the Lua specs in an Arch container.

## Releasing

Changes go under `## [Unreleased]` in `CHANGELOG.md` as they land. Then, on a clean `main`:

```sh
make release V=minor DRY=1          # preview the version and notes
make release V=minor                # or patch / major / X.Y.Z
git push origin main --follow-tags
```

`scripts/release.js` runs `npm test`, moves the [Unreleased] entries under `## [X.Y.Z] - date`, bumps `package.json`, commits `chore: release X.Y.Z` and tags `vX.Y.Z`. The pushed tag triggers `.github/workflows/release.yml`: it re-runs CI, checks the tag against `package.json`, and publishes a GitHub release whose notes are that changelog section plus a compare link, with a `claude-constellation-X.Y.Z.tar.gz` that leaves out tests, demos and GIFs (`.gitattributes`).
