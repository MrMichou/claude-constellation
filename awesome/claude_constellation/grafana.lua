-- Grafana mini graphs for the HUD layout: the config, the `POST /api/ds/query` request and the
-- parsing of its answer into sparklines. No AwesomeWM dependency and no network here: init.lua
-- runs curl in the background and hands the body to G.parse, so a slow or unreachable server
-- never blocks a frame. Same pattern as promview.lua.

local DIR = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local json = dofile(DIR .. "json.lua")

local G = {}

G.CONFIG_FILE = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config"))
  .. "/claude-constellation/grafana.conf"

G.MAX_SERIES = 4 -- lines drawn per graph; the rest of a query's series are dropped

-- "90s", "30m", "1h", "2d", "1w" -> seconds; nil when unreadable.
function G.seconds(s)
  local n, u = tostring(s or ""):match("^%s*(%d+)%s*([smhdw]?)%s*$")
  if not n then return nil end
  local mult = { s = 1, [""] = 1, m = 60, h = 3600, d = 86400, w = 604800 }
  return tonumber(n) * mult[u]
end

-- `key = value` lines, `#` comments, and one `[title]` section per graph:
--   datasource (uid, required), expr (required), unit, warn, crit, legend ("{{instance}}").
-- GRAFANA_URL overrides the file's url. nil when there is no url or no complete graph: Grafana
-- stays off.
function G.read_config(path)
  local cfg = { interval = 60, range = "1h", points = 60, graphs = {} }
  local f = io.open(path or G.CONFIG_FILE, "r")
  local cur
  if f then
    for line in f:lines() do
      if not line:match("^%s*#") then
        local title = line:match("^%s*%[(.-)%]%s*$")
        if title then
          cur = { title = title }
          cfg.graphs[#cfg.graphs + 1] = cur
        else
          local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
          if k then
            -- A trailing comment needs a space before the `#` (an expr may hold one otherwise).
            if k ~= "expr" then v = v:gsub("%s+#.*$", "") end
            v = v:match('^"(.*)"$') or v
            if cur then
              if k == "warn" or k == "crit" then cur[k] = tonumber(v) else cur[k] = v end
            elseif k == "interval" or k == "points" then cfg[k] = tonumber(v) or cfg[k]
            else cfg[k] = v end
          end
        end
      end
    end
    f:close()
  end
  local env = os.getenv("GRAFANA_URL")
  if env and env ~= "" then cfg.url = env end
  if cfg.url == "" then cfg.url = nil end
  local graphs = {}
  for _, g in ipairs(cfg.graphs) do
    if g.datasource and g.datasource ~= "" and g.expr and g.expr ~= "" then graphs[#graphs + 1] = g end
  end
  cfg.graphs = graphs
  if not cfg.url or #graphs == 0 then return nil end
  cfg.url = cfg.url:gsub("/+$", "")
  cfg.interval = math.max(15, cfg.interval)
  cfg.points = math.max(10, math.min(500, math.floor(cfg.points)))
  cfg.range_s = G.seconds(cfg.range) or 3600
  if not G.seconds(cfg.range) then cfg.range = "1h" end
  return cfg
end

local function str(s)
  return '"' .. tostring(s):gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
    return ("\\u%04x"):format(c:byte())
  end) .. '"'
end

-- One request for every graph: refId G<i>.
function G.body(cfg)
  local step = math.max(1, math.floor(cfg.range_s / cfg.points)) * 1000
  local q = {}
  for i, g in ipairs(cfg.graphs) do
    q[i] = ('{"refId":%s,"datasource":{"uid":%s},"expr":%s,"range":true,"instant":false,'
      .. '"intervalMs":%d,"maxDataPoints":%d}'):format(str("G" .. i), str(g.datasource), str(g.expr),
      step, cfg.points)
  end
  return ('{"from":%s,"to":"now","queries":[%s]}'):format(str("now-" .. cfg.range), table.concat(q, ","))
end

-- Service account token stored by bin/constellation-grafana-token, looked up at every poll and
-- fed to curl on stdin (-H @-) so it never shows on a command line. No token: no header
-- (anonymous access).
G.SECRET_SERVICE = "claude-constellation-grafana"
local FETCH = [[
server=$1; shift
token=$(timeout 5 secret-tool lookup service "$0" server "$server" 2>/dev/null) || token=
if [ -n "$token" ]; then printf 'Authorization: Bearer %s\n' "$token" | curl -H @- "$@"; exit $?; fi
exec curl "$@"
]]

-- argv for awful.spawn: the poll, run by sh.
function G.command(cfg)
  return { "sh", "-c", FETCH, G.SECRET_SERVICE, cfg.url,
    "-sS", "-f", "--proto", "=https,http", "--max-time", "15",
    "-H", "Accept: application/json", "-H", "Content-Type: application/json",
    "--data-binary", G.body(cfg), cfg.url .. "/api/ds/query" }
end

-- A failed poll -> message, and whether a token would fix it (HTTP 401/403).
function G.failure(stderr, code)
  stderr = tostring(stderr or "")
  if stderr:match("returned error: 40[13]") then return "token needed", true end
  return stderr:match("curl: %(%d+%) ([^\n]*)") or ("curl exited " .. tostring(code)), false
end

-- A series' name: the legend template, Grafana's display name, its labels, or the field name.
local function label(field, legend)
  local labels = type(field.labels) == "table" and field.labels or {}
  if legend and legend ~= "" then
    return (legend:gsub("{{%s*([%w_]+)%s*}}", function(k) return tostring(labels[k] or "") end))
  end
  local c = type(field.config) == "table" and field.config or {}
  local name = c.displayNameFromDS or c.displayName
  if type(name) == "string" and name ~= "" then return name end
  local parts = {}
  for k, v in pairs(labels) do
    if k ~= "__name__" then parts[#parts + 1] = k .. "=" .. tostring(v) end
  end
  table.sort(parts)
  if #parts > 0 then return table.concat(parts, ",") end
  return tostring(field.name or "")
end

-- Decoded `/api/ds/query` answer -> { from, to, graphs = { {title, unit, warn, crit, error,
-- series = { {label, ts (unix seconds), vs}, ... }, last, min, max}, ... } } in the config's
-- order. A query that failed carries its own error; its graph stays empty. `now` is the poll
-- time (the window's end). nil, err when the body isn't a query answer.
function G.parse(body, cfg, now)
  local d = json.decode(body or "")
  if type(d) ~= "table" or type(d.results) ~= "table" then return nil, "unexpected response" end
  now = now or os.time()
  local out = { from = now - cfg.range_s, to = now, graphs = {} }
  for i, g in ipairs(cfg.graphs) do
    local r = d.results["G" .. i]
    local gr = { title = g.title, unit = g.unit, warn = g.warn, crit = g.crit, series = {} }
    out.graphs[i] = gr
    if type(r) ~= "table" then
      gr.error = "no result"
    elseif r.error and r.error ~= "" then
      gr.error = tostring(r.error):match("^[^\n]*")
    else
      for _, frame in ipairs(type(r.frames) == "table" and r.frames or {}) do
        local fields = type(frame.schema) == "table" and type(frame.schema.fields) == "table"
          and frame.schema.fields or {}
        local values = type(frame.data) == "table" and type(frame.data.values) == "table"
          and frame.data.values or {}
        local ti
        for j, fd in ipairs(fields) do
          if type(fd) == "table" and fd.type == "time" then ti = j; break end
        end
        local times = ti and type(values[ti]) == "table" and values[ti] or {}
        for j, fd in ipairs(fields) do
          if j ~= ti and type(fd) == "table" and fd.type == "number" and #gr.series < G.MAX_SERIES then
            local s = { label = label(fd, g.legend), ts = {}, vs = {} }
            local col = type(values[j]) == "table" and values[j] or {}
            -- json.lua leaves a hole for null: walk by index, the time column has none.
            for k = 1, #times do
              local v, x = times[k], col[k]
              if type(v) == "number" and type(x) == "number" and x == x then
                s.ts[#s.ts + 1] = v / 1000
                s.vs[#s.vs + 1] = x
              end
            end
            if #s.vs > 0 then gr.series[#gr.series + 1] = s end
          end
        end
      end
      for _, s in ipairs(gr.series) do
        for _, v in ipairs(s.vs) do
          if not gr.min or v < gr.min then gr.min = v end
          if not gr.max or v > gr.max then gr.max = v end
        end
      end
      local s1 = gr.series[1]
      if s1 then gr.last = s1.vs[#s1.vs] end
    end
    -- What the card shows, ready to draw (the layout and the lock screen don't load this module).
    gr.value = G.format(gr.last, g.unit)
    gr.level = G.level(g, gr.last)
    if gr.min then gr.lo, gr.hi = G.format(gr.min, g.unit), G.format(gr.max, g.unit) end
  end
  return out
end

-- A value for a small card: 3 significant digits, k/M/G past a thousand, then the unit.
function G.format(v, unit)
  if type(v) ~= "number" then return "–" end
  local a, s = math.abs(v), ""
  if a >= 1e9 then v, s = v / 1e9, "G" elseif a >= 1e6 then v, s = v / 1e6, "M"
  elseif a >= 1e4 then v, s = v / 1e3, "k" end
  a = math.abs(v)
  local txt
  if a < 1e-9 then txt = "0" -- float noise around zero
  elseif a >= 100 then txt = ("%.0f"):format(v)
  elseif a >= 10 then txt = ("%.1f"):format(v)
  elseif a >= 0.01 then txt = ("%.2f"):format(v)
  else txt = ("%.1e"):format(v) end
  if txt:find("%.") and not txt:find("e") then txt = txt:gsub("0+$", ""):gsub("%.$", "") end
  unit = unit or ""
  local sep = (unit ~= "" and unit ~= "%" and s == "") and " " or ""
  return txt .. s .. sep .. unit
end

-- Colour level for a value: "crit", "warn" or nil, by the graph's thresholds. A crit below
-- warn means lower is worse (free space, replicas up).
function G.level(g, v)
  if type(v) ~= "number" then return nil end
  if g.crit and g.warn and g.crit < g.warn then
    if v <= g.crit then return "crit" end
    if v <= g.warn then return "warn" end
    return nil
  end
  if g.crit and v >= g.crit then return "crit" end
  if g.warn and v >= g.warn then return "warn" end
  return nil
end

return G
