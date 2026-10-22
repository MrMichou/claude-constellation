-- Minimal pure-Lua JSON decoder (object/array/string/number/bool/null).
-- Sufficient for reading ~/.claude/statusbar/state.json (a small flat object).
-- Returns a table with a single function: json.decode(str) -> value (or nil, errmsg).

local json = {}

local function skip_ws(s, i)
  local _, e = s:find("^[ \t\r\n]*", i)
  return (e or i - 1) + 1
end

local decode_value -- forward decl

local escapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local function decode_string(s, i)
  -- s:sub(i) == '"...'
  i = i + 1
  local buf, n = {}, 0
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(buf), i + 1
    elseif c == '\\' then
      local nc = s:sub(i + 1, i + 1)
      if nc == 'u' then
        local hex = s:sub(i + 2, i + 5)
        local cp = tonumber(hex, 16)
        if not cp then return nil, "bad \\u escape" end
        -- UTF-8 encode (BMP only; good enough for our labels like "…").
        local out
        if cp < 0x80 then
          out = string.char(cp)
        elseif cp < 0x800 then
          out = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
        else
          out = string.char(0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
        end
        n = n + 1; buf[n] = out
        i = i + 6
      else
        n = n + 1; buf[n] = escapes[nc] or nc
        i = i + 2
      end
    else
      n = n + 1; buf[n] = c
      i = i + 1
    end
  end
  return nil, "unterminated string"
end

local function decode_number(s, i)
  local _, e = s:find("^%-?%d+%.?%d*[eE]?[+%-]?%d*", i)
  local num = tonumber(s:sub(i, e))
  if not num then return nil, "bad number" end
  return num, e + 1
end

local function decode_array(s, i)
  local arr, n = {}, 0
  i = skip_ws(s, i + 1)
  if s:sub(i, i) == ']' then return arr, i + 1 end
  while true do
    local v, ni = decode_value(s, i)
    if v == nil and ni == nil then return nil, "bad array element" end
    if ni == nil then return nil, v end -- error string in v
    n = n + 1; arr[n] = v
    i = skip_ws(s, ni)
    local c = s:sub(i, i)
    if c == ']' then return arr, i + 1 end
    if c ~= ',' then return nil, "expected , or ]" end
    i = skip_ws(s, i + 1)
  end
end

local function decode_object(s, i)
  local obj = {}
  i = skip_ws(s, i + 1)
  if s:sub(i, i) == '}' then return obj, i + 1 end
  while true do
    if s:sub(i, i) ~= '"' then return nil, "expected object key" end
    local key, ni = decode_string(s, i)
    if not key then return nil, ni end
    i = skip_ws(s, ni)
    if s:sub(i, i) ~= ':' then return nil, "expected :" end
    local val, vi = decode_value(s, skip_ws(s, i + 1))
    if vi == nil then return nil, val end
    obj[key] = val
    i = skip_ws(s, vi)
    local c = s:sub(i, i)
    if c == '}' then return obj, i + 1 end
    if c ~= ',' then return nil, "expected , or }" end
    i = skip_ws(s, i + 1)
  end
end

decode_value = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == '"' then return decode_string(s, i)
  elseif c == '{' then return decode_object(s, i)
  elseif c == '[' then return decode_array(s, i)
  elseif c == 't' and s:sub(i, i + 3) == "true" then return true, i + 4
  elseif c == 'f' and s:sub(i, i + 4) == "false" then return false, i + 5
  elseif c == 'n' and s:sub(i, i + 3) == "null" then return nil, i + 4
  elseif c:match("[%-%d]") then return decode_number(s, i)
  end
  return nil, "unexpected character at " .. i
end

function json.decode(str)
  if type(str) ~= "string" then return nil, "not a string" end
  local ok, val, idx = pcall(decode_value, str, 1)
  if not ok then return nil, "decode error" end
  if idx == nil then return nil, val end -- val holds the error message
  return val
end

-- Minimal encoder for a *flat* object: string/number/boolean values only (the shape
-- of widget.json). Keys are sorted for deterministic output, nested tables and other
-- value types are skipped. Strings escape `"` and `\` (our values never contain
-- control chars). Enough to round-trip settings back through json.decode.
local function encode_string(s)
  return '"' .. s:gsub('[\\"]', { ['\\'] = '\\\\', ['"'] = '\\"' }) .. '"'
end

function json.encode(t)
  if type(t) ~= "table" then return nil, "not a table" end
  local keys = {}
  for k in pairs(t) do
    if type(k) == "string" then keys[#keys + 1] = k end
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = t[k]
    local tv = type(v)
    local enc
    if tv == "string" then enc = encode_string(v)
    elseif tv == "boolean" then enc = tostring(v)
    elseif tv == "number" then enc = tostring(v)
    end
    if enc then parts[#parts + 1] = encode_string(k) .. ":" .. enc end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

return json
