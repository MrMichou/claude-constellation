-- Treemap: each session's tile is as big as the time it spent in tool calls over the last
-- WINDOW, split by kind of tool. Who works the most, and on what, at a glance.

local WINDOW = 30 * 60
local KINDS = { "file", "shell", "search", "web", "agent", "mcp", "other" }
local KNOWN = {}
for _, k in ipairs(KINDS) do KNOWN[k] = true end
local HEADER = 56

-- Busy seconds per kind over the window (running calls count up to now), and the call count.
local function activity(s, t)
  local by, total, calls = {}, 0, 0
  for _, e in ipairs(type(s.timeline) == "table" and s.timeline or {}) do
    local a = math.max(tonumber(e.s) or t, t - WINDOW)
    local b = math.min(tonumber(e.e) or t, t)
    if b >= t - WINDOW then
      local d = math.max(1, b - a) -- an instant call still shows
      local k = KNOWN[e.k] and e.k or "other"
      by[k] = (by[k] or 0) + d
      total, calls = total + d, calls + 1
    end
  end
  return by, total, calls
end

-- Squarified treemap (Bruls et al.): lays items (with .v > 0) out in the rectangle, setting
-- their .rx, .ry, .rw, .rh. Items must be sorted by decreasing value.
local function squarify(items, x, y, w, h)
  local total = 0
  for _, it in ipairs(items) do total = total + it.v end
  if total <= 0 then return end
  local scale = w * h / total
  local i = 1
  while i <= #items do
    local side = math.min(w, h)
    -- Grow the row while the worst aspect ratio improves.
    local row_sum, best, j = 0, math.huge, i
    while j <= #items do
      local sum = row_sum + items[j].v * scale
      local lo, hi = math.huge, 0
      for k = i, j do
        local a = items[k].v * scale
        lo, hi = math.min(lo, a), math.max(hi, a)
      end
      local worst = math.max(side * side * hi / (sum * sum), sum * sum / (side * side * lo))
      if worst > best then break end
      best, row_sum, j = worst, sum, j + 1
    end
    local thick = row_sum / side
    local off = 0
    for k = i, j - 1 do
      local len = items[k].v * scale / thick
      local it = items[k]
      if w >= h then it.rx, it.ry, it.rw, it.rh = x, y + off, thick, len
      else it.rx, it.ry, it.rw, it.rh = x + off, y, len, thick end
      off = off + len
    end
    if w >= h then x, w = x + thick, w - thick else y, h = y + thick, h - thick end
    i = j
  end
end

local function minutes(sec)
  if sec < 60 then return math.floor(sec) .. "s" end
  return math.floor(sec / 60 + 0.5) .. "m"
end

return function(K, cr, w, h, f)
  local C, t = K.C, f.t
  local n = #f.list
  if n == 0 then return end
  local margin, gap = 30, 8

  local items, grand = {}, 0
  for _, s in ipairs(f.list) do
    local by, total, calls = activity(s, t)
    items[#items + 1] = { s = s, by = by, total = total, calls = calls }
    grand = grand + total
  end
  -- Idle sessions still get a small tile.
  local floor_v = math.max(grand * 0.04, 30)
  for _, it in ipairs(items) do it.v = math.max(it.total, floor_v) end
  table.sort(items, function(a, b)
    if a.v ~= b.v then return a.v > b.v end
    return a.s.id < b.s.id
  end)
  squarify(items, margin, margin, w - 2 * margin, h - 2 * margin - 30)

  for i, it in ipairs(items) do
    local s = it.s
    local A, col = s.alpha, K.node_color(s)
    -- Tiles ease into their new place, like the nodes.
    local e = f.static and 1 or 0.15
    local r = s._tm or { it.rx, it.ry, it.rw, it.rh }
    r[1], r[2] = r[1] + (it.rx - r[1]) * e, r[2] + (it.ry - r[2]) * e
    r[3], r[4] = r[3] + (it.rw - r[3]) * e, r[4] + (it.rh - r[4]) * e
    s._tm = r
    local x, y, tw, th = r[1] + gap / 2, r[2] + gap / 2, r[3] - gap, r[4] - gap
    if tw > 4 and th > 4 then
      cr:save(); K.rrect(cr, x, y, tw, th, 10); cr:clip()
      K.set(cr, C.fg, 0.04 * A); cr:paint()

      -- Kinds, sliced across the body along its longer side.
      local bx, by, bw, bh = x, y + HEADER, tw, th - HEADER
      if bh > 6 and it.total > 0 then
        local off = 0
        for _, k in ipairs(KINDS) do
          local v = it.by[k]
          if v then
            local share = v / it.total
            local kx, ky, kw, kh
            if bw >= bh then kx, ky, kw, kh = bx + off * bw, by, share * bw, bh
            else kx, ky, kw, kh = bx, by + off * bh, bw, share * bh end
            K.set(cr, K.kind_color(k), 0.28 * A); cr:rectangle(kx + 1, ky + 1, kw - 2, kh - 2); cr:fill()
            if kw > 46 and kh > 20 then
              K.text(cr, k, kx + 8, ky + 16, 11, K.kind_color(k), A)
              if kh > 36 then
                K.text(cr, math.floor(share * 100 + 0.5) .. "%", kx + 8, ky + 31, 10, C.fg, 0.6 * A)
              end
            end
            off = off + share
          end
        end
      elseif bh > 14 then
        K.text(cr, "no tool calls", bx + 12, by + 18, 11, C.dim, 0.8 * A)
      end

      local size = math.min(40, th * 0.6, tw * 0.3)
      K.place(s, x + 10 + size / 2, y + HEADER / 2, f, 0.2)
      K.node(cr, s, i, s.x, s.y, f, size)
      local tx = x + 20 + size
      K.bold(cr, true); K.text(cr, K.name(s), tx, y + 24, 14, C.fg, A); K.bold(cr, false)
      local busy = it.total > 0 and (minutes(it.total) .. " busy · " .. it.calls .. " calls") or "idle"
      K.text(cr, (s.state or "") .. " · " .. busy, tx, y + 42, 11, col, 0.9 * A)
      cr:restore()

      K.set(cr, col, 0.9 * A); cr:set_line_width(s.state == "permission" and 3 or 1.2)
      K.rrect(cr, x, y, tw, th, 10); cr:stroke()
    end
  end

  -- Legend, under the map.
  local lx, ly = margin, h - margin - 6
  K.text(cr, "time in tool calls, last 30 min", lx, ly + 4, 11, C.dim, 1)
  lx = lx + K.text_width(cr, "time in tool calls, last 30 min", 11) + 24
  for _, k in ipairs(KINDS) do
    if k ~= "other" then
      K.set(cr, K.kind_color(k)); K.rrect(cr, lx, ly - 6, 12, 12, 3); cr:fill()
      K.text(cr, k, lx + 18, ly + 4, 11, C.dim, 1)
      lx = lx + 36 + K.text_width(cr, k, 11)
    end
  end
end
