-- Tree: an icicle chart, read left to right. Each session, split into its own calls and its
-- subagents, each split into the targets they last touched. Heights follow the number of calls:
-- the session's own over the last WINDOW, a subagent's last few targets, a group's member count.
-- On the lock screen targets give way to their kind.

local WINDOW = 30 * 60
local SESSION_MIN, GAP, PAD = 64, 10, 3
local TOP = 50

-- Calls over the window (targets from an older hook without a timeline).
local function own_calls(s, t)
  local n = 0
  local timeline = type(s.timeline) == "table" and s.timeline or {}
  for _, e in ipairs(timeline) do
    if t - (tonumber(e.s) or 0) < WINDOW then n = n + 1 end
  end
  if #timeline == 0 then n = #(type(s.history) == "table" and s.history or {}) end
  return n
end

-- Targets of a history list grouped (by kind when private), most used first:
-- { {label, kind, n}, ... }
local function leaves(history, private)
  local by, list = {}, {}
  for _, hst in ipairs(history) do
    local label = private and (hst.kind or "other") or (hst.target or "")
    if label ~= "" then
      local l = by[label]
      if not l then
        l = { label = label, kind = hst.kind, n = 0 }
        by[label] = l; list[#list + 1] = l
      end
      l.n = l.n + 1
    end
  end
  table.sort(list, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.label < b.label
  end)
  return list
end

local function cell(K, cr, x, y, w, h, col, a)
  if h < 1 then return end
  local r = math.min(6, h / 2)
  K.set(cr, col, 0.16 * a); K.rrect(cr, x, y, w, h, r); cr:fill()
  K.set(cr, col, 0.9 * a); cr:rectangle(x, y + math.min(r, h / 4), 3, h - 2 * math.min(r, h / 4)); cr:fill()
end

-- Text inside a cell, clipped to it, when it is tall enough.
local function label(K, cr, x, y, w, h, str, size, col, a, sub, sub_col)
  if h < size + 2 then return end
  cr:save(); cr:rectangle(x, y, w - 6, h); cr:clip()
  local two = sub and h >= 2 * size + 12
  local cy = y + h / 2 + (two and -2 or size / 3)
  K.text(cr, str, x + 12, cy, size, col, a)
  if two then K.text(cr, sub, x + 12, cy + size + 3, size - 2, sub_col or col, 0.8 * a) end
  cr:restore()
end

-- Rows for the sessions, recomputed when they change: { {s, kids, v, y, rh}, ... }
local function build(K, h, f)
  local t, private = f.t, f.private
  local n = #f.list
  local top, bottom = TOP, h - 40

  -- Weights: the session's own calls plus each subagent (or group).
  local rows, total = {}, 0
  for _, s in ipairs(f.list) do
    local own = own_calls(s, t)
    local kids = { { own = true, v = math.max(1, own), calls = own,
      leaves = leaves(type(s.history) == "table" and s.history or {}, private) } }
    for _, r in ipairs(K.runner_list(s, t)) do
      local single = r.count == 1
      kids[#kids + 1] = { r = r, v = single and math.max(1, #r.history) or r.count,
        leaves = single and leaves(r.history, private) or {} }
    end
    local v = 0
    for _, k in ipairs(kids) do v = v + k.v end
    rows[#rows + 1] = { s = s, kids = kids, v = v }
    total = total + v
  end
  local avail = bottom - top - GAP * (n - 1)
  local scale = math.max(0, (avail - n * SESSION_MIN) / total)
  local y = top
  for _, row in ipairs(rows) do
    row.y, row.rh = y, math.max(SESSION_MIN, row.v * scale)
    y = y + row.rh + GAP
  end
  return rows
end

local function node_size(row) return math.min(44, row.rh - 16) end

-- Everything but the nodes: it only changes with the sessions (see K.layer).
local function still(K, cr, w, f, rows)
  local C, private = K.C, f.private
  local top = TOP
  local x1, x2, x3, x4 = 24, w * 0.25, w * 0.50, w - 24
  for _, row in ipairs(rows) do
    local s, A, col = row.s, row.s.alpha, K.node_color(row.s)
    local y, rh = row.y, row.rh

    -- Session.
    cell(K, cr, x1, y, x2 - x1 - PAD, rh, col, A)
    if s.state == "permission" then
      K.set(cr, col, A); cr:set_line_width(2)
      K.rrect(cr, x1, y, x2 - x1 - PAD, rh, math.min(6, rh / 2)); cr:stroke()
    end
    local size = node_size(row)
    cr:save(); cr:rectangle(x1, y, x2 - x1 - 10, rh); cr:clip()
    local tx = x1 + 28 + size
    K.bold(cr, true); K.text(cr, K.name(s), tx, y + rh / 2 - 3, 13, C.fg, A); K.bold(cr, false)
    K.text(cr, K.sub(s, private), tx, y + rh / 2 + 14, 10, col, 0.9 * A)
    cr:restore()

    -- Own calls and subagents, then their targets.
    local ky = y
    for _, kid in ipairs(row.kids) do
      local kh = rh * kid.v / row.v
      local kc, name, sub
      if kid.own then
        kc = C.thinking
        name, sub = "own calls", kid.calls .. " in 30 min"
      else
        local r = kid.r
        kc = K.runner_color(r)
        if r.merged then name = "+" .. r.count .. " agents"
        elseif r.count > 1 then name = r.type .. " ×" .. r.count
        elseif not private and r.label and r.label ~= "" then name = r.label
        else name = r.type end
        sub = r.state
      end
      cell(K, cr, x2, ky + PAD / 2, x3 - x2 - PAD, kh - PAD, kc, A)
      label(K, cr, x2, ky, x3 - x2 - PAD, kh, name, 11, C.fg, A, sub, kc)

      local lsum = 0
      for _, l in ipairs(kid.leaves) do lsum = lsum + l.n end
      local ly = ky
      for _, l in ipairs(kid.leaves) do
        local lh = kh * l.n / lsum
        local lc = K.kind_color(l.kind)
        cell(K, cr, x3, ly + PAD / 2, x4 - x3, lh - PAD, lc, 0.8 * A)
        label(K, cr, x3, ly, x4 - x3, lh, l.label .. (l.n > 1 and ("  ×" .. l.n) or ""), 10, C.fg, 0.85 * A)
        ly = ly + lh
      end
      ky = ky + kh
    end
  end

  K.text(cr, "session", x1, top - 16, 11, C.dim, 1)
  K.text(cr, "own calls · subagents", x2, top - 16, 11, C.dim, 1)
  K.text(cr, private and "kinds" or "recent targets", x3, top - 16, 11, C.dim, 1)
end

local cache = {}

return function(K, cr, w, h, f)
  if #f.list == 0 then return end
  if cache.gen ~= f.gen or cache.h ~= h or cache.private ~= f.private then
    cache.rows = build(K, h, f)
    cache.gen, cache.h, cache.private = f.gen, h, f.private
  end
  local rows = cache.rows
  K.layer(cr, w, h, f, "tree", function(lc) still(K, lc, w, f, rows) end)
  for i, row in ipairs(rows) do
    local size = node_size(row)
    K.place(row.s, 24 + 16 + size / 2, row.y + row.rh / 2, f, 0.2)
    K.node(cr, row.s, i, row.s.x, row.s.y, f, size)
  end
end
