#!/bin/sh
_=[[
# Polyglot: sh runs this block, which re-executes the file under the first Lua that can load
# lgi (distros name and version the interpreter differently); Lua sees it as a comment and a
# string. A plain `#!/usr/bin/env lua5.x` shebang can't probe for lgi.
for lua in lua5.4 lua5.3 lua5.5 lua luajit lua5.1; do
  if command -v "$lua" >/dev/null 2>&1 && "$lua" -e 'require("lgi")' >/dev/null 2>&1; then
    exec "$lua" "$0" "$@"
  fi
done
echo "claude-constellation-saver: no Lua interpreter with lgi found" >&2
exit 1
]]
-- xsecurelock saver: animates the Claude constellation inside the lock window, in private mode
-- (no paths, commands or tool targets). xsecurelock runs it with XSECURELOCK_SAVER=<this file>
-- and hands over the window to draw into in $XSCREENSAVER_WINDOW. The saver has no say in
-- authentication: if it crashes, the screen just stays locked (blank).

local xid = tonumber(os.getenv("XSCREENSAVER_WINDOW") or "")
if not xid then
  io.stderr:write("claude-constellation-saver: XSCREENSAVER_WINDOW is not set\n")
  os.exit(1)
end

local DIR = (arg and arg[0] or ""):match("^(.*/)") or "./"
local lgi = require("lgi")
local GLib, cairo = lgi.GLib, lgi.cairo
local Gtk = lgi.require("Gtk", "3.0")
local Gdk = lgi.require("Gdk", "3.0")
local GdkX11 = lgi.require("GdkX11", "3.0")
local R = dofile(DIR .. "render.lua")

-- Palette written by the Awesome module (init.lua); defaults if Awesome never ran it.
R.set_palette(R.read_json(R.CACHE_DIR .. "theme.json"))
local layout = R.read_layout() -- the one chosen on the desktop
local backend_choice = R.read_backend() -- likewise; "auto" is rechecked every second
local backend = R.resolve_backend(backend_choice)
local eco_choice = R.read_eco() -- likewise

Gtk.init()
local display = Gdk.Display.get_default()
local win = GdkX11.X11Window.foreign_new_for_display(display, xid)

-- Each frame is drawn off-screen, then copied to the window in one paint (no flicker). On the
-- GPU the buffer is a surface similar to the window (an X pixmap), else an in-memory image.
local static, eco = false, false
local buf, buf_cr, bw, bh, bb
local function frame()
  local w, h = win:get_width(), win:get_height()
  if not buf or w ~= bw or h ~= bh or backend ~= bb then
    buf = backend == "gpu" and win:create_similar_surface(cairo.Content.COLOR, w, h)
      or cairo.ImageSurface.create(cairo.Format.RGB24, w, h)
    bw, bh, bb = w, h, backend
    buf_cr = cairo.Context(buf)
  end
  R.draw(buf_cr, w, h, { private = true, static = static, still = eco, layout = layout, backend = backend })
  local out = Gdk.cairo_create(win)
  out:set_source_surface(buf, 0, 0)
  out:paint()
  display:flush()
end

-- Same pacing as the desktop layer: fast while a session works, idle rate otherwise or on
-- battery, a frame a second in eco mode.
local fps, timer_id, last_err
local function schedule(want)
  if want == fps and timer_id then return end
  fps = want
  if timer_id then GLib.source_remove(timer_id) end
  timer_id = GLib.timeout_add(GLib.PRIORITY_DEFAULT, math.floor(1000 / fps), function()
    local ok, err = pcall(frame)
    if not ok and backend == "gpu" and backend_choice == "auto" then
      backend, backend_choice = "cpu", "cpu" -- same fallback as the desktop layer
      ok, err = pcall(frame)
    end
    if not ok and err ~= last_err then
      last_err = err
      io.stderr:write("claude-constellation-saver: ", tostring(err), "\n")
    end
    return true
  end)
end

local function poll()
  local active, count = R.read_sessions()
  active = active or R.fx_playing()
  -- Promview alerts written by the desktop layer, only shown by the HUD; old ones are stale.
  local alerts = layout == "hud" and R.read_alerts() or nil
  if alerts and os.time() - alerts.fetched > 300 then alerts.ok, alerts.error = false, "stale" end
  R.set_alerts(alerts)
  static = R.on_battery()
  eco = R.eco_active(eco_choice, static)
  if backend_choice == "auto" then backend = R.resolve_backend("auto") end
  -- No session: an empty background, repainted once a second in case the window was exposed.
  schedule(((count == 0 and not alerts) or eco) and R.FPS_ECO
    or (active and not static) and R.FPS_ACTIVE or R.FPS_IDLE)
  collectgarbage("step") -- per-frame cairo contexts are only freed by the GC
  return true
end

poll()
GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, poll)
GLib.MainLoop():run()
