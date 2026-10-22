-- Specs for saver.lua outside of X: it must refuse to run without a window to draw into, and
-- its sh prologue must pick a Lua that can load lgi. (Drawing goes through render.lua, covered
-- by render_spec.)
local H = require("spec.helpers")
local SAVER = "awesome/claude_constellation/saver.lua"

describe("saver.lua", function()
  it("is executable", function()
    local h = io.popen("test -x " .. SAVER .. " && echo yes")
    assert.are.equal("yes", h:read("*l"))
    h:close()
  end)

  it("exits 1 with a message when XSCREENSAVER_WINDOW is missing", function()
    local h = io.popen("env -u XSCREENSAVER_WINDOW lua5.4 " .. SAVER .. " 2>&1; echo \"exit=$?\"")
    local out = h:read("*a")
    h:close()
    assert.truthy(out:find("XSCREENSAVER_WINDOW is not set", 1, true))
    assert.truthy(out:find("exit=1", 1, true))
  end)

  describe("interpreter choice (sh prologue)", function()
    local bin, log
    -- A fake interpreter on PATH: logs its name and arguments; `has_lgi` decides whether the
    -- `-e 'require("lgi")'` probe succeeds. A chosen one hands over to the real lua5.4.
    local function fake(name, has_lgi)
      H.write(bin .. name, table.concat({
        "#!/bin/sh",
        ('echo "%s $*" >> %s'):format(name, log),
        ('if [ "$1" = -e ]; then exit %d; fi'):format(has_lgi and 0 or 1),
        'exec "$REAL_LUA" "$@"',
      }, "\n") .. "\n")
      os.execute("chmod +x " .. bin .. name)
    end
    local function run()
      local real = io.popen("command -v lua5.4"):read("*l")
      local h = io.popen(("env -u XSCREENSAVER_WINDOW PATH=%s REAL_LUA=%s /bin/sh %s 2>&1; echo \"exit=$?\"")
        :format(bin, real, SAVER))
      local out = h:read("*a"); h:close()
      local f = io.open(log); local calls = f and f:read("*a") or ""; if f then f:close() end
      return out, calls
    end

    before_each(function()
      bin = H.tmpdir()
      log = bin .. "calls.log"
    end)
    after_each(function() H.rmrf(bin) end)

    it("skips a Lua without lgi and runs the file under the first one that has it", function()
      fake("lua5.4", false)
      fake("lua5.3", true)
      fake("luajit", true)
      local out, calls = run()
      assert.truthy(calls:find("lua5.4 -e", 1, true))       -- probed, rejected
      assert.truthy(calls:find("lua5.3 " .. SAVER, 1, true)) -- re-executed the saver
      assert.falsy(calls:find("luajit", 1, true))           -- never reached
      -- The real saver then ran: no window here, so it stops with its own message.
      assert.truthy(out:find("XSCREENSAVER_WINDOW is not set", 1, true))
      assert.truthy(out:find("exit=1", 1, true))
    end)

    it("fails with a clear message when no Lua can load lgi", function()
      fake("lua5.4", false)
      fake("lua", false)
      local out = run()
      assert.truthy(out:find("no Lua interpreter with lgi found", 1, true))
      assert.truthy(out:find("exit=1", 1, true))
    end)
  end)
end)
