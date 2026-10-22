-- Claude constellation: an animated desktop layer drawing every live Claude Code session
-- as a glowing node, with the resources it touches (files, shell, web, MCP, agents)
-- orbiting around it. Data comes from ~/.claude/constellation/<sid>.json, written by
-- hooks/track.js. Load with: pcall(require, "ui.desktop.claude_constellation")

local awful = require("awful")
local beautiful = require("beautiful")
local gears = require("gears")
local wibox = require("wibox")
local lgi = require("lgi")
local GLib = lgi.GLib
local Gio = lgi.Gio
local json = require((...) .. ".json")

local DATA_DIR = os.getenv("HOME") .. "/.claude/constellation/"
local STALE_AFTER = 10 * 60 -- seconds without activity -> dimmed
local HIDE_AFTER = 3 * 3600 -- seconds without activity -> hidden (crashed session)
local FADE_LINK = 5 * 60 -- a satellite link fades out over this many seconds
local PARTICLE_TIME = 1.4 -- seconds for a pulse to travel session -> target
local FPS_ACTIVE, FPS_IDLE = 30, 8
local DONE_PARTY = 30 -- seconds the "birthday" emote plays after a turn ends

-- Clawd emotes (same sprite strips as claude-status-bar): one loop per session state.
-- Artwork from github.com/xixicc186/clawd-emotes-skill.
local SPRITE_FPS = 14
local SPRITE_SIZE = 64
local CLAWD = {
  thinking = "clawd/thinking",
  tool = "clawd/typing",
  permission = "clawd/listening",
  waiting = "clawd/listening",
  done = "clawd/birthday",
  sleeping = "clawd/sleeping",
  rest = "crab",
}
local FRAMES_DIR = (debug.getinfo(1, "S").source:match("^@(.*/)") or "./") .. "frames/"

local function rgb(hex, fallback)
  local r, g, b = gears.color.parse_color(hex or fallback or "#ffffff")
  if not r then r, g, b = 1, 1, 1 end
  return { r, g, b }
end

local C = {
  bg = rgb(beautiful.black, "#000000"),
  fg = rgb(beautiful.xforeground, "#dddddd"),
  dim = rgb(beautiful.white, "#888888"),
  thinking = rgb(beautiful.accent or beautiful.blue, "#7aa2f7"),
  permission = rgb(beautiful.yellow, "#e0af68"),
  kind = {
    file = rgb(beautiful.blue, "#7aa2f7"),
    shell = rgb(beautiful.green, "#9ece6a"),
    search = rgb(beautiful.cyan, "#7dcfff"),
    web = rgb(beautiful.magenta, "#bb9af7"),
    agent = rgb(beautiful.yellow, "#e0af68"),
    mcp = rgb(beautiful.red, "#f7768e"),
    other = rgb(beautiful.white, "#c0caf5"),
  },
}

local function now() return GLib.get_real_time() / 1e6 end

local function set(cr, c, a) cr:set_source_rgba(c[1], c[2], c[3], a or 1) end

-- Sprite manifest: each set is one horizontal strip of `n` square-ish cells.
local manifest = (function()
  local f = io.open(FRAMES_DIR .. "sprites.json", "r")
  if not f then return {} end
  local t = json.decode(f:read("*a") or ""); f:close()
  return type(t) == "table" and t or {}
end)()

-- Strips are decoded lazily and memoised; {} when a set is missing (falls back to a dot).
local sprite_cache = {}
local function sprite_set(name)
  local set = sprite_cache[name]
  if set then return set end
  set = {}
  local n = math.floor(tonumber(manifest[name]) or 0)
  local sheet, err = gears.surface.load_uncached_silently(FRAMES_DIR .. name .. ".png")
  if n > 0 and sheet and not err then
    local w, h = math.floor(sheet:get_width() / n), sheet:get_height()
    for i = 0, n - 1 do
      local cell = lgi.cairo.ImageSurface.create(lgi.cairo.Format.ARGB32, w, h)
      local c = lgi.cairo.Context(cell)
      c:set_source_surface(sheet, -i * w, 0)
      c:paint()
      set[#set + 1] = cell
    end
    sheet:finish()
  end
  sprite_cache[name] = set
  return set
end

-- sessions[sid] = decoded state file + layout fields (x, y, alpha)
local sessions = {}
local order = {} -- sids sorted, for stable placement

local function read_sessions()
  local seen = {}
  pcall(function()
    local en = Gio.File.new_for_path(DATA_DIR)
      :enumerate_children("standard::name", Gio.FileQueryInfoFlags.NONE)
    if not en then return end
    while true do
      local info = en:next_file(); if not info then break end
      local sid = info:get_name():match("^(.+)%.json$")
      if sid then
        local f = io.open(DATA_DIR .. sid .. ".json", "r")
        if f then
          local t = json.decode(f:read("*a") or ""); f:close()
          if type(t) == "table" and now() - (tonumber(t.ts) or 0) < HIDE_AFTER then
            local s = sessions[sid] or { alpha = 0 }
            for k, v in pairs(t) do s[k] = v end
            sessions[sid] = s
            seen[sid] = true
          end
        end
      end
    end
  end)
  for sid in pairs(sessions) do
    if not seen[sid] then sessions[sid] = nil end
  end
  order = {}
  for sid in pairs(sessions) do order[#order + 1] = sid end
  table.sort(order)
end

local function is_active(s)
  return s.state == "thinking" or s.state == "tool" or s.state == "permission"
end

-- Unique targets of a session, newest last: { {kind, target, ts}, ... }
local function satellites(s)
  local by, list = {}, {}
  for _, h in ipairs(type(s.history) == "table" and s.history or {}) do
    local key = (h.kind or "") .. "|" .. (h.target or "")
    if by[key] then by[key].ts = h.ts else
      by[key] = { kind = h.kind, target = h.target, ts = h.ts }
      list[#list + 1] = by[key]
    end
  end
  return list
end

local function node_color(s)
  if s.state == "thinking" then return C.thinking end
  if s.state == "tool" then return C.kind[s.kind] or C.kind.other end
  if s.state == "permission" or s.state == "waiting" then return C.permission end
  return C.dim
end

-- Emote for a session's state, plus whether it loops (the resting crab is a still pose).
local function emote(s, t, stale)
  if is_active(s) or s.state == "waiting" then return CLAWD[s.state], true end
  if stale then return CLAWD.sleeping, true end
  if s.state == "done" and t - (tonumber(s.ts) or 0) < DONE_PARTY then return CLAWD.done, true end
  return CLAWD.rest, false
end

local function draw_sprite(cr, set, idx, x, y, a)
  local cell = set[(idx % #set) + 1]
  local w, h = cell:get_width(), cell:get_height()
  local k = SPRITE_SIZE / math.max(w, h)
  cr:save()
  cr:translate(x - w * k / 2, y - h * k / 2)
  cr:scale(k, k)
  cr:set_source_surface(cell, 0, 0)
  cr:get_source():set_filter(lgi.cairo.Filter.NEAREST) -- keep the pixel art crisp
  cr:paint_with_alpha(a)
  cr:restore()
end

local function glow(cr, x, y, r, c, a)
  local pat = lgi.cairo.Pattern.create_radial(x, y, 0, x, y, r)
  pat:add_color_stop_rgba(0, c[1], c[2], c[3], a)
  pat:add_color_stop_rgba(0.35, c[1], c[2], c[3], a * 0.35)
  pat:add_color_stop_rgba(1, c[1], c[2], c[3], 0)
  cr:set_source(pat)
  cr:arc(x, y, r, 0, 2 * math.pi)
  cr:fill()
end

local function text(cr, str, x, y, size, c, a, center)
  cr:set_font_size(size)
  local ext = cr:text_extents(str)
  cr:move_to(center and x - ext.width / 2 or x, y)
  set(cr, c, a)
  cr:show_text(str)
end

-- On battery: "static" freezes every animation and redraws only on change, "off" hides the layer.
local ON_BATTERY = "static"
local static = false

local function draw(cr, w, h)
  local t = now()
  local ta = static and 0 or t -- animation clock; frozen while static
  local ease = static and 1 or 0.05
  set(cr, C.bg); cr:paint()
  cr:select_font_face("monospace", lgi.cairo.FontSlant.NORMAL, lgi.cairo.FontWeight.NORMAL)

  local n = #order
  local cx, cy = w / 2, h / 2 + 15
  local rx, ry = w * 0.32, h * 0.28
  for i, sid in ipairs(order) do
    local s = sessions[sid]
    -- Anchor on an ellipse (a lone session sits in the middle), plus a slow drift.
    local ang = (i - 1) / math.max(n, 1) * 2 * math.pi - math.pi / 2
    local ax = n == 1 and cx or cx + rx * math.cos(ang)
    local ay = n == 1 and cy or cy + ry * math.sin(ang)
    local seed = i * 1.7
    local tx = ax + 18 * math.sin(ta * 0.13 + seed)
    local ty = ay + 12 * math.cos(ta * 0.11 + seed)
    s.x = s.x and s.x + (tx - s.x) * ease or tx
    s.y = s.y and s.y + (ty - s.y) * ease or ty

    local stale = t - (tonumber(s.ts) or 0) > STALE_AFTER and not is_active(s)
    s.alpha = s.alpha + (((stale and 0.35) or 1) - s.alpha) * (static and 1 or 0.08)
    local A = s.alpha
    local col = node_color(s)

    -- Satellites: resources this session touched, orbiting slowly.
    local sats = satellites(s)
    for j, sat in ipairs(sats) do
      local age = t - (tonumber(sat.ts) or 0)
      local fade = math.max(0.12, 1 - age / FADE_LINK)
      local sa = (j - 1) / #sats * 2 * math.pi + ta * 0.04 + seed
      local rad = (j % 2 == 0) and 150 or 115
      local sx, sy = s.x + rad * math.cos(sa), s.y + rad * 0.8 * math.sin(sa)
      local kc = C.kind[sat.kind] or C.kind.other

      cr:set_line_width(1)
      set(cr, kc, 0.25 * fade * A)
      cr:move_to(s.x, s.y); cr:line_to(sx, sy); cr:stroke()

      glow(cr, sx, sy, 9, kc, 0.8 * fade * A)
      set(cr, kc, fade * A); cr:arc(sx, sy, 2.2, 0, 2 * math.pi); cr:fill()
      local right = math.cos(sa) >= 0
      if right then
        text(cr, sat.target or "", sx + 8, sy + 4, 11, C.dim, 0.75 * fade * A)
      else
        cr:set_font_size(11)
        local ext = cr:text_extents(sat.target or "")
        text(cr, sat.target or "", sx - 8 - ext.width, sy + 4, 11, C.dim, 0.75 * fade * A)
      end

      -- Pulse travelling along the link right after the call.
      if not static and age >= 0 and age < PARTICLE_TIME then
        local k = age / PARTICLE_TIME
        local px, py = s.x + (sx - s.x) * k, s.y + (sy - s.y) * k
        glow(cr, px, py, 12, kc, 0.9 * A)
      end
    end

    -- Session node: pulse speed and colour follow the session state.
    local pulse
    if static then pulse = 0.6
    elseif s.state == "thinking" then pulse = 0.5 + 0.5 * math.sin(t * 5)
    elseif s.state == "tool" then pulse = 0.6 + 0.4 * math.sin(t * 8)
    elseif s.state == "permission" then pulse = (math.floor(t * 2) % 2 == 0) and 1 or 0.3
    elseif s.state == "waiting" then pulse = 0.5 + 0.5 * math.sin(t * 1.5)
    else pulse = 0.25 end
    glow(cr, s.x, s.y, 40 + 18 * pulse, col, (0.35 + 0.4 * pulse) * A)
    -- Clawd emote on top of the glow, desynced per session; a plain dot if sprites are missing.
    local name, loops = emote(s, t, stale)
    local frames = sprite_set(name)
    if #frames > 0 then
      draw_sprite(cr, frames, (loops and not static) and math.floor(t * SPRITE_FPS + i * 7) or 0, s.x, s.y, A)
    else
      set(cr, col, A); cr:arc(s.x, s.y, 5, 0, 2 * math.pi); cr:fill()
    end

    text(cr, s.project ~= "" and s.project or sid:sub(1, 8), s.x, s.y - 52, 14, C.fg, 0.9 * A, true)
    local sub = s.state or ""
    if s.state == "tool" and s.target and s.target ~= "" then
      sub = (s.tool or "") .. " · " .. s.target
    end
    text(cr, sub, s.x, s.y + 62, 11, col, 0.8 * A, true)
  end
end

-- Animated surface: one desktop-type wibox on the primary screen, below every client.
local canvas = wibox.widget.base.make_widget()
function canvas:fit(_, width, height) return width, height end
function canvas:draw(_, cr, width, height)
  local ok, err = pcall(draw, cr, width, height)
  if not ok then gears.debug.print_warning("claude_constellation: " .. tostring(err)) end
end

local box
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

-- On battery = the system battery is discharging (peripheral batteries have scope "Device").
-- Machines without a battery are always on mains.
local PS_DIR = "/sys/class/power_supply/"
local function read_line(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local v = f:read("*l"); f:close()
  return v
end
local function on_battery()
  local discharging = false
  pcall(function()
    local en = Gio.File.new_for_path(PS_DIR)
      :enumerate_children("standard::name", Gio.FileQueryInfoFlags.NONE)
    if not en then return end
    while true do
      local info = en:next_file(); if not info then break end
      local dev = PS_DIR .. info:get_name() .. "/"
      if read_line(dev .. "type") == "Battery" and read_line(dev .. "scope") ~= "Device"
        and read_line(dev .. "status") == "Discharging" then
        discharging = true
      end
    end
  end)
  return discharging
end

-- Redraw at a high rate only while something is happening, to spare the GPU.
-- While static (on battery) the animation timer stops: redraws happen only when a session
-- changes, or every STATIC_REFRESH seconds so fades and dimming still progress.
local STATIC_REFRESH = 30
local user_hidden = false
local anim = gears.timer {
  timeout = 1 / FPS_IDLE,
  autostart = true,
  callback = function() canvas:emit_signal("widget::redraw_needed") end,
}

local last_sig, last_draw = nil, 0
gears.timer {
  timeout = 1,
  autostart = true,
  call_now = true,
  callback = function()
    read_sessions()
    local battery = on_battery()
    local was_static = static
    static = battery and ON_BATTERY == "static"
    if box then box.visible = not user_hidden and not (battery and ON_BATTERY == "off") end

    if static then
      if anim.started then anim:stop() end
      local parts = {}
      for _, sid in ipairs(order) do
        local s = sessions[sid]
        parts[#parts + 1] = sid .. ":" .. tostring(s.state) .. ":" .. tostring(s.ts)
      end
      local sig = table.concat(parts, "|")
      if sig ~= last_sig or not was_static or now() - last_draw >= STATIC_REFRESH then
        last_sig, last_draw = sig, now()
        canvas:emit_signal("widget::redraw_needed")
      end
      return
    end

    local active = false
    for _, s in pairs(sessions) do if is_active(s) then active = true end end
    local want = 1 / (active and FPS_ACTIVE or FPS_IDLE)
    if not anim.started then anim.timeout = want; anim:start()
    elseif anim.timeout ~= want then anim.timeout = want; anim:again() end
  end,
}

return {
  toggle = function()
    user_hidden = not user_hidden
    if box then box.visible = not user_hidden end
  end,
}
