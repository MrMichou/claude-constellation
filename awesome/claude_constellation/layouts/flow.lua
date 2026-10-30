-- Flow: a Sankey diagram of the last WINDOW. Sessions on the left feed the kinds of tool they
-- called (band width = number of calls), and each kind feeds the resources it touched, split
-- like the sessions' recent targets. The lock screen stops at the kinds.

local WINDOW = 30 * 60
local KINDS = { "file", "shell", "search", "web", "agent", "mcp", "other" }
local KNOWN = {}
for _, k in ipairs(KINDS) do KNOWN[k] = true end
local MAX_RESOURCES = 14
local GAP, BAR = 10, 10

local function kind_of(k) return KNOWN[k] and k or "other" end

-- Calls per kind over the window; sessions from an older hook (no timeline) count their targets.
local function calls(s, t)
  local by, total = {}, 0
  local timeline = type(s.timeline) == "table" and s.timeline or {}
  for _, e in ipairs(timeline) do
    if t - (tonumber(e.s) or 0) < WINDOW then
      local k = kind_of(e.k)
      by[k] = (by[k] or 0) + 1; total = total + 1
    end
  end
  if #timeline == 0 then
    for _, h in ipairs(type(s.history) == "table" and s.history or {}) do
      if t - (tonumber(h.ts) or 0) < WINDOW then
        local k = kind_of(h.kind)
        by[k] = (by[k] or 0) + 1; total = total + 1
      end
    end
  end
  return by, total
end

-- Stack nodes ({v, min}) in a column centred on [top, bottom]: sets .y (slot top), .slot, .bar
-- (bar height) and .by (bar top).
local function stack(nodes, scale, top, bottom)
  local used = 0
  for _, nd in ipairs(nodes) do
    nd.bar = nd.v * scale
    nd.slot = math.max(nd.bar, nd.min)
    used = used + nd.slot
  end
  used = used + GAP * math.max(0, #nodes - 1)
  local y = top + math.max(0, (bottom - top - used) / 2)
  for _, nd in ipairs(nodes) do
    nd.y, nd.by = y, y + (nd.slot - nd.bar) / 2
    nd.cursor_in, nd.cursor_out = nd.by, nd.by
    y = y + nd.slot + GAP
  end
end

-- Pixels per call that let every column fit.
local function fit(nodes, top, bottom)
  local total, mins = 0, 0
  for _, nd in ipairs(nodes) do total, mins = total + nd.v, mins + nd.min end
  if total <= 0 then return math.huge end
  return math.max(0, (bottom - top - mins - GAP * math.max(0, #nodes - 1)) / total)
end

local function band(cr, x1, y1, x2, y2, hgt)
  local mx = (x1 + x2) / 2
  cr:move_to(x1, y1)
  cr:curve_to(mx, y1, mx, y2, x2, y2)
  cr:line_to(x2, y2 + hgt)
  cr:curve_to(mx, y2 + hgt, mx, y1 + hgt, x1, y1 + hgt)
  cr:close_path()
end

local function bezier(u, x1, y1, x2, y2)
  local mx, v = (x1 + x2) / 2, 1 - u
  return v ^ 3 * x1 + 3 * v * v * u * mx + 3 * v * u * u * mx + u ^ 3 * x2,
    v ^ 3 * y1 + 3 * v * v * u * y1 + 3 * v * u * u * y2 + u ^ 3 * y2
end

-- Columns, bands and pulses for the sessions, recomputed when they change: { xs, xk, xr, top,
-- snodes, knodes, rnodes, bands = { {k, s, x1, y1, x2, y2, hgt}, ... }, sparks }.
local function build(w, h, f)
  local t, private = f.t, f.private
  local top, bottom = 60, h - 50
  local xs = math.max(250, w * 0.17)
  local xk = private and w * 0.62 or w * 0.50
  local xr = w * 0.72

  -- Sessions, and their calls per kind.
  local snodes, kinds_v = {}, {}
  for _, s in ipairs(f.list) do
    local by, total = calls(s, t)
    snodes[#snodes + 1] = { s = s, kinds = by, v = total, min = 52 }
    for k, v in pairs(by) do kinds_v[k] = (kinds_v[k] or 0) + v end
  end
  local knodes, kidx = {}, {}
  for _, k in ipairs(KINDS) do
    if kinds_v[k] then
      knodes[#knodes + 1] = { k = k, v = kinds_v[k], min = 26 }
      kidx[k] = knodes[#knodes]
    end
  end

  -- Resources: each kind's calls split like the recent targets of that kind.
  local rnodes, flows_r = {}, {}
  if not private then
    local share, per_kind = {}, {}
    for _, s in ipairs(f.list) do
      for _, hst in ipairs(type(s.history) == "table" and s.history or {}) do
        local k, target = kind_of(hst.kind), hst.target or ""
        if kidx[k] and target ~= "" then
          share[k] = share[k] or {}
          share[k][target] = (share[k][target] or 0) + 1
          per_kind[k] = (per_kind[k] or 0) + 1
        end
      end
    end
    local res = {}
    for _, kn in ipairs(knodes) do
      for target, c in pairs(share[kn.k] or {}) do
        res[#res + 1] = { k = kn.k, label = target, v = kn.v * c / per_kind[kn.k], min = 18 }
      end
    end
    table.sort(res, function(a, b)
      if a.v ~= b.v then return a.v > b.v end
      return a.label < b.label
    end)
    local rest
    for i, r in ipairs(res) do
      local to = r
      if i < MAX_RESOURCES or #res == MAX_RESOURCES then rnodes[#rnodes + 1] = r
      else -- the smallest share one node
        rest = rest or { label = "", v = 0, min = 18, n = 0 }
        rest.v, rest.n, to = rest.v + r.v, rest.n + 1, rest
      end
      flows_r[#flows_r + 1] = { from = kidx[r.k], to = to, v = r.v, k = r.k }
    end
    -- Same kind order as the middle column, so bands cross less.
    local order = {}
    for i, kn in ipairs(knodes) do order[kn.k] = i end
    table.sort(rnodes, function(a, b)
      if a.k ~= b.k then return order[a.k] < order[b.k] end
      if a.v ~= b.v then return a.v > b.v end
      return a.label < b.label
    end)
    if rest then rest.label = "+" .. rest.n .. " more"; rnodes[#rnodes + 1] = rest end
  end

  local scale = math.min(fit(snodes, top, bottom), fit(knodes, top, bottom), fit(rnodes, top, bottom))
  if scale == math.huge then scale = 0 end
  stack(snodes, scale, top, bottom)
  stack(knodes, scale, top, bottom)
  stack(rnodes, scale, top, bottom)

  -- Bands: session -> kind, then kind -> resource; a pulse on the band of each running call.
  local bands, sparks = {}, {}
  for _, sn in ipairs(snodes) do
    for _, k in ipairs(KINDS) do
      local v = sn.kinds[k]
      if v then
        local kn, hgt = kidx[k], v * scale
        bands[#bands + 1] = { k = k, s = sn.s, x1 = xs + BAR, y1 = sn.cursor_out, x2 = xk, y2 = kn.cursor_in,
          hgt = hgt }
        if sn.s.state == "tool" and kind_of(sn.s.kind) == k then
          sparks[#sparks + 1] = { sn.s, xs + BAR, sn.cursor_out + hgt / 2, xk, kn.cursor_in + hgt / 2, k }
        end
        sn.cursor_out, kn.cursor_in = sn.cursor_out + hgt, kn.cursor_in + hgt
      end
    end
  end
  for _, fl in ipairs(flows_r) do
    local hgt = fl.v * scale
    bands[#bands + 1] = { k = fl.k, x1 = xk + BAR, y1 = fl.from.cursor_out, x2 = xr, y2 = fl.to.cursor_in,
      hgt = hgt }
    fl.from.cursor_out, fl.to.cursor_in = fl.from.cursor_out + hgt, fl.to.cursor_in + hgt
  end
  return { xs = xs, xk = xk, xr = xr, top = top, snodes = snodes, knodes = knodes, rnodes = rnodes,
    bands = bands, sparks = sparks }
end

-- Everything but the pulses and the nodes: it only changes with the sessions (see K.layer).
local function still(K, cr, w, h, m)
  local C, xs, xk, xr = K.C, m.xs, m.xk, m.xr
  for _, b in ipairs(m.bands) do
    K.set(cr, K.kind_color(b.k), b.s and 0.3 * b.s.alpha or 0.22)
    band(cr, b.x1, b.y1, b.x2, b.y2, b.hgt); cr:fill()
  end
  -- Sessions (their nodes are drawn on top, every frame).
  for _, sn in ipairs(m.snodes) do
    local s, A, col = sn.s, sn.s.alpha, K.node_color(sn.s)
    local cy = sn.y + sn.slot / 2
    K.set(cr, col, 0.9 * A); cr:rectangle(xs, sn.by, BAR, math.max(2, sn.bar)); cr:fill()
    cr:save(); cr:rectangle(0, sn.y - 20, xs - 14, sn.slot + 40); cr:clip()
    K.bold(cr, true); K.text(cr, K.name(s), 86, cy - 3, 13, C.fg, A); K.bold(cr, false)
    local count = sn.v == 0 and "" or (" · " .. sn.v .. (sn.v == 1 and " call" or " calls"))
    K.text(cr, (s.state or "") .. count, 86, cy + 14, 10, col, 0.9 * A)
    cr:restore()
  end
  -- Kinds.
  for _, kn in ipairs(m.knodes) do
    local col = K.kind_color(kn.k)
    K.set(cr, col); cr:rectangle(xk, kn.by, BAR, math.max(2, kn.bar)); cr:fill()
    K.bold(cr, true); K.text(cr, kn.k, xk + BAR + 8, kn.y + kn.slot / 2 + 1, 12, col, 1); K.bold(cr, false)
    K.text(cr, tostring(kn.v), xk + BAR + 8, kn.y + kn.slot / 2 + 15, 10, C.dim, 1)
  end
  -- Resources.
  cr:save(); cr:rectangle(xr, 0, w - xr - 20, h); cr:clip()
  for _, rn in ipairs(m.rnodes) do
    local col = rn.k and K.kind_color(rn.k) or C.dim
    K.set(cr, col, 0.9); cr:rectangle(xr, rn.by, BAR, math.max(2, rn.bar)); cr:fill()
    K.text(cr, rn.label, xr + BAR + 8, rn.y + rn.slot / 2 + 4, 11, rn.k and C.fg or C.dim, 0.85)
  end
  cr:restore()

  K.text(cr, "tool calls, last 30 min", xs, m.top - 24, 11, C.dim, 1)
  if #m.knodes == 0 then
    K.text(cr, "no tool calls in the last 30 min", (xs + w) / 2, h / 2, 13, C.dim, 1, true)
  end
end

local cache = {}

return function(K, cr, w, h, f)
  if #f.list == 0 then return end
  if cache.gen ~= f.gen or cache.w ~= w or cache.h ~= h or cache.private ~= f.private then
    cache.m = build(w, h, f)
    cache.gen, cache.w, cache.h, cache.private = f.gen, w, h, f.private
  end
  local m = cache.m
  K.layer(cr, w, h, f, "flow", function(lc) still(K, lc, w, h, m) end)
  if not f.static then
    for i, sp in ipairs(m.sparks) do
      local x, y = bezier((f.ta * 0.5 + i * 0.37) % 1, sp[2], sp[3], sp[4], sp[5])
      K.glow(cr, x, y, 12, K.kind_color(sp[6]), 0.8 * sp[1].alpha)
    end
  end
  for i, sn in ipairs(m.snodes) do
    K.place(sn.s, 50, sn.y + sn.slot / 2, f, 0.2)
    K.node(cr, sn.s, i, sn.s.x, sn.s.y, f, 40)
  end
end
