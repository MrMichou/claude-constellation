-- Strip: a thin band across the top of the screen, one chip per session (most urgent first)
-- with a sparkline of its tool calls over the last 10 minutes. The rest stays empty.

local SPARK_WINDOW, BUCKETS = 10 * 60, 20
local counts = {} -- reused per chip

return function(K, cr, w, _, f)
  local C, t = K.C, f.t
  local n = #f.list
  if n == 0 then return end
  local band, pad = 64, 14
  local cw = math.min(270, (w - pad * (n + 1)) / n)
  K.set(cr, C.fg, 0.04); cr:rectangle(0, 0, w, band); cr:fill()
  K.set(cr, C.dim, 0.25); cr:rectangle(0, band - 1, w, 1); cr:fill()

  for i, s in ipairs(K.by_urgency(f.list)) do
    local x = pad + (i - 1) * (cw + pad)
    local A, col = s.alpha, K.node_color(s)
    K.set(cr, col, 0.12 * A); K.rrect(cr, x, 8, cw, band - 16, 10); cr:fill()
    if s.state == "permission" then
      K.set(cr, col, A); cr:set_line_width(2); K.rrect(cr, x, 8, cw, band - 16, 10); cr:stroke()
    end
    K.place(s, x + 26, band / 2, f, 0.2)
    cr:save(); K.rrect(cr, x, 8, cw, band - 16, 10); cr:clip()
    K.node(cr, s, i, s.x, s.y, f, 34)
    K.bold(cr, true); K.text(cr, K.name(s), x + 50, 29, 12, C.fg, A); K.bold(cr, false)
    K.text(cr, s.state or "", x + 50, 46, 10, col, A)

    -- Sparkline: calls started per 30 s bucket.
    for b = 1, BUCKETS do counts[b] = 0 end
    for _, e in ipairs(type(s.timeline) == "table" and s.timeline or {}) do
      local age = t - (tonumber(e.s) or 0)
      if age >= 0 and age < SPARK_WINDOW then
        local b = BUCKETS - math.floor(age / SPARK_WINDOW * BUCKETS)
        counts[b] = counts[b] + 1
      end
    end
    local sx = x + cw - 12 - BUCKETS * 4
    for b = 1, BUCKETS do
      local hgt = math.min(30, counts[b] * 8 + 2)
      K.set(cr, col, (counts[b] > 0 and 0.8 or 0.2) * A)
      cr:rectangle(sx + (b - 1) * 4, band - 16 - hgt, 3, hgt); cr:fill()
    end
    cr:restore()
  end
end
