-- Constellation: sessions on an ellipse, drifting slowly, the resources they touch orbiting
-- around them, their subagents running around them, and a bowed link between sessions sharing
-- a resource.

-- A bowed line between two linked sessions, a glow travelling along it, and the shared
-- resource names at its middle (just the kind when private).
local function draw_links(K, cr, f)
  for k, link in ipairs(f.links) do
    local a, b = link.a, link.b
    local A = math.min(a.alpha, b.alpha) * math.max(0.3, 1 - (f.t - link.ts) / K.LINK_WINDOW)
    local kc = K.kind_color(link.kind)
    local mx, my = (a.x + b.x) / 2, (a.y + b.y) / 2
    local dx, dy = b.x - a.x, b.y - a.y
    local len = math.max(1, math.sqrt(dx * dx + dy * dy))
    local bow = 0.12 * len
    local qx, qy = mx - dy / len * bow, my + dx / len * bow -- control point, off to one side
    local function at(u) -- point on the quadratic curve
      local v = 1 - u
      return v * v * a.x + 2 * v * u * qx + u * u * b.x, v * v * a.y + 2 * v * u * qy + u * u * b.y
    end

    cr:set_line_width(1.5)
    K.set(cr, kc, 0.45 * A)
    cr:move_to(a.x, a.y)
    cr:curve_to(a.x + (qx - a.x) * 2 / 3, a.y + (qy - a.y) * 2 / 3,
      b.x + (qx - b.x) * 2 / 3, b.y + (qy - b.y) * 2 / 3, b.x, b.y)
    cr:stroke()

    if not f.static then
      local u = (f.ta * 0.18 + k * 0.37) % 2
      local px, py = at(u <= 1 and u or 2 - u) -- back and forth: a shared channel
      K.glow(cr, px, py, 10, kc, 0.8 * A)
    end

    local lx, ly = at(0.5)
    local label = f.private and (link.kind == "file" and "file" or "tmux")
      or table.concat(link.labels, " · ")
    K.text(cr, "⇄ " .. label, lx, ly - 6, 11, kc, 0.85 * A, true)
  end
end

-- A night sky behind the sessions: faint stars twinkling, and now and then a shooting star.
-- Stars are placed once per screen size from a fixed seed; each frame they are batched into a
-- few brightness levels, so the sky costs a handful of fills.
local STARS, LEVELS = 140, 5
local SHOOT_EVERY, SHOOT_TIME = 11, 0.9 -- seconds between shooting stars, and how long one lasts
local sky = {}

local function rand(n) local v = math.sin(n * 78.233) * 43758.5453; return v - math.floor(v) end

local function draw_sky(K, cr, w, h, f)
  if sky.w ~= w or sky.h ~= h then
    sky = { w = w, h = h }
    for n = 1, STARS do
      sky[n] = { x = rand(n) * w, y = rand(n + 0.5) * h, r = 0.6 + 1.1 * rand(n + 0.25) ^ 3,
        speed = 0.4 + 1.6 * rand(n + 0.75), phase = rand(n + 0.9) * 6.28 }
    end
  end
  local by = {}
  for l = 1, LEVELS do by[l] = {} end
  for _, s in ipairs(sky) do
    local b = 0.5 + 0.5 * math.sin(f.ta * s.speed + s.phase)
    local l = math.min(LEVELS, math.floor(b * LEVELS) + 1)
    by[l][#by[l] + 1] = s
  end
  for l = 1, LEVELS do
    K.set(cr, K.C.fg, 0.08 + 0.4 * (l - 1) / (LEVELS - 1))
    for _, s in ipairs(by[l]) do
      cr:new_sub_path(); cr:arc(s.x, s.y, s.r, 0, 2 * math.pi)
    end
    cr:fill()
  end

  if f.static then return end
  local cycle = math.floor(f.ta / SHOOT_EVERY)
  local u = (f.ta - cycle * SHOOT_EVERY) / SHOOT_TIME
  if u >= 1 then return end
  -- From somewhere in the upper half, down and sideways; a fading tail behind a bright head.
  local x0, y0 = (0.15 + 0.7 * rand(cycle)) * w, (0.05 + 0.35 * rand(cycle + 0.5)) * h
  local dir = rand(cycle + 0.3) < 0.5 and -1 or 1
  local len = 0.35 * w
  local hx, hy = x0 + dir * len * u, y0 + 0.4 * len * u
  local tail = 0.18 * w * math.min(1, u * 3)
  local tx, ty = hx - dir * tail, hy - 0.4 * tail
  local a = math.sin(u * math.pi)
  local pat = K.linear(tx, ty, hx, hy, K.C.fg, 0, 0.8 * a)
  cr:set_source(pat)
  cr:set_line_width(2)
  cr:move_to(tx, ty); cr:line_to(hx, hy); cr:stroke()
  K.glow(cr, hx, hy, 8, K.C.fg, 0.9 * a)
end

return function(K, cr, w, h, f)
  local C, t, ta = K.C, f.t, f.ta
  local n = #f.list
  draw_sky(K, cr, w, h, f)
  local cx, cy = w / 2, h / 2 + 15
  local rx, ry = w * 0.32, h * 0.28
  for i, s in ipairs(f.list) do
    -- Anchor on an ellipse (a lone session sits in the middle), plus a slow drift.
    local ang = (i - 1) / math.max(n, 1) * 2 * math.pi - math.pi / 2
    local ax = n == 1 and cx or cx + rx * math.cos(ang)
    local ay = n == 1 and cy or cy + ry * math.sin(ang)
    local seed = i * 1.7
    K.place(s, ax + 18 * math.sin(ta * 0.13 + seed), ay + 12 * math.cos(ta * 0.11 + seed), f)
  end

  draw_links(K, cr, f)

  for i, s in ipairs(f.list) do
    local seed = i * 1.7
    local A = s.alpha

    -- Satellites: resources this session touched, orbiting slowly.
    local sats = s.sats
    for j, sat in ipairs(sats) do
      local age = t - (tonumber(sat.ts) or 0)
      local fade = math.max(0.12, 1 - age / K.FADE_LINK)
      local sa = (j - 1) / #sats * 2 * math.pi + ta * 0.04 + seed
      local rad = (j % 2 == 0) and 150 or 115
      local sx, sy = s.x + rad * math.cos(sa), s.y + rad * 0.8 * math.sin(sa)
      local kc = K.kind_color(sat.kind)

      cr:set_line_width(1)
      K.set(cr, kc, 0.25 * fade * A)
      cr:move_to(s.x, s.y); cr:line_to(sx, sy); cr:stroke()

      K.glow(cr, sx, sy, 9, kc, 0.8 * fade * A)
      K.set(cr, kc, fade * A); cr:arc(sx, sy, 2.2, 0, 2 * math.pi); cr:fill()
      if not f.private then -- private: dot only, no path/command label
        local label = sat.target or ""
        -- Left half: right-align the label against the dot.
        if math.cos(sa) < 0 then K.text(cr, label, sx - 8, sy + 4, 11, C.dim, 0.75 * fade * A, "right")
        else K.text(cr, label, sx + 8, sy + 4, 11, C.dim, 0.75 * fade * A) end
      end

      -- Pulse travelling along the link right after the call.
      if not f.static and age >= 0 and age < K.PARTICLE_TIME then
        local k = age / K.PARTICLE_TIME
        K.glow(cr, s.x + (sx - s.x) * k, s.y + (sy - s.y) * k, 12, kc, 0.9 * A)
      end
    end

    K.runners(cr, s, f) -- subagents, as mini Clawds circling the session
    K.node(cr, s, i, s.x, s.y, f, 64)
    K.text(cr, K.name(s), s.x, s.y - 52, 14, C.fg, 0.9 * A, true)
    K.text(cr, K.sub(s, f.private), s.x, s.y + 62, 11, K.node_color(s), 0.8 * A, true)
  end
end
