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
local PromviewBus = dofile(MODULE_DIR .. "promview_bus.lua")

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
-- Eco mode: the choice ("auto", "on", "off"; see set_eco) and whether it is on right now.
local eco_choice, eco = R.read_eco(), false
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
  local opts = { static = static, still = eco, layout = layout, backend = backend,
    area = area(box and box.screen) }
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

-- A window hiding the whole layer (maximised, fullscreen, or alone in a tiled layout): nobody
-- sees the wallpaper, so it isn't redrawn until the window moves away. Windows Awesome draws
-- translucent don't count; a compositor's own transparency rules can't be seen from here.
local function covered(s)
  local wa = s.workarea
  for _, c in ipairs(s.clients) do -- the screen's visible clients
    if (c.opacity or 1) >= 1 then
      local g = c:geometry()
      local w = math.min(g.x + g.width, wa.x + wa.width) - math.max(g.x, wa.x)
      local h = math.min(g.y + g.height, wa.y + wa.height) - math.max(g.y, wa.y)
      if w > 0 and h > 0 and w * h >= 0.95 * wa.width * wa.height then return true end
    end
  end
  return false
end

-- Redraw at a high rate only while something is happening, to spare the GPU/CPU.
-- While static (on battery) only the emotes move, so it stays at the idle rate; in eco mode
-- nothing moves and a frame a second follows the sessions.
-- With no session, the layer hidden or covered by a window, nothing moves: no redraws at all.
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
    eco = R.eco_active(eco_choice, battery)
    static = eco or (battery and ON_BATTERY == "static")
    local visible = not user_hidden and not (battery and ON_BATTERY == "off")
    if box then box.visible = visible end

    local alerts_shown = layout == "hud" and R.alerts() ~= nil
    if not visible or (count == 0 and not alerts_shown) then
      if anim.started then anim:stop(); redraw() end -- one last frame clears the old nodes
      return
    end
    if box and covered(box.screen) then
      if anim.started then anim:stop() end -- the last frame stays, behind the window
      return
    end
    local want = 1 / (eco and R.FPS_ECO or (active and not static) and R.FPS_ACTIVE or R.FPS_IDLE)
    if anim.timeout ~= want or not anim.started then anim.timeout = want; anim:again() end
  end,
}

-- Promview alerts for the HUD, only while the HUD is the layout and the layer is shown. Asked of a
-- running promview-desktop over the session bus when there is one (it pushes AlertsChanged, so the
-- timer is only a slow fallback), else polled in the background with curl. A failed poll keeps the
-- last alerts, dimmed.
local promview = Promview.read_config()
local promview_busy, promview_last, promview_again = false, 0, false
local promview_bus -- set below, once the poll and its timer exist
-- The desktop owns the name but has no GetAlerts (an older or newer promview-desktop): use curl
-- until it restarts.
local promview_bus_unsupported = false
local promview_poll
local FALLBACK_INTERVAL = 120 -- seconds between polls while the desktop is pushing changes
local function promview_via_bus()
  return promview and promview.desktop ~= "off" and promview_bus and promview_bus:owned()
    and not (promview_bus_unsupported and promview.url)
end
local promview_pace
-- via: "desktop" when the alerts came from promview-desktop (the HUD then says to sign in from
-- its tray, not with constellation-promview-login), else nil.
local function promview_done(body, err, auth, via)
  promview_busy = false
  local state
  if body then state, err = Promview.parse(body) end
  if state then
    state.ok, state.fetched = true, os.time()
  else
    local prev = R.alerts() or {}
    state = { ok = false, fetched = prev.fetched, alerts = prev.alerts or {}, groups = prev.groups or {},
      counts = prev.counts or {}, total = prev.total or 0, error = err, auth = auth }
  end
  state.via = via
  R.set_alerts(state)
  pcall(R.write_alerts, state)
  redraw()
  -- A change that arrived while this read was in flight may not be in it.
  if promview_again then promview_again = false; promview_poll() end
end
function promview_poll()
  if not promview or layout ~= "hud" or not (box and box.visible) then return end
  if promview_busy then promview_again = true; return end
  promview_busy, promview_last = true, os.time()
  if promview_via_bus() then
    promview_bus:get_alerts(promview, function(body, err, auth, unsupported)
      if unsupported and promview.url then
        -- No GetAlerts on this desktop: back to curl now, and at the configured pace.
        promview_bus_unsupported, promview_busy = true, false
        promview_pace()
        return promview_poll()
      end
      promview_done(body, err, auth, "desktop")
    end)
  elseif promview.url then
    awful.spawn.easy_async(Promview.command(promview), function(stdout, stderr, _, code)
      if code == 0 then return promview_done(stdout) end
      local err, auth = Promview.failure(stderr, code)
      promview_done(nil, err, auth)
    end)
  else
    promview_done(nil, "promview-desktop is not running")
  end
end
local CONNECTING = { ok = false, alerts = {}, counts = {}, total = 0 } -- until the first poll
if promview then R.set_alerts(CONNECTING)
else pcall(R.write_alerts, nil) end -- Promview turned off: the lock screen drops the old board
local promview_timer = gears.timer {
  timeout = promview and promview.interval or 30, autostart = true, call_now = true, callback = promview_poll,
}
-- Slow while the desktop pushes changes, the configured interval otherwise.
function promview_pace()
  if not promview then return end
  local want = promview.interval
  if promview_via_bus() then want = math.max(want, FALLBACK_INTERVAL) end
  if promview_timer.timeout ~= want then promview_timer.timeout = want; promview_timer:again() end
end
if promview and promview.desktop ~= "off" then
  promview_bus = PromviewBus.open_safe({
    on_owner = function() promview_bus_unsupported = false; promview_pace(); promview_poll() end,
    on_change = promview_poll,
  })
end

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
      { private = private, static = static, still = eco, layout = layout, area = area(screen.primary) })
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
  -- Per-user dir (XDG_RUNTIME_DIR, else ~/.cache): a fixed /tmp path could be pre-planted as a symlink.
  local img = GLib.get_user_runtime_dir() .. "/constellation-lock.png"
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

-- Eco mode: "on", "off", "auto" (on battery) or "toggle" (on <-> off). Kept for the next start
-- and for the lock screen. Returns the choice and whether eco is on right now.
local function set_eco(name)
  if name == "toggle" then name = eco and "off" or "on" end
  local known = false
  for _, m in ipairs(R.ECO_MODES) do if m == name then known = true end end
  if known then
    eco_choice = name
    eco = R.eco_active(name, R.on_battery())
    R.write_eco(name)
    redraw()
    local ok, naughty = pcall(require, "naughty")
    if ok then
      local now = name == "auto" and (eco and " (on: on battery)" or " (off: on mains)") or ""
      naughty.notify({ title = "Claude constellation", text = "Eco mode: " .. name .. now, timeout = 2 })
    end
  end
  return eco_choice, eco
end

return {
  set_layout = set_layout,
  set_eco = set_eco,
  eco = function() return eco_choice, eco end,
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
    if promview.desktop ~= "off" and not promview_bus then
      promview_bus = PromviewBus.open_safe({ on_owner = function() promview_pace(); promview_poll() end,
        on_change = promview_poll })
    end
    promview_timer.timeout = promview.interval
    promview_timer:again()
    promview_pace()
    promview_poll()
  end,
  toggle = function()
    user_hidden = not user_hidden
    if box then box.visible = not user_hidden end
  end,
}
