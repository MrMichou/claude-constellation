-- Promview alerts from a running promview-desktop, over the session bus: the desktop already holds
-- the alert stream and the signed-in session, so asking it replaces polling the server with curl
-- (and a second copy of the credentials). Interface: org.promview.Desktop1 on /org/promview/Desktop,
-- described in promview-desktop's desktop/org.promview.Desktop1.xml.
--
-- No AwesomeWM dependency. `gio` and `glib` can be passed in, so the specs drive it with fakes.

local NAME = "org.promview.Desktop"
local PATH = "/org/promview/Desktop"
local IFACE = "org.promview.Desktop1"
local TIMEOUT_MS = 15000

local B = { NAME = NAME }

-- A D-Bus failure -> message, and whether signing in again would fix it. The desktop names the
-- error (org.promview.Desktop.Error.SignInNeeded / Unreachable); anything else, such as the
-- desktop going away mid-call, is just a message.
function B.failure(err)
  local msg = tostring(type(err) == "table" and err.message or err or "unknown error")
  if msg:find("Error.SignInNeeded", 1, true) then return "sign in needed", true end
  msg = msg:gsub("^GDBus%.Error:[%w%._]+: ", "")
  return msg, false
end

-- Opens the session bus and watches for the desktop. nil, message when there is no bus.
--   opts.on_owner(owned)  the desktop appeared (true) or went away (false)
--   opts.on_change()      the desktop says the alerts may have changed
-- The returned object has :owned() and :get_alerts(cfg, cb); cb(body) or cb(nil, message, signin).
function B.open(opts)
  opts = opts or {}
  local lgi = not (opts.gio and opts.glib and opts.closure) and require("lgi") or nil
  local Gio, GLib = opts.gio or lgi.Gio, opts.glib or lgi.GLib
  -- Gio wants the watch callbacks as GClosures, not plain functions.
  local Closure = opts.closure or lgi.GObject.Closure

  local ok, conn = pcall(Gio.bus_get_sync, Gio.BusType.SESSION, nil)
  if not ok or not conn then return nil, tostring(conn or "no session bus") end

  local bus, owned = {}, false
  function bus:owned() return owned end

  -- The name watch tells us when the desktop starts or stops, so a desktop started later is
  -- picked up without restarting Awesome, and one that quits sends us back to curl.
  Gio.bus_watch_name(Gio.BusType.SESSION, NAME, Gio.BusNameWatcherFlags.NONE,
    Closure(function()
      owned = true
      if opts.on_owner then opts.on_owner(true) end
    end),
    Closure(function()
      owned = false
      if opts.on_owner then opts.on_owner(false) end
    end))

  conn:signal_subscribe(NAME, IFACE, "AlertsChanged", PATH, nil, Gio.DBusSignalFlags.NONE,
    function() if opts.on_change then opts.on_change() end end)

  function bus:get_alerts(cfg, cb)
    local params = GLib.Variant("(uas)", { cfg.limit, cfg.match or {} })
    conn:call(NAME, PATH, IFACE, "GetAlerts", params, GLib.VariantType("(s)"),
      Gio.DBusCallFlags.NONE, TIMEOUT_MS, nil,
      function(c, res)
        -- lgi raises or returns nil, err for a GError depending on the build; take both.
        local done, reply, err = pcall(c.call_finish, c, res)
        if done and reply then
          local body = reply:get_child_value(0):get_string()
          return cb(body)
        end
        local msg, signin = B.failure(done and err or reply)
        cb(nil, msg, signin)
      end)
  end

  return bus
end

-- B.open that never raises: with lgi's Gio missing or no bus, the caller just has no desktop to
-- ask and keeps polling with curl.
function B.open_safe(opts)
  local ok, bus = pcall(B.open, opts)
  return ok and bus or nil
end

return B
