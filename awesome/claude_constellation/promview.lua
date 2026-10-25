-- Promview (github.com/cropalato/promview) alerts for the HUD layout: the config, the URL to
-- poll and the parsing of a `GET /api/v1/alerts` snapshot. No AwesomeWM dependency and no
-- network here: init.lua runs curl in the background and hands the body to P.parse, so a slow
-- or unreachable server never blocks a frame.

local lgi = require("lgi")
local GLib = lgi.GLib

local DIR = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local json = dofile(DIR .. "json.lua")

local P = {}

P.CONFIG_FILE = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config"))
  .. "/claude-constellation/promview.conf"

P.SEVERITIES = { "critical", "warning", "info" }
local RANK = { critical = 1, warning = 2, info = 3 }

-- `key = value` lines, `#` comments; `match` may repeat (ANDed label matchers, `team=platform`,
-- `severity!=info`). PROMVIEW_URL overrides the file's url. `desktop` is auto (the default: ask a
-- running promview-desktop, else poll the url), on (ask the desktop, no url needed) or off (never
-- ask it). nil when there is neither a url nor `desktop = on`: Promview stays off.
function P.read_config(path)
  local cfg = { interval = 30, limit = 200, match = {}, desktop = "auto" }
  local f = io.open(path or P.CONFIG_FILE, "r")
  if f then
    for line in f:lines() do
      local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if k and not line:match("^%s*#") then
        v = v:match('^"(.*)"$') or v
        if k == "match" then cfg.match[#cfg.match + 1] = v
        elseif k == "interval" or k == "limit" then cfg[k] = tonumber(v) or cfg[k]
        else cfg[k] = v end
      end
    end
    f:close()
  end
  local env = os.getenv("PROMVIEW_URL")
  if env and env ~= "" then cfg.url = env end
  if cfg.url == "" then cfg.url = nil end
  if cfg.desktop ~= "on" and cfg.desktop ~= "off" then cfg.desktop = "auto" end
  if not cfg.url and cfg.desktop ~= "on" then return nil end
  if cfg.url then cfg.url = cfg.url:gsub("/+$", "") end
  cfg.interval = math.max(5, cfg.interval)
  cfg.limit = math.max(1, math.min(500, math.floor(cfg.limit)))
  return cfg
end

local function escape(s)
  return (s:gsub("[^%w%-%._~]", function(c) return ("%%%02X"):format(c:byte()) end))
end

-- Firing alerts, closed ones excluded (the server's default).
function P.url(cfg)
  local q = { "status=firing", "limit=" .. cfg.limit }
  for _, m in ipairs(cfg.match) do q[#q + 1] = "match=" .. escape(m) end
  return cfg.url .. "/api/v1/alerts?" .. table.concat(q, "&")
end

-- Session token stored by bin/constellation-promview-login (OIDC servers). Looked up at every
-- poll, so a new sign-in is picked up without a restart; fed to curl on stdin (-H @-) so it
-- never shows on a command line. No token (open mode, or no secret-tool): no header.
P.SECRET_SERVICE = "claude-constellation-promview"
local FETCH = [[
server=$1; shift
token=$(timeout 5 secret-tool lookup service "$0" server "$server" 2>/dev/null) || token=
if [ -n "$token" ]; then printf 'Authorization: Bearer %s\n' "$token" | curl -H @- "$@"; exit $?; fi
exec curl "$@"
]]

-- argv for awful.spawn: the poll, run by sh.
function P.command(cfg)
  return { "sh", "-c", FETCH, P.SECRET_SERVICE, cfg.url,
    "-sS", "-f", "--proto", "=https,http", "--max-time", "10", "-H", "Accept: application/json", P.url(cfg) }
end

-- A failed poll -> message, and whether signing in again would fix it (HTTP 401).
function P.failure(stderr, code)
  stderr = tostring(stderr or "")
  if stderr:match("returned error: 401") then return "sign in needed", true end
  return stderr:match("curl: %(%d+%) ([^\n]*)") or ("curl exited " .. tostring(code)), false
end

local function unix(iso)
  local ok, d = pcall(GLib.DateTime.new_from_iso8601, tostring(iso or ""), nil)
  return ok and d and d:to_unix() or nil
end

local function present(v)
  v = type(v) == "string" and v:match("^%s*(.-)%s*$") or ""
  return v ~= "" and v or nil
end

-- Alerts (sorted as P.parse leaves them) -> one group per alert name: { name, severity (the
-- worst), count, newest (latest start), suppressed (every member silenced), where = { instance
-- or summary, ... } (distinct, newest first) }, most severe first, then the biggest.
function P.group(alerts)
  local by, list = {}, {}
  for _, a in ipairs(alerts) do
    local g = by[a.name]
    if not g then
      g = { name = a.name, severity = a.severity, count = 0, newest = a.starts, suppressed = true,
        where = {}, seen = {} }
      by[a.name] = g
      list[#list + 1] = g
    end
    g.count = g.count + 1
    if RANK[a.severity] < RANK[g.severity] then g.severity = a.severity end
    if a.starts and (not g.newest or a.starts > g.newest) then g.newest = a.starts end
    if not a.suppressed then g.suppressed = false end
    local w = a.instance or a.summary
    if w and not g.seen[w] then g.seen[w] = true; g.where[#g.where + 1] = w end
  end
  for _, g in ipairs(list) do g.seen = nil end
  table.sort(list, function(a, b)
    if RANK[a.severity] ~= RANK[b.severity] then return RANK[a.severity] < RANK[b.severity] end
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)
  return list
end

-- Decoded snapshot -> { alerts = { {name, severity, instance, summary, starts, suppressed}, ... },
-- counts = {critical, warning, info}, total }, most severe first, then newest first.
-- Severities outside the three buckets count as info, like the Promview console.
-- nil, err when the body isn't an alerts snapshot.
function P.parse(body)
  local d = json.decode(body or "")
  if type(d) ~= "table" or type(d.alerts) ~= "table" then return nil, "unexpected response" end
  local out = { alerts = {}, counts = { critical = 0, warning = 0, info = 0 } }
  for _, a in ipairs(d.alerts) do
    if type(a) == "table" then
      local labels = type(a.labels) == "table" and a.labels or {}
      local ann = type(a.annotations) == "table" and a.annotations or {}
      local sev = tostring(a.severity or labels.severity or ""):lower()
      if not RANK[sev] then sev = "info" end
      out.alerts[#out.alerts + 1] = {
        name = present(labels.alertname) or "(unnamed alert)",
        severity = sev,
        instance = present(labels.instance),
        summary = present(ann.summary) or present(ann.description),
        starts = unix(a.startsAt),
        suppressed = a.suppressed == true,
      }
    end
  end
  table.sort(out.alerts, function(a, b)
    if RANK[a.severity] ~= RANK[b.severity] then return RANK[a.severity] < RANK[b.severity] end
    if (a.starts or 0) ~= (b.starts or 0) then return (a.starts or 0) > (b.starts or 0) end
    return a.name < b.name
  end)
  -- The server's histogram covers every matching alert, not just this page.
  local sc = type(d.severityCounts) == "table" and d.severityCounts or nil
  for sev, n in pairs(sc or {}) do
    sev = tostring(sev):lower()
    if not RANK[sev] then sev = "info" end
    out.counts[sev] = out.counts[sev] + (tonumber(n) or 0)
  end
  if not sc then
    for _, a in ipairs(out.alerts) do out.counts[a.severity] = out.counts[a.severity] + 1 end
  end
  out.total = tonumber(d.total) or #out.alerts
  out.groups = P.group(out.alerts)
  return out
end

return P
