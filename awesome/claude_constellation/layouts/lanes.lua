-- Swimlanes: one lane per session, its tool calls over the last WINDOW as blocks coloured by
-- kind, so parallel work, idle gaps and blocked sessions show at a glance.

local WINDOW = 20 * 60
local KINDS = { "file", "shell", "search", "web", "agent", "mcp" }

-- Filling the bars (one per call, hundreds of them) is most of a frame, so a session's finished
-- calls are drawn once into a strip, which each frame paints shifted: time passing slides every
-- bar left at the same rate. The strip is redrawn when the timeline is reloaded or the
-- geometry or the backend changes; the running call, which grows, is drawn live.
local strips = setmetatable({}, { __mode = "k" })

local function strip(K, cr, s, x0, x1, bar, t)
  local c = strips[s]
  if c and c.tl == s.timeline and c.sats == s.sats and c.x0 == x0 and c.x1 == x1 and c.bar == bar
    and c.backend == K.backend() then return c end
  local span = x1 - x0
  -- The hook keeps 30 min of calls, the lane shows 20: the strip starts half a window early.
  local ox = x0 - math.ceil(span / 2) - 4 -- screen x of the strip's left edge, at t
  local sw, sh = math.max(1, x1 - ox + 4), math.ceil(bar) + 2 -- a narrow screen may leave no span
  local surf, g = K.offscreen(cr, sw, sh)
  local function x_at(ts) return x1 - (t - ts) / WINDOW * span - ox end
  local bars, kinds = {}, {}
  local function add(kind, xa, xb, radius)
    if xb < x0 - ox then return end -- already out of the window, never seen again
    kind = kind or "other"
    local list = bars[kind]
    if not list then list = {}; bars[kind] = list; kinds[#kinds + 1] = kind end
    list[#list + 1] = math.max(0, xa); list[#list + 1] = xb; list[#list + 1] = radius
  end
  local timeline = type(s.timeline) == "table" and s.timeline or {}
  for _, e in ipairs(timeline) do
    if e.e ~= nil then
      local xa = x_at(tonumber(e.s) or t)
      add(e.k, xa, math.max(xa + 3, x_at(tonumber(e.e) or t)), 3)
    end
  end
  if #timeline == 0 then -- state file from an older hook: ticks from the last targets
    for _, sat in ipairs(s.sats) do
      local x = x_at(tonumber(sat.ts) or 0)
      add(sat.kind, x, x + 3, 1.5)
    end
  end
  -- One fill per kind: the bars of a colour go into one path.
  for _, kind in ipairs(kinds) do
    local list = bars[kind]
    g:new_path()
    for j = 1, #list, 3 do K.rrect(g, list[j], 1, list[j + 1] - list[j], bar, list[j + 2]) end
    K.set(g, K.kind_color(kind)); g:fill()
  end
  surf:flush()
  c = { tl = s.timeline, sats = s.sats, x0 = x0, x1 = x1, bar = bar, backend = K.backend(),
    surf = surf, ox = ox, t0 = t }
  strips[s] = c
  return c
end

return function(K, cr, w, h, f)
  local C, t = K.C, f.t
  local n = #f.list
  if n == 0 then return end
  local top, bottom = 40, 60
  local lane = math.min(110, (h - top - bottom) / n)
  local x0, x1 = math.max(300, w * 0.2), w - 40
  local function x_at(ts) return x1 - (t - ts) / WINDOW * (x1 - x0) end

  -- Time grid, every 5 minutes.
  cr:set_line_width(1)
  for m = 0, WINDOW / 60, 5 do
    local x = x1 - (x1 - x0) * m * 60 / WINDOW
    K.set(cr, C.dim, 0.15); cr:move_to(x, top); cr:line_to(x, top + lane * n); cr:stroke()
    K.text(cr, m == 0 and "now" or ("-" .. m .. " min"), x, top + lane * n + 18, 11, C.dim, 0.8, true)
  end

  local bar = math.max(6, math.min(18, lane * 0.22))
  for i, s in ipairs(f.list) do
    local A, col = s.alpha, K.node_color(s)
    local y = top + (i - 1) * lane
    local cy = y + lane / 2
    K.set(cr, C.fg, 0.04 * A); K.rrect(cr, 20, y + 4, w - 40, lane - 8, 10); cr:fill()

    K.place(s, 70, cy, f, 0.2)
    K.node(cr, s, i, s.x, s.y, f, math.min(56, lane * 0.6))
    cr:save(); cr:rectangle(0, y, x0 - 10, lane); cr:clip() -- long names stop at the timeline
    K.bold(cr, true); K.text(cr, K.name(s), 110, cy - 3, 14, C.fg, A); K.bold(cr, false)
    K.text(cr, K.sub(s, f.private), 110, cy + 15, 11, col, 0.9 * A)
    cr:restore()

    K.set(cr, C.dim, 0.25 * A); cr:move_to(x0, cy); cr:line_to(x1, cy); cr:stroke()
    local c = strip(K, cr, s, x0, x1, bar, t)
    local y_top = cy - bar / 2 - 1
    cr:save(); cr:rectangle(x0, y_top, x1 - x0, bar + 2); cr:clip()
    cr:set_source_surface(c.surf, c.ox - (t - c.t0) / WINDOW * (x1 - x0), y_top)
    cr:paint_with_alpha(0.85 * A)
    cr:restore()
    for _, e in ipairs(type(s.timeline) == "table" and s.timeline or {}) do
      if e.e == nil then -- no end yet: still running, so it grows up to now
        local xa = math.max(x0, x_at(tonumber(e.s) or t))
        K.set(cr, K.kind_color(e.k), 0.85 * A)
        K.rrect(cr, xa, cy - bar / 2, math.max(3, x1 - xa), bar, 3); cr:fill()
      end
    end

    if s.state == "permission" or s.state == "waiting" then
      -- Dashed tail since the session started waiting.
      K.set(cr, C.permission, 0.9 * A); cr:set_line_width(2); cr:set_dash({ 5, 4 }, 0)
      cr:move_to(math.max(x0, x_at(tonumber(s.ts) or t)), cy); cr:line_to(x1, cy); cr:stroke()
      cr:set_dash({}, 0); cr:set_line_width(1)
      K.text(cr, s.state .. " " .. K.ago(t, s.ts), x1 - 4, cy - bar / 2 - 6, 11, C.permission, A, "right")
    elseif s.stale then
      K.text(cr, "idle " .. K.ago(t, s.ts), x1 - 4, cy - bar / 2 - 6, 11, C.dim, A, "right")
    end
  end

  -- Legend.
  local lx, ly = x0, math.min(h - 30, top + lane * n + 40)
  for _, k in ipairs(KINDS) do
    K.set(cr, K.kind_color(k)); K.rrect(cr, lx, ly, 12, 12, 3); cr:fill()
    K.text(cr, k, lx + 18, ly + 10, 11, C.dim, 1)
    lx = lx + 36 + K.text_width(cr, k, 11)
  end
end
