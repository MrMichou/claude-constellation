-- Obsidian vaults for the obsi-constellation layout: which vaults there are, each one's graph
-- (its notes and the [[wikilinks]] between them, as Obsidian's graph view draws it), and the
-- notes the sessions read or edited in it (recorded by hooks/track.js under `notes`).
-- Plain Lua + io, no AwesomeWM: the lock-screen saver draws the same layout.

local DIR = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local json = dofile(DIR .. "json.lua")

local O = {}

local HOME = os.getenv("HOME") or ""
local XDG = os.getenv("XDG_CONFIG_HOME") or (HOME .. "/.config")
-- Overridable for tests.
O.CONF = XDG .. "/claude-constellation/obsidian.conf" -- `vault = <path>`, repeatable
O.OBSIDIAN_JSON = XDG .. "/obsidian/obsidian.json" -- Obsidian's own list of vaults
O.RESCAN = 30 -- seconds between two scans of a vault's files
O.MAX_NOTES = 3000 -- notes read per vault; a bigger vault shows its first ones

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function strip_slash(p) return (p:gsub("/+$", "")) end
local function expand(p) return (p:gsub("^~", HOME)) end

-- Vault roots, without trailing slash: the `vault` lines of obsidian.conf if there are any,
-- else every vault Obsidian knows, the open one first, then the most recently opened.
function O.vaults()
  local out = {}
  local f = io.open(O.CONF, "r")
  if f then
    for line in f:lines() do
      local v = line:gsub("#.*$", ""):match("^%s*vault%s*=%s*(.-)%s*$")
      if v and v ~= "" then out[#out + 1] = strip_slash(expand(v)) end
    end
    f:close()
  end
  if #out > 0 then return out end
  local jf = io.open(O.OBSIDIAN_JSON, "r")
  if not jf then return out end
  local ok, d = pcall(json.decode, jf:read("*a") or "")
  jf:close()
  local list = {}
  for _, v in pairs(ok and type(d) == "table" and type(d.vaults) == "table" and d.vaults or {}) do
    if type(v) == "table" and type(v.path) == "string" then list[#list + 1] = v end
  end
  table.sort(list, function(a, b)
    if (a.open == true) ~= (b.open == true) then return a.open == true end
    return (tonumber(a.ts) or 0) > (tonumber(b.ts) or 0)
  end)
  for _, v in ipairs(list) do out[#out + 1] = strip_slash(v.path) end
  return out
end

-- The vault holding absolute path p, and p relative to it; nil outside every vault.
function O.locate(vaults, p)
  for _, v in ipairs(vaults) do
    if p:sub(1, #v + 1) == v .. "/" then return v, p:sub(#v + 2) end
  end
end

-- Link targets in a note's text: [[target]], [[target|alias]], [[target#heading]], ![[embed]],
-- and markdown links to a .md file. Targets as written, without .md.
function O.parse_links(text)
  local out = {}
  for target in text:gmatch("%[%[([^%]|#\n]+)") do
    target = trim(target)
    if target ~= "" then out[#out + 1] = (target:gsub("%.md$", "")) end
  end
  for target in text:gmatch("%]%(([^)%s]+%.md)%)") do
    if not target:match("^%a+://") then
      target = target:gsub("%%20", " "):gsub("^%./", "")
      out[#out + 1] = (target:gsub("%.md$", ""))
    end
  end
  return out
end

local function shell_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

-- Per vault: { notes = { {rel, name, folder, links = {targets}}... }, by_rel, mtimes, scanned }
local cache = {}

-- Markdown files of a vault with their mtime, hidden folders (.obsidian, .trash) left out.
local function list_files(vault)
  local p = io.popen("find " .. shell_quote(vault) .. " -name '.*' -prune -o -type f -name '*.md' "
    .. "-printf '%T@ %P\\n' 2>/dev/null")
  if not p then return {} end
  local out = {}
  for line in p:lines() do
    local mtime, rel = line:match("^(%S+) (.+)$")
    if rel then out[#out + 1] = { rel = rel, mtime = mtime } end
    if #out >= O.MAX_NOTES then break end
  end
  p:close()
  table.sort(out, function(a, b) return a.rel < b.rel end)
  return out
end

-- Obsidian's link resolution: a target with a folder matches the note at that path (or ending
-- with it), a bare name the note with that name, the one nearest the root if several.
local function resolver(notes)
  local by_name, by_path = {}, {}
  for _, n in ipairs(notes) do
    local lower = n.rel:lower():gsub("%.md$", "")
    by_path[lower] = n
    local name = n.name:lower()
    local cur = by_name[name]
    if not cur or #n.rel < #cur.rel then by_name[name] = n end
  end
  return function(target)
    local t = target:lower():gsub("^/", "")
    if t:find("/", 1, true) then
      if by_path[t] then return by_path[t] end
      for p, n in pairs(by_path) do
        if p:sub(-#t - 1) == "/" .. t then return n end
      end
      return nil
    end
    return by_name[t]
  end
end

-- The vault's graph, rescanned every O.RESCAN seconds (files read again only when changed):
-- { notes = {...}, edges = { {a, b}... }, by_rel = { rel = note }, version } where a note is
-- { rel, name, folder, degree, i }. `version` changes whenever notes or edges do.
function O.graph(vault, t)
  local g = cache[vault]
  if g and t - g.scanned < O.RESCAN then return g end
  local old = g and g.files or {}
  local files, notes, changed = {}, {}, not g
  for _, fl in ipairs(list_files(vault)) do
    local prev = old[fl.rel]
    local entry = prev
    if not prev or prev.mtime ~= fl.mtime then
      changed = true
      local fh = io.open(vault .. "/" .. fl.rel, "r")
      local text = fh and fh:read("*a") or ""
      if fh then fh:close() end
      entry = { mtime = fl.mtime, links = O.parse_links(text) }
    end
    files[fl.rel] = entry
    local name = fl.rel:match("([^/]+)%.md$") or fl.rel
    notes[#notes + 1] = { rel = fl.rel, name = name, folder = fl.rel:match("^([^/]+)/") or "",
      targets = entry.links, degree = 0, i = #notes + 1 }
  end
  for rel in pairs(old) do if not files[rel] then changed = true end end
  if not changed then g.scanned = t; return g end
  local resolve = resolver(notes)
  local edges, seen, by_rel = {}, {}, {}
  for _, n in ipairs(notes) do by_rel[n.rel] = n end
  for _, n in ipairs(notes) do
    for _, target in ipairs(n.targets) do
      local m = resolve(target)
      if m and m ~= n then
        local a, b = math.min(n.i, m.i), math.max(n.i, m.i)
        local key = a * 100000 + b
        if not seen[key] then
          seen[key] = true
          edges[#edges + 1] = { a, b }
          n.degree, m.degree = n.degree + 1, m.degree + 1
        end
      end
    end
  end
  -- A note edited without its links changing leaves the graph as it was: same version, so the
  -- layout neither settles it again nor redraws it (sessions write notes all the time).
  local parts = {}
  for _, n in ipairs(notes) do parts[#parts + 1] = n.rel end
  for _, e in ipairs(edges) do parts[#parts + 1] = e[1] .. "-" .. e[2] end
  local shape = table.concat(parts, "\n")
  if g and g.shape == shape then g.files, g.scanned = files, t; return g end
  g = { notes = notes, edges = edges, by_rel = by_rel, files = files, scanned = t, shape = shape,
    version = ((g and g.version) or 0) + 1, vault = vault, name = vault:match("([^/]+)$") or vault }
  cache[vault] = g
  return g
end

-- Notes the sessions touched, per vault: { [vault] = { {s, rel, read, edit, ts}... } }, and the
-- vault touched last. `notes` keys are absolute paths, or "obsidian:<rel>" for a note reached
-- through an Obsidian MCP server (resolved against the first vault holding it).
function O.touched(list, vaults)
  local by_vault, last_vault, last_ts = {}, nil, -1
  for _, s in ipairs(list) do
    for key, n in pairs(type(s.notes) == "table" and s.notes or {}) do
      if type(n) == "table" then
        local vault, rel
        local mcp = key:match("^obsidian:(.+)$")
        if mcp then
          mcp = mcp:gsub("^/", "")
          if not mcp:match("%.md$") then mcp = mcp .. ".md" end
          for _, v in ipairs(vaults) do
            local fh = io.open(v .. "/" .. mcp, "r")
            if fh then fh:close(); vault, rel = v, mcp; break end
          end
        else
          vault, rel = O.locate(vaults, key)
        end
        if vault then
          local read, edit = tonumber(n.r), tonumber(n.w)
          local ts = math.max(read or 0, edit or 0)
          by_vault[vault] = by_vault[vault] or {}
          table.insert(by_vault[vault], { s = s, rel = rel, read = read, edit = edit, ts = ts })
          if ts > last_ts then last_vault, last_ts = vault, ts end
        end
      end
    end
  end
  for _, l in pairs(by_vault) do
    table.sort(l, function(a, b)
      if a.ts ~= b.ts then return a.ts < b.ts end
      return a.rel < b.rel
    end)
  end
  return by_vault, last_vault
end

return O
