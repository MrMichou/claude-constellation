-- Specs for saver.lua outside of X: it must refuse to run without a window to draw into.
-- (Drawing itself goes through render.lua, covered by render_spec.)
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
end)
