#!/usr/bin/env lua5.4
-- Renders the README demos offline with the real renderer (render.lua) on a scripted set of
-- fake sessions and a simulated clock, so the output is reproducible and leaks nothing.
-- Usage: demo/record.sh (wraps this script and encodes the GIFs with ffmpeg).
--   lua5.4 demo/record.lua <out_dir> <wallpaper|lock|layouts|promview> <width> <height> <fps> <seconds>
--     [scenario]
-- "layouts" cycles through every layout (R.LAYOUTS), an equal share of the time each.
-- "promview" is the hud layout with a board of made-up Promview alerts, under a 36px bar.
-- Scenarios: "sessions" (default, four everyday sessions) and "workflow" (a big multi-agent
-- workflow fanning out to ~30 subagents, to show runners being grouped and ungrouped).

local OUT, MODE = arg[1], arg[2] or "wallpaper"
local W, H = tonumber(arg[3]) or 1280, tonumber(arg[4]) or 720
local FPS, SECONDS = tonumber(arg[5]) or 30, tonumber(arg[6]) or 12
local SCENARIO = arg[7] or "sessions"

local lgi = require("lgi")
local cairo, GLib = lgi.cairo, lgi.GLib

-- Simulated clock: render.lua reads the time through GLib.get_real_time.
local T0, clock = 1.8e9, 0
GLib.get_real_time = function() return (T0 + clock) * 1e6 end

-- record.sh points HOME at a scratch dir, so session files never touch ~/.claude.
local DIR = arg[0]:match("^(.*/)") or "./"
local R = dofile(DIR .. "../awesome/claude_constellation/render.lua")
local DATA = os.getenv("HOME") .. "/.claude/constellation/"
os.execute("mkdir -p '" .. DATA .. "'")

-- Session files hold nested history arrays, which json.lua's flat encoder doesn't cover.
local function encode(v)
  local t = type(v)
  if t == "string" then return string.format("%q", v) end
  if t == "number" then return string.format("%.3f", v) end
  if t == "boolean" then return tostring(v) end
  if v[1] ~= nil then
    local parts = {}
    for _, x in ipairs(v) do parts[#parts + 1] = encode(x) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local parts = {}
  for k, x in pairs(v) do parts[#parts + 1] = string.format("%q", k) .. ":" .. encode(x) end
  return "{" .. table.concat(parts, ",") .. "}"
end
local function save(s)
  local f = assert(io.open(DATA .. s.sid .. ".json", "w"))
  f:write(encode(s)); f:close()
end

-- Session state, mirroring what hooks/track.js writes.
local S = {}
local function session(sid, project, state, history, ago)
  local h = {}
  for _, e in ipairs(history) do
    h[#h + 1] = { kind = e[1], target = e[2], ts = T0 + e[3] }
  end
  S[sid] = { sid = sid, project = project, state = state, tool = "", kind = "", target = "",
    history = h, timeline = {}, links = {}, agents = {}, ts = T0 - (ago or 0),
    since = T0 - (ago or 0) - 60 }
end

-- Tool calls over the last 20 minutes for the swimlanes, from a seeded generator so every
-- run draws the same lanes: { k = kind, s = start, e = end }, like the hook writes them.
local seed = 7
local function rnd() seed = (seed * 16807) % 2147483647; return seed / 2147483647 end
local KINDS = { "file", "file", "file", "shell", "shell", "search", "web", "agent", "mcp" }
local function past_calls(sid, busy, quiet_since)
  local t = T0 - 1200
  while t < T0 - (quiet_since or 0) - 5 do
    if rnd() < busy then
      local e = t + 3 + rnd() * 25
      table.insert(S[sid].timeline, { k = KINDS[math.floor(rnd() * #KINDS) + 1], s = t, e = e })
    end
    t = t + 10 + rnd() * 35
  end
end

local function emit(sid, event, tool, kind, target)
  local s, ts = S[sid], T0 + clock
  s.ts = ts
  local open = s.timeline[#s.timeline]
  if open and not open.e and event ~= "permission" then open.e = ts end
  if event == "pre" then
    s.state, s.tool, s.kind, s.target = "tool", tool, kind, target
    table.insert(s.history, { tool = tool, kind = kind, target = target, ts = ts })
    while #s.history > 10 do table.remove(s.history, 1) end
    table.insert(s.timeline, { k = kind, s = ts })
  elseif event == "post" or event == "prompt" then s.state = "thinking"
  elseif event == "permission" then s.state = "permission"
  elseif event == "stop" then s.state, s.since = "done", ts
  end
  save(s)
end

-- Subagent events, as track.js records them under s.agents[id].
local function agent(sid, id, event, a1, a2, a3)
  local s, ts = S[sid], T0 + clock
  s.ts = ts
  local a = s.agents[id]
  if event == "start" then
    a = { type = a1, label = a2 or "", state = "thinking", tool = "", kind = "", target = "",
      history = {}, started = ts, ts = ts }
    s.agents[id] = a
  elseif not a then return
  elseif event == "pre" then
    a.state, a.tool, a.kind, a.target = "tool", a1, a2, a3
    table.insert(a.history, { kind = a2, target = a3, ts = ts })
    while #a.history > 4 do table.remove(a.history, 1) end
  elseif event == "post" then a.state = "thinking"
  elseif event == "permission" then a.state = "permission"
  elseif event == "stop" then a.state = "done"
  end
  a.ts = ts
  save(s)
end

local timeline
if SCENARIO == "sessions" then
session("a", "claude-constellation", "thinking", {
  { "file", "…/claude_constellation/init.lua", -140 },
  { "search", "FPS_IDLE", -95 },
  { "shell", "git log --oneline -5", -60 },
})
session("b", "api-server", "tool", {
  { "file", "…/src/routes.ts", -200 },
  { "shell", "npm test", -150 },
  { "web", "developer.mozilla.org", -110 },
  { "mcp", "postgres:query", -40 },
})
session("c", "infra", "thinking", {
  { "agent", "Explore", -170 },
  { "file", "…/modules/vpc.tf", -120 },
  { "web", "terraform aws provider s3", -80 },
})
session("d", "dotfiles", "done", {
  { "file", "…/nvim/init.lua", -1300 },
  { "shell", "stow nvim", -1250 },
}, 15 * 60)
if MODE == "layouts" then
  past_calls("a", 0.8); past_calls("b", 0.85); past_calls("c", 0.6); past_calls("d", 0.4, 15 * 60)
  -- api-server and infra both edit the CI pipeline: a shared resource.
  local shared = { kind = "file", label = "deploy.yml", ts = T0 - 90 }
  S.b.links["file:/work/ci/deploy.yml"] = shared
  S.c.links["file:/work/ci/deploy.yml"] = shared
  table.insert(S.b.history, { kind = "file", target = "…/ci/deploy.yml", ts = T0 - 90 })
  table.insert(S.c.history, { kind = "file", target = "…/ci/deploy.yml", ts = T0 - 80 })
end
for _, s in pairs(S) do save(s) end

-- Made-up Promview snapshot (alert name, severity, instances, minutes since the newest started,
-- summary when there is no instance), parsed by the real promview.lua.
if MODE == "promview" then
  local P = dofile(DIR .. "../awesome/claude_constellation/promview.lua")
  local ALERTS = {
    { "PostgresPrimaryDown", "critical", { "pg-main-01:9187" }, 3 },
    { "KubeNodeNotReady", "critical", { "node-07", "node-12" }, 26 },
    { "DiskWillFillIn4Hours", "warning", { "logs-01:9100", "logs-02:9100", "logs-03:9100",
      "metrics-01:9100" }, 7 },
    { "HostHighCpuLoad", "warning", { "ci-runner-03:9100", "ci-runner-04:9100", "ci-runner-07:9100",
      "ci-runner-09:9100", "ci-runner-11:9100", "ci-runner-12:9100", "ci-runner-15:9100" }, 48 },
    { "KubeDeploymentReplicasMismatch", "warning", { "checkout/api", "search/indexer" }, 95 },
    { "RabbitmqQueueBacklog", "warning", { "mq-01:15692", "mq-02:15692", "mq-03:15692" }, 180 },
    { "CertificateExpiresSoon", "warning", { "auth.example.com", "status.example.com" }, 60 * 30 },
    { "PuppetLastRunTooOld", "warning", { "web-01", "web-02", "web-03", "web-04", "web-05", "web-06",
      "web-07", "web-08", "web-09" }, 60 * 50 },
    { "RedisMemoryHigh", "warning", { "cache-02:9121" }, 300 },
    { "BlackboxProbeSlow", "warning", { "https://shop.example.com" }, 14 },
    { "NodeClockSkew", "info", { "build-02:9100", "build-05:9100" }, 600 },
    { "PrometheusRuleEvaluationSlow", "warning", { "prometheus-0:9090" }, 60 * 24 * 12, true },
    { "Watchdog", "info", {}, 60 * 24 * 40, false, "Alerting pipeline is alive" },
  }
  local list = {}
  for _, a in ipairs(ALERTS) do
    local where = #a[3] > 0 and a[3] or { false }
    for i, inst in ipairs(where) do
      list[#list + 1] = { id = tostring(#list + 1), status = "firing", severity = a[2], source = "demo",
        startsAt = os.date("!%Y-%m-%dT%H:%M:%SZ", math.floor(T0 - a[4] * 60 - (i - 1) * 600)),
        labels = { alertname = a[1], instance = inst or nil }, annotations = { summary = a[6] },
        suppressed = a[5] or false }
    end
  end
  local state = P.parse(encode({ total = #list, alerts = list }))
  state.ok, state.fetched = true, T0 - 8
  R.set_alerts(state)
end

-- Timeline: { at, sid, event, tool, kind, target }
timeline = {
  { 0.6, "a", "pre", "Read", "file", "…/claude_constellation/render.lua" },
  { 1.4, "b", "post" },
  { 1.8, "c", "pre", "Agent", "agent", "general-purpose" },
  { 2.2, "a", "post" },
  { 2.6, "b", "pre", "Read", "file", "…/src/db/pool.ts" },
  { 3.1, "a", "pre", "Grep", "search", "set_palette" },
  { 3.8, "b", "post" },
  { 4.0, "a", "post" },
  { 4.3, "b", "pre", "mcp__postgres__query", "mcp", "postgres:query" },
  { 4.8, "c", "post" },
  { 5.0, "a", "pre", "Edit", "file", "…/claude_constellation/render.lua" },
  { 5.6, "b", "post" },
  { 5.9, "c", "pre", "WebFetch", "web", "registry.terraform.io" },
  { 6.4, "a", "post" },
  { 6.6, "b", "pre", "Bash", "shell", "npm run migrate" },
  { 6.7, "b", "permission" },
  { 7.2, "a", "pre", "Bash", "shell", "lua5.4 demo/record.lua" },
  { 7.6, "c", "post" },
  { 8.4, "c", "pre", "Edit", "file", "…/modules/vpc.tf" },
  { 8.8, "a", "post" },
  { 9.4, "a", "stop" },
  { 9.6, "b", "pre", "Bash", "shell", "npm run migrate" },
  { 9.9, "c", "post" },
  { 10.5, "c", "pre", "Bash", "shell", "terraform plan" },
  { 11.0, "b", "post" },
}

elseif SCENARIO == "workflow" then
  -- Deterministic pseudo-random so the GIF is reproducible.
  local wseed = 7
  local function rnd_n(n) wseed = (wseed * 1103515245 + 12345) % 2147483648; return wseed % n end
  local TOOLS = {
    { "Read", "file", "…/packages/%s/index.ts" }, { "Grep", "search", "import .* from '%s'" },
    { "Edit", "file", "…/packages/%s/package.json" }, { "Bash", "shell", "pnpm -F %s test" },
    { "Glob", "search", "packages/%s/**/*.ts" }, { "WebFetch", "web", "nodejs.org" },
  }
  local PKGS = { "auth", "billing", "ui-kit", "search", "mailer", "cli", "sdk", "jobs", "cache", "flags" }

  session("w", "monorepo-migration", "thinking", {
    { "file", "…/docs/migration-plan.md", -90 }, { "agent", "Explore", -60 }, { "agent", "Explore", -58 },
  })
  session("b", "api-server", "done", { { "file", "…/src/routes.ts", -200 }, { "agent", "Explore", -30 } })
  session("c", "infra", "tool", { { "file", "…/modules/vpc.tf", -120 }, { "shell", "terraform plan", -10 } })
  S.c.tool, S.c.kind, S.c.target = "Bash", "shell", "terraform plan"
  for _, s in pairs(S) do save(s) end

  timeline = {}
  local function at(time, fn) timeline[#timeline + 1] = { time, fn } end
  local n = 0
  -- Spawn `count` agents of `type` at `time`, each busy until `done` with random tool calls.
  local function wave(sid, time, type, count, labels, done, perm)
    for k = 1, count do
      n = n + 1
      local id, pkg = "ag" .. n, PKGS[(n % #PKGS) + 1]
      local t0 = time + k * 0.12
      at(t0, function() agent(sid, id, "start", type, labels and labels:format(pkg) or "") end)
      local tt = t0 + 0.3 + rnd_n(60) / 100
      local stop = done + rnd_n(150) / 100
      while tt < stop do
        local tool = TOOLS[rnd_n(#TOOLS) + 1]
        at(tt, function() agent(sid, id, "pre", tool[1], tool[2], tool[3]:format(pkg)) end)
        local dur = 0.4 + rnd_n(120) / 100
        at(tt + dur, function() agent(sid, id, "post") end)
        tt = tt + dur + 0.2 + rnd_n(80) / 100
      end
      stop = math.max(stop, tt)
      if perm and k == 1 then
        at(perm, function() agent(sid, id, "permission") end)
        at(perm + 2.5, function() agent(sid, id, "post") end)
      end
      at(stop + 0.3, function() agent(sid, id, "stop") end)
    end
  end

  -- api-server: two individual subagents, for contrast.
  wave("b", -1.5, "Explore", 1, "find route handlers", 9)
  wave("b", 0.5, "general-purpose", 1, "write route tests", 15)
  -- monorepo-migration: 4 runners, then a big fan-out (grouped by type), then even more types
  -- (smallest groups merge into "+k agents"), then the waves finish and it ungroups.
  wave("w", -1.8, "Explore", 3, "map %s imports", 6)
  at(0.8, function() emit("w", "pre", "Agent", "agent", "Plan") end)
  wave("w", 1.0, "Plan", 1, "migration order", 4.5)
  at(2.5, function() emit("w", "pre", "Agent", "agent", "general-purpose") end)
  wave("w", 2.6, "general-purpose", 10, "migrate %s", 11)
  wave("w", 3.4, "code-reviewer", 5, "review %s", 12.5, 9)
  wave("w", 4.2, "test-writer", 3, "tests for %s", 11.5)
  at(4.6, function() emit("w", "stop") end)
  wave("w", 6.0, "security-reviewer", 2, "audit %s", 10.5)
  wave("w", 6.4, "docs-writer", 1, "changelog", 9.5)
  wave("w", 6.6, "perf-auditor", 1, "bundle size", 9)
  wave("w", 6.8, "i18n-checker", 1, "strings", 8.5)
  wave("w", 12.5, "Explore", 2, "verify %s build", 17)

  at(1.0, function() emit("c", "post") end)
  at(5.0, function() emit("c", "pre", "Bash", "shell", "terraform apply") end)
  at(5.2, function() emit("c", "permission") end)
  at(9.0, function() emit("c", "post") end)
  at(14.0, function() emit("c", "stop") end)
  table.sort(timeline, function(x, y) return x[1] < y[1] end)
end

local surface = cairo.ImageSurface.create(cairo.Format.RGB24, W, H)
local opts = { private = MODE == "lock" }
if MODE == "promview" then opts.layout, opts.area = "hud", { x = 0, y = 36, w = W, h = H - 36 } end
local layout_time = SECONDS / #R.LAYOUTS
local PREROLL = 2 -- seconds rendered but not saved, so nodes have faded in and settled
local frames, next_ev = math.floor(SECONDS * FPS), 1
while timeline[next_ev] and timeline[next_ev][1] < -PREROLL do -- before the preroll: apply now
  local e = timeline[next_ev]
  if type(e[2]) == "function" then e[2]() else emit(e[2], e[3], e[4], e[5], e[6]) end
  next_ev = next_ev + 1
end
for f = -PREROLL * FPS, frames - 1 do
  clock = f / FPS
  while timeline[next_ev] and timeline[next_ev][1] <= clock do
    local e = timeline[next_ev]
    if type(e[2]) == "function" then e[2]() else emit(e[2], e[3], e[4], e[5], e[6]) end
    next_ev = next_ev + 1
  end
  R.read_sessions()
  if MODE == "layouts" then
    opts.layout = R.LAYOUTS[math.min(#R.LAYOUTS, math.floor(math.max(clock, 0) / layout_time) + 1)]
  end
  R.draw(cairo.Context(surface), W, H, opts)
  if f >= 0 then surface:write_to_png(string.format("%s/%05d.png", OUT, f)) end
  collectgarbage("step")
end
