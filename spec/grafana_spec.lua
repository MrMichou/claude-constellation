-- Specs for grafana.lua (config, request, `/api/ds/query` parsing) and the Grafana graphs of the HUD.
local H = require("spec.helpers")

local function grafana() return dofile(H.MODULE_DIR .. "grafana.lua") end
local function promview() return dofile(H.MODULE_DIR .. "promview.lua") end

-- A `/api/ds/query` answer: results = { G1 = {frames = ...} | {error = ...}, ... }.
local function frame(times, columns)
  local fields, values = { { name = "Time", type = "time" } }, { times }
  for _, c in ipairs(columns) do
    fields[#fields + 1] = { name = "Value", type = "number", labels = c.labels, config = c.config }
    values[#values + 1] = c.values
  end
  return { schema = { fields = fields }, data = { values = values } }
end

local CONF = [[
url = http://graf:3000/   # trailing slash dropped
interval = 5
range = 30m
points = 1000

[CPU api]
datasource = PROM1
expr = sum(rate(cpu{app="api", path=~"a|b"}[5m]))
unit = %
warn = 70
crit = 90

[No expr]
datasource = PROM1

[Disk free]
datasource = PROM1
expr = node_filesystem_free_bytes # not a comment: expr keeps everything
legend = {{instance}}
warn = 20
crit = 10
]]

describe("grafana.lua", function()
  local G, dir
  before_each(function()
    G = grafana()
    dir = H.tmpdir()
  end)
  after_each(function() H.rmrf(dir) end)

  describe("read_config", function()
    it("is off without a url, or without a complete graph", function()
      assert.is_nil(G.read_config(dir .. "missing.conf"))
      H.write(dir .. "a.conf", "[CPU]\ndatasource = x\nexpr = up\n")
      assert.is_nil(G.read_config(dir .. "a.conf"))
      H.write(dir .. "b.conf", "url = http://g\n[CPU]\ndatasource = x\n")
      assert.is_nil(G.read_config(dir .. "b.conf"))
    end)

    it("reads one graph per section, skips incomplete ones and clamps the numbers", function()
      H.write(dir .. "g.conf", CONF)
      local cfg = G.read_config(dir .. "g.conf")
      assert.are.equal("http://graf:3000", cfg.url)
      assert.are.equal(15, cfg.interval)
      assert.are.equal(500, cfg.points)
      assert.are.equal(1800, cfg.range_s)
      assert.are.equal(2, #cfg.graphs)
      local g = cfg.graphs[1]
      assert.are.same({ "CPU api", "PROM1", "%", 70, 90 }, { g.title, g.datasource, g.unit, g.warn, g.crit })
      assert.are.equal('sum(rate(cpu{app="api", path=~"a|b"}[5m]))', g.expr)
      assert.are.equal("node_filesystem_free_bytes # not a comment: expr keeps everything",
        cfg.graphs[2].expr)
    end)
  end)

  it("asks for every graph in one escaped request", function()
    H.write(dir .. "g.conf", CONF)
    local cfg = G.read_config(dir .. "g.conf")
    local json = dofile(H.MODULE_DIR .. "json.lua")
    local body = json.decode(G.body(cfg))
    assert.are.equal("now-30m", body.from)
    assert.are.equal(2, #body.queries)
    local q = body.queries[1]
    assert.are.equal("G1", q.refId)
    assert.are.equal("PROM1", q.datasource.uid)
    assert.are.equal(cfg.graphs[1].expr, q.expr)
    assert.are.equal(500, q.maxDataPoints)
    assert.are.equal(3000, q.intervalMs) -- 1800 s / 500 points, in whole seconds
  end)

  describe("command", function()
    local function run(token)
      H.write(dir .. "bin/curl", "#!/bin/sh\necho \"args: $*\"\n"
        .. "case \"$*\" in *@-*) echo \"stdin: $(/bin/cat)\";; esac\n")
      H.write(dir .. "bin/secret-tool", token
        and ("#!/bin/sh\n[ \"$*\" = 'lookup service claude-constellation-grafana server http://g' ] "
          .. "&& printf %s '" .. token .. "'\n")
        or "#!/bin/sh\nexit 1\n")
      os.execute("chmod +x '" .. dir .. "bin/curl' '" .. dir .. "bin/secret-tool'")
      local cfg = { url = "http://g", range = "1h", range_s = 3600, points = 60,
        graphs = { { title = "a", datasource = "d", expr = "up" } } }
      local quoted = {}
      for i, a in ipairs(G.command(cfg)) do quoted[i] = "'" .. a:gsub("'", "'\\''") .. "'" end
      local f = io.popen("PATH='" .. dir .. "bin:/usr/bin:/bin' " .. table.concat(quoted, " "))
      local out = f:read("*a"); f:close()
      return out
    end

    it("posts the queries with the stored token on stdin, never on the command line", function()
      local out = run("glsa_s3cret")
      assert.is_truthy(out:find("stdin: Authorization: Bearer glsa_s3cret", 1, true))
      assert.is_nil(out:match("args:[^\n]*s3cret"))
      assert.is_truthy(out:find("http://g/api/ds/query", 1, true))
      assert.is_truthy(out:find("--data-binary", 1, true))
    end)

    it("polls anonymously when there is no token", function()
      assert.is_nil(run(nil):find("Authorization", 1, true))
    end)
  end)

  it("tells a token problem from an unreachable server", function()
    local http = "curl: (22) The requested URL returned error: "
    assert.are.same({ "token needed", true }, { G.failure(http .. "401\n", 22) })
    assert.are.same({ "token needed", true }, { G.failure(http .. "403\n", 22) })
    assert.are.same({ "Could not resolve host: g", false },
      { G.failure("curl: (6) Could not resolve host: g\n", 6) })
  end)

  describe("parse", function()
    local cfg
    before_each(function()
      H.write(dir .. "g.conf", CONF)
      cfg = G.read_config(dir .. "g.conf")
    end)

    it("rejects what isn't a query answer", function()
      assert.is_nil(G.parse("<html>", cfg))
      assert.is_nil(G.parse('{"message":"nope"}', cfg))
    end)

    it("turns frames into series, skipping nulls, with the latest value and thresholds", function()
      local t0 = 1700000000000
      local body = H.encode({ results = {
        G1 = { frames = { frame({ t0, t0 + 60000, t0 + 120000 }, { { values = { 10, 50, 95 } } }) } },
        G2 = { frames = {
          frame({ t0, t0 + 60000 }, { { labels = { instance = "db1" }, values = { 30, 15 } } }),
          frame({ t0, t0 + 60000 }, { { labels = { instance = "db2" }, values = { 40, 45 } } }),
        } },
      } }):gsub("%[10,", "[null,") -- a gap in the first series
      local s = G.parse(body, cfg, 1700000200)
      assert.are.equal(1700000200 - 1800, s.from)
      local cpu = s.graphs[1]
      assert.are.same({ 50, 95 }, cpu.series[1].vs)
      assert.are.same({ 1700000060, 1700000120 }, cpu.series[1].ts)
      assert.are.same({ 95, 50, 95 }, { cpu.last, cpu.min, cpu.max })
      assert.are.equal("95%", cpu.value)
      assert.are.equal("crit", cpu.level)
      local disk = s.graphs[2]
      assert.are.equal(2, #disk.series)
      assert.are.same({ "db1", "db2" }, { disk.series[1].label, disk.series[2].label })
      assert.are.equal(15, disk.last)
      assert.are.equal("warn", disk.level) -- crit below warn: lower is worse
    end)

    it("keeps a failed query's error on its own graph", function()
      local body = H.encode({ results = { G1 = { error = "parse error\nat char 3", status = 400 } } })
      local s = G.parse(body, cfg)
      assert.are.equal("parse error", s.graphs[1].error)
      assert.are.equal("no result", s.graphs[2].error)
      assert.are.equal("–", s.graphs[1].value)
    end)
  end)

  it("formats values for a small card", function()
    assert.are.equal("0", G.format(0))
    assert.are.equal("42.5%", G.format(42.5, "%"))
    assert.are.equal("123 ms", G.format(123.4, "ms"))
    assert.are.equal("0.25 s", G.format(0.25, "s"))
    assert.are.equal("12.3kB", G.format(12345, "B"))
    assert.are.equal("1.5M", G.format(1.5e6))
    assert.are.equal("–", G.format(nil))
  end)
end)

describe("HUD with Grafana", function()
  local R, G, data, cache
  before_each(function()
    data, cache = H.tmpdir(), H.tmpdir()
    R = H.renderer()
    R.set_dirs(data, H.tmpdir(), H.tmpdir(), H.tmpdir())
    R.set_cache_dir(cache)
    G = grafana()
  end)
  after_each(function() H.rmrf(data); H.rmrf(cache) end)

  local function draw(opts)
    local cr, rec = H.recorder()
    opts = opts or {}
    opts.layout = "hud"
    R.draw(cr, 1920, 1080, opts)
    return rec
  end

  local function pos(rec, text)
    for i, t in ipairs(rec.texts) do
      if t == text then
        local x, y = rec.text_pos[i]:match("^([^,]+),(.+)$")
        return tonumber(x), tonumber(y)
      end
    end
  end

  -- n graphs of a few points each, as G.parse leaves them.
  local function metrics(n)
    local now = os.time()
    local cfg = { range_s = 3600, graphs = {} }
    local frames = {}
    for i = 1, n do
      cfg.graphs[i] = { title = "Graph" .. i, unit = "%", warn = 50, crit = 90 }
      frames["G" .. i] = { frames = { frame({ (now - 120) * 1000, (now - 60) * 1000, now * 1000 },
        { { values = { 10, 20 + i, 30 + i } } }) } }
    end
    local s = G.parse(H.encode({ results = frames }), cfg, now)
    s.ok, s.fetched = true, now
    return s
  end

  local function alerts()
    local P = promview()
    local s = P.parse(H.encode({ total = 1, alerts = { { id = "1", status = "firing", severity = "critical",
      startsAt = "2026-08-14T12:00:00Z", labels = { alertname = "Down", instance = "web" },
      annotations = {} } } }))
    s.ok = true
    return s
  end

  it("draws nothing extra while Grafana is off", function()
    assert.is_nil(draw().text_matching("GRAFANA"))
  end)

  it("fills the board with graphs when there is no Promview", function()
    R.set_metrics(metrics(3))
    local rec = draw()
    assert.is_true(rec.has_text("GRAFANA"))
    assert.is_true(rec.has_text("Graph1"))
    assert.is_true(rec.has_text("31%"))
    assert.is_true(rec.has_text("min 10% · max 31%"))
    assert.is_nil(rec.text_matching("PROMVIEW"))
  end)

  it("sits right of the Promview counts, above the alert cards", function()
    R.set_alerts(alerts())
    R.set_metrics(metrics(2))
    local rec = draw({ area = { x = 0, y = 44, w = 1920, h = 1036 } })
    local xp, yp = pos(rec, "PROMVIEW")
    local xg, yg = pos(rec, "GRAFANA")
    local xc = pos(rec, "critical")
    local _, ya = pos(rec, "Down")
    local x1, y1 = pos(rec, "Graph1")
    assert.is_truthy(xp and xg and xc and ya and x1)
    assert.are.equal(yp, yg) -- same header line
    assert.is_true(xg > xc + 100)
    assert.is_true(y1 < ya) -- the graphs end before the alert cards start
    assert.is_nil(rec.text_matching("^min ")) -- compact cards
  end)

  it("says when the server can't be reached or wants a token, keeping the last graphs", function()
    local s = metrics(1)
    s.ok, s.error = false, "Could not resolve host"
    R.set_metrics(s)
    local rec = draw()
    assert.is_truthy(rec.text_matching("^unreachable"))
    assert.is_true(rec.has_text("Graph1"))
    s.auth = true
    assert.is_truthy(draw().text_matching("token needed: run constellation%-grafana%-token"))
  end)

  it("shows a query's own error on its card", function()
    local s = metrics(1)
    s.graphs[1].series, s.graphs[1].error = {}, "bad expr"
    R.set_metrics(s)
    assert.is_true(draw().has_text("error · bad expr"))
  end)

  it("caps the cards and says how many more", function()
    R.set_metrics(metrics(60))
    assert.is_truthy(draw().text_matching("^%+%d+ more graphs$"))
    R.set_alerts(alerts())
    assert.is_truthy(draw().text_matching("^%+%d+ more graphs$"))
  end)

  it("hands the graphs to the lock screen through the cache", function()
    assert.is_nil(R.read_metrics())
    local s = metrics(2)
    s.graphs[1].title = 'quote " back\\slash'
    s.graphs[2].series[1].ts, s.graphs[2].series[1].vs = {}, {}
    assert.is_true(R.write_metrics(s))
    local c = R.read_metrics()
    assert.is_true(c.ok)
    assert.are.equal(s.fetched, c.fetched)
    assert.are.equal(2, #c.graphs)
    assert.are.equal('quote " back\\slash', c.graphs[1].title)
    assert.are.same(s.graphs[1].series[1].vs, c.graphs[1].series[1].vs)
    assert.are.same({}, c.graphs[2].series[1].vs)
    R.set_metrics(c)
    local rec = draw({ private = true })
    assert.is_true(rec.has_text("32%"))
    assert.is_true(R.write_metrics(nil))
    assert.is_nil(R.read_metrics())
  end)

  it("draws real cairo frames, animated and static", function()
    local cairo = require("lgi").cairo
    R.set_alerts(alerts())
    R.set_metrics(metrics(4))
    for _, static in ipairs({ false, true }) do
      local surf = cairo.ImageSurface.create(cairo.Format.RGB24, 1920, 1080)
      R.draw(cairo.Context(surf), 1920, 1080, { layout = "hud", static = static })
      surf:finish()
    end
    R.set_alerts(nil)
    local surf = cairo.ImageSurface.create(cairo.Format.RGB24, 1920, 1080)
    R.draw(cairo.Context(surf), 1920, 1080, { layout = "hud" })
    surf:finish()
  end)
end)
