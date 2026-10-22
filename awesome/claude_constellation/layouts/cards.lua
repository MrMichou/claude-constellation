-- Cards: one card per session in a grid (state, running tool, last targets), plus a summary
-- tile when a slot is free. Stays readable with many sessions.

return function(K, cr, w, h, f)
  local C, t = K.C, f.t
  local n = #f.list
  if n == 0 then return end
  local cols = n == 1 and 1 or n <= 4 and 2 or n <= 9 and 3 or 4
  local tiles = n + ((n > 1 and n % cols ~= 0) and 1 or 0) -- summary in a free slot
  local rows = math.ceil(tiles / cols)
  local gap, margin = 22, 40
  local cw = math.min(460, (w - 2 * margin - gap * (cols - 1)) / cols)
  local ch = math.min(300, (h - 2 * margin - gap * (rows - 1)) / rows)
  local gx = (w - cols * cw - (cols - 1) * gap) / 2
  local gy = (h - rows * ch - (rows - 1) * gap) / 2
  local function slot(i)
    return gx + ((i - 1) % cols) * (cw + gap), gy + math.floor((i - 1) / cols) * (ch + gap)
  end

  for i, s in ipairs(f.list) do
    local x, y = slot(i)
    local A, col = s.alpha, K.node_color(s)
    local size = math.min(72, ch * 0.28)
    local hx, hy = x + 20 + size / 2, y + 16 + size / 2 -- node centre in the header
    K.set(cr, C.fg, 0.05 * A); K.rrect(cr, x, y, cw, ch, 14); cr:fill()
    K.set(cr, col, 0.9 * A); cr:set_line_width(s.state == "permission" and 3 or 1.5)
    K.rrect(cr, x, y, cw, ch, 14); cr:stroke()

    K.place(s, hx, hy, f, 0.2)
    cr:save(); K.rrect(cr, x, y, cw, ch, 14); cr:clip()
    K.node(cr, s, i, s.x, s.y, f, size)
    local tx = x + 40 + size
    K.bold(cr, true); K.text(cr, K.name(s), tx, hy - 4, 16, C.fg, A); K.bold(cr, false)
    K.text(cr, K.sub(s, f.private), tx, hy + 16, 12, col, A)
    K.text(cr, K.ago(t, s.ts), x + cw - 16, y + 24, 11, C.dim, A, "right")

    local ly = y + 32 + size
    K.set(cr, C.dim, 0.2 * A); cr:set_line_width(1)
    cr:move_to(x + 16, ly); cr:line_to(x + cw - 16, ly); cr:stroke()
    -- Last targets, newest first; private shows only their kind.
    local sats, row = s.sats, 0
    for j = #sats, 1, -1 do
      local ty = ly + 24 + row * 24
      if ty > y + ch - 10 then break end
      local sat = sats[j]
      local fade = math.max(0.35, 1 - (t - (tonumber(sat.ts) or 0)) / K.FADE_LINK)
      K.set(cr, K.kind_color(sat.kind), fade * A); cr:arc(x + 24, ty - 4, 4, 0, 2 * math.pi); cr:fill()
      K.text(cr, f.private and (sat.kind or "") or (sat.target or ""), x + 38, ty, 12, C.fg, 0.75 * fade * A)
      row = row + 1
    end
    cr:restore()
  end

  if tiles > n then -- summary tile
    local x, y = slot(tiles)
    local count = { permission = 0, working = 0, waiting = 0, rest = 0, asleep = 0 }
    for _, s in ipairs(f.list) do
      local k = s.stale and "asleep" or s.state == "permission" and "permission"
        or K.is_active(s) and "working" or s.state == "waiting" and "waiting" or "rest"
      count[k] = count[k] + 1
    end
    K.set(cr, C.fg, 0.03); K.rrect(cr, x, y, cw, ch, 14); cr:fill()
    cr:save(); K.rrect(cr, x, y, cw, ch, 14); cr:clip()
    K.bold(cr, true); K.text(cr, n .. " sessions", x + 24, y + 44, 18, C.fg, 1); K.bold(cr, false)
    local lines = {
      { "permission", C.permission, "awaiting permission" }, { "working", C.thinking, "working" },
      { "waiting", C.permission, "waiting for you" }, { "rest", C.dim, "done" },
      { "asleep", C.dim, "asleep" },
    }
    local row = 0
    for _, l in ipairs(lines) do
      if count[l[1]] > 0 then
        local ly = y + 80 + row * 28
        K.set(cr, l[2]); cr:arc(x + 30, ly - 4, 5, 0, 2 * math.pi); cr:fill()
        K.text(cr, count[l[1]] .. " " .. l[3], x + 46, ly, 13, C.fg, 0.85)
        row = row + 1
      end
    end
    if #f.links > 0 then
      K.text(cr, "⇄ " .. #f.links .. " shared resource" .. (#f.links > 1 and "s" or ""),
        x + 24, y + ch - 24, 12, C.dim, 1)
    end
    cr:restore()
  end
end
