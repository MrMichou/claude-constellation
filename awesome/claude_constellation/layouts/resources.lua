-- Resources first: files, commands and tmux sessions are the nodes, sessions sit around them,
-- and a resource used by several sessions is drawn between them, bigger: who touches what, and
-- where they collide.

local OWN_LABELS = 4 -- labelled unshared resources per session
local LABEL_LEN = 28

-- `str` cut to n characters, with an ellipsis. UTF-8 aware without the utf8 library, which
-- Lua 5.1 / LuaJIT lack (the lock-screen saver runs under whichever Lua has lgi).
local function shorten(str, n)
  local count, cut = 0, nil
  for pos in str:gmatch("()[^\128-\191][\128-\191]*") do
    count = count + 1
    if count == n then cut = pos end
  end
  if count <= n then return str end
  return str:sub(1, cut - 1) .. "…"
end

-- Two-argument arctangent: math.atan2 up to Lua 5.2 / LuaJIT, math.atan(y, x) since 5.3.
local atan2 = rawget(math, "atan2") or math.atan

-- Resources derived from the sessions, rebuilt only when they are reloaded.
local cache = { gen = -1 }

-- { {key, kind, label, users = {s...}, ts, shared}, ... } sorted by key, for stable placement.
local function collect(K, f)
  local by, list = {}, {}
  local function add(key, kind, label, s, ts, from_sat)
    local r = by[key]
    if not r then
      r = { key = key, kind = kind, label = label, users = {}, seen = {}, ts = 0 }
      by[key] = r; list[#list + 1] = r
    end
    if not r.seen[s] then r.seen[s] = true; r.users[#r.users + 1] = s end
    r.ts = math.max(r.ts, tonumber(ts) or 0)
    r.from_sat = r.from_sat or from_sat
  end
  for _, s in ipairs(f.list) do
    -- Shared-resource keys (same file, same tmux session) recorded by the hook.
    local shared_files = {}
    for key, l in pairs(type(s.links) == "table" and s.links or {}) do
      if type(l) == "table" and f.t - (tonumber(l.ts) or 0) < K.LINK_WINDOW then
        if l.kind == "file" and l.label then shared_files[l.label] = key end
        add(key, l.kind, l.label or key, s, l.ts)
      end
    end
    -- Recent targets; a file target joins its shared-file node when there is one.
    for _, sat in ipairs(s.sats) do
      local target = sat.target or ""
      local base = sat.kind == "file" and target:match("([^/]+)$")
      local key = base and shared_files[base]
      if key then add(key, sat.kind, by[key].label, s, sat.ts, true)
      else
        -- Only a file is the same resource for two sessions; the same command text is not.
        local scope = sat.kind == "file" and "" or s.id .. "|"
        add(scope .. (sat.kind or "") .. "|" .. target, sat.kind, target, s, sat.ts, true)
      end
    end
  end
  local out = {}
  for _, r in ipairs(list) do
    r.shared = #r.users > 1
    if r.shared or r.from_sat then out[#out + 1] = r end -- drop links nobody else shares
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

-- Session anchors on an outer ellipse; shared resources between their users, pulled towards the
-- centre; a session's own resources fanned out from it towards the centre.
local function layout(K, f, w, h)
  local cx, cy = w / 2, h / 2 + 10
  local rx, ry = w * 0.40, h * 0.36
  local n = #f.list
  local anchor = {}
  for i, s in ipairs(f.list) do
    local ang = (i - 1) / math.max(n, 1) * 2 * math.pi - math.pi / 2
    anchor[s] = n == 1 and { cx - rx * 0.5, cy } or { cx + rx * math.cos(ang), cy + ry * math.sin(ang) }
  end
  local res = collect(K, f)
  local own = {} -- per session, its unshared resources
  for _, r in ipairs(res) do
    if r.shared then
      local x, y = 0, 0
      for _, u in ipairs(r.users) do x = x + anchor[u][1]; y = y + anchor[u][2] end
      x, y = x / #r.users, y / #r.users
      r.x, r.y = x + (cx - x) * 0.45, y + (cy - y) * 0.45
    else
      local s = r.users[1]
      own[s] = own[s] or {}
      table.insert(own[s], r)
    end
  end
  for s, rs in pairs(own) do
    local a = anchor[s]
    local dir = n == 1 and 0 or atan2(cy - a[2], cx - a[1])
    local m = #rs
    local spread = math.min(0.45, 2.6 / m)
    -- Labels only on the most recent few, so a busy session stays readable.
    local recent = {}
    for j, r in ipairs(rs) do recent[j] = r end
    table.sort(recent, function(p, q) return p.ts > q.ts end)
    for j, r in ipairs(recent) do r.labelled = j <= OWN_LABELS end
    for j, r in ipairs(rs) do
      local ang = dir + (j - (m + 1) / 2) * spread
      local d = 130 + (j % 2) * 55
      r.x, r.y = a[1] + d * math.cos(ang), a[2] + d * 0.85 * math.sin(ang)
    end
  end
  return anchor, res
end

return function(K, cr, w, h, f)
  local C, t, ta = K.C, f.t, f.ta
  if #f.list == 0 then return end
  if cache.gen ~= f.gen or cache.w ~= w or cache.h ~= h then
    cache.anchor, cache.res = layout(K, f, w, h)
    cache.gen, cache.w, cache.h = f.gen, w, h
  end
  local anchor, res = cache.anchor, cache.res

  for i, s in ipairs(f.list) do
    local a = anchor[s]
    if a then K.place(s, a[1] + 10 * math.sin(ta * 0.13 + i), a[2] + 8 * math.cos(ta * 0.11 + i), f, 0.08) end
  end

  -- Edges, then resource nodes, then sessions on top.
  for _, r in ipairs(res) do
    local age = t - r.ts
    r.fade = math.max(0.15, 1 - age / K.FADE_LINK)
    if r.shared then r.fade = math.max(0.5, r.fade) end
    local kc = K.kind_color(r.kind)
    for _, s in ipairs(r.users) do
      K.set(cr, kc, (r.shared and 0.55 or 0.22) * r.fade * s.alpha)
      cr:set_line_width(r.shared and 2.5 or 1)
      cr:move_to(s.x, s.y); cr:line_to(r.x, r.y); cr:stroke()
      if not f.static and age >= 0 and age < K.PARTICLE_TIME then -- pulse on a fresh call
        local k = age / K.PARTICLE_TIME
        K.glow(cr, s.x + (r.x - s.x) * k, s.y + (r.y - s.y) * k, 12, kc, 0.9 * s.alpha)
      end
    end
  end
  for _, r in ipairs(res) do
    local kc = K.kind_color(r.kind)
    local size = r.shared and 1 or 0.35
    K.glow(cr, r.x, r.y, 16 + 34 * size, kc, 0.6 * r.fade)
    K.set(cr, kc, r.fade); cr:arc(r.x, r.y, 3 + 6 * size, 0, 2 * math.pi); cr:fill()
    if r.shared then
      K.bold(cr, true)
      local label = f.private and (r.kind == "file" and "file" or "tmux") or shorten(r.label, LABEL_LEN)
      K.text(cr, label, r.x, r.y - 22, 14, C.fg, 0.9 * r.fade, true)
      K.bold(cr, false)
      K.text(cr, "⇄ " .. #r.users .. " sessions", r.x, r.y + 28, 11, kc, r.fade, true)
    elseif r.labelled and not f.private then
      K.text(cr, shorten(r.label, LABEL_LEN), r.x, r.y - 12, 11, C.dim, 0.8 * r.fade, true)
    end
  end
  for i, s in ipairs(f.list) do
    local A = s.alpha
    K.node(cr, s, i, s.x, s.y, f, 52)
    K.bold(cr, true); K.text(cr, K.name(s), s.x, s.y - 40, 13, C.fg, 0.9 * A, true); K.bold(cr, false)
    K.text(cr, K.sub(s, f.private), s.x, s.y + 48, 11, K.node_color(s), 0.8 * A, true)
  end
end
