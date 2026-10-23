-- Claude constellation: an animated desktop layer drawing every live Claude Code session
-- as a glowing node, with the resources it touches (files, shell, web, MCP, agents)
-- orbiting around it. Drawing lives in render.lua (shared with the xsecurelock saver).
-- Load with: pcall(require, "ui.desktop.claude_constellation")

local awful = require("awful")
local beautiful = require("beautiful")
local gears = require("gears")
local wibox = require("wibox")
local lgi = require("lgi")
local GLib = lgi.GLib

local MODULE_DIR = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local R = dofile(MODULE_DIR .. "render.lua")
local Promview = dofile(MODULE_DIR .. "promview.lua")

-- On battery: "static" freezes everything but the Clawd emotes, "off" hides the layer.
local ON_BATTERY = "static"

-- Theme colours; also written to THEME_FILE so the lock-screen saver (which runs outside
-- Awesome) draws with the same palette.
local THEME_FILE = R.CACHE_DIR .. "theme.json"
local palette = {
  bg = beautiful.black, fg = beautiful.xforeground, dim = beautiful.white,
  thinking = beautiful.accent or beautiful.blue, permission = beautiful.yellow,
  file = beautiful.blue, shell = beautiful.green, search = beautiful.cyan,
  web = beautiful.magenta, agent = beautiful.yellow, mcp = beautiful.red, other = beautiful.white,
}
for k, v in pairs(palette) do if type(v) ~= "string" then palette[k] = nil end end
R.set_palette(palette)
pcall(function()
  gears.filesystem.make_parent_directories(THEME_FILE)
  R.write_json(THEME_FILE, palette)
end)

local static = false
local layout = R.read_layout() -- one of R.LAYOUTS; see set_layout()

-- Render backend: the choice ("auto", "gpu", "cpu"; see set_backend) and the one in use.
-- "auto" uses the GPU when there is one, rechecked every second; a GPU frame that fails
-- switches "auto" to the CPU for the rest of the session.
local backend_choice = R.read_backend()
local gpu_failed = false
local function resolve_backend()
  if backend_choice == "auto" and gpu_failed then return "cpu" end
  return R.resolve_backend(backend_choice)
end
local backend = resolve_backend()

-- Animated surface: one desktop-type wibox on the primary screen, below every client.
local canvas = wibox.widget.base.make_widget()
function canvas:fit(_, width, height) return width, height end

-- The screen's workarea (what the bars leave), relative to the screen.
local function area(s)
  if not s then return nil end
  local g, wa = s.geometry, s.workarea
  return { x = wa.x - g.x, y = wa.y - g.y, w = wa.width, h = wa.height }
end

local box
function canvas:draw(_, cr, width, height)
  local opts = { static = static, layout = layout, backend = backend, area = area(box and box.screen) }
  local ok, err = pcall(R.draw, cr, width, height, opts)
  if not ok and backend == "gpu" and backend_choice == "auto" then
    gpu_failed, backend = true, "cpu"
    gears.debug.print_warning("claude_constellation: GPU frame failed, using the CPU: " .. tostring(err))
    opts.backend = backend
    ok, err = pcall(R.draw, cr, width, height, opts)
  end
  if not ok then gears.debug.print_warning("claude_constellation: " .. tostring(err)) end
end

local function place(s)
  if not s then return end
  if not box then
    box = wibox {
      type = "desktop",
      below = true,
      visible = true,
      input_passthrough = true,
      bg = "#00000000",
      widget = canvas,
    }
  end
  box.screen = s
  box:geometry(s.geometry)
end

place(screen.primary)
screen.connect_signal("property::geometry", function(s) if s == screen.primary then place(s) end end)
screen.connect_signal("primary_changed", function(s) if s == screen.primary then place(s) end end)

-- Redraw at a high rate only while something is happening, to spare the GPU/CPU.
-- While static (on battery) only the emotes move, so it stays at the idle rate.
-- With no session, or the layer hidden, nothing moves: no redraws at all.
local user_hidden = false
local function redraw() canvas:emit_signal("widget::redraw_needed") end
local anim = gears.timer {
  timeout = 1 / R.FPS_IDLE,
  autostart = true,
  callback = redraw,
}

gears.timer {
  timeout = 1,
  autostart = true,
  call_now = true,
  callback = function()
    local active, count = R.read_sessions()
    backend = resolve_backend()
    local battery = R.on_battery()
    static = battery and ON_BATTERY == "static"
    local visible = not user_hidden and not (battery and ON_BATTERY == "off")
    if box then box.visible = visible end

    local alerts_shown = layout == "hud" and R.alerts() ~= nil
    if not visible or (count == 0 and not alerts_shown) then
      if anim.started then anim:stop(); redraw() end -- one last frame clears the old nodes
      return
    end
    local want = 1 / ((active and not static) and R.FPS_ACTIVE or R.FPS_IDLE)
    if anim.timeout ~= want or not anim.started then anim.timeout = want; anim:again() end
  end,
}

-- Promview alerts for the HUD: polled in the background with curl, only while the HUD is
-- the layout and the layer is shown. A failed poll keeps the last alerts, dimmed.
local promview = Promview.read_config()
local promview_busy, promview_last = false, 0
local function promview_poll()
  if not promview or promview_busy or layout ~= "hud" or not (box and box.visible) then return end
  promview_busy, promview_last = true, os.time()
  awful.spawn.easy_async(Promview.command(promview), function(stdout, stderr, _, code)
    promview_busy = false
    local state, err, auth
    if code == 0 then state, err = Promview.parse(stdout) else err, auth = Promview.failure(stderr, code) end
    if state then
      state.ok, state.fetched = true, os.time()
    else
      local prev = R.alerts() or {}
      state = { ok = false, fetched = prev.fetched, alerts = prev.alerts or {},
        counts = prev.counts or {}, total = prev.total or 0, error = err, auth = auth }
    end
    R.set_alerts(state)
    pcall(R.write_alerts, state)
    redraw()
  end)
end
local CONNECTING = { ok = false, alerts = {}, counts = {}, total = 0 } -- until the first poll
if promview then R.set_alerts(CONNECTING) end
local promview_timer = gears.timer {
  timeout = promview and promview.interval or 30, autostart = true, call_now = true, callback = promview_poll,
}

-- Render one frame into a root-sized PNG (the constellation on the primary screen, black
-- elsewhere), e.g. as an i3lock image: `i3lock -c 000000 -i <path>`. Returns true on success.
local function snapshot(path, private)
  local ok = pcall(function()
    local rw, rh = root.size()
    local g = screen.primary.geometry
    local surf = lgi.cairo.ImageSurface.create(lgi.cairo.Format.RGB24, rw, rh)
    local cr = lgi.cairo.Context(surf)
    cr:set_source_rgb(0, 0, 0); cr:paint()
    cr:translate(g.x, g.y)
    cr:rectangle(0, 0, g.width, g.height); cr:clip()
    R.draw(cr, g.width, g.height,
      { private = private, static = static, layout = layout, area = area(screen.primary) })
    assert(surf:write_to_png(path) == "SUCCESS")
    surf:finish()
  end)
  return ok
end

-- Lock the screen on the constellation: animated via xsecurelock + saver.lua when xsecurelock
-- is installed, else an i3lock still (labels hidden), else plain black i3lock.
local function lock()
  if GLib.find_program_in_path("xsecurelock") then
    awful.spawn({ "env", "XSECURELOCK_SAVER=" .. MODULE_DIR .. "saver.lua", "xsecurelock" })
    return
  end
  local cmd = { "i3lock", "-c", "000000" }
  local img = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/constellation-lock.png"
  if snapshot(img, true) then
    table.insert(cmd, "-i")
    table.insert(cmd, img)
  end
  awful.spawn(cmd)
end

-- Switch the presentation: a layout name, or "next" / "prev" to cycle through R.LAYOUTS.
-- The choice is kept for the next start and for the lock screen. Returns the layout shown.
local function set_layout(name)
  local list, i = R.LAYOUTS, 1
  for j, l in ipairs(list) do if l == layout then i = j end end
  if name == "next" or name == nil then name = list[i % #list + 1]
  elseif name == "prev" then name = list[(i - 2) % #list + 1] end
  local known = false
  for _, l in ipairs(list) do if l == name then known = true end end
  if not known then return layout end
  layout = name
  R.write_layout(name)
  if os.time() - promview_last > 5 then promview_poll() end
  canvas:emit_signal("widget::redraw_needed")
  local ok, naughty = pcall(require, "naughty")
  if ok then naughty.notify({ title = "Claude constellation", text = "Layout: " .. name, timeout = 2 }) end
  return layout
end

-- Pick the render backend: "auto" (the GPU if there is one, else the CPU), "gpu" or "cpu".
-- Kept for the next start and for the lock screen. Returns the choice and the backend in use.
local function set_backend(name)
  local known = false
  for _, b in ipairs(R.BACKENDS) do if b == name then known = true end end
  if known then
    backend_choice, gpu_failed = name, false
    backend = resolve_backend()
    R.write_backend(name)
    canvas:emit_signal("widget::redraw_needed")
    local ok, naughty = pcall(require, "naughty")
    if ok then
      naughty.notify({ title = "Claude constellation",
        text = "Rendering: " .. name .. " (" .. backend .. ")", timeout = 2 })
    end
  end
  return backend_choice, backend
end

return {
  set_layout = set_layout,
  layouts = R.LAYOUTS,
  set_backend = set_backend,
  backend = function() return backend_choice, backend end,
  lock = lock,
  snapshot = snapshot,
  -- Poll Promview now (constellation-promview-login calls it after signing in).
  promview_refresh = function()
    promview = Promview.read_config()
    if not promview then R.set_alerts(nil); pcall(R.write_alerts, nil); redraw(); return end
    if not R.alerts() then R.set_alerts(CONNECTING) end
    promview_timer.timeout = promview.interval
    promview_timer:again()
    promview_poll()
  end,
  toggle = function()
    user_hidden = not user_hidden
    if box then box.visible = not user_hidden end
  end,
}
