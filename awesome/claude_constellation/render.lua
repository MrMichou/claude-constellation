-- Claude constellation renderer: reads ~/.claude/constellation/<sid>.json (written by
-- hooks/track.js) and draws every live session as a glowing Clawd node with the resources it
-- touches orbiting around it. Pure cairo + Gio (lgi), no AwesomeWM dependency, so the same code
-- drives the desktop layer (init.lua) and the xsecurelock saver (saver.lua).

local lgi = require("lgi")
local cairo = lgi.cairo
local GLib = lgi.GLib
local Gio = lgi.Gio

local DIR = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local json = dofile(DIR .. "json.lua")

local FRAMES_DIR = DIR .. "frames/"
local STALE_AFTER = 10 * 60 -- seconds without activity -> dimmed
local HIDE_AFTER = 3 * 3600 -- seconds without activity -> hidden (crashed session)
local FADE_LINK = 5 * 60 -- a satellite link fades out over this many seconds
local PARTICLE_TIME = 1.4 -- seconds for a pulse to travel session -> target
local DONE_PARTY = 30 -- seconds the "birthday" emote plays after a turn ends
local LINK_WINDOW = 30 * 60 -- two sessions using one resource within this window get linked

-- Subagents: mini Clawds running around their session. Past RUNNERS_MAX they are grouped by
-- agent type ("Explore ×12"), and past RUNNERS_MAX groups the smallest merge into "+k agents".
local RUNNERS_MAX = 6
local AGENT_FADE = 20 -- seconds a finished subagent stays (birthday, then fading out)
local MINI_SIZE = 34
local RUN_ORBIT_X, RUN_ORBIT_Y = 200, 140 -- outside the satellites
local RUN_SPEED = { tool = 0.35, thinking = 0.15 } -- rad/s of the ring
local CATCH_UP = 0.5 -- extra rad/s a runner gains back after standing still
local URGENCY = { permission = 4, waiting = 3, tool = 2, thinking = 1, done = 0 }

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
  walk = "clawd/walk",
}
-- clawd/walk turns around first (cells 1-15); cells 16-23 are the stepping loop, facing right.
local WALK_FIRST, WALK_LAST = 16, 23

local R = { FPS_ACTIVE = 30, FPS_IDLE = 8 }

-- Where session files and power supplies are read from; overridable for tests.
local DATA_DIR = os.getenv("HOME") .. "/.claude/constellation/"
local PS_DIR = "/sys/class/power_supply/"
function R.set_dirs(data_dir, power_dir)
  DATA_DIR = data_dir or DATA_DIR
  PS_DIR = power_dir or PS_DIR
end

-- "#rgb", "#rrggbb" or "#rrggbbaa" -> {r, g, b} in 0..1; nil if unparsable.
local function rgb(hex)
  hex = tostring(hex or ""):match("^#(%x+)$")
  if not hex then return nil end
  if #hex == 3 then hex = hex:gsub(".", "%0%0") end
  if #hex < 6 then return nil end
  return {
    tonumber(hex:sub(1, 2), 16) / 255,
    tonumber(hex:sub(3, 4), 16) / 255,
    tonumber(hex:sub(5, 6), 16) / 255,
  }
end

-- Palette keys, as hex strings; overridable with R.set_palette (init.lua passes the theme).
R.DEFAULT_PALETTE = {
  bg = "#000000", fg = "#dddddd", dim = "#888888",
  thinking = "#7aa2f7", permission = "#e0af68",
  file = "#7aa2f7", shell = "#9ece6a", search = "#7dcfff", web = "#bb9af7",
  agent = "#e0af68", mcp = "#f7768e", other = "#c0caf5",
}
local KINDS = { "file", "shell", "search", "web", "agent", "mcp", "other" }
local C

function R.set_palette(p)
  p = p or {}
  local function pick(k) return rgb(p[k]) or rgb(R.DEFAULT_PALETTE[k]) end
  C = { bg = pick("bg"), fg = pick("fg"), dim = pick("dim"),
    thinking = pick("thinking"), permission = pick("permission"), kind = {} }
  for _, k in ipairs(KINDS) do C.kind[k] = pick(k) end
end
R.set_palette()

function R.read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local t = json.decode(f:read("*a") or ""); f:close()
  return t
end

function R.write_json(path, t)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(json.encode(t)); f:close()
  return true
end

local function now() return GLib.get_real_time() / 1e6 end

local function set(cr, c, a) cr:set_source_rgba(c[1], c[2], c[3], a or 1) end

-- Sprite manifest: each set is one horizontal strip of `n` square-ish cells.
local manifest = R.read_json(FRAMES_DIR .. "sprites.json")
if type(manifest) ~= "table" then manifest = {} end

-- Strips are decoded lazily and memoised; {} when a set is missing (falls back to a dot).
local sprite_cache = {}
local function sprite_set(name)
  local cells = sprite_cache[name]
  if cells then return cells end
  cells = {}
  local n = math.floor(tonumber(manifest[name]) or 0)
  local ok, sheet = pcall(cairo.ImageSurface.create_from_png, FRAMES_DIR .. name .. ".png")
  if n > 0 and ok and sheet and sheet.status == "SUCCESS" then
    local w, h = math.floor(sheet:get_width() / n), sheet:get_height()
    for i = 0, n - 1 do
      local cell = cairo.ImageSurface.create(cairo.Format.ARGB32, w, h)
      local c = cairo.Context(cell)
      c:set_source_surface(sheet, -i * w, 0)
      c:paint()
      cells[#cells + 1] = cell
    end
    sheet:finish()
  end
  sprite_cache[name] = cells
  return cells
end

-- sessions[sid] = decoded state file + layout fields (x, y, alpha)
local sessions = {}
local order = {} -- sids sorted, for stable placement

local function is_active(s)
  return s.state == "thinking" or s.state == "tool" or s.state == "permission"
end

-- Subagents still shown at time t, oldest first: { {id, a = entry}, ... }
local function live_agents(s, t)
  local list = {}
  for id, a in pairs(type(s.agents) == "table" and s.agents or {}) do
    if type(a) == "table" and (a.state ~= "done" or t - (tonumber(a.ts) or 0) < AGENT_FADE) then
      list[#list + 1] = { id = id, a = a }
    end
  end
  table.sort(list, function(x, y)
    local sx, sy = tonumber(x.a.started) or 0, tonumber(y.a.started) or 0
    if sx ~= sy then return sx < sy end
    return x.id < y.id
  end)
  return list
end

local function has_running_agent(s, t)
  for _, e in ipairs(live_agents(s, t)) do
    if e.a.state ~= "done" then return true end
  end
  return false
end

-- What to draw for a session's subagents: one runner per subagent (finished ones too while
-- they fade, if there is room), or once more than RUNNERS_MAX are running, one per agent type
-- over the running ones. A group takes its most urgent member's state and the most recent
-- target. { {id, type, label, count, state, kind, target, history, ts}, ... }
function R.runners(s, t)
  local live, running = live_agents(s, t), {}
  for _, e in ipairs(live) do
    if e.a.state ~= "done" then running[#running + 1] = e end
  end
  if #live > RUNNERS_MAX then live = running end
  local out = {}
  if #live <= RUNNERS_MAX then
    for _, e in ipairs(live) do
      local a = e.a
      out[#out + 1] = { id = e.id, type = a.type or "agent", label = a.label, count = 1, state = a.state,
        kind = a.kind, target = a.target, history = type(a.history) == "table" and a.history or {},
        ts = tonumber(a.ts) or 0 }
    end
    return out
  end
  local by = {}
  local function absorb(g, a, n)
    g.count = g.count + (n or 1)
    if (URGENCY[a.state] or 0) > (URGENCY[g.state] or 0) then g.state = a.state end
    local ts = tonumber(a.ts) or 0
    if ts >= g.ts then
      g.ts = ts
      if a.target and a.target ~= "" then g.kind, g.target = a.kind, a.target end
    end
  end
  for _, e in ipairs(live) do
    local ty = e.a.type or "agent"
    local g = by[ty]
    if not g then
      g = { id = "type:" .. ty, type = ty, count = 0, state = "done", ts = 0, history = {} }
      by[ty] = g
      out[#out + 1] = g
    end
    absorb(g, e.a)
  end
  if #out > RUNNERS_MAX then
    -- Keep the biggest groups, in creation order so their slots don't swap; merge the rest.
    local rank = {}
    for k, g in ipairs(out) do rank[g] = k end
    local big = { table.unpack(out) }
    table.sort(big, function(x, y)
      if x.count ~= y.count then return x.count > y.count end
      return rank[x] < rank[y]
    end)
    local keep = {}
    for k = 1, RUNNERS_MAX - 1 do keep[big[k]] = true end
    local rest = { id = "type:*", type = "agents", count = 0, state = "done", ts = 0, history = {},
      merged = true }
    local kept = {}
    for _, g in ipairs(out) do
      if keep[g] then kept[#kept + 1] = g else absorb(rest, g, g.count) end
    end
    kept[#kept + 1] = rest
    out = kept
  end
  return out
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

-- Sessions sharing a resource (same tmux session, same file) used within LINK_WINDOW:
-- { {a = s1, b = s2, kind, labels = {...}, ts = latest shared use}, ... }
local function shared_links(t)
  local by_key = {}
  for _, sid in ipairs(order) do
    local s = sessions[sid]
    for key, l in pairs(type(s.links) == "table" and s.links or {}) do
      if type(l) == "table" and t - (tonumber(l.ts) or 0) < LINK_WINDOW then
        by_key[key] = by_key[key] or {}
        table.insert(by_key[key], { s = s, l = l })
      end
    end
  end
  local by_pair, list, keys = {}, {}, {}
  for key in pairs(by_key) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local users = by_key[key]
    for x = 1, #users - 1 do
      for y = x + 1, #users do
        local a, b = users[x], users[y]
        local id = a.s.sid .. "|" .. b.s.sid
        local link = by_pair[id]
        if not link then
          link = { a = a.s, b = b.s, kind = a.l.kind, labels = {}, ts = 0 }
          by_pair[id] = link
          list[#list + 1] = link
        end
        if #link.labels < 2 then link.labels[#link.labels + 1] = a.l.label or key end
        link.ts = math.max(link.ts, math.min(tonumber(a.l.ts) or 0, tonumber(b.l.ts) or 0))
      end
    end
  end
  return list
end

-- Decoded session files with the size/mtime they were read at: a file is only parsed again
-- when the hook rewrote it.
local files = {}
local links = {} -- shared_links(), refreshed with the sessions

-- Reload the session files; returns whether any session is working, and the session count.
function R.read_sessions()
  local seen, seen_files = {}, {}
  local t = now()
  pcall(function()
    local en = Gio.File.new_for_path(DATA_DIR):enumerate_children(
      "standard::name,standard::size,time::modified,time::modified-usec", Gio.FileQueryInfoFlags.NONE)
    if not en then return end
    while true do
      local info = en:next_file(); if not info then break end
      local sid = info:get_name():match("^(.+)%.json$")
      if sid then
        local stamp = ("%d:%d:%d"):format(info:get_size(), info:get_attribute_uint64("time::modified"),
          info:get_attribute_uint32("time::modified-usec"))
        local f = files[sid]
        local fresh = not f or f.stamp ~= stamp
        if fresh then
          f = { stamp = stamp, data = R.read_json(DATA_DIR .. sid .. ".json") }
          files[sid] = f
        end
        seen_files[sid] = true
        local d = f.data
        if type(d) == "table" and t - (tonumber(d.ts) or 0) < HIDE_AFTER then
          local s = sessions[sid]
          if not s or fresh then
            s = s or { alpha = 0 }
            for k, v in pairs(d) do s[k] = v end
            s.sats = satellites(s)
            sessions[sid] = s
          end
          seen[sid] = true
        end
      end
    end
  end)
  for sid in pairs(files) do
    if not seen_files[sid] then files[sid] = nil end
  end
  for sid in pairs(sessions) do
    if not seen[sid] then sessions[sid] = nil end
  end
  order = {}
  local active = false
  for sid, s in pairs(sessions) do
    order[#order + 1] = sid
    if is_active(s) or has_running_agent(s, t) then active = true end
  end
  table.sort(order)
  links = shared_links(t)
  return active, #order
end

-- On battery = the system battery is discharging (peripheral batteries have scope "Device").
-- Machines without a battery are always on mains.
local function read_line(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local v = f:read("*l"); f:close()
  return v
end
function R.on_battery()
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
  -- `since`: subagent events refresh ts, which must not replay the party.
  if s.state == "done" and t - (tonumber(s.since or s.ts) or 0) < DONE_PARTY then return CLAWD.done, true end
  return CLAWD.rest, false
end

-- size defaults to SPRITE_SIZE; flip mirrors the sprite horizontally.
local function draw_sprite(cr, cells, idx, x, y, a, size, flip)
  local cell = cells[(idx % #cells) + 1]
  local w, h = cell:get_width(), cell:get_height()
  local k = (size or SPRITE_SIZE) / math.max(w, h)
  cr:save()
  cr:translate(x - w * k / 2, y - h * k / 2)
  if flip then cr:translate(w * k, 0); cr:scale(-k, k) else cr:scale(k, k) end
  cr:set_source_surface(cell, 0, 0)
  cr:get_source():set_filter(cairo.Filter.NEAREST) -- keep the pixel art crisp
  cr:paint_with_alpha(a)
  cr:restore()
end

-- Rasterising a radial gradient was the costliest part of a frame, so each glow is drawn once
-- per (colour, whole-pixel radius) into a small surface, then blitted with the wanted alpha.
-- Keyed by the palette's colour tables: set_palette drops the old ones, and their surfaces.
local glow_cache = setmetatable({}, { __mode = "k" })
local function glow(cr, x, y, r, c, a)
  r = math.floor(r + 0.5)
  local by_r = glow_cache[c]
  if not by_r then by_r = {}; glow_cache[c] = by_r end
  local surf = by_r[r]
  if not surf then
    surf = cairo.ImageSurface.create(cairo.Format.ARGB32, 2 * r, 2 * r)
    local g = cairo.Context(surf)
    local pat = cairo.Pattern.create_radial(r, r, 0, r, r, r)
    pat:add_color_stop_rgba(0, c[1], c[2], c[3], 1)
    pat:add_color_stop_rgba(0.35, c[1], c[2], c[3], 0.35)
    pat:add_color_stop_rgba(1, c[1], c[2], c[3], 0)
    g:set_source(pat)
    g:paint()
    by_r[r] = surf
  end
  cr:set_source_surface(surf, x - r, y - r)
  cr:paint_with_alpha(a)
end

-- Label widths, memoised per font size: text_extents is a costly lgi round-trip and labels
-- rarely change. Flushed when it grows, since targets come and go.
local widths, n_widths = {}, 0
local function text_width(cr, str, size)
  local by_str = widths[size]
  local w = by_str and by_str[str]
  if w then return w end
  if n_widths > 500 then widths, n_widths = {}, 0 end
  cr:set_font_size(size)
  w = cr:text_extents(str).width
  widths[size] = widths[size] or {}
  widths[size][str] = w
  n_widths = n_widths + 1
  return w
end

local function text(cr, str, x, y, size, c, a, center)
  local x0 = center and x - text_width(cr, str, size) / 2 or x
  cr:set_font_size(size)
  cr:move_to(x0, y)
  set(cr, c, a)
  cr:show_text(str)
end

-- A bowed line between two linked sessions, a glow travelling along it, and the shared
-- resource names at its middle (just the kind when private).
local function draw_links(cr, t, ta, static, private)
  for k, link in ipairs(links) do
    local a, b = link.a, link.b
    local A = math.min(a.alpha, b.alpha) * math.max(0.3, 1 - (t - link.ts) / LINK_WINDOW)
    local kc = C.kind[link.kind] or C.kind.other
    local mx, my = (a.x + b.x) / 2, (a.y + b.y) / 2
    local dx, dy = b.x - a.x, b.y - a.y
    local len = math.max(1, math.sqrt(dx * dx + dy * dy))
    local bow = 0.12 * len
    local qx, qy = mx - dy / len * bow, my + dx / len * bow -- control point, off to one side
    local function at(u) -- point on the quadratic curve
      local v = 1 - u
      return v * v * a.x + 2 * v * u * qx + u * u * b.x, v * v * a.y + 2 * v * u * qy + u * u * b.y
    end

    cr:set_line_width(1.5)
    set(cr, kc, 0.45 * A)
    cr:move_to(a.x, a.y)
    cr:curve_to(a.x + (qx - a.x) * 2 / 3, a.y + (qy - a.y) * 2 / 3,
      b.x + (qx - b.x) * 2 / 3, b.y + (qy - b.y) * 2 / 3, b.x, b.y)
    cr:stroke()

    if not static then
      local u = (ta * 0.18 + k * 0.37) % 2
      local px, py = at(u <= 1 and u or 2 - u) -- back and forth: a shared channel
      glow(cr, px, py, 10, kc, 0.8 * A)
    end

    local lx, ly = at(0.5)
    local label = private and (link.kind == "file" and "file" or "tmux")
      or table.concat(link.labels, " · ")
    text(cr, "⇄ " .. label, lx, ly - 6, 11, kc, 0.85 * A, true)
  end
end

-- The walk loop of clawd/walk, or {} when the strip is missing or too short.
local walk_cache
local function walk_cells()
  if walk_cache then return walk_cache end
  local all, cells = sprite_set(CLAWD.walk), {}
  for k = WALK_FIRST, math.min(WALK_LAST, #all) do cells[#cells + 1] = all[k] end
  walk_cache = cells
  return cells
end

local function runner_color(r)
  if r.state == "tool" then return C.kind[r.kind] or C.kind.agent end
  if r.state == "permission" or r.state == "waiting" then return C.permission end
  if r.state == "done" then return C.dim end
  return C.kind.agent
end

-- Mini Clawds circling session s like a merry-go-round: the ring turns at the pace of its
-- busiest runner and each runner eases into an evenly spaced slot. A runner that stands still
-- (permission, done) falls behind the ring, then catches up running once it moves again.
-- Runners run during a tool call, walk while thinking, listen (blinking) on a permission,
-- and party then fade out once done.
local function draw_runners(cr, s, t, ta, static, private, A)
  local list = R.runners(s, t)
  s._run = s._run or {}
  local dt = (s._run_t and not static) and math.max(0, math.min(t - s._run_t, 0.5)) or 0
  s._run_t = t
  local ring = 0
  for _, r in ipairs(list) do ring = math.max(ring, RUN_SPEED[r.state] or 0) end
  s._spin = (s._spin or -math.pi / 2) + ring * dt
  local seen = {}
  local two_pi = 2 * math.pi
  for i, r in ipairs(list) do
    local slot = (i - 1) / #list * two_pi
    local p = s._run[r.id]
    if not p then
      p = { slot = slot, lag = 0 }
      s._run[r.id] = p
    end
    seen[r.id] = true
    -- Shortest way to the new slot, eased.
    local d = (slot - p.slot + math.pi) % two_pi - math.pi
    p.slot = p.slot + d * math.min(1, dt * 1.5)
    if r.state == "permission" or r.state == "waiting" then
      p.lag = math.min(math.pi, p.lag + ring * dt)
    else
      p.lag = math.max(0, p.lag - CATCH_UP * dt)
    end
    p.a = s._spin + p.slot - p.lag

    local fade = r.state == "done" and math.max(0, 1 - (t - r.ts) / AGENT_FADE) or 1
    local RA = A * fade
    local running = not static and (r.state == "tool" or p.lag > 0 and RUN_SPEED[r.state])
    local bob = running and -math.abs(math.sin(ta * 12 + i)) * 3 or 0
    local x = s.x + RUN_ORBIT_X * math.cos(p.a)
    local y = s.y + RUN_ORBIT_Y * math.sin(p.a) + bob
    local col = runner_color(r)

    cr:set_line_width(1)
    set(cr, col, 0.18 * RA)
    cr:move_to(s.x, s.y); cr:line_to(x, y); cr:stroke()

    -- Its last targets, as tiny dots orbiting it (single subagents only, groups mix them).
    for j, h in ipairs(r.count == 1 and r.history or {}) do
      local ha = (j - 1) / #r.history * 2 * math.pi + ta * 0.3 + i
      local hc = C.kind[h.kind] or C.kind.other
      local hf = math.max(0.15, 1 - (t - (tonumber(h.ts) or 0)) / FADE_LINK)
      set(cr, hc, 0.8 * hf * RA)
      cr:arc(x + 24 * math.cos(ha), y + 18 * math.sin(ha), 1.6, 0, 2 * math.pi); cr:fill()
    end

    local blink = (r.state == "permission") and ((math.floor(t * 2) % 2 == 0) and 1 or 0.3) or 0.6
    glow(cr, x, y, 18 + 6 * blink, col, (0.25 + 0.35 * blink) * RA)

    local cells, idx, fps
    if r.state == "tool" or r.state == "thinking" then
      cells, fps = walk_cells(), running and 22 or 10
    elseif r.state == "done" then
      cells, fps = sprite_set(CLAWD.done), SPRITE_FPS
    else
      cells, fps = sprite_set(CLAWD.permission), SPRITE_FPS
    end
    idx = math.floor(t * fps + i * 5)
    if #cells > 0 then
      -- The walk loop faces right; moving left on the far side of the orbit, so mirror it.
      draw_sprite(cr, cells, idx, x, y, RA, MINI_SIZE, math.sin(p.a) > 0)
    else
      set(cr, col, RA); cr:arc(x, y, 3.5, 0, 2 * math.pi); cr:fill()
    end

    local name
    if r.merged then name = "+" .. r.count .. " agents"
    elseif r.count > 1 then name = r.type .. " ×" .. r.count
    elseif not private and r.label and r.label ~= "" then name = r.label
    else name = r.type end
    text(cr, name, x, y - 22, 10, C.fg, 0.75 * RA, true)
    if not private and r.count == 1 and r.state == "tool" and r.target and r.target ~= "" then
      text(cr, r.target, x, y + 28, 9, col, 0.65 * RA, true)
    end
  end
  for id in pairs(s._run) do
    if not seen[id] then s._run[id] = nil end
  end
end

-- Draw one frame. opts.static freezes everything but the Clawd emotes (battery mode);
-- opts.private drops what could leak on a lock screen: satellite labels and the tool target.
function R.draw(cr, w, h, opts)
  opts = opts or {}
  local static, private = opts.static, opts.private
  local t = now()
  local ta = static and 0 or t -- animation clock; frozen while static
  local ease = static and 1 or 0.05
  set(cr, C.bg); cr:paint()
  cr:select_font_face("monospace", cairo.FontSlant.NORMAL, cairo.FontWeight.NORMAL)

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

    s.stale = t - (tonumber(s.ts) or 0) > STALE_AFTER and not is_active(s)
    s.alpha = s.alpha + (((s.stale and 0.35) or 1) - s.alpha) * (static and 1 or 0.08)
  end

  draw_links(cr, t, ta, static, private)

  for i, sid in ipairs(order) do
    local s = sessions[sid]
    local seed = i * 1.7
    local stale = s.stale
    local A = s.alpha
    local col = node_color(s)

    -- Satellites: resources this session touched, orbiting slowly.
    local sats = s.sats
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
      if not private then -- private: dot only, no path/command label
        local label = sat.target or ""
        local lx = sx + 8
        if math.cos(sa) < 0 then -- left half: right-align the label against the dot
          lx = sx - 8 - text_width(cr, label, 11)
        end
        text(cr, label, lx, sy + 4, 11, C.dim, 0.75 * fade * A)
      end

      -- Pulse travelling along the link right after the call.
      if not static and age >= 0 and age < PARTICLE_TIME then
        local k = age / PARTICLE_TIME
        local px, py = s.x + (sx - s.x) * k, s.y + (sy - s.y) * k
        glow(cr, px, py, 12, kc, 0.9 * A)
      end
    end

    draw_runners(cr, s, t, ta, static, private, A)

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
      draw_sprite(cr, frames, loops and math.floor(t * SPRITE_FPS + i * 7) or 0, s.x, s.y, A)
    else
      set(cr, col, A); cr:arc(s.x, s.y, 5, 0, 2 * math.pi); cr:fill()
    end

    text(cr, s.project ~= "" and s.project or sid:sub(1, 8), s.x, s.y - 52, 14, C.fg, 0.9 * A, true)
    local sub = s.state or ""
    if s.state == "tool" and s.target and s.target ~= "" and not private then
      sub = (s.tool or "") .. " · " .. s.target
    end
    text(cr, sub, s.x, s.y + 62, 11, col, 0.8 * A, true)
  end
end

return R
