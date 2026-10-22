-- Shared spec helpers: temp dirs, session fixtures and a recording cairo context.
local lgi = require("lgi")
local GLib = lgi.GLib

local H = {}

H.MODULE_DIR = "awesome/claude_constellation/"

-- Fresh renderer instance (render.lua keeps module-level state, so reload it per test).
function H.renderer()
  return dofile(H.MODULE_DIR .. "render.lua")
end

-- Nested JSON encoder for fixtures (json.lua only encodes flat objects).
function H.encode(v)
  local t = type(v)
  if t == "string" then return '"' .. v:gsub('[\\"]', { ["\\"] = "\\\\", ['"'] = '\\"' }) .. '"' end
  if t == "number" or t == "boolean" then return tostring(v) end
  if t ~= "table" then return "null" end
  if #v > 0 or next(v) == nil then
    local parts = {}
    for _, x in ipairs(v) do parts[#parts + 1] = H.encode(x) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local parts = {}
  for k, x in pairs(v) do parts[#parts + 1] = H.encode(tostring(k)) .. ":" .. H.encode(x) end
  return "{" .. table.concat(parts, ",") .. "}"
end

function H.tmpdir()
  return GLib.dir_make_tmp("constellation-spec-XXXXXX") .. "/"
end

function H.rmrf(dir)
  os.execute("rm -rf '" .. dir:gsub("'", "") .. "'")
end

function H.write(path, content)
  local dir = path:match("^(.*)/")
  if dir then os.execute("mkdir -p '" .. dir .. "'") end
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

-- Write a session state file like hooks/track.js does; `fields` override the defaults.
function H.session(dir, sid, fields)
  local s = { sid = sid, project = sid, state = "done", history = {}, ts = os.time() }
  for k, v in pairs(fields or {}) do s[k] = v end
  H.write(dir .. sid .. ".json", H.encode(s))
end

-- Claude Code registry entry (<registry>/<pid>.json) plus a matching fake /proc/<pid>/stat;
-- `fields` override the defaults.
function H.registry(registry, proc, pid, fields, comm)
  local r = { pid = pid, sessionId = "sid" .. pid, cwd = "/home/me/proj" .. pid,
    kind = "interactive", status = "idle", procStart = "12345", updatedAt = os.time() * 1000 }
  for k, v in pairs(fields or {}) do r[k] = v end
  H.write(registry .. pid .. ".json", H.encode(r))
  H.write(proc .. pid .. "/stat", ("%d (%s) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 12345 0\n")
    :format(pid, comm or "claude"))
end

-- Fake /sys/class/power_supply entry.
function H.supply(dir, name, files)
  for k, v in pairs(files) do H.write(dir .. name .. "/" .. k, v .. "\n") end
end

-- A cairo context stand-in that records what gets drawn: texts (and where), arcs and colours.
-- Every other cairo method is a no-op, so render.lua's drawing logic can be asserted
-- without pixels.
function H.recorder()
  local rec = { texts = {}, text_pos = {}, arcs = {}, colors = {} }
  local cr = setmetatable({}, { __index = function() return function() end end })
  local px, py = 0, 0
  function cr.move_to(_, x, y) px, py = x, y end
  function cr.show_text(_, s)
    rec.texts[#rec.texts + 1] = s
    rec.text_pos[#rec.text_pos + 1] = px .. "," .. py
  end
  function cr.text_extents() return { width = 10, height = 10 } end
  function cr.arc(_, x, y, r) rec.arcs[#rec.arcs + 1] = { x = x, y = y, r = r } end
  function cr.get_source() return { set_filter = function() end } end
  function cr.set_source_rgba(_, r, g, b, a) rec.colors[#rec.colors + 1] = { r, g, b, a } end
  function rec.has_text(s)
    for _, t in ipairs(rec.texts) do if t == s then return true end end
    return false
  end
  function rec.text_matching(pat)
    for _, t in ipairs(rec.texts) do if t:find(pat) then return t end end
  end
  return cr, rec
end

return H
