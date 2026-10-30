-- Zen: almost nothing. One small dot per session in the bottom-right corner, breathing while it
-- works; only a session that needs you (a permission, a question) grows into a Clawd with its
-- name and how long it has been waiting.

local ROW, BIG_ROW = 20, 64

return function(K, cr, w, h, f)
  local C, t = K.C, f.t
  if #f.list == 0 then return end
  local area = f.area or { x = 0, y = 0, w = w, h = h }
  local right, y = area.x + area.w - 36, area.y + area.h - 30

  -- Bottom-up: calm sessions at the bottom, the ones that need you stacked above them.
  local list = K.by_urgency(f.list)
  for i = #list, 1, -1 do
    local s = list[i]
    local A, col = s.alpha, K.node_color(s)
    if K.urgency(s) <= 2 then
      local cy = y - BIG_ROW / 2
      K.place(s, right - 14, cy, f, 0.15)
      K.node(cr, s, i, s.x, s.y, f, 44)
      K.bold(cr, true); K.text(cr, K.name(s), right - 46, cy - 2, 13, C.fg, A, "right"); K.bold(cr, false)
      K.text(cr, (s.state or "") .. " " .. K.ago(t, s.ts), right - 46, cy + 15, 11, col, A, "right")
      y = y - BIG_ROW
    else
      local cy = y - ROW / 2
      K.place(s, right - 14, cy, f, 0.15)
      local breath = K.is_active(s) and not f.static and 0.5 + 0.5 * math.sin(t * 2 + i) or 0
      K.glow(cr, s.x, s.y, 9 + 5 * breath, col, (0.15 + 0.35 * breath) * A)
      K.set(cr, col, 0.9 * A); cr:arc(s.x, s.y, 3.5, 0, 2 * math.pi); cr:fill()
      K.text(cr, K.name(s), right - 28, cy + 4, 10, C.dim, 0.7 * A, "right")
      y = y - ROW
    end
  end
end
