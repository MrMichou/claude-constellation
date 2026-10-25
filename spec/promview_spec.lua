-- Specs for promview.lua (config, URL, snapshot parsing) and the Promview column of the HUD.
local H = require("spec.helpers")

local function promview() return dofile(H.MODULE_DIR .. "promview.lua") end

local function alert(fields)
  local a = { id = "1", status = "firing", severity = "warning", source = "demo",
    startsAt = "2026-08-14T12:00:00Z", labels = { alertname = "Example" }, annotations = {} }
  for k, v in pairs(fields or {}) do a[k] = v end
  return a
end

describe("promview.lua", function()
  local P, dir
  before_each(function()
    P = promview()
    dir = H.tmpdir()
  end)
  after_each(function() H.rmrf(dir) end)

  describe("read_config desktop", function()
    it("needs a url, or the desktop asked for outright", function()
      H.write(dir .. "a.conf", "desktop = auto\n")
      assert.is_nil(P.read_config(dir .. "a.conf"))
      H.write(dir .. "b.conf", "desktop = on\n")
      local cfg = P.read_config(dir .. "b.conf")
      assert.are.equal("on", cfg.desktop)
      assert.is_nil(cfg.url)
    end)

    it("defaults to auto and treats anything unknown as auto", function()
      H.write(dir .. "c.conf", "url = http://pv:8080\n")
      assert.are.equal("auto", P.read_config(dir .. "c.conf").desktop)
      H.write(dir .. "d.conf", "url = http://pv:8080\ndesktop = maybe\n")
      assert.are.equal("auto", P.read_config(dir .. "d.conf").desktop)
      H.write(dir .. "e.conf", "url = http://pv:8080\ndesktop = off\n")
      assert.are.equal("off", P.read_config(dir .. "e.conf").desktop)
    end)
  end)

  describe("read_config", function()
    it("is off without a url", function()
      assert.is_nil(P.read_config(dir .. "missing.conf"))
      H.write(dir .. "p.conf", "# nothing\ninterval = 10\n")
      assert.is_nil(P.read_config(dir .. "p.conf"))
    end)

    it("reads the url, repeated matchers and clamps the numbers", function()
      H.write(dir .. "p.conf", table.concat({
        "# Promview", 'url = "http://pv:8080/"', "interval = 1", "limit = 9999",
        "match = team=platform", "match = severity!=info",
      }, "\n"))
      local cfg = P.read_config(dir .. "p.conf")
      assert.are.equal("http://pv:8080", cfg.url)
      assert.are.equal(5, cfg.interval)
      assert.are.equal(500, cfg.limit)
      assert.are.same({ "team=platform", "severity!=info" }, cfg.match)
    end)
  end)

  it("asks for firing alerts with url-encoded matchers", function()
    local url = P.url({ url = "http://pv:8080", limit = 50, match = { "team=platform", "severity!=info" } })
    assert.are.equal("http://pv:8080/api/v1/alerts?status=firing&limit=50"
      .. "&match=team%3Dplatform&match=severity%21%3Dinfo", url)
  end)

  describe("command", function()
    local cfg = { url = "http://pv:8080", limit = 50, match = {} }
    -- Run P.command's argv with fake secret-tool and curl on PATH; curl prints its argv and the
    -- headers it got on stdin.
    local function run(token)
      H.write(dir .. "bin/curl", "#!/bin/sh\necho \"args: $*\"\n"
        .. "case \"$*\" in *@-*) echo \"stdin: $(/bin/cat)\";; esac\n")
      H.write(dir .. "bin/secret-tool", token
        and ("#!/bin/sh\n[ \"$*\" = 'lookup service claude-constellation-promview server http://pv:8080' ] "
          .. "&& printf %s '" .. token .. "'\n")
        or "#!/bin/sh\nexit 1\n")
      os.execute("chmod +x '" .. dir .. "bin/curl' '" .. dir .. "bin/secret-tool'")
      local quoted = {}
      for i, a in ipairs(P.command(cfg)) do quoted[i] = "'" .. a:gsub("'", "'\\''") .. "'" end
      local f = io.popen("PATH='" .. dir .. "bin:/usr/bin:/bin' " .. table.concat(quoted, " "))
      local out = f:read("*a"); f:close()
      return out
    end

    it("sends the stored session token on stdin, never on the command line", function()
      local out = run("s3cret")
      assert.is_truthy(out:find("stdin: Authorization: Bearer s3cret", 1, true))
      assert.is_nil(out:match("args:[^\n]*s3cret"))
      assert.is_truthy(out:find("/api/v1/alerts?status=firing", 1, true))
    end)

    it("polls without a header when there is no token", function()
      local out = run(nil)
      assert.is_nil(out:find("Authorization", 1, true))
      assert.is_truthy(out:find("args: -sS -f", 1, true))
    end)
  end)

  it("tells a sign-in problem from an unreachable server", function()
    assert.are.same({ "sign in needed", true },
      { P.failure("curl: (22) The requested URL returned error: 401\n", 22) })
    assert.are.same({ "Failed to connect to pv port 8080", false },
      { P.failure("curl: (7) Failed to connect to pv port 8080\n", 7) })
  end)

  describe("parse", function()
    it("rejects what isn't an alerts snapshot", function()
      assert.is_nil(P.parse("<html>"))
      assert.is_nil(P.parse('{"error":"nope"}'))
    end)

    it("sorts by severity, newest first, and buckets unknown severities as info", function()
      local body = H.encode({ total = 4, streamCursor = 3, alerts = {
        alert({ severity = "warning", labels = { alertname = "Old" }, startsAt = "2026-08-14T10:00:00Z" }),
        alert({ severity = "Critical", labels = { alertname = "Down", instance = "db-1:9100" },
          annotations = { summary = "Database down" } }),
        alert({ severity = "page", labels = { alertname = "Odd" } }),
        alert({ severity = "warning", labels = { alertname = "New" }, startsAt = "2026-08-14T11:00:00Z",
          suppressed = true, annotations = { description = "only a description" } }),
      } })
      local s = P.parse(body)
      local names = {}
      for i, a in ipairs(s.alerts) do names[i] = a.name end
      assert.are.same({ "Down", "New", "Old", "Odd" }, names)
      assert.are.equal("critical", s.alerts[1].severity)
      assert.are.equal("db-1:9100", s.alerts[1].instance)
      assert.are.equal("Database down", s.alerts[1].summary)
      assert.is_true(s.alerts[2].suppressed)
      assert.are.equal("only a description", s.alerts[2].summary)
      assert.are.equal("info", s.alerts[4].severity)
      assert.are.same({ critical = 1, warning = 2, info = 1 }, s.counts)
      assert.are.equal(4, s.total)
    end)

    it("takes the counts from the server's histogram, which covers every page", function()
      local s = P.parse(H.encode({ total = 120, alerts = { alert() },
        severityCounts = { critical = 20, warning = 90, custom = 10 } }))
      assert.are.same({ critical = 20, warning = 90, info = 10 }, s.counts)
      assert.are.equal(120, s.total)
    end)
  end)
end)

describe("HUD with Promview", function()
  local R, P, data, cache
  before_each(function()
    data, cache = H.tmpdir(), H.tmpdir()
    R = H.renderer()
    R.set_dirs(data, H.tmpdir(), H.tmpdir(), H.tmpdir())
    R.set_cache_dir(cache)
    P = promview()
  end)
  after_each(function() H.rmrf(data); H.rmrf(cache) end)

  local function draw(opts)
    local cr, rec = H.recorder()
    opts = opts or {}
    opts.layout = "hud"
    R.draw(cr, 1920, 1080, opts)
    return rec
  end

  local function snapshot(n)
    local list = {}
    for i = 1, n do
      list[i] = alert({ id = tostring(i), severity = i == 1 and "critical" or "warning",
        labels = { alertname = "Alert" .. i, instance = "host" .. i } })
    end
    local s = P.parse(H.encode({ total = n, alerts = list }))
    s.ok = true
    return s
  end

  local function pos(rec, text)
    for i, t in ipairs(rec.texts) do
      if t == text then
        local x, y = rec.text_pos[i]:match("^([^,]+),(.+)$")
        return tonumber(x), tonumber(y)
      end
    end
  end

  it("draws nothing extra while Promview is off", function()
    assert.is_nil(draw().text_matching("PROMVIEW"))
  end)

  it("fills the desktop left of the sessions, which stay on the right edge", function()
    H.session(data, "a", { project = "api", state = "thinking" })
    R.read_sessions()
    R.set_alerts(snapshot(2))
    local rec = draw({ area = { x = 0, y = 44, w = 1920, h = 1036 } })
    assert.is_true(rec.has_text("PROMVIEW"))
    assert.is_true(rec.has_text("critical"))
    local xa, ya = pos(rec, "Alert1")
    local xs = pos(rec, "api")
    assert.is_truthy(xa and xs)
    assert.is_true(xa < 200 and xs > 1920 - 240)
    local _, yt = pos(rec, "PROMVIEW")
    assert.is_true(yt > 44 and ya > yt) -- below the bar, under the header
  end)

  it("groups alerts by name, with their count and where they fire", function()
    local list = {}
    for i = 1, 3 do
      list[i] = alert({ id = tostring(i), labels = { alertname = "DiskFull", instance = "db-" .. i },
        startsAt = ("2026-08-14T1%d:00:00Z"):format(i) })
    end
    list[4] = alert({ id = "4", severity = "critical", labels = { alertname = "Down", instance = "web" } })
    local s = P.parse(H.encode({ total = 4, alerts = list }))
    assert.are.equal(2, #s.groups)
    assert.are.equal("Down", s.groups[1].name)
    assert.are.equal(3, s.groups[2].count)
    assert.are.same({ "db-3", "db-2", "db-1" }, s.groups[2].where) -- newest first
    s.ok = true
    R.set_alerts(s)
    local rec = draw()
    assert.is_true(rec.has_text("×3"))
    assert.is_true(rec.has_text("db-2"))
  end)

  it("shows alerts with no session at all", function()
    R.set_alerts(snapshot(1))
    assert.is_true(draw().has_text("Alert1"))
  end)

  it("says when nothing is firing, and when the server can't be reached", function()
    R.set_alerts(snapshot(0))
    assert.is_true(draw().has_text("No firing alerts"))
    local s = snapshot(1)
    s.ok, s.error = false, "Failed to connect"
    R.set_alerts(s)
    local rec = draw()
    assert.is_truthy(rec.text_matching("^unreachable"))
    assert.is_true(rec.has_text("Alert1")) -- the last known alerts stay
  end)

  it("asks to sign in again when the session expired", function()
    local s = snapshot(1)
    s.ok, s.error, s.auth = false, "sign in needed", true
    R.set_alerts(s)
    assert.is_truthy(draw().text_matching("sign in needed: run constellation%-promview%-login"))
    -- Alerts from promview-desktop: signing in happens from its tray, on screen and locked.
    s.via = "desktop"
    assert.is_truthy(draw().text_matching("sign in needed: sign in from the Promview tray"))
    assert.is_true(R.write_alerts(s))
    R.set_alerts(R.read_alerts())
    assert.is_truthy(draw({ private = true }).text_matching("sign in from the Promview tray"))
  end)

  it("caps the cards to the screen and says how many more", function()
    R.set_alerts(snapshot(60))
    assert.is_truthy(draw().text_matching("^%+%d+ more alert names$"))
  end)

  it("shows the same board on the lock screen", function()
    R.set_alerts(snapshot(3))
    local rec = draw({ private = true })
    assert.is_true(rec.has_text("critical"))
    assert.is_true(rec.has_text("Alert1"))
    assert.is_true(rec.has_text("host2"))
  end)

  it("hands the whole board to the lock screen through the cache", function()
    assert.is_nil(R.read_alerts())
    local s = snapshot(3)
    s.fetched = 1234
    s.groups[1].where[1] = 'quote " back\\slash\nnewline'
    assert.is_true(R.write_alerts(s))
    local c = R.read_alerts()
    assert.is_true(c.ok)
    assert.are.equal(1234, c.fetched)
    assert.are.equal(3, c.total)
    assert.are.same({ critical = 1, warning = 2, info = 0 }, c.counts)
    assert.are.equal(3, #c.groups)
    assert.are.equal("Alert1", c.groups[1].name)
    assert.are.equal('quote " back\\slash\nnewline', c.groups[1].where[1])
    R.set_alerts(c)
    local rec = draw({ private = true })
    assert.is_true(rec.has_text("Alert2"))
    assert.is_nil(rec.text_matching("No firing"))
    assert.is_true(R.write_alerts(nil)) -- Promview turned off: no stale board on the lock screen
    assert.is_nil(R.read_alerts())
  end)

  it("cuts long names to the card", function()
    local s = snapshot(1)
    s.groups[1].name = string.rep("é", 200)
    R.set_alerts(s)
    local cr, rec = H.recorder()
    -- Monospace stand-in: 8px per character.
    function cr.text_extents(_, str) return { width = 8 * select(2, str:gsub("[^\128-\191]", "")) } end
    R.draw(cr, 1920, 1080, { layout = "hud" })
    local name = rec.text_matching("^é")
    assert.is_truthy(name:match("…$"))
    assert.is_true(#name < 200)
  end)
end)
