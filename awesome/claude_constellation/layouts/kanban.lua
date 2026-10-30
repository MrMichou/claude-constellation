-- Kanban: sessions sorted into columns by what they need from you. The left column is your
-- to-do list (a permission to grant, a question to answer).

local COLUMNS = {
  { title = "Needs you", levels = { [1] = true, [2] = true }, color = "permission" },
  { title = "Working", levels = { [3] = true }, color = "thinking" },
  { title = "Done", levels = { [4] = true }, color = "shell" },
  { title = "Asleep", levels = { [5] = true }, color = "dim" },
}

local MARGIN, GAP, TOP, CARD_H = 40, 22, 60, 96

-- Columns and their cards: { {col, x, cc, items, cards = { {s, j, x, y, w}, ... }, more}, ... }
local function columns(K, w, h, f)
  local C = K.C
  local cw = (w - 2 * MARGIN - GAP * (#COLUMNS - 1)) / #COLUMNS
  local sorted = K.by_urgency(f.list)
  local out = {}
  for ci, col in ipairs(COLUMNS) do
    local x = MARGIN + (ci - 1) * (cw + GAP)
    local cc = col.color == "shell" and K.kind_color("shell") or C[col.color]
    local items = {}
    for _, s in ipairs(sorted) do if col.levels[K.urgency(s)] then items[#items + 1] = s end end
    local c = { col = col, x = x, w = cw, cc = cc, items = items, cards = {} }
    for j, s in ipairs(items) do
      local y = TOP + 56 + (j - 1) * (CARD_H + 10)
      if y + CARD_H > h - MARGIN then c.more = { j = j, y = y }; break end
      c.cards[#c.cards + 1] = { s = s, j = j, x = x + 10, y = y, w = cw - 20 }
    end
    out[#out + 1] = c
  end
  return out
end

-- Everything but the nodes: it only changes with the sessions (see K.layer).
local function still(K, cr, h, f, cols)
  local C, t = K.C, f.t
  for _, c in ipairs(cols) do
    local x, cw, cc = c.x, c.w, c.cc
    K.set(cr, C.fg, 0.035); K.rrect(cr, x, TOP, cw, h - TOP - MARGIN, 12); cr:fill()
    K.set(cr, cc); K.rrect(cr, x, TOP, cw, 4, 2); cr:fill()
    K.bold(cr, true)
    K.text(cr, c.col.title, x + 16, TOP + 34, 16, C.fg, 1)
    K.text(cr, tostring(#c.items), x + cw - 16, TOP + 34, 14, cc, 1, "right")
    K.bold(cr, false)

    for _, card in ipairs(c.cards) do
      local s, y = card.s, card.y
      local A, sc = s.alpha, K.node_color(s)
      K.set(cr, C.bg, 0.9); K.rrect(cr, card.x, y, card.w, CARD_H, 9); cr:fill()
      K.set(cr, sc, 0.7 * A); cr:set_line_width(s.state == "permission" and 2.5 or 1.2)
      K.rrect(cr, card.x, y, card.w, CARD_H, 9); cr:stroke()
      cr:save(); K.rrect(cr, card.x, y, card.w, CARD_H, 9); cr:clip()
      K.bold(cr, true); K.text(cr, K.name(s), x + 82, y + 34, 14, C.fg, A); K.bold(cr, false)
      K.text(cr, K.sub(s, f.private), x + 82, y + 56, 11, sc, A)
      K.text(cr, K.ago(t, s.ts), x + 82, y + 76, 10, C.dim, A)
      cr:restore()
    end
    if c.more then
      K.text(cr, "+" .. (#c.items - c.more.j + 1) .. " more", x + 16, c.more.y + 20, 12, C.dim, 1)
    end
  end
end

return function(K, cr, w, h, f)
  local cols = columns(K, w, h, f)
  K.layer(cr, w, h, f, "kanban", function(lc) still(K, lc, h, f, cols) end)
  for _, c in ipairs(cols) do
    for _, card in ipairs(c.cards) do
      local s = card.s
      K.place(s, c.x + 46, card.y + CARD_H / 2, f, 0.2)
      cr:save(); K.rrect(cr, card.x, card.y, card.w, CARD_H, 9); cr:clip()
      K.node(cr, s, card.j, s.x, s.y, f, 48)
      cr:restore()
    end
  end
end
