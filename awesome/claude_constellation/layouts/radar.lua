-- Radar: the recent past as a clock face. One ring per session, an arc per tool call coloured
-- by kind, the sweep at the top is now and time runs back anticlockwise. The most urgent
-- session sits in the middle.

local WINDOW = 30 * 60 -- the hook keeps a 30-minute timeline

-- Centre and inner/outer ring radii.
local function geometry(w, h)
  local size = math.min(w, h)
  return w / 2, h / 2 + 10, size * 0.14, size * 0.43
end

-- Everything but the middle node: it only changes with the sessions (see K.layer).
local function still(K, cr, w, h, f, top)
  local C, t = K.C, f.t
  local n = #f.list
  local cx, cy, r0, r1 = geometry(w, h)
  local step = n > 1 and (r1 - r0) / (n - 1) or 0
  local band = math.max(4, math.min(12, step * 0.35))
  local function ang(ts) return -math.pi / 2 - (t - ts) / WINDOW * 2 * math.pi end

  for i, s in ipairs(f.list) do
    local r, A = r0 + (i - 1) * step, s.alpha
    K.set(cr, C.dim, 0.18 * A); cr:set_line_width(1)
    cr:new_path(); cr:arc(cx, cy, r, 0, 2 * math.pi); cr:stroke()
    cr:set_line_width(band)
    local timeline = type(s.timeline) == "table" and s.timeline or {}
    for _, e in ipairs(timeline) do
      local ts, te = tonumber(e.s) or t, tonumber(e.e) or t
      if t - ts < WINDOW then
        K.set(cr, K.kind_color(e.k), 0.85 * A)
        cr:new_path(); cr:arc(cx, cy, r, ang(ts), ang(te) + 0.01); cr:stroke()
      end
    end
    if #timeline == 0 then -- older hook: a tick per recent target
      for _, sat in ipairs(s.sats) do
        local ts = tonumber(sat.ts) or 0
        if t - ts < WINDOW then
          K.set(cr, K.kind_color(sat.kind), 0.85 * A)
          cr:new_path(); cr:arc(cx, cy, r, ang(ts), ang(ts) + 0.02); cr:stroke()
        end
      end
    end
  end

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

  local u = K.urgency(top)
  local line = u <= 2 and (K.name(top) .. " needs you") or u == 3 and "working" or "all quiet"
  K.bold(cr, true)
  K.text(cr, line, cx, cy + r0 * 0.75, 12, u <= 2 and C.permission or C.dim, 1, true)
  K.bold(cr, false)
end

return function(K, cr, w, h, f)
  if #f.list == 0 then return end
  -- The most urgent session in the middle.
  local top = K.by_urgency(f.list)[1]
  K.layer(cr, w, h, f, "radar", function(lc) still(K, lc, w, h, f, top) end)
  local cx, cy, r0 = geometry(w, h)
  K.place(top, cx, cy, f, 0.2)
  K.node(cr, top, 1, top.x, top.y, f, math.min(72, r0 * 0.9))
end
