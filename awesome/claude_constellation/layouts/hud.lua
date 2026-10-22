-- HUD: a compact column on the right edge, most urgent session first, meant to stay visible
-- beside your windows. A pending permission gets a ring.

return function(K, cr, w, h, f)
  local C = K.C
  local n = #f.list
  if n == 0 then return end
  local pw, margin = 220, 20
  local x0 = w - pw - margin
  local slot = math.min(118, (h - 2 * margin - 40) / n)
  local ph = slot * n + 40
  local y0 = math.max(margin, (h - ph) / 2)
  K.set(cr, C.fg, 0.05); K.rrect(cr, x0, y0, pw, ph, 14); cr:fill()
  local size = math.min(56, slot * 0.45)
  for i, s in ipairs(K.by_urgency(f.list)) do
    local A, col = s.alpha, K.node_color(s)
    local cx, cy = x0 + pw / 2, y0 + 20 + (i - 1) * slot + slot * 0.4
    K.place(s, cx, cy, f, 0.2)
    K.node(cr, s, i, s.x, s.y, f, size)
    if s.state == "permission" then
      K.set(cr, col, A); cr:set_line_width(2)
      cr:new_path(); cr:arc(s.x, s.y, size * 0.62, 0, 2 * math.pi); cr:stroke()
    end
    K.bold(cr, true); K.text(cr, K.name(s), cx, cy + size * 0.6 + 14, 12, C.fg, A, true); K.bold(cr, false)
    K.text(cr, s.state or "", cx, cy + size * 0.6 + 30, 10, col, A, true)
  end
end
