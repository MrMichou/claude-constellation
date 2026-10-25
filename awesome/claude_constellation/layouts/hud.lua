-- HUD: a compact column on the right edge, most urgent session first, meant to stay visible
-- beside your windows. A pending permission gets a ring. With Promview set up, the rest of the
-- desktop becomes an alert board behind the windows: the count per severity, then one card per
-- alert name, most severe first.

-- Monospace: cut a string to what fits in maxw pixels, with an ellipsis (UTF-8 safe).
local function fit(K, cr, str, size, maxw)
  local cw = K.text_width(cr, "MMMMMMMMMM", size) / 10 -- the advance, not one glyph's ink
  local max = math.floor(maxw / math.max(cw, 1))
  local n = select(2, str:gsub("[^\128-\191]", ""))
  if n <= max then return str end
  local out, count = {}, 0
  for ch in str:gmatch("[^\128-\191][\128-\191]*") do
    if count >= max - 1 then break end
    out[#out + 1] = ch; count = count + 1
  end
  return table.concat(out) .. "…"
end

local function sessions(K, cr, w, h, f, margin)
  local C = K.C
  local n = #f.list
  local pw = 220
  local x0 = w - pw - margin
  local slot = math.min(118, (h - 2 * margin - 40) / n)
  local ph = slot * n + 40
  local y0 = math.max(margin, (h - ph) / 2)
  K.set(cr, C.fg, 0.05); K.rrect(cr, x0, y0, pw, ph, 14); cr:fill()
  local size = math.min(56, slot * 0.45)
  for i, s in ipairs(K.by_urgency(f.list)) do
    local A, col = s.alpha, K.node_color(s)
    local cx, cy = x0 + pw / 2, y0 + 20 + (i - 1) * slot + slot * 0.4
    K.place(s, cx, cy, f, 0.2)
    K.node(cr, s, i, s.x, s.y, f, size)
    if s.state == "permission" then
      K.set(cr, col, A); cr:set_line_width(2)
      cr:new_path(); cr:arc(s.x, s.y, size * 0.62, 0, 2 * math.pi); cr:stroke()
    end
    K.bold(cr, true); K.text(cr, K.name(s), cx, cy + size * 0.6 + 14, 12, C.fg, A, true); K.bold(cr, false)
    K.text(cr, s.state or "", cx, cy + size * 0.6 + 30, 10, col, A, true)
  end
  return x0
end

local SEVERITIES = { "critical", "warning", "info" }
local NEW = 10 * 60 -- an alert name that fired again within this is flagged as new

-- "35d" past two days, else K.ago's "now" / "4m" / "2h".
local function age(K, t, t0)
  if not t0 then return "" end
  if t - t0 >= 48 * 3600 then return math.floor((t - t0) / 86400) .. "d" end
  return K.ago(t, t0)
end

-- One card per alert name: severity bar, name, count, newest age, where it fires.
local function card(K, cr, g, x, y, cw, ch, f, col, blink)
  local C = K.C
  local A = (f.alerts.ok and 1 or 0.5) * (g.suppressed and 0.4 or 1)
  K.set(cr, C.fg, 0.05); K.rrect(cr, x, y, cw, ch, 10); cr:fill()
  K.set(cr, col, A * (g.severity == "critical" and blink or 1)); K.rrect(cr, x, y, 4, ch, 2); cr:fill()
  local fresh = g.newest and f.t - g.newest < NEW
  local count = "×" .. g.count
  K.bold(cr, true)
  K.text(cr, count, x + cw - 14, y + 24, 14, col, A, "right")
  local cntw = K.text_width(cr, count, 14)
  K.text(cr, fit(K, cr, g.name, 14, cw - 40 - cntw), x + 18, y + 24, 14, C.fg, A)
  K.bold(cr, false)
  local when = (g.suppressed and "silenced · " or "") .. (fresh and "new · " or "") .. age(K, f.t, g.newest)
  K.text(cr, when, x + cw - 14, y + 42, 10, fresh and col or C.dim, A, "right")
  local lines = math.floor((ch - 36) / 16)
  for i = 1, math.min(lines, #g.where) do
    local w = g.where[i]
    if i == lines and #g.where > lines then w = "+" .. (#g.where - lines + 1) .. " more" end
    local maxw = cw - 32 - (i == 1 and K.text_width(cr, when, 10) + 12 or 0)
    K.text(cr, fit(K, cr, w, 11, maxw), x + 18, y + 26 + 16 * i, 11, C.dim, A)
  end
end

local function board(K, cr, x0, y0, x1, y1, f)
  local C, P = K.C, f.alerts
  local col = { critical = C.kind.mcp, warning = C.permission, info = C.kind.search }
  local t = f.t
  local blink = f.static and 1 or 0.55 + 0.45 * math.sin(t * 3)

  -- Header: the count per severity, large, and the poll state.
  K.bold(cr, true); K.text(cr, "PROMVIEW", x0, y0 + 14, 12, C.dim, 1); K.bold(cr, false)
  local status, scol
  if P.auth then
    status = P.via == "desktop" and "sign in needed: sign in from the Promview tray"
      or "sign in needed: run constellation-promview-login"
    scol = C.permission
  elseif not P.ok then status, scol = P.error and ("unreachable · " .. P.error) or "connecting…", C.permission
  elseif P.fetched then
    status, scol = "updated " .. K.ago(t, P.fetched) .. (t - P.fetched < 60 and "" or " ago"), C.dim
  end
  if status then K.text(cr, fit(K, cr, status, 10, (x1 - x0) / 2), x1, y0 + 14, 10, scol, 1, "right") end
  local x = x0
  for _, sev in ipairs(SEVERITIES) do
    local n = (P.counts or {})[sev] or 0
    local a = (n > 0 and 1 or 0.3) * (P.ok and 1 or 0.5)
    K.bold(cr, true); K.text(cr, tostring(n), x, y0 + 62, 40, col[sev], a); K.bold(cr, false)
    K.text(cr, sev, x, y0 + 82, 11, C.dim, a)
    x = x + math.max(K.text_width(cr, tostring(n), 40), K.text_width(cr, sev, 11)) + 40
  end
  if P.ok and (P.total or 0) == 0 then
    K.text(cr, "No firing alerts", x + 20, y0 + 62, 16, C.kind.shell, 1)
  end

  -- Cards: as many columns as fit at 300px or more; they grow to fill the height (more places
  -- listed) when there are few, and stop at 104px, past which the last slot counts the rest.
  local groups = P.groups or {}
  local gap = 14
  local top = y0 + 110
  local cols = math.max(1, math.floor((x1 - x0 + gap) / (300 + gap)))
  local cw = (x1 - x0 - (cols - 1) * gap) / cols
  local need = math.max(1, math.ceil(#groups / cols))
  local ch = math.max(104, math.min(200, (y1 - top - (need - 1) * gap) / need))
  local rows = math.max(0, math.floor((y1 - top + gap) / (ch + gap)))
  local shown = math.min(#groups, cols * rows)
  if shown < #groups then shown = shown - 1 end -- the last slot says how many are left
  for i = 1, shown do
    local g = groups[i]
    local cx = x0 + ((i - 1) % cols) * (cw + gap)
    local cy = top + math.floor((i - 1) / cols) * (ch + gap)
    card(K, cr, g, cx, cy, cw, ch, f, col[g.severity], blink)
  end
  if shown < #groups and shown >= 0 then
    local i = shown + 1
    local cx = x0 + ((i - 1) % cols) * (cw + gap)
    local cy = top + math.floor((i - 1) / cols) * (ch + gap)
    K.text(cr, "+" .. (#groups - shown) .. " more alert names", cx + cw / 2, cy + ch / 2, 12, C.dim, 1, true)
  end
end

return function(K, cr, w, h, f)
  local margin = 20
  local area = f.area or { x = 0, y = 0, w = w, h = h }
  local right = area.x + area.w - margin
  if #f.list > 0 then right = sessions(K, cr, w, h, f, margin) - 28 end
  if f.alerts then
    board(K, cr, area.x + margin + 8, area.y + margin, right, area.y + area.h - margin, f)
  end
end
