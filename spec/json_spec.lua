-- Specs for the pure-Lua JSON codec shipped with the module.
local json = dofile("awesome/claude_constellation/json.lua")

describe("json.decode", function()
  it("decodes a session file", function()
    local v = json.decode('{"sid":"s1","state":"tool","ts":1792675262.055,"history":[{"kind":"file"}]}')
    assert.are.equal("s1", v.sid)
    assert.are.equal("tool", v.state)
    assert.are.equal(1792675262.055, v.ts)
    assert.are.equal("file", v.history[1].kind)
  end)

  it("decodes nested objects, arrays, booleans and null", function()
    local v = json.decode('{"a":[1,2,{"b":true}],"c":{"d":null},"e":false}')
    assert.are.equal(2, v.a[2])
    assert.is_true(v.a[3].b)
    assert.is_nil(v.c.d)
    assert.is_false(v.e)
  end)

  it("decodes escapes and unicode", function()
    assert.are.equal('a"b\\c\nd', json.decode('"a\\"b\\\\c\\nd"'))
    assert.are.equal("…/c/d.txt", json.decode('"…/c/d.txt"'))
    assert.are.equal("é", json.decode('"\\u00e9"'))
  end)

  it("decodes numbers", function()
    assert.are.equal(-3.5, json.decode("-3.5"))
    assert.are.equal(1000, json.decode("1e3"))
  end)

  it("returns nil plus an error on invalid input", function()
    for _, bad in ipairs({ "", "{", "{not json", "[1,", '{"a":}', 42 }) do
      local v, err = json.decode(bad)
      assert.is_nil(v)
      assert.is_string(err)
    end
  end)
end)

describe("json.encode", function()
  it("round-trips a flat palette with sorted keys", function()
    local p = { bg = "#232a31", fg = "#f2f0fd", n = 3, ok = true }
    local s = json.encode(p)
    assert.are.equal('{"bg":"#232a31","fg":"#f2f0fd","n":3,"ok":true}', s)
    assert.are.same(p, json.decode(s))
  end)

  it("escapes quotes and backslashes", function()
    assert.are.same({ s = 'a"b\\c' }, json.decode(json.encode({ s = 'a"b\\c' })))
  end)

  it("skips nested values and rejects non-tables", function()
    assert.are.equal('{"a":1}', json.encode({ a = 1, nested = { 1 } }))
    assert.is_nil(json.encode("x"))
  end)
end)
