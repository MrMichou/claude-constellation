-- e2e/run.sh helper: loads the installed module (through the installer's symlink) under whichever
-- Lua runs it, reads the session files the hooks just wrote, and draws every layout to PNGs.
-- Usage: <lua> e2e/render.lua <module_dir> <out_dir>
local MODULE, OUT = arg[1], arg[2]
local cairo = require("lgi").cairo
local R = dofile(MODULE .. "/render.lua")

local function check(ok, msg)
  if not ok then io.stderr:write("FAIL: ", msg, "\n"); os.exit(1) end
end

local active, n = R.read_sessions()
check(n == 2, "2 sessions read, got " .. tostring(n))
check(active, "a session with running subagents counts as active")

local main = R.read_json(os.getenv("HOME") .. "/.claude/constellation/e2e-main.json")
local runners = R.runners(main, os.time())
-- 16 running subagents of 7 types (code-reviewer is done): past RUNNERS_MAX they are grouped by
-- type, and past RUNNERS_MAX types the smallest groups (created last) merge into "+k agents".
local by = {}
for _, r in ipairs(runners) do by[r.type] = r end
check(#runners == 6, "6 groups, got " .. #runners)
check(by.agents and by.agents.merged and by.agents.count == 2, "perf-auditor + i18n-checker merged")
check(by["general-purpose"] and by["general-purpose"].count == 10, "general-purpose ×10")
check(by.Plan and by.Plan.state == "permission", "Plan keeps its permission state")
check(not by["code-reviewer"], "a finished subagent is dropped once grouped")

os.execute("mkdir -p '" .. OUT .. "'")
local W, H = 640, 360
local blank
for _, private in ipairs({ false, true }) do
  for _, name in ipairs(R.LAYOUTS) do
    local surf = cairo.ImageSurface.create(cairo.Format.RGB24, W, H)
    -- Twice, so nodes have faded in a bit and the layout cached what it derives from sessions.
    for _ = 1, 2 do R.draw(cairo.Context(surf), W, H, { layout = name, private = private }) end
    local path = ("%s/%s%s.png"):format(OUT, name, private and "-private" or "")
    surf:write_to_png(path)
    local f = assert(io.open(path, "rb")); local size = f:seek("end"); f:close()
    if not blank then -- a black frame of this size, to tell drawn frames apart
      local b = cairo.ImageSurface.create(cairo.Format.RGB24, W, H)
      b:write_to_png(OUT .. "/blank.png")
      local g = assert(io.open(OUT .. "/blank.png", "rb")); blank = g:seek("end"); g:close()
    end
    check(size > blank * 2, path .. " looks empty (" .. size .. " bytes)")
  end
end
print(("%d layouts drawn, public and private (%s)"):format(#R.LAYOUTS, _VERSION))
