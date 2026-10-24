-- Radar: the recent past as a clock face. One ring per session, an arc per tool call coloured
-- by kind, the sweep at the top is now and time runs back anticlockwise. The most urgent
-- session sits in the middle.

local WINDOW = 30 * 60 -- the hook keeps a 30-minute timeline
local ALPHA_STEPS = 32 -- a session's alpha is baked into the cached rings, in steps of 1/32
local DRIFT = 0.5 -- pixels the outer ring may turn before the rings are drawn again

-- Stroking the rings (an arc per call, hundreds of them) is most of a frame, while they turn
-- by under two pixels a second: so they are drawn into an offscreen surface, blitted as is
-- until the outer ring would have moved DRIFT pixels, then drawn again. The surface is also
-- redrawn when a timeline is reloaded, a session's alpha moves, the geometry, position or
-- backend changes, or the oldest call leaves the window.
local cache = { items = {}, expires = -1 }

local function rings_valid(K, f, cx, cy, r0, step, band)
  local c = cache
  if c.cx ~= cx or c.cy ~= cy or c.r0 ~= r0 or c.step ~= step or c.band ~= band
    or c.backend ~= K.backend() or #c.items ~= #f.list or f.t >= c.expires
    or (f.t - c.t0) / WINDOW * 2 * math.pi * c.R0 >= DRIFT then return false end
  for i, s in ipairs(f.list) do
    local it = c.items[i]
    if it.tl ~= s.timeline or it.sats ~= s.sats or it.a ~= math.floor(s.alpha * ALPHA_STEPS) then
      return false
    end
  end
  return true
end

local function draw_rings(K, cr, f, cx, cy, r0, step, band)
  local C, t = K.C, f.t
  local n = #f.list
  local R0 = math.ceil(r0 + (n - 1) * step + band / 2 + 1) -- the outer ring, band included
  -- The surface is blitted at a whole-pixel offset (no resampling), so the centre keeps its
  -- fractional part inside it and the result matches drawing straight onto the frame.
  local ox, oy = math.floor(cx) - R0, math.floor(cy) - R0
  local X, Y = cx - ox, cy - oy
  local surf, g = K.offscreen(cr, 2 * R0 + 1, 2 * R0 + 1)
  local function ang(ts) return -math.pi / 2 - (t - ts) / WINDOW * 2 * math.pi end
  local expires, items = math.huge, {}
  for i, s in ipairs(f.list) do
    local r, A = r0 + (i - 1) * step, s.alpha
    items[i] = { tl = s.timeline, sats = s.sats, a = math.floor(A * ALPHA_STEPS) }
    K.set(g, C.dim, 0.18 * A); g:set_line_width(1)
    g:new_path(); g:arc(X, Y, r, 0, 2 * math.pi); g:stroke()
    -- One stroke per kind: the arcs of a colour go into one path.
    local arcs, kinds = {}, {}
    local function arc(kind, ts, a1)
      if t - ts >= WINDOW then return end
      kind = kind or "other"
      local list = arcs[kind]
      if not list then list = {}; arcs[kind] = list; kinds[#kinds + 1] = kind end
      list[#list + 1] = ang(ts); list[#list + 1] = a1
      expires = math.min(expires, ts + WINDOW)
    end
    local timeline = type(s.timeline) == "table" and s.timeline or {}
    for _, e in ipairs(timeline) do
      local ts = tonumber(e.s) or t
      arc(e.k, ts, ang(tonumber(e.e) or t) + 0.01)
    end
    if #timeline == 0 then -- older hook: a tick per recent target
      for _, sat in ipairs(s.sats) do
        local ts = tonumber(sat.ts) or 0
        arc(sat.kind, ts, ang(ts) + 0.02)
      end
    end
    g:set_line_width(band)
    for _, kind in ipairs(kinds) do
      local list = arcs[kind]
      g:new_path()
      for j = 1, #list, 2 do g:new_sub_path(); g:arc(X, Y, r, list[j], list[j + 1]) end
      K.set(g, K.kind_color(kind), 0.85 * A); g:stroke()
    end
  end
  surf:flush()
  cache = { items = items, cx = cx, cy = cy, r0 = r0, step = step, band = band,
    backend = K.backend(), surf = surf, R0 = R0, ox = ox, oy = oy, t0 = t, expires = expires }
end

return function(K, cr, w, h, f)
  local C = K.C
  local n = #f.list
  if n == 0 then return end
  local cx, cy = w / 2, h / 2 + 10
  local size = math.min(w, h)
  local r0, r1 = size * 0.14, size * 0.43
  local step = n > 1 and (r1 - r0) / (n - 1) or 0
  local band = math.max(4, math.min(12, step * 0.35))

  if not rings_valid(K, f, cx, cy, r0, step, band) then draw_rings(K, cr, f, cx, cy, r0, step, band) end
  cr:set_source_surface(cache.surf, cache.ox, cache.oy)
  cr:paint()

  -- Sweep, time marks, then the ring labels on top.
  K.set(cr, C.fg, 0.5); cr:set_line_width(2)
  cr:new_path(); cr:move_to(cx, cy - r0 * 0.6); cr:line_to(cx, cy - r1 - 18); cr:stroke()
  K.glow(cr, cx, cy - r1 - 18, 18, C.fg, 0.5)
  for m = 0, WINDOW / 60 - 1, 10 do
    local a = -math.pi / 2 - m * 60 / WINDOW * 2 * math.pi
    K.text(cr, m == 0 and "now" or ("-" .. m .. " min"), cx + (r1 + 40) * math.cos(a),
      cy + (r1 + 40) * math.sin(a) + 4, 11, C.dim, 1, true)
  end
  local a = -math.pi / 2 - 0.1
  K.bold(cr, true)
  for i, s in ipairs(f.list) do
    local r = r0 + (i - 1) * step
    local lx, ly = cx + r * math.cos(a), cy + r * math.sin(a)
    local name = K.name(s)
    local tw = K.text_width(cr, name, 11)
    K.set(cr, C.bg, 0.92); K.rrect(cr, lx - tw - 34, ly - 9, tw + 30, 18, 5); cr:fill()
    K.text(cr, name, lx - 8, ly + 4, 11, C.fg, s.alpha, "right")
    K.set(cr, K.node_color(s), s.alpha); cr:new_path(); cr:arc(lx - tw - 22, ly, 4, 0, 2 * math.pi); cr:fill()
  end
  K.bold(cr, false)

  -- The most urgent session in the middle.
  local top = K.by_urgency(f.list)[1]
  K.place(top, cx, cy, f, 0.2)
  K.node(cr, top, 1, top.x, top.y, f, math.min(72, r0 * 0.9))
  local u = K.urgency(top)
  local line = u <= 2 and (K.name(top) .. " needs you") or u == 3 and "working" or "all quiet"
  K.bold(cr, true)
  K.text(cr, line, cx, cy + r0 * 0.75, 12, u <= 2 and C.permission or C.dim, 1, true)
  K.bold(cr, false)
end
