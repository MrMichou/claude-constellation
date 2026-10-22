#!/usr/bin/env lua5.4
-- Renders the README demos offline with the real renderer (render.lua) on a scripted set of
-- fake sessions and a simulated clock, so the output is reproducible and leaks nothing.
-- Usage: demo/record.sh (wraps this script and encodes the GIFs with ffmpeg).
--   lua5.4 demo/record.lua <out_dir> <wallpaper|lock|layouts> <width> <height> <fps> <seconds>
-- "layouts" cycles through every layout (R.LAYOUTS), an equal share of the time each.

local OUT, MODE = arg[1], arg[2] or "wallpaper"
local W, H = tonumber(arg[3]) or 1280, tonumber(arg[4]) or 720
local FPS, SECONDS = tonumber(arg[5]) or 30, tonumber(arg[6]) or 12

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
    history = h, timeline = {}, links = {}, ts = T0 - (ago or 0) }
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
  elseif event == "stop" then s.state = "done"
  end
  save(s)
end

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

-- Timeline: { at, sid, event, tool, kind, target }
local timeline = {
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

local surface = cairo.ImageSurface.create(cairo.Format.RGB24, W, H)
local opts = { private = MODE == "lock" }
local layout_time = SECONDS / #R.LAYOUTS
local PREROLL = 2 -- seconds rendered but not saved, so nodes have faded in and settled
local frames, next_ev = math.floor(SECONDS * FPS), 1
for f = -PREROLL * FPS, frames - 1 do
  clock = f / FPS
  while timeline[next_ev] and timeline[next_ev][1] <= clock do
    local e = timeline[next_ev]
    emit(e[2], e[3], e[4], e[5], e[6])
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
