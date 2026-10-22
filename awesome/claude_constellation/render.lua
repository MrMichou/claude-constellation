-- Claude constellation renderer: reads ~/.claude/constellation/<sid>.json (written by
-- hooks/track.js) and draws every live session as a glowing Clawd node with the resources it
-- touches orbiting around it. Running sessions with no hook file yet are discovered from
-- Claude Code's own registry (~/.claude/sessions). Pure cairo + Gio (lgi), no AwesomeWM
-- dependency, so the same code drives the desktop layer (init.lua) and the xsecurelock saver
-- (saver.lua).

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
local MINI_SIZE = 38
local RUN_TILT = 0.2 -- rad a runner leans towards where it is heading
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
}

local R = { FPS_ACTIVE = 30, FPS_IDLE = 8 }

-- Where session files, Claude Code's session registry (internal, best-effort), processes,
-- power supplies and the cache (theme, chosen layout) live; overridable for tests.
local DATA_DIR = os.getenv("HOME") .. "/.claude/constellation/"
local PS_DIR = "/sys/class/power_supply/"
local REGISTRY_DIR = os.getenv("HOME") .. "/.claude/sessions/"
local PROC_DIR = "/proc/"
R.CACHE_DIR = (os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")) .. "/claude-constellation/"
function R.set_dirs(data_dir, power_dir, registry_dir, proc_dir)
  DATA_DIR = data_dir or DATA_DIR
  PS_DIR = power_dir or PS_DIR
  REGISTRY_DIR = registry_dir or REGISTRY_DIR
  PROC_DIR = proc_dir or PROC_DIR
end
function R.set_cache_dir(dir) R.CACHE_DIR = dir end

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
local K -- drawing kit for the layouts, defined below; exposes the palette as K.C

function R.set_palette(p)
  p = p or {}
  local function pick(k) return rgb(p[k]) or rgb(R.DEFAULT_PALETTE[k]) end
  C = { bg = pick("bg"), fg = pick("fg"), dim = pick("dim"),
    thinking = pick("thinking"), permission = pick("permission"), kind = {} }
  for _, k in ipairs(KINDS) do C.kind[k] = pick(k) end
  if K then K.C = C end
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
    local rank, big = {}, {} -- no table.unpack: the saver may run under Lua 5.1/LuaJIT
    for k, g in ipairs(out) do rank[g], big[k] = k, g end
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

local function read_line(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local v = f:read("*l"); f:close()
  return v
end

-- Decoded session files with the size/mtime they were read at: a file is only parsed again
-- when the hook rewrote it.
local files = {}
local links = {} -- shared_links(), refreshed with the sessions
local generation = 0 -- bumped on every reload, so layouts can cache what they derive from sessions

local function file_stamp(info)
  return ("%d:%d:%d"):format(info:get_size(), info:get_attribute_uint64("time::modified"),
    info:get_attribute_uint32("time::modified-usec"))
end
local STAMP_ATTRS = "standard::name,standard::size,time::modified,time::modified-usec"

-- Start time (clock ticks since boot) of a process: field 22 of /proc/<pid>/stat, matching the
-- registry's procStart. nil if the process is gone.
local function proc_start(pid)
  local line = read_line(PROC_DIR .. pid .. "/stat")
  if not line then return nil end
  local rest = line:match("^%d+ %b() (.*)$") -- skip "pid (comm)" (comm may hold spaces)
  local n = 0
  for field in (rest or ""):gmatch("%S+") do
    n = n + 1
    if n == 20 then return field end -- field 22 overall, 3 is the first after comm
  end
end

-- Registry entries (~/.claude/sessions/<pid>.json), cached by size/mtime like the hook files.
local registry = {}

-- Sessions Claude Code reports as running but that have no hook file yet (idle, or started
-- before the hooks were installed): kept if the pid is alive with the same start time. Hook
-- data wins as soon as it exists; these only fill the gaps.
local function read_registry(seen)
  local seen_files = {}
  pcall(function()
    local en = Gio.File.new_for_path(REGISTRY_DIR):enumerate_children(STAMP_ATTRS,
      Gio.FileQueryInfoFlags.NONE)
    if not en then return end
    while true do
      local info = en:next_file(); if not info then break end
      local name = info:get_name()
      if name:match("^%d+%.json$") then
        local stamp = file_stamp(info)
        local f = registry[name]
        local fresh = not f or f.stamp ~= stamp
        if fresh then
          f = { stamp = stamp, data = R.read_json(REGISTRY_DIR .. name) }
          registry[name] = f
        end
        seen_files[name] = true
        local r = f.data
        local sid = type(r) == "table" and type(r.sessionId) == "string" and r.sessionId
        if sid and not seen[sid] and r.kind == "interactive" and r.procStart ~= nil
          and proc_start(tonumber(r.pid) or -1) == tostring(r.procStart) then
          local s = sessions[sid]
          if not s or fresh or not s.registry then
            s = s or { alpha = 0, id = sid }
            s.sid, s.registry, s.history, s.links, s.timeline = sid, true, {}, nil, nil
            s.tool, s.kind, s.target = nil, nil, nil
            s.project = tostring(r.cwd or ""):match("([^/]+)/*$") or ""
            s.state = r.status == "busy" and "thinking" or "idle"
            s.ts = (tonumber(r.updatedAt) or tonumber(r.startedAt) or 0) / 1000
            s.sats = {}
            sessions[sid] = s
          end
          seen[sid] = true
        end
      end
    end
  end)
  for name in pairs(registry) do
    if not seen_files[name] then registry[name] = nil end
  end
end

-- Reload the session files; returns whether any session is working, and the session count.
function R.read_sessions()
  local seen, seen_files = {}, {}
  local t = now()
  pcall(function()
    local en = Gio.File.new_for_path(DATA_DIR):enumerate_children(STAMP_ATTRS,
      Gio.FileQueryInfoFlags.NONE)
    if not en then return end
    while true do
      local info = en:next_file(); if not info then break end
      local sid = info:get_name():match("^(.+)%.json$")
      if sid then
        local stamp = file_stamp(info)
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
          if not s or fresh or s.registry then
            s = s or { alpha = 0, id = sid }
            for k, v in pairs(d) do s[k] = v end
            s.registry = nil
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
  read_registry(seen)
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
  generation = generation + 1
  return active, #order
end

-- On battery = the system battery is discharging (peripheral batteries have scope "Device").
-- Machines without a battery are always on mains.
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

-- Drawing kit shared by the layouts (layouts/*.lua) --------------------------------------------
K = {
  C = C, FADE_LINK = FADE_LINK, LINK_WINDOW = LINK_WINDOW, PARTICLE_TIME = PARTICLE_TIME,
  STALE_AFTER = STALE_AFTER, set = set, is_active = is_active,
}

function K.node_color(s)
  if s.state == "thinking" then return C.thinking end
  if s.state == "tool" then return C.kind[s.kind] or C.kind.other end
  if s.state == "permission" or s.state == "waiting" then return C.permission end
  return C.dim
end

function K.kind_color(kind) return C.kind[kind] or C.kind.other end

-- Emote for a session's state, plus whether it loops (the resting crab is a still pose).
local function emote(s, t)
  if is_active(s) or s.state == "waiting" then return CLAWD[s.state], true end
  if s.stale then return CLAWD.sleeping, true end
  -- `since`: subagent events refresh ts, which must not replay the party.
  if s.state == "done" and t - (tonumber(s.since or s.ts) or 0) < DONE_PARTY then return CLAWD.done, true end
  return CLAWD.rest, false
end

-- tilt rotates the sprite around its centre (rad, clockwise).
local function draw_sprite(cr, cells, idx, x, y, a, size, tilt)
  local cell = cells[(idx % #cells) + 1]
  local w, h = cell:get_width(), cell:get_height()
  local k = size / math.max(w, h)
  cr:save()
  cr:translate(x, y)
  if tilt then cr:rotate(tilt) end
  cr:translate(-w * k / 2, -h * k / 2)
  cr:scale(k, k)
  cr:set_source_surface(cell, 0, 0)
  cr:get_source():set_filter(cairo.Filter.NEAREST) -- keep the pixel art crisp
  cr:paint_with_alpha(a)
  cr:restore()
end

-- Rasterising a radial gradient was the costliest part of a frame, so each glow is drawn once
-- per (colour, whole-pixel radius) into a small surface, then blitted with the wanted alpha.
-- Keyed by the palette's colour tables: set_palette drops the old ones, and their surfaces.
local glow_cache = setmetatable({}, { __mode = "k" })
function K.glow(cr, x, y, r, c, a)
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

-- Regular or bold monospace; text widths are cached per weight.
local bold = false
function K.bold(cr, on)
  if on == bold then return end
  bold = on
  cr:select_font_face("monospace", cairo.FontSlant.NORMAL,
    on and cairo.FontWeight.BOLD or cairo.FontWeight.NORMAL)
end

-- Label widths, memoised per font size and weight: text_extents is a costly lgi round-trip and
-- labels rarely change. Flushed when it grows, since targets come and go.
local widths, n_widths = {}, 0
function K.text_width(cr, str, size)
  local key = bold and -size or size
  local by_str = widths[key]
  local w = by_str and by_str[str]
  if w then return w end
  if n_widths > 500 then widths, n_widths = {}, 0 end
  cr:set_font_size(size)
  w = cr:text_extents(str).width
  widths[key] = widths[key] or {}
  widths[key][str] = w
  n_widths = n_widths + 1
  return w
end

-- align: nil/false = left of x, true = centred on x, "right" = ending at x.
function K.text(cr, str, x, y, size, c, a, align)
  local x0 = x
  if align == "right" then x0 = x - K.text_width(cr, str, size)
  elseif align then x0 = x - K.text_width(cr, str, size) / 2 end
  cr:set_font_size(size)
  cr:move_to(x0, y)
  set(cr, c, a)
  cr:show_text(str)
end

function K.rrect(cr, x, y, w, h, r)
  cr:new_sub_path()
  cr:arc(x + w - r, y + r, r, -math.pi / 2, 0)
  cr:arc(x + w - r, y + h - r, r, 0, math.pi / 2)
  cr:arc(x + r, y + h - r, r, math.pi / 2, math.pi)
  cr:arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
  cr:close_path()
end

-- Ease a session's node towards (tx, ty): smooth drift, and nodes glide when the layout changes.
function K.place(s, tx, ty, f, rate)
  local e = f.static and 1 or (rate or 0.05)
  s.x = s.x and s.x + (tx - s.x) * e or tx
  s.y = s.y and s.y + (ty - s.y) * e or ty
end

function K.name(s) return (s.project and s.project ~= "") and s.project or s.id:sub(1, 8) end

-- State line under a session; the running tool's target is hidden when private.
function K.sub(s, private)
  if s.state == "tool" and s.target and s.target ~= "" and not private then
    return (s.tool or "") .. " · " .. s.target
  end
  return s.state or ""
end

-- "now", "4m", "2h" since t0.
function K.ago(t, t0)
  local d = t - (tonumber(t0) or t)
  if d < 60 then return "now" end
  if d < 3600 then return math.floor(d / 60) .. "m" end
  return math.floor(d / 3600) .. "h"
end

-- How much a session needs you: 1 permission, 2 waiting, 3 working, 4 done/idle, 5 asleep.
function K.urgency(s)
  if s.stale then return 5 end
  if s.state == "permission" then return 1 end
  if s.state == "waiting" then return 2 end
  if is_active(s) then return 3 end
  return 4
end

-- The sessions, most urgent first (stable: by name within a level).
function K.by_urgency(list)
  local out = {}
  for i, s in ipairs(list) do out[i] = s end
  table.sort(out, function(a, b)
    local ua, ub = K.urgency(a), K.urgency(b)
    if ua ~= ub then return ua < ub end
    return a.id < b.id
  end)
  return out
end

-- A session's node: glow pulsing with its state, and its Clawd emote on top (a dot if the
-- sprites are missing). `size` is the sprite size; the glow scales with it.
function K.node(cr, s, i, x, y, f, size)
  local t, A, col = f.t, s.alpha, K.node_color(s)
  local pulse
  if f.static then pulse = 0.6
  elseif s.state == "thinking" then pulse = 0.5 + 0.5 * math.sin(t * 5)
  elseif s.state == "tool" then pulse = 0.6 + 0.4 * math.sin(t * 8)
  elseif s.state == "permission" then pulse = (math.floor(t * 2) % 2 == 0) and 1 or 0.3
  elseif s.state == "waiting" then pulse = 0.5 + 0.5 * math.sin(t * 1.5)
  else pulse = 0.25 end
  local k = size / SPRITE_SIZE
  K.glow(cr, x, y, (40 + 18 * pulse) * k, col, (0.35 + 0.4 * pulse) * A)
  local name, loops = emote(s, t)
  local frames = sprite_set(name)
  if #frames > 0 then
    -- Desynced per session.
    draw_sprite(cr, frames, loops and math.floor(t * SPRITE_FPS + i * 7) or 0, x, y, A, size)
  else
    set(cr, col, A); cr:arc(x, y, 5 * k, 0, 2 * math.pi); cr:fill()
  end
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
-- Runners are the front-facing walking crab: running (fast steps, bouncing, leaning where they
-- head) during a tool call, walking while thinking; they listen (blinking) on a permission and
-- party then fade out once done.
-- Layouts call it before drawing the session's node, so the node stays on top.
function K.runners(cr, s, f)
  local t, ta, static, private, A = f.t, f.ta, f.static, f.private, s.alpha
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
    K.glow(cr, x, y, 18 + 6 * blink, col, (0.25 + 0.35 * blink) * RA)

    local cells, idx, fps
    if r.state == "tool" or r.state == "thinking" then
      cells, fps = sprite_set(CLAWD.rest), running and 24 or 10
    elseif r.state == "done" then
      cells, fps = sprite_set(CLAWD.done), SPRITE_FPS
    else
      cells, fps = sprite_set(CLAWD.permission), SPRITE_FPS
    end
    idx = math.floor(t * fps + i * 5)
    if #cells > 0 then
      -- Heading right on the top half of the orbit, left on the bottom half.
      local tilt = running and RUN_TILT * (math.sin(p.a) > 0 and -1 or 1) or nil
      draw_sprite(cr, cells, idx, x, y, RA, MINI_SIZE, tilt)
    else
      set(cr, col, RA); cr:arc(x, y, 3.5, 0, 2 * math.pi); cr:fill()
    end

    local name
    if r.merged then name = "+" .. r.count .. " agents"
    elseif r.count > 1 then name = r.type .. " ×" .. r.count
    elseif not private and r.label and r.label ~= "" then name = r.label
    else name = r.type end
    K.text(cr, name, x, y - 22, 10, C.fg, 0.75 * RA, true)
    if not private and r.count == 1 and r.state == "tool" and r.target and r.target ~= "" then
      K.text(cr, r.target, x, y + 28, 9, col, 0.65 * RA, true)
    end
  end
  for id in pairs(s._run) do
    if not seen[id] then s._run[id] = nil end
  end
end

-- Layouts ----------------------------------------------------------------------------------------
-- Each layouts/<name>.lua returns function(K, cr, w, h, f), f being the frame:
-- { t, ta (animation clock, frozen while static), static, private, list (sessions), links, gen }.
R.LAYOUTS = { "constellation", "lanes", "cards", "resources", "kanban", "radar", "strip", "hud", "popup" }
local layouts = {}
for _, name in ipairs(R.LAYOUTS) do layouts[name] = dofile(DIR .. "layouts/" .. name .. ".lua") end

-- The chosen layout, shared by the desktop layer and the lock-screen saver.
function R.read_layout()
  local name = read_line(R.CACHE_DIR .. "layout")
  return layouts[name] and name or R.LAYOUTS[1]
end
function R.write_layout(name)
  local f = io.open(R.CACHE_DIR .. "layout", "w")
  if not f then return false end
  f:write(name, "\n"); f:close()
  return true
end

-- Draw one frame. opts.layout picks the presentation (constellation by default);
-- opts.static freezes everything but the Clawd emotes (battery mode); opts.private drops what
-- could leak on a lock screen: paths, commands and the tool target.
function R.draw(cr, w, h, opts)
  opts = opts or {}
  local t = now()
  local f = { t = t, ta = opts.static and 0 or t, static = opts.static, private = opts.private,
    list = {}, links = links, gen = generation }
  for i, sid in ipairs(order) do
    local s = sessions[sid]
    s.stale = t - (tonumber(s.ts) or 0) > STALE_AFTER and not is_active(s)
    s.alpha = s.alpha + (((s.stale and 0.35) or 1) - s.alpha) * (opts.static and 1 or 0.08)
    f.list[i] = s
  end
  set(cr, C.bg); cr:paint()
  bold = nil; K.bold(cr, false) -- a fresh context starts with the default font
  local layout = layouts[opts.layout] or layouts.constellation
  layout(K, cr, w, h, f)
end

return R
