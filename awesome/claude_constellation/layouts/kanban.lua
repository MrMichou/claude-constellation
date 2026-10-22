-- Kanban: sessions sorted into columns by what they need from you. The left column is your
-- to-do list (a permission to grant, a question to answer).

local COLUMNS = {
  { title = "Needs you", levels = { [1] = true, [2] = true }, color = "permission" },
  { title = "Working", levels = { [3] = true }, color = "thinking" },
  { title = "Done", levels = { [4] = true }, color = "shell" },
  { title = "Asleep", levels = { [5] = true }, color = "dim" },
}

return function(K, cr, w, h, f)
  local C, t = K.C, f.t
  local margin, gap = 40, 22
  local cw = (w - 2 * margin - gap * (#COLUMNS - 1)) / #COLUMNS
  local top, card_h = 60, 96
  local sorted = K.by_urgency(f.list)
  for ci, col in ipairs(COLUMNS) do
    local x = margin + (ci - 1) * (cw + gap)
    local cc = col.color == "shell" and K.kind_color("shell") or C[col.color]
    local items = {}
    for _, s in ipairs(sorted) do if col.levels[K.urgency(s)] then items[#items + 1] = s end end

    K.set(cr, C.fg, 0.035); K.rrect(cr, x, top, cw, h - top - margin, 12); cr:fill()
    K.set(cr, cc); K.rrect(cr, x, top, cw, 4, 2); cr:fill()
    K.bold(cr, true)
    K.text(cr, col.title, x + 16, top + 34, 16, C.fg, 1)
    K.text(cr, tostring(#items), x + cw - 16, top + 34, 14, cc, 1, "right")
    K.bold(cr, false)

    for j, s in ipairs(items) do
      local y = top + 56 + (j - 1) * (card_h + 10)
      if y + card_h > h - margin then
        K.text(cr, "+" .. (#items - j + 1) .. " more", x + 16, y + 20, 12, C.dim, 1)
        break
      end
      local A, sc = s.alpha, K.node_color(s)
      K.set(cr, C.bg, 0.9); K.rrect(cr, x + 10, y, cw - 20, card_h, 9); cr:fill()
      K.set(cr, sc, 0.7 * A); cr:set_line_width(s.state == "permission" and 2.5 or 1.2)
      K.rrect(cr, x + 10, y, cw - 20, card_h, 9); cr:stroke()
      K.place(s, x + 46, y + card_h / 2, f, 0.2)
      cr:save(); K.rrect(cr, x + 10, y, cw - 20, card_h, 9); cr:clip()
      K.node(cr, s, j, s.x, s.y, f, 48)
      K.bold(cr, true); K.text(cr, K.name(s), x + 82, y + 34, 14, C.fg, A); K.bold(cr, false)
      K.text(cr, K.sub(s, f.private), x + 82, y + 56, 11, sc, A)
      K.text(cr, K.ago(t, s.ts), x + 82, y + 76, 10, C.dim, A)
      cr:restore()
    end
  end
end
