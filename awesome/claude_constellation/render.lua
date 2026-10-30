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

local R = { FPS_ACTIVE = 20, FPS_IDLE = 8, FPS_ECO = 1 }

-- Where session files, Claude Code's session registry (internal, best-effort), processes,
-- power supplies, graphics devices and the cache (theme, chosen layout, backend, eco mode and
-- off switch) live;
-- overridable for tests.
local DATA_DIR = os.getenv("HOME") .. "/.claude/constellation/"
local PS_DIR = "/sys/class/power_supply/"
local REGISTRY_DIR = os.getenv("HOME") .. "/.claude/sessions/"
local PROC_DIR = "/proc/"
local DRM_DIR = "/sys/class/drm/"
R.CACHE_DIR = (os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")) .. "/claude-constellation/"
function R.set_dirs(data_dir, power_dir, registry_dir, proc_dir, drm_dir)
  DATA_DIR = data_dir or DATA_DIR
  PS_DIR = power_dir or PS_DIR
  REGISTRY_DIR = registry_dir or REGISTRY_DIR
  PROC_DIR = proc_dir or PROC_DIR
  DRM_DIR = drm_dir or DRM_DIR
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

-- Backend of the frame being drawn ("gpu" or "cpu", see R.draw) and the offscreen surfaces
-- it caches: on the GPU they are made similar to the target (on X, pixmaps in video memory,
-- so blitting them stays on the GPU); on the CPU, or if the target can't make them, images.
-- opaque: no alpha channel (cheaper to copy).
local backend = "cpu"
local function offscreen(cr, w, h, opaque)
  if backend == "gpu" then
    local ok, surf = pcall(function()
      return cr:get_target():create_similar(opaque and cairo.Content.COLOR or cairo.Content.COLOR_ALPHA, w, h)
    end)
    if ok and surf and surf.status == "SUCCESS" then return surf end
  end
  return cairo.ImageSurface.create(opaque and cairo.Format.RGB24 or cairo.Format.ARGB32, w, h)
end

-- Strips are decoded lazily and memoised per backend: a list of cells plus their size (cells.w,
-- cells.h; non-image surfaces can't tell); {} when a set is missing (falls back to a dot).
local sprite_cache = { cpu = {}, gpu = {} }
local function sprite_set(name, cr)
  local cells = sprite_cache[backend][name]
  if cells then return cells end
  cells = {}
  local n = math.floor(tonumber(manifest[name]) or 0)
  local ok, sheet = pcall(cairo.ImageSurface.create_from_png, FRAMES_DIR .. name .. ".png")
  if n > 0 and ok and sheet and sheet.status == "SUCCESS" then
    local w, h = math.floor(sheet:get_width() / n), sheet:get_height()
    cells.w, cells.h = w, h
    for i = 0, n - 1 do
      local cell = offscreen(cr, w, h)
      local c = cairo.Context(cell)
      c:set_source_surface(sheet, -i * w, 0)
      c:paint()
      cells[#cells + 1] = cell
    end
    sheet:finish()
  end
  sprite_cache[backend][name] = cells
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

-- Event effects: a session showing up, asking for a permission or ending its turn starts a
-- short effect around its node (K.node plays it): s._fx = { {kind, t0}, ... }. Seconds each:
local FX = { born = 0.9, permission = 1.6, done = 1.8 }

-- Notes what changed since the last read. The first sight of a session is a birth (so all of
-- them pop in when Awesome or the lock screen starts); a turn only ends after real work.
local function track_fx(s, t)
  local fx = s._fx
  if not fx then
    s._fx, s._fx_state = { { kind = "born", t0 = t } }, s.state
    return
  end
  local prev = s._fx_state
  if prev ~= s.state then
    if s.state == "permission" then fx[#fx + 1] = { kind = "permission", t0 = t }
    elseif s.state == "done" and (prev == "thinking" or prev == "tool" or prev == "permission") then
      fx[#fx + 1] = { kind = "done", t0 = t }
    end
    s._fx_state = s.state
  end
  for i = #fx, 1, -1 do
    if t - fx[i].t0 > FX[fx[i].kind] then table.remove(fx, i) end
  end
end

-- Whether an effect is still playing: the redraw rate stays high until it ends.
function R.fx_playing()
  local t = now()
  for _, s in pairs(sessions) do
    for _, e in ipairs(s._fx or {}) do
      if t - e.t0 < FX[e.kind] then return true end
    end
  end
  return false
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
    track_fx(s, t)
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

-- Render backend: "gpu" draws straight onto the target (on X, a surface the X server renders
-- with the graphics driver) with cached glows and sprites kept next to it; "cpu" draws into an
-- in-memory image (pixman) and copies it to the target in one paint. "auto" prefers the GPU.
R.BACKENDS = { "auto", "gpu", "cpu" }

-- DRM drivers with no 2D acceleration behind them: firmware framebuffers, virtual GPUs without
-- 3D, server BMC display chips. Anything else bound to a /sys/class/drm/cardN counts as a GPU.
local SOFT_DRM = {
  simpledrm = true, ["simple-framebuffer"] = true, efifb = true, vesafb = true, ofdrm = true,
  vkms = true, ["bochs-drm"] = true, bochs = true, ["cirrus-qemu"] = true, cirrus = true,
  qxl = true, vboxvideo = true, hyperv_drm = true, udl = true, ast = true, mgag200 = true,
}

function R.has_gpu()
  local found = false
  pcall(function()
    local en = Gio.File.new_for_path(DRM_DIR)
      :enumerate_children("standard::name", Gio.FileQueryInfoFlags.NONE)
    if not en then return end
    while true do
      local info = en:next_file(); if not info then break end
      local name = info:get_name()
      if name:match("^card%d+$") then
        local f = io.open(DRM_DIR .. name .. "/device/uevent", "r")
        local driver = f and (f:read("*a") or ""):match("DRIVER=([^\n]+)")
        if f then f:close() end
        if driver and not SOFT_DRM[driver] then found = true end
      end
    end
  end)
  return found
end

-- "auto" (or anything unknown) -> "gpu" when a GPU is found, else "cpu".
function R.resolve_backend(choice)
  if choice == "gpu" or choice == "cpu" then return choice end
  return R.has_gpu() and "gpu" or "cpu"
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
  local w, h = cells.w, cells.h
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
-- One cache per backend, like the sprites.
local glow_cache = { cpu = setmetatable({}, { __mode = "k" }), gpu = setmetatable({}, { __mode = "k" }) }
function K.glow(cr, x, y, r, c, a)
  r = math.floor(r + 0.5)
  local by_r = glow_cache[backend][c]
  if not by_r then by_r = {}; glow_cache[backend][c] = by_r end
  local surf = by_r[r]
  if not surf then
    surf = offscreen(cr, 2 * r, 2 * r)
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

-- A layout's still part (what only changes with the sessions: timelines, bands, tiles, labels)
-- is drawn once per session read into an offscreen frame, background included, then copied onto
-- every frame; the layout draws what moves (nodes, glows, pulses) on top. Hundreds of small
-- shapes then cost one copy a frame. draw(cr) gets the layer's context. `key` stands for what
-- else the still part depends on, the layout's name at least; nil draws it straight onto the
-- frame (e.g. while tiles ease), as does a context that isn't cairo's (the specs' recorder).
-- One layer, for the layout on screen; R.draw drops it when the layout doesn't use it.
local layer = {}
function K.layer(cr, w, h, f, key, draw)
  local ok, target = pcall(function() return cr:get_target() end)
  if key == nil or not ok or not target then return draw(cr) end
  layer.used = true
  local id = table.concat({ backend, w, h, f.gen, tostring(f.static), tostring(f.private), key }, "|")
  if layer.id ~= id or layer.C ~= C then
    local bw, bh = math.ceil(w), math.ceil(h)
    if not (layer.surf and layer.backend == backend and layer.w == bw and layer.h == bh) then
      if layer.surf then layer.surf:finish() end
      layer.surf, layer.backend, layer.w, layer.h = offscreen(cr, bw, bh, true), backend, bw, bh
    end
    layer.id = nil -- until drawn whole
    local lc = cairo.Context(layer.surf)
    set(lc, C.bg); lc:paint()
    local was = bold
    bold = nil; K.bold(lc, false) -- a fresh context starts with the default font
    draw(lc)
    bold = nil; K.bold(cr, was)
    layer.surf:flush()
    layer.id, layer.C = id, C
  end
  cr:save()
  cr:set_operator(cairo.Operator.SOURCE)
  cr:set_source_surface(layer.surf, 0, 0)
  cr:paint()
  cr:restore()
end

-- A gradient from (x0, y0) to (x1, y1) in colour c, alpha a0 to a1, for cr:set_source.
function K.linear(x0, y0, x1, y1, c, a0, a1)
  local pat = cairo.Pattern.create_linear(x0, y0, x1, y1)
  pat:add_color_stop_rgba(0, c[1], c[2], c[3], a0)
  pat:add_color_stop_rgba(1, c[1], c[2], c[3], a1)
  return pat
end

-- Straight lines, batched: every stroke has a high fixed cost, so K.line queues a line and
-- K.lines draws the queue with one stroke per colour, width and alpha (rounded to 1/100), in the
-- order they first came. Overlaps within a batch blend once, which faint links don't show.
local batches, batch_of = {}, {}
function K.line(c, a, x1, y1, x2, y2, width)
  a = math.floor(a * 100 + 0.5)
  if a <= 0 then return end
  width = width or 1
  local by_c = batch_of[c]
  if not by_c then by_c = {}; batch_of[c] = by_c end
  local key = width * 1000 + a
  local b = by_c[key]
  if not b then
    b = { c = c, a = a / 100, width = width }
    by_c[key] = b
    batches[#batches + 1] = b
  end
  b[#b + 1] = x1; b[#b + 1] = y1; b[#b + 1] = x2; b[#b + 1] = y2
end
function K.lines(cr)
  for _, b in ipairs(batches) do
    cr:set_line_width(b.width)
    set(cr, b.c, b.a)
    for i = 1, #b, 4 do cr:move_to(b[i], b[i + 1]); cr:line_to(b[i + 2], b[i + 3]) end
    cr:stroke()
  end
  batches, batch_of = {}, {}
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

local function ease_out(u) return 1 - (1 - u) ^ 3 end
local function ease_out_back(u) -- overshoots a little, then settles at 1
  local c = 1.70158
  return 1 + (c + 1) * (u - 1) ^ 3 + c * (u - 1) ^ 2
end

-- A soft ring: a wide faint stroke under a thin bright one.
local function soft_ring(cr, x, y, r, c, a, lw)
  for _, p in ipairs({ { 3 * lw, 0.25 * a }, { lw, a } }) do
    cr:set_line_width(p[1])
    set(cr, c, p[2])
    cr:new_sub_path(); cr:arc(x, y, r, 0, 2 * math.pi); cr:stroke()
  end
end

-- Stable pseudo-random in 0..1 for confetti piece n of a burst.
local function hash(n) local v = math.sin(n * 12.9898) * 43758.5453; return v - math.floor(v) end

local CONFETTI = 22

-- Confetti from a node whose turn just ended: pieces of every kind colour thrown out with drag,
-- falling, spinning and fading. u is the effect's progress (0..1), dt its age in seconds.
local function confetti(cr, x, y, k, u, dt, seed, A)
  local drag, g = 3.2, 260 * k
  local spread = (1 - math.exp(-drag * dt)) / drag
  for n = 1, CONFETTI do
    local r1, r2, r3 = hash(seed + n), hash(seed + n + 0.37), hash(seed + n + 0.71)
    local ang = (n / CONFETTI + 0.3 * r1) * 2 * math.pi
    local v = (380 + 320 * r2) * k
    local px = x + math.cos(ang) * v * spread
    local py = y + math.sin(ang) * v * spread - 120 * k * spread + 0.5 * g * dt * dt
    local c = C.kind[KINDS[(n % #KINDS) + 1]]
    cr:save()
    cr:translate(px, py)
    cr:rotate(r3 * 6 + dt * (6 + 8 * r1))
    set(cr, c, (1 - u ^ 2) * A)
    cr:rectangle(-3.5 * k, -1.5 * k, 7 * k, 3 * k)
    cr:fill()
    cr:restore()
  end
end

-- A session's node: glow pulsing with its state, and its Clawd emote on top (a dot if the
-- sprites are missing). `size` is the sprite size; the glow scales with it. Plays the
-- session's event effects too (see track_fx): popping in with a ring, two shock waves on a
-- permission request, confetti when a turn ends. Nothing of them while static.
function K.node(cr, s, i, x, y, f, size)
  local t, A, col = f.t, s.alpha, K.node_color(s)
  local k = size / SPRITE_SIZE
  local scale, burst = 1, nil
  for _, e in ipairs(not f.static and s._fx or {}) do
    local dt = t - e.t0
    local u = dt / FX[e.kind]
    if u >= 0 and u < 1 then
      if e.kind == "born" then
        scale = 0.25 + 0.75 * ease_out_back(math.min(1, u / 0.7))
        soft_ring(cr, x, y, size * (0.3 + 1.4 * ease_out(u)), col, 0.8 * (1 - u), 1 + 2 * (1 - u))
      elseif e.kind == "permission" then
        for j = 0, 1 do
          local v = (u - 0.3 * j) / 0.7
          if v > 0 and v < 1 then
            soft_ring(cr, x, y, size * (0.5 + 2.2 * ease_out(v)), C.permission, 0.9 * (1 - v) ^ 1.5 * A,
              1 + 3 * (1 - v))
          end
        end
      elseif e.kind == "done" then
        burst = { u = u, dt = dt, seed = e.t0 % 1000 }
        if u < 0.3 then K.glow(cr, x, y, size * (0.6 + 1.2 * u), C.fg, 0.5 * (1 - u / 0.3) * A) end
      end
    end
  end
  local pulse
  if f.static then pulse = 0.6
  elseif s.state == "thinking" then pulse = 0.5 + 0.5 * math.sin(t * 5)
  elseif s.state == "tool" then pulse = 0.6 + 0.4 * math.sin(t * 8)
  elseif s.state == "permission" then pulse = (math.floor(t * 2) % 2 == 0) and 1 or 0.3
  elseif s.state == "waiting" then pulse = 0.5 + 0.5 * math.sin(t * 1.5)
  else pulse = 0.25 end
  K.glow(cr, x, y, (40 + 18 * pulse) * k * scale, col, (0.35 + 0.4 * pulse) * A)
  local name, loops = emote(s, t)
  local frames = sprite_set(name, cr)
  if #frames > 0 then
    -- Desynced per session; the first frame when still (eco mode).
    local idx = loops and not f.still and math.floor(t * SPRITE_FPS + i * 7) or 0
    draw_sprite(cr, frames, idx, x, y, A, size * scale)
  else
    set(cr, col, A); cr:arc(x, y, 5 * k * scale, 0, 2 * math.pi); cr:fill()
  end
  if burst then confetti(cr, x, y, k, burst.u, burst.dt, burst.seed, A) end
end

local function runner_color(r)
  if r.state == "tool" then return C.kind[r.kind] or C.kind.agent end
  if r.state == "permission" or r.state == "waiting" then return C.permission end
  if r.state == "done" then return C.dim end
  return C.kind.agent
end

-- A session's subagents as R.runners groups them, and the colour of one, for layouts that
-- draw them their own way.
K.runner_list, K.runner_color = R.runners, runner_color

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
-- { t, ta (animation clock, frozen while static), static, private, list (sessions), links, gen,
-- alerts (Promview, see R.set_alerts), area (the screen's workarea {x, y, w, h}: what the bars
-- leave, nil for the whole frame) }.
R.LAYOUTS = { "constellation", "lanes", "cards", "resources", "kanban", "radar", "strip", "hud", "popup",
  "zen", "treemap", "flow", "tree" }
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

-- Whether the desktop layer is switched off (init.lua's set_off); kept across restarts.
function R.read_off() return read_line(R.CACHE_DIR .. "off") == "1" end
function R.write_off(off)
  local f = io.open(R.CACHE_DIR .. "off", "w")
  if not f then return false end
  f:write(off and "1" or "0", "\n"); f:close()
  return true
end

-- The chosen backend ("auto", "gpu" or "cpu"), shared with the lock-screen saver.
function R.read_backend()
  local name = read_line(R.CACHE_DIR .. "backend")
  for _, b in ipairs(R.BACKENDS) do if b == name then return name end end
  return "auto"
end
function R.write_backend(name)
  local f = io.open(R.CACHE_DIR .. "backend", "w")
  if not f then return false end
  f:write(name, "\n"); f:close()
  return true
end

-- Promview alerts shown by the HUD (see promview.lua): nil while Promview is off, else
-- { ok, error, auth, fetched, alerts, groups, counts = {critical, warning, info}, total }.
-- Set by init.lua after each poll, which also writes it to the cache for the lock-screen saver
-- (R.write_alerts / R.read_alerts): the board looks the same there.
local alerts
function R.set_alerts(state) alerts = state end
function R.alerts() return alerts end

-- Nested JSON for the cache (json.lua's encoder only does flat objects). Tables with a [1] or
-- listed in `arrays` are arrays.
local function encode(v, arrays)
  local t = type(v)
  if t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c) return ("\\u%04x"):format(c:byte()) end) .. '"'
  end
  if t == "number" then return v == v and v ~= math.huge and v ~= -math.huge and tostring(v) or "0" end
  if t == "boolean" then return tostring(v) end
  if t ~= "table" then return "null" end
  local parts = {}
  if v[1] ~= nil or arrays then
    for _, x in ipairs(v) do parts[#parts + 1] = encode(x) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  for k, x in pairs(v) do
    if type(k) == "string" then
      parts[#parts + 1] = encode(k) .. ":" .. encode(x, k == "where" or k == "groups")
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local ALERTS_FILE = "promview.json"
function R.write_alerts(state)
  if not state then os.remove(R.CACHE_DIR .. ALERTS_FILE); return true end
  local f = io.open(R.CACHE_DIR .. ALERTS_FILE, "w")
  if not f then return false end
  f:write(encode({ ok = state.ok == true, error = state.error, auth = state.auth, via = state.via,
    fetched = state.fetched or 0, total = state.total or 0, counts = state.counts or {},
    groups = state.groups or {} }))
  f:close()
  return true
end
function R.read_alerts()
  local d = R.read_json(R.CACHE_DIR .. ALERTS_FILE)
  if type(d) ~= "table" or d.ok == nil then return nil end
  d.ok, d.auth = d.ok == true, d.auth == true
  d.via = d.via == "desktop" and "desktop" or nil
  d.fetched, d.total = tonumber(d.fetched) or 0, tonumber(d.total) or 0
  d.counts = type(d.counts) == "table" and d.counts or {}
  d.groups = type(d.groups) == "table" and d.groups or {}
  for _, g in ipairs(d.groups) do
    if type(g.where) ~= "table" then g.where = {} end
    g.count, g.newest = tonumber(g.count) or 0, tonumber(g.newest)
  end
  d.alerts = {}
  return d
end

-- Eco mode: "on" always, "auto" on battery, "off" never. While it is on nothing moves, not even
-- the Clawd emotes, and a frame a second is enough to follow the sessions. Shared with the
-- lock-screen saver.
R.ECO_MODES = { "auto", "on", "off" }
function R.read_eco()
  local name = read_line(R.CACHE_DIR .. "eco")
  for _, m in ipairs(R.ECO_MODES) do if m == name then return name end end
  return "auto"
end
function R.write_eco(name)
  local f = io.open(R.CACHE_DIR .. "eco", "w")
  if not f then return false end
  f:write(name, "\n"); f:close()
  return true
end
function R.eco_active(choice, battery)
  return choice == "on" or (choice == "auto" and battery == true)
end

-- Draw one frame. opts.layout picks the presentation (constellation by default);
-- opts.static freezes everything but the Clawd emotes (battery mode), opts.still the emotes
-- too (eco mode); opts.private drops what could leak on a lock screen: paths, commands and the
-- tool target (Promview alerts stay). opts.backend is "gpu" or "cpu" (the default; see
-- R.resolve_backend): on the CPU, a target that isn't an image (an X surface) gets the frame
-- from an in-memory buffer, in one paint. opts.area is the screen's workarea (see Layouts).
local cpu_buf, cpu_cr
function R.draw(cr, w, h, opts)
  opts = opts or {}
  backend = opts.backend == "gpu" and "gpu" or "cpu"
  local out = cr
  if backend == "cpu" then
    local ok, target = pcall(function() return cr:get_target() end)
    if ok and target and target.type ~= cairo.SurfaceType.IMAGE then
      local bw, bh = math.ceil(w), math.ceil(h)
      if not cpu_buf or cpu_buf:get_width() ~= bw or cpu_buf:get_height() ~= bh then
        cpu_buf = cairo.ImageSurface.create(cairo.Format.RGB24, bw, bh) -- the background is opaque
        cpu_cr = cairo.Context(cpu_buf)
      end
      cr = cpu_cr
    end
  end
  local t = now()
  local static = opts.static or opts.still
  local f = { t = t, ta = static and 0 or t, static = static, still = opts.still, private = opts.private,
    list = {}, links = links, gen = generation, alerts = alerts, area = opts.area }
  for i, sid in ipairs(order) do
    local s = sessions[sid]
    s.stale = t - (tonumber(s.ts) or 0) > STALE_AFTER and not is_active(s)
    s.alpha = s.alpha + (((s.stale and 0.35) or 1) - s.alpha) * (static and 1 or 0.08)
    f.list[i] = s
  end
  set(cr, C.bg); cr:paint()
  bold = nil; K.bold(cr, false) -- a fresh context starts with the default font
  local layout = layouts[opts.layout] or layouts.constellation
  layer.used = false
  layout(K, cr, w, h, f)
  if not layer.used and layer.surf then -- a full-screen surface: freed once unused
    layer.surf:finish()
    layer.surf, layer.id = nil, nil
  end
  if cr ~= out then
    cpu_buf:flush()
    out:set_source_surface(cpu_buf, 0, 0)
    out:paint()
  end
end

return R
