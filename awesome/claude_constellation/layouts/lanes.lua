-- Swimlanes: one lane per session, its tool calls over the last WINDOW as blocks coloured by
-- kind, so parallel work, idle gaps and blocked sessions show at a glance.

local WINDOW = 20 * 60
local KINDS = { "file", "shell", "search", "web", "agent", "mcp" }

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
    local timeline = type(s.timeline) == "table" and s.timeline or {}
    for _, e in ipairs(timeline) do
      local xb = e.e and x_at(tonumber(e.e) or t) or x1 -- no end yet: still running
      if xb >= x0 then
        local xa = math.max(x0, x_at(tonumber(e.s) or t))
        K.set(cr, K.kind_color(e.k), 0.85 * A)
        K.rrect(cr, xa, cy - bar / 2, math.max(3, xb - xa), bar, 3); cr:fill()
      end
    end
    if #timeline == 0 then -- state file from an older hook: ticks from the last targets
      for _, sat in ipairs(s.sats) do
        local x = x_at(tonumber(sat.ts) or 0)
        if x >= x0 then
          K.set(cr, K.kind_color(sat.kind), 0.85 * A)
          K.rrect(cr, x, cy - bar / 2, 3, bar, 1.5); cr:fill()
        end
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
