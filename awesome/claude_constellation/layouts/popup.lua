-- Popup: the session list a key binding would open over your windows, most urgent first, the
-- top one highlighted (Enter would jump to its terminal once sessions know their window).

return function(K, cr, w, h, f)
  local C, t = K.C, f.t
  local n = #f.list
  if n == 0 then return end
  local row = 60
  local pw = math.min(560, w - 80)
  local ph = math.min(h - 80, 80 + row * n)
  local px, py = (w - pw) / 2, (h - ph) / 2
  K.set(cr, C.bg); K.rrect(cr, px, py, pw, ph, 14); cr:fill()
  K.set(cr, C.thinking, 0.8); cr:set_line_width(1.5); K.rrect(cr, px, py, pw, ph, 14); cr:stroke()
  K.bold(cr, true); K.text(cr, "Claude sessions", px + 24, py + 38, 16, C.fg, 1); K.bold(cr, false)
  K.text(cr, "↑↓ select · ⏎ focus terminal · Esc close", px + pw - 24, py + 38, 10, C.dim, 1, "right")

  cr:save(); K.rrect(cr, px, py, pw, ph, 14); cr:clip()
  for i, s in ipairs(K.by_urgency(f.list)) do
    local y = py + 60 + (i - 1) * row
    if y + row > py + ph then break end
    local A, col = s.alpha, K.node_color(s)
    if i == 1 then K.set(cr, col, 0.15); K.rrect(cr, px + 12, y, pw - 24, row - 6, 8); cr:fill() end
    K.place(s, px + 44, y + (row - 6) / 2, f, 0.2)
    K.node(cr, s, i, s.x, s.y, f, 40)
    K.bold(cr, true); K.text(cr, K.name(s), px + 78, y + 24, 14, C.fg, A); K.bold(cr, false)
    K.text(cr, K.sub(s, f.private), px + 78, y + 43, 11, col, A)
    K.text(cr, K.ago(t, s.ts), px + pw - 28, y + 32, 11, C.dim, A, "right")
  end
  cr:restore()
end
