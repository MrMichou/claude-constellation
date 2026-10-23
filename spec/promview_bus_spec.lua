-- Specs for promview_bus.lua: the desktop's D-Bus interface, driven with a fake Gio so no bus is needed.
local H = require("spec.helpers")
local lgi = require("lgi")
local GLib = lgi.GLib

local function identity(f) return f end

local function module() return dofile(H.MODULE_DIR .. "promview_bus.lua") end

-- A Gio that records what the module asks of the bus and lets the spec answer.
local function fake_gio()
  local g = { calls = {}, subs = {} }
  g.BusType = { SESSION = "session" }
  g.BusNameWatcherFlags = { NONE = 0 }
  g.DBusCallFlags = { NONE = 0 }
  g.DBusSignalFlags = { NONE = 0 }
  local conn = {}
  function conn:signal_subscribe(sender, iface, member, path, _, _, cb)
    g.subs[#g.subs + 1] = { sender = sender, iface = iface, member = member, path = path, cb = cb }
  end
  function conn:call(name, path, iface, method, params, reply_type, _, timeout, _, cb)
    g.calls[#g.calls + 1] = { name = name, path = path, iface = iface, method = method,
      params = params, reply_type = reply_type, timeout = timeout, cb = cb }
  end
  function conn:call_finish(res)
    if res.err then error(res.err, 0) end
    return { get_child_value = function() return { get_string = function() return res.body end } end }
  end
  g.conn = conn
  g.bus_get_sync = function()
    if g.no_bus then error("no session bus") end
    return conn
  end
  g.bus_watch_name = function(_, name, _, appeared, vanished)
    g.watched, g.appeared, g.vanished = name, appeared, vanished
    return 1
  end
  return g
end

describe("promview_bus.lua", function()
  local B, g
  before_each(function()
    B, g = module(), fake_gio()
  end)

  it("watches the desktop's name and tells the caller when it comes and goes", function()
    local seen = {}
    local bus = B.open({ gio = g, glib = GLib, closure = identity,
      on_owner = function(o) seen[#seen + 1] = o end })
    assert.are.equal("org.promview.Desktop", g.watched)
    assert.is_false(bus:owned())
    g.appeared()
    assert.is_true(bus:owned())
    g.vanished()
    assert.is_false(bus:owned())
    assert.are.same({ true, false }, seen)
  end)

  it("reports AlertsChanged to the caller", function()
    local n = 0
    B.open({ gio = g, glib = GLib, closure = identity, on_change = function() n = n + 1 end })
    local sub = g.subs[1]
    assert.are.equal("AlertsChanged", sub.member)
    assert.are.equal("org.promview.Desktop1", sub.iface)
    assert.are.equal("/org/promview/Desktop", sub.path)
    sub.cb()
    sub.cb()
    assert.are.equal(2, n)
  end)

  it("asks GetAlerts with the limit and matchers, and hands back the body", function()
    local bus = B.open({ gio = g, glib = GLib, closure = identity })
    local got
    bus:get_alerts({ limit = 50, match = { "team=platform" } }, function(body) got = body end)
    local call = g.calls[1]
    assert.are.equal("GetAlerts", call.method)
    assert.are.equal("org.promview.Desktop1", call.iface)
    assert.are.equal("(uas)", call.params:get_type_string())
    assert.are.equal(50, call.params:get_child_value(0):get_uint32())
    assert.are.equal("team=platform", call.params:get_child_value(1):get_child_value(0):get_string())
    call.cb(g.conn, { body = '{"alerts":[]}' })
    assert.are.equal('{"alerts":[]}', got)
  end)

  it("sends an empty matcher list when there are none", function()
    local bus = B.open({ gio = g, glib = GLib, closure = identity })
    bus:get_alerts({ limit = 10 }, function() end)
    assert.are.equal(0, g.calls[1].params:get_child_value(1):n_children())
  end)

  it("tells a missing sign-in from any other failure", function()
    local bus = B.open({ gio = g, glib = GLib, closure = identity })
    local msg, signin
    bus:get_alerts({ limit = 10 }, function(_, m, s) msg, signin = m, s end)
    g.calls[1].cb(g.conn, { err = "GDBus.Error:org.promview.Desktop.Error.SignInNeeded: needs a session" })
    assert.are.equal("sign in needed", msg)
    assert.is_true(signin)

    bus:get_alerts({ limit = 10 }, function(_, m, s) msg, signin = m, s end)
    g.calls[2].cb(g.conn, { err = "GDBus.Error:org.promview.Desktop.Error.Unreachable: HTTP 500" })
    assert.are.equal("HTTP 500", msg)
    assert.is_false(signin)
  end)

  it("has no bus to open when the session bus is missing", function()
    g.no_bus = true
    assert.is_nil(B.open_safe({ gio = g, glib = GLib, closure = identity }))
  end)
end)
