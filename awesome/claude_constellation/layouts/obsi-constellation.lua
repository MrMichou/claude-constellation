-- Obsi-constellation: the Obsidian vault's brain (its graph view: every note, every [[link]])
-- drawn faintly, with the notes the sessions read or edit lit up in it, the dots each session
-- consulted joined into a trail in the order it went through them, and the sessions around the
-- brain beaming at their latest note. The graph settles like Obsidian's own, by a small force
-- simulation run a few milliseconds per frame.

local O -- obsidian.lua, from K.obsidian

local TRAIL = 12 -- notes per session joined into its trail
local LIT_FADE = 30 * 60 -- seconds a touched note takes to dim down to LIT_MIN
local LIT_MIN = 0.3
local HUB_LABELS = 8 -- best-linked notes labelled even when nobody touched them
local NEIGHBOR_LABELS = 15 -- neighbours of touched notes labelled while there are at most this many
local LABEL_LEN = 30
local BUDGET = 0.004 -- CPU seconds of simulation per frame (more while static: it won't move)

-- Force simulation, in graph units (about a link's length).
local REPEL, CUT, SPRING, LEN, GRAV, DAMP, COOL, MIN_HEAT = 1.0, 4, 0.08, 1.6, 0.02, 0.55, 0.985, 0.02

local function shorten(str, n)
  local count, cut = 0, nil
  for pos in str:gmatch("()[^\128-\191][\128-\191]*") do
    count = count + 1
    if count == n then cut = pos end
  end
  if count <= n then return str end
  return str:sub(1, cut - 1) .. "…"
end

local atan2 = rawget(math, "atan2") or math.atan

-- Stable 0..1 from a string, for placement jitter.
local function hash(str)
  local hsh = 5381
  for k = 1, #str do hsh = (hsh * 33 + str:byte(k)) % 2147483647 end
  return (hsh % 10007) / 10007
end

local sim = {} -- { vault, version, x, y, vx, vy, adj, heat, quiet }
-- What is drawn: the graph and positions of the last settled layout (or the live simulation
-- while the vault first settles in view). A rescan that changes the graph settles out of view,
-- the old brain staying on screen from its cache: a redrawn brain costs ~30 ms a frame.
local shown = {} -- { g, x, y, adj }
local view = {} -- { s, ox, oy }: screen = graph * s + offset, eased
local vaults = { at = -math.huge }
local lit_cache = { gen = -1 }
local touched_cache = { gen = -1 }

-- Folders on a ring, each note on a spiral in its folder's disc; notes already placed by the
-- previous scan keep their place, and the graph warms up again to make room for the new ones.
local function reset_sim(g)
  local old = sim.vault == g.vault and sim.by_rel or {}
  local folders, fidx = {}, {}
  for _, n in ipairs(g.notes) do
    if not fidx[n.folder] then fidx[n.folder] = true; folders[#folders + 1] = n.folder end
  end
  table.sort(folders)
  for k, name in ipairs(folders) do fidx[name] = k end
  local ring = #folders > 1 and math.sqrt(#g.notes) * 0.9 or 0
  local count, x, y, vx, vy, adj, by_rel, kept = {}, {}, {}, {}, {}, {}, {}, 0
  for i, n in ipairs(g.notes) do
    local p = old[n.rel]
    if p then
      x[i], y[i] = p[1], p[2]; kept = kept + 1
    else
      local k = (count[n.folder] or 0) + 1
      count[n.folder] = k
      local fa = (fidx[n.folder] - 1) / #folders * 2 * math.pi
      local r, a = 0.7 * math.sqrt(k), k * 2.39996 + hash(n.rel) * 0.5
      x[i] = ring * math.cos(fa) + r * math.cos(a)
      y[i] = ring * math.sin(fa) + r * math.sin(a)
    end
    vx[i], vy[i], adj[i] = 0, 0, {}
  end
  for _, e in ipairs(g.edges) do
    table.insert(adj[e[1]], e[2]); table.insert(adj[e[2]], e[1])
  end
  sim = { vault = g.vault, version = g.version, x = x, y = y, vx = vx, vy = vy, adj = adj,
    by_rel = by_rel, heat = kept > 0 and kept == #g.notes and 0.3 or 1 }
  for i, n in ipairs(g.notes) do by_rel[n.rel] = { x[i], y[i] } end
end

-- One step: repulsion between nearby notes (a grid keeps it linear), springs along links and
-- a pull towards the centre that keeps orphans around the brain.
local function step(g)
  local x, y, vx, vy, n = sim.x, sim.y, sim.vx, sim.vy, #g.notes
  local fx, fy, grid, cell = {}, {}, {}, {}
  for i = 1, n do
    fx[i], fy[i] = -GRAV * x[i], -GRAV * y[i]
    local cx, cy = math.floor(x[i] / CUT), math.floor(y[i] / CUT)
    local key = cx * 65536 + cy
    cell[i] = { cx, cy }
    local bucket = grid[key]
    if not bucket then bucket = {}; grid[key] = bucket end
    bucket[#bucket + 1] = i
  end
  local cut2 = CUT * CUT
  for i = 1, n do
    local cx, cy, xi, yi = cell[i][1], cell[i][2], x[i], y[i]
    for dx = -1, 1 do
      for dy = -1, 1 do
        for _, j in ipairs(grid[(cx + dx) * 65536 + cy + dy] or {}) do
          if j ~= i then
            local ex, ey = xi - x[j], yi - y[j]
            local d2 = ex * ex + ey * ey
            if d2 < cut2 then
              if d2 < 1e-4 then ex, ey, d2 = (i - j) * 0.01, 0.01, 1e-4 end
              local k = REPEL / (d2 * math.sqrt(d2))
              fx[i], fy[i] = fx[i] + ex * k, fy[i] + ey * k
            end
          end
        end
      end
    end
  end
  for _, e in ipairs(g.edges) do
    local a, b = e[1], e[2]
    local ex, ey = x[b] - x[a], y[b] - y[a]
    local d = math.sqrt(ex * ex + ey * ey) + 1e-6
    local k = SPRING * (d - LEN) / d
    fx[a], fy[a], fx[b], fy[b] = fx[a] + ex * k, fy[a] + ey * k, fx[b] - ex * k, fy[b] - ey * k
  end
  local heat = sim.heat
  for i = 1, n do
    local nx, ny = (vx[i] + fx[i] * heat) * DAMP, (vy[i] + fy[i] * heat) * DAMP
    local v = math.sqrt(nx * nx + ny * ny)
    if v > 0.5 then nx, ny = nx * 0.5 / v, ny * 0.5 / v end
    vx[i], vy[i], x[i], y[i] = nx, ny, x[i] + nx, y[i] + ny
  end
  sim.heat = heat * COOL
end

local function settle(g, static)
  if sim.heat < MIN_HEAT then return true end
  local stop = os.clock() + (static and 0.25 or BUDGET)
  repeat step(g) until sim.heat < MIN_HEAT or os.clock() > stop
  for i, n in ipairs(g.notes) do sim.by_rel[n.rel] = { sim.x[i], sim.y[i] } end
  return sim.heat < MIN_HEAT
end

-- Fit the graph into box {x, y, w, h}; eased while it settles, so the brain grows into place,
-- at once when `snap` (a layout settled out of view replacing the old one).
local function fit(g, X, Y, box, f, settled, snap)
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for i = 1, #g.notes do
    x0, x1 = math.min(x0, X[i]), math.max(x1, X[i])
    y0, y1 = math.min(y0, Y[i]), math.max(y1, Y[i])
  end
  if x0 > x1 then x0, y0, x1, y1 = -1, -1, 1, 1 end
  local s = math.min(box.w / math.max(x1 - x0, 1), box.h / math.max(y1 - y0, 1), 60)
  local ox = box.x + box.w / 2 - (x0 + x1) / 2 * s
  local oy = box.y + box.h / 2 - (y0 + y1) / 2 * s
  local e = (snap or f.static or not view.s or view.vault ~= g.vault) and 1 or 0.12
  if settled and view.s and math.abs(view.s - s) < 0.01 * s then e = 1 end
  view.s = view.s and view.s + (s - view.s) * e or s
  view.ox = view.ox and view.ox + (ox - view.ox) * e or ox
  view.oy = view.oy and view.oy + (oy - view.oy) * e or oy
  view.vault = g.vault
  return e == 1
end

-- Touched notes of the vault on screen, derived once per session read:
-- { notes = { [i] = {i, read, edit, ts, users} }, trails = { [s] = {i...} }, latest = { [s] = i } }
local function lit_notes(g, adj, entries, gen)
  if lit_cache.gen == gen and lit_cache.version == g.version and lit_cache.vault == g.vault then
    return lit_cache
  end
  local notes, trails, latest, count = {}, {}, {}, 0
  for _, e in ipairs(entries or {}) do
    local note = g.by_rel[e.rel]
    if note then
      local i = note.i
      local l = notes[i]
      if not l then
        l = { i = i, ts = 0, users = {} }
        notes[i] = l; count = count + 1
      end
      l.ts = math.max(l.ts, e.ts)
      l.read = math.max(l.read or 0, e.read or 0)
      l.edit = e.edit and math.max(l.edit or 0, e.edit) or l.edit
      l.users[e.s] = true
      trails[e.s] = trails[e.s] or {}
      table.insert(trails[e.s], i) -- entries come oldest first
      latest[e.s] = i
    end
  end
  for s, tr in pairs(trails) do
    while #tr > TRAIL do table.remove(tr, 1) end
    trails[s] = tr
  end
  local near = {} -- neighbours of touched notes
  local n_near = 0
  for i in pairs(notes) do
    for _, j in ipairs(adj[i] or {}) do
      if not notes[j] and not near[j] then near[j] = true; n_near = n_near + 1 end
    end
  end
  local hubs = {}
  for k, n in ipairs(g.notes) do hubs[k] = n end
  table.sort(hubs, function(a, b)
    if a.degree ~= b.degree then return a.degree > b.degree end
    return a.rel < b.rel
  end)
  local hub = {}
  for k = 1, math.min(HUB_LABELS, #hubs) do if hubs[k].degree > 0 then hub[hubs[k].i] = true end end
  lit_cache = { gen = gen, version = g.version, vault = g.vault, notes = notes, trails = trails,
    latest = latest, count = count, near = near, n_near = n_near, hub = hub }
  return lit_cache
end

local function lit_color(K, l) return l.edit and K.C.kind.web or K.C.kind.file end

-- The still brain: links, notes and their labels. Lit links and labels are part of it, they
-- only change with the sessions.
local function draw_brain(K, cr, g, lit, f, px, py)
  local C = K.C
  for _, e in ipairs(g.edges) do
    local a, b = e[1], e[2]
    local la, lb = lit.notes[a], lit.notes[b]
    local l = la or lb
    if l then
      local both = la and lb
      K.line(lit_color(K, l), both and 0.6 or 0.35, px(a), py(a), px(b), py(b), both and 1.6 or 1.1)
    else
      K.line(C.dim, 0.13, px(a), py(a), px(b), py(b), 0.8)
    end
  end
  K.lines(cr)
  -- Dots batched per style: one fill each.
  local styles = { { C.dim, 0.5 }, { C.fg, 0.75 } }
  for k, st in ipairs(styles) do
    for i, n in ipairs(g.notes) do
      if not lit.notes[i] and (lit.near[i] and 2 or 1) == k then
        cr:new_sub_path()
        cr:arc(px(i), py(i), math.min(1.6 + math.sqrt(n.degree) * 0.9, 7), 0, 2 * math.pi)
      end
    end
    K.set(cr, st[1], st[2]); cr:fill()
  end
  if f.private then return end
  local near_labels = lit.n_near <= NEIGHBOR_LABELS
  for i, n in ipairs(g.notes) do
    if not lit.notes[i] and ((near_labels and lit.near[i]) or lit.hub[i]) then
      local r = math.min(1.6 + math.sqrt(n.degree) * 0.9, 7)
      K.text(cr, shorten(n.name, LABEL_LEN), px(i), py(i) + r + 11, 10, lit.near[i] and C.fg or C.dim,
        lit.near[i] and 0.6 or 0.45, true)
    end
  end
end

-- A gentle curve from a to b, bulging to the left of the way.
local function bend(ax, ay, bx, by)
  local mx, my = (ax + bx) / 2, (ay + by) / 2
  return mx - (by - ay) * 0.18, my + (bx - ax) * 0.18
end

local function qpoint(ax, ay, qx, qy, bx, by, u)
  local v = 1 - u
  return v * v * ax + 2 * v * u * qx + u * u * bx, v * v * ay + 2 * v * u * qy + u * u * by
end

-- Sessions around the brain, each at the angle of the notes it touched (spread apart), the
-- others filling the gaps.
local function place_sessions(K, f, list, lit, px, py, gx, gy, area)
  local n = #list
  if n == 0 then return end
  local want = {}
  for i, s in ipairs(list) do
    local tr = lit.trails[s]
    if tr and #tr > 0 then
      local sx, sy = 0, 0
      for _, k in ipairs(tr) do sx, sy = sx + px(k), sy + py(k) end
      want[i] = { s = s, a = atan2(sy / #tr - gy, sx / #tr - gx) }
    else
      want[i] = { s = s, a = (i - 1) / n * 2 * math.pi + math.pi * 0.75 }
    end
  end
  table.sort(want, function(p, q) return p.a < q.a end)
  local gap = math.min(2 * math.pi / n, 0.55)
  for _ = 1, 8 do
    for k = 1, n do
      local p, q = want[k], want[k % n + 1]
      local d = (q.a - p.a) % (2 * math.pi)
      if n > 1 and d < gap then
        local push = (gap - d) / 2
        p.a, q.a = p.a - push, q.a + push
      end
    end
  end
  local rx, ry = area.w / 2 - 90, area.h / 2 - 70
  for k, p in ipairs(want) do
    local x = math.max(area.x + 80, math.min(area.x + area.w - 80, gx + rx * math.cos(p.a)))
    local y = math.max(area.y + 90, math.min(area.y + area.h - 90, gy + ry * math.sin(p.a)))
    K.place(p.s, x + 6 * math.sin(f.ta * 0.13 + k), y + 5 * math.cos(f.ta * 0.11 + k), f, 0.08)
  end
end

return function(K, cr, w, h, f)
  local C, t = K.C, f.t
  O = O or K.obsidian
  local area = f.area or { x = 0, y = 0, w = w, h = h }

  if t - vaults.at > (O.RESCAN or 30) or vaults.pin_gen ~= O.pin_gen then
    vaults = { at = t, list = O.vaults(), pinned = O.pinned(), pin_gen = O.pin_gen }
  end
  if touched_cache.gen ~= f.gen or touched_cache.vaults ~= vaults.list then
    local by_vault, last = O.touched(f.list, vaults.list)
    touched_cache = { gen = f.gen, vaults = vaults.list, by_vault = by_vault, last = last }
  end
  local touched, last = touched_cache.by_vault, touched_cache.last
  local vault = O.pick(vaults.list, last, vaults.pinned)

  local hx, hy = area.x + 40, area.y + 46
  if not vault then
    K.bold(cr, true)
    K.text(cr, "No Obsidian vault found", area.x + area.w / 2, area.y + area.h / 2 - 10, 18, C.fg, 0.8, true)
    K.bold(cr, false)
    K.text(cr, "open one in Obsidian, or add  vault = <path>  to "
      .. "~/.config/claude-constellation/obsidian.conf",
      area.x + area.w / 2, area.y + area.h / 2 + 18, 12, C.dim, 0.8, true)
    local gx, gy = area.x + area.w / 2, area.y + area.h / 2
    place_sessions(K, f, f.list, { trails = {} }, nil, nil, gx, gy, area)
    for i, s in ipairs(f.list) do
      K.node(cr, s, i, s.x, s.y, f, 48)
      K.bold(cr, true); K.text(cr, K.name(s), s.x, s.y - 38, 13, C.fg, 0.9 * s.alpha, true); K.bold(cr, false)
      K.text(cr, K.sub(s, f.private), s.x, s.y + 46, 11, K.node_color(s), 0.8 * s.alpha, true)
    end
    return
  end

  local live = O.graph(vault, t)
  if sim.vault ~= live.vault or sim.version ~= live.version then
    local quiet = shown.g ~= nil and shown.g.vault == live.vault
    reset_sim(live)
    sim.quiet = quiet
  end
  local settled = settle(live, f.static)
  local snap = false
  if not sim.quiet or settled then
    snap = sim.quiet
    sim.quiet = false
    shown = { g = live, x = sim.x, y = sim.y, adj = sim.adj }
  end
  local g, X, Y = shown.g, shown.x, shown.y
  settled = settled or g ~= live -- the brain on screen is a settled one
  local box = { x = area.x + 190, y = area.y + 120, w = area.w - 380, h = area.h - 220 }
  local still = fit(g, X, Y, box, f, settled, snap) and settled
  local s_, ox, oy = view.s, view.ox, view.oy
  local function px(i) return X[i] * s_ + ox end
  local function py(i) return Y[i] * s_ + oy end
  local lit = lit_notes(g, shown.adj, touched[vault], f.gen)

  K.layer(cr, w, h, f, still and ("obsi|" .. g.vault .. "|" .. g.version .. "|" .. lit.count) or nil,
    function(lc)
      draw_brain(K, lc, g, lit, f, px, py)
      -- Header: the vault and what the sessions touched in it.
      K.bold(lc, true)
      K.text(lc, f.private and "obsidian" or g.name, hx, hy, 20, C.fg, 0.85)
      K.bold(lc, false)
      K.text(lc, ("%d notes · %d links · %d touched"):format(#g.notes, #g.edges, lit.count), hx, hy + 22, 12,
        C.dim, 0.8)
      K.set(lc, C.kind.file, 0.9); lc:arc(hx + 4, hy + 42, 4, 0, 2 * math.pi); lc:fill()
      K.text(lc, "read", hx + 14, hy + 46, 11, C.dim, 0.8)
      K.set(lc, C.kind.web, 0.9); lc:arc(hx + 64, hy + 42, 4, 0, 2 * math.pi); lc:fill()
      K.text(lc, "edited", hx + 74, hy + 46, 11, C.dim, 0.8)
    end)

  -- Session trails: the notes in the order the session went through them, newest brightest.
  local gx, gy = box.x + box.w / 2, box.y + box.h / 2
  place_sessions(K, f, f.list, lit, px, py, gx, gy, area)
  for _, s in ipairs(f.list) do
    local tr = lit.trails[s]
    if tr and #tr > 1 then
      for k = 2, #tr do
        local a, b = tr[k - 1], tr[k]
        local ax, ay, bx, by = px(a), py(a), px(b), py(b)
        local qx, qy = bend(ax, ay, bx, by)
        local recent = (k - 1) / (#tr - 1)
        K.set(cr, C.fg, (0.12 + 0.6 * recent) * s.alpha)
        cr:set_line_width(1 + 1.6 * recent)
        cr:move_to(ax, ay); cr:curve_to(ax + (qx - ax) * 2 / 3, ay + (qy - ay) * 2 / 3,
          bx + (qx - bx) * 2 / 3, by + (qy - by) * 2 / 3, bx, by)
        cr:stroke()
      end
      -- A comet along the last step, right after the session reached the note.
      local l = lit.notes[tr[#tr]]
      local age = t - l.ts
      if not f.static and age >= 0 and age < 2 * K.PARTICLE_TIME then
        local a, b = tr[#tr - 1], tr[#tr]
        local ax, ay, bx, by = px(a), py(a), px(b), py(b)
        local qx, qy = bend(ax, ay, bx, by)
        local cx, cy = qpoint(ax, ay, qx, qy, bx, by, age / (2 * K.PARTICLE_TIME))
        K.glow(cr, cx, cy, 14, C.fg, 0.9 * s.alpha)
      end
    end
  end

  -- Touched notes: a glow (pulsing while fresh) and their name.
  for i, l in pairs(lit.notes) do
    local age = t - l.ts
    local fade = math.max(LIT_MIN, 1 - age / LIT_FADE)
    local col = lit_color(K, l)
    local x, y = px(i), py(i)
    local fresh = not f.static and age < 4 and 0.5 + 0.5 * math.sin(f.ta * 8) or 0
    K.glow(cr, x, y, 18 + 10 * fade + 8 * fresh, col, (0.35 + 0.4 * fade) * (0.7 + 0.3 * fresh))
    K.set(cr, col, 0.6 + 0.4 * fade); cr:arc(x, y, 4 + 2 * fade, 0, 2 * math.pi); cr:fill()
    if l.edit then -- a ring marks the notes written to
      cr:set_line_width(1.5); K.set(cr, col, 0.8 * fade)
      cr:arc(x, y, 9 + 2 * fade, 0, 2 * math.pi); cr:stroke()
    end
    if not f.private then
      K.bold(cr, true)
      K.text(cr, shorten(g.notes[i].name, LABEL_LEN), x, y - 12, 12, C.fg,
        0.5 + 0.45 * fade, true)
      K.bold(cr, false)
    end
  end

  -- Sessions, beaming at the notes they touched, brightest at the latest one.
  for i, s in ipairs(f.list) do
    local tr, A = lit.trails[s], s.alpha
    for k, j in ipairs(tr or {}) do
      local l = lit.notes[j]
      local latest = k == #tr
      K.line(lit_color(K, l), (latest and 0.45 or 0.08) * A, s.x, s.y, px(j), py(j), latest and 1.5 or 1)
    end
    K.lines(cr)
    local j = lit.latest[s]
    if j and not f.static then
      local age = t - lit.notes[j].ts
      if age >= 0 and age < K.PARTICLE_TIME then
        local u = age / K.PARTICLE_TIME
        K.glow(cr, s.x + (px(j) - s.x) * u, s.y + (py(j) - s.y) * u, 12, lit_color(K, lit.notes[j]), 0.9 * A)
      end
    end
    K.node(cr, s, i, s.x, s.y, f, 48)
    K.bold(cr, true); K.text(cr, K.name(s), s.x, s.y - 38, 13, C.fg, 0.9 * A, true); K.bold(cr, false)
    K.text(cr, K.sub(s, f.private), s.x, s.y + 46, 11, K.node_color(s), 0.8 * A, true)
    if tr then
      K.text(cr, #tr .. (#tr > 1 and " notes" or " note"), s.x, s.y + 61, 10, C.dim, 0.7 * A, true)
    end
  end
end
