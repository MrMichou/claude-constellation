-- Specs for render.lua: session loading, power detection, palette, and what draw() puts on
-- screen (labels, private mode, shared-resource links, battery freeze, eco mode), asserted through a
-- recording cairo context, plus a real cairo smoke test and sprite asset checks.
local H = require("spec.helpers")
local lgi = require("lgi")
local cairo, GLib = lgi.cairo, lgi.GLib
local GdkPixbuf = lgi.require("GdkPixbuf", "2.0")

describe("render.lua", function()
  local R, data, power, registry, proc

  before_each(function()
    data, power, registry, proc = H.tmpdir(), H.tmpdir(), H.tmpdir(), H.tmpdir()
    R = H.renderer()
    R.set_dirs(data, power, registry, proc)
  end)

  after_each(function()
    H.rmrf(data)
    H.rmrf(power)
    H.rmrf(registry)
    H.rmrf(proc)
  end)

  local function draw(opts)
    local cr, rec = H.recorder()
    R.draw(cr, 1920, 1080, opts)
    return rec
  end

  describe("read_sessions", function()
    it("returns false with no sessions", function()
      assert.is_false(R.read_sessions())
    end)

    it("reports activity for thinking, tool and permission sessions", function()
      for _, st in ipairs({ "thinking", "tool", "permission" }) do
        H.rmrf(data)
        H.session(data, "s1", { state = st })
        assert.is_true(R.read_sessions(), st)
      end
    end)

    it("does not report done, waiting or idle sessions as active", function()
      H.session(data, "a", { state = "done" })
      H.session(data, "b", { state = "waiting" })
      H.session(data, "c", { state = "idle" })
      assert.is_false(R.read_sessions())
    end)

    it("hides sessions silent for more than 3 hours", function()
      H.session(data, "old", { project = "old-proj", ts = os.time() - 4 * 3600 })
      H.session(data, "new", { project = "new-proj" })
      R.read_sessions()
      local rec = draw()
      assert.is_true(rec.has_text("new-proj"))
      assert.is_false(rec.has_text("old-proj"))
    end)

    it("skips corrupt and non-json files", function()
      H.write(data .. "bad.json", "{not json")
      H.write(data .. "notes.txt", "hello")
      H.session(data, "ok", { project = "fine" })
      R.read_sessions()
      local rec = draw()
      assert.is_true(rec.has_text("fine"))
      assert.are.equal(2, #rec.texts) -- project + state of the single valid session
    end)

    it("forgets sessions whose file was removed", function()
      H.session(data, "s1", { project = "gone" })
      R.read_sessions()
      os.remove(data .. "s1.json")
      R.read_sessions()
      assert.are.equal(0, #draw().texts)
    end)

    it("returns the number of shown sessions", function()
      H.session(data, "a")
      H.session(data, "b", { ts = os.time() - 4 * 3600 })
      H.session(data, "c")
      assert.are.same({ false, 2 }, { R.read_sessions() })
    end)

    it("picks up a rewritten session file, even at the same size", function()
      H.session(data, "s1", { project = "aaa" })
      R.read_sessions()
      GLib.usleep(10000)
      H.session(data, "s1", { project = "bbb" })
      R.read_sessions()
      local rec = draw()
      assert.is_true(rec.has_text("bbb"))
      assert.is_false(rec.has_text("aaa"))
    end)

    it("copes with a missing data directory", function()
      R.set_dirs(data .. "nope/")
      assert.is_false(R.read_sessions())
    end)
  end)

  describe("read_sessions from Claude Code's registry", function()
    it("shows a live session with no hook file yet", function()
      H.registry(registry, proc, 4242, { sessionId = "r1", cwd = "/home/me/reg-proj" })
      assert.are.same({ false, 1 }, { R.read_sessions() })
      assert.is_true(draw().has_text("reg-proj"))
    end)

    it("reports a busy session as active", function()
      H.registry(registry, proc, 4242, { sessionId = "r1", status = "busy" })
      assert.is_true(R.read_sessions())
    end)

    it("ignores dead processes, reused pids and non-interactive sessions", function()
      H.registry(registry, proc, 1, { sessionId = "gone" })
      H.rmrf(proc .. "1")
      H.registry(registry, proc, 2, { sessionId = "reused" })
      H.write(proc .. "2/stat", "2 (other) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 999 0\n")
      H.registry(registry, proc, 3, { sessionId = "bg", kind = "background" })
      assert.are.same({ false, 0 }, { R.read_sessions() })
    end)

    it("prefers the hook file, then falls back when it goes away", function()
      H.registry(registry, proc, 4242, { sessionId = "s1", cwd = "/x/reg-name" })
      H.session(data, "s1", { project = "hook-name", state = "tool", tool = "Bash" })
      assert.are.same({ true, 1 }, { R.read_sessions() })
      assert.is_true(draw().has_text("hook-name"))
      os.remove(data .. "s1.json")
      assert.are.same({ false, 1 }, { R.read_sessions() })
      local rec = draw()
      assert.is_true(rec.has_text("reg-name"))
      assert.is_false(rec.has_text("hook-name"))
    end)

    it("drops a session once its process exits", function()
      H.registry(registry, proc, 4242, { sessionId = "r1", cwd = "/x/short-lived" })
      assert.are.same({ false, 1 }, { R.read_sessions() })
      H.rmrf(proc .. "4242")
      assert.are.same({ false, 0 }, { R.read_sessions() })
      assert.is_false(draw().has_text("short-lived"))
    end)

    it("follows an entry rewritten from idle to busy", function()
      H.registry(registry, proc, 4242, { sessionId = "r1" })
      assert.is_false(R.read_sessions())
      GLib.usleep(10000)
      H.registry(registry, proc, 4242, { sessionId = "r1", status = "busy" })
      assert.is_true(R.read_sessions())
      assert.is_true(draw().has_text("thinking"))
    end)

    it("skips corrupt and incomplete entries without failing", function()
      H.write(registry .. "10.json", "{not json")
      H.registry(registry, proc, 11, { sessionId = 42 })   -- not a string
      H.registry(registry, proc, 12, { procStart = false }) -- no start time to check
      H.write(registry .. "notes.txt", "hello")
      H.registry(registry, proc, 13, { sessionId = "ok", cwd = "/x/valid" })
      assert.are.same({ false, 1 }, { R.read_sessions() })
      assert.is_true(draw().has_text("valid"))
    end)

    it("draws a registry-only session in every layout, named by its id without a cwd", function()
      H.registry(registry, proc, 4242, { sessionId = "abcdef123456", cwd = "/" })
      R.read_sessions()
      for _, layout in ipairs(R.LAYOUTS) do
        assert.is_true(draw({ layout = layout }).has_text("abcdef12"), layout)
      end
    end)

    it("parses process names holding spaces and parentheses", function()
      H.registry(registry, proc, 7, { sessionId = "r1", cwd = "/x/odd" }, "my (weird) proc")
      R.read_sessions()
      assert.is_true(draw().has_text("odd"))
    end)
  end)

  describe("on_battery", function()
    it("is true when the system battery discharges", function()
      H.supply(power, "AC", { type = "Mains", online = "0" })
      H.supply(power, "BAT0", { type = "Battery", status = "Discharging" })
      assert.is_true(R.on_battery())
    end)

    it("is false when charging, full or not charging", function()
      for _, st in ipairs({ "Charging", "Full", "Not charging" }) do
        H.rmrf(power)
        H.supply(power, "BAT0", { type = "Battery", status = st })
        assert.is_false(R.on_battery(), st)
      end
    end)

    it("ignores peripheral batteries (scope Device)", function()
      H.supply(power, "BAT0", { type = "Battery", status = "Full" })
      H.supply(power, "hidpp_battery_0", { type = "Battery", scope = "Device", status = "Discharging" })
      assert.is_false(R.on_battery())
    end)

    it("is false without any battery or power supply directory", function()
      H.supply(power, "AC", { type = "Mains", online = "1" })
      assert.is_false(R.on_battery())
      R.set_dirs(nil, power .. "missing/")
      assert.is_false(R.on_battery())
    end)
  end)

  describe("render backend", function()
    local drm
    before_each(function()
      drm = H.tmpdir()
      R.set_dirs(nil, nil, nil, nil, drm)
    end)
    after_each(function() H.rmrf(drm) end)

    local function card(name, driver)
      H.write(drm .. name .. "/device/uevent", "DRIVER=" .. driver .. "\nPCI_CLASS=30000\n")
    end

    it("finds a GPU bound to a DRM card", function()
      card("card1", "nvidia")
      assert.is_true(R.has_gpu())
      assert.are.equal("gpu", R.resolve_backend("auto"))
    end)

    it("ignores framebuffer and virtual display drivers, and connectors", function()
      card("card0", "simpledrm")
      card("card1", "vkms")
      card("card0-HDMI-A-1", "amdgpu")
      assert.is_false(R.has_gpu())
      assert.are.equal("cpu", R.resolve_backend("auto"))
    end)

    it("prefers the GPU when the machine has both kinds", function()
      card("card0", "simpledrm")
      card("card1", "i915")
      assert.are.equal("gpu", R.resolve_backend("auto"))
    end)

    it("falls back to the CPU without any DRM device", function()
      R.set_dirs(nil, nil, nil, nil, drm .. "missing/")
      assert.are.equal("cpu", R.resolve_backend("auto"))
      assert.are.equal("cpu", R.resolve_backend(nil))
    end)

    it("honours a forced choice whatever the hardware", function()
      assert.are.equal("gpu", R.resolve_backend("gpu"))
      card("card1", "nvidia")
      assert.are.equal("cpu", R.resolve_backend("cpu"))
    end)
  end)

  describe("palette", function()
    local function bg_of(rec) return rec.colors[1] end

    it("paints the background with the palette bg", function()
      R.set_palette({ bg = "#336699" })
      local bg = bg_of(draw())
      assert.are.near(0x33 / 255, bg[1], 1e-6)
      assert.are.near(0x66 / 255, bg[2], 1e-6)
      assert.are.near(0x99 / 255, bg[3], 1e-6)
    end)

    it("accepts #rgb and #rrggbbaa", function()
      R.set_palette({ bg = "#fff" })
      assert.are.same({ 1, 1, 1, 1 }, bg_of(draw()))
      R.set_palette({ bg = "#00000080" })
      assert.are.same({ 0, 0, 0, 1 }, bg_of(draw()))
    end)

    it("falls back to the default for unparsable colours", function()
      R.set_palette({ bg = "black", fg = 42 })
      assert.are.same({ 0, 0, 0, 1 }, bg_of(draw())) -- default bg is #000000
    end)
  end)

  describe("draw labels", function()
    before_each(function()
      H.session(data, "s1", {
        project = "api", state = "tool", tool = "Bash", kind = "shell", target = "cargo test",
        history = {
          { tool = "Read", kind = "file", target = "…/src/main.rs", ts = os.time() },
          { tool = "Bash", kind = "shell", target = "cargo test", ts = os.time() },
        },
      })
      R.read_sessions()
    end)

    it("shows the project, the running tool and the satellite targets", function()
      local rec = draw()
      assert.is_true(rec.has_text("api"))
      assert.is_true(rec.has_text("Bash · cargo test"))
      assert.is_true(rec.has_text("…/src/main.rs"))
    end)

    it("private mode hides targets and the running tool but keeps project and state", function()
      local rec = draw({ private = true })
      assert.is_true(rec.has_text("api"))
      assert.is_true(rec.has_text("tool"))
      assert.is_nil(rec.text_matching("cargo"))
      assert.is_nil(rec.text_matching("main%.rs"))
    end)

    it("falls back to the session id prefix without a project", function()
      H.session(data, "abcdef123456", { project = "" })
      R.read_sessions()
      assert.is_true(draw().has_text("abcdef12"))
    end)

    it("draws a node for every session state, sprites or not", function()
      for _, st in ipairs({ "thinking", "tool", "permission", "waiting", "done", "idle" }) do
        H.session(data, "s-" .. st, { state = st })
      end
      H.session(data, "stale", { state = "done", ts = os.time() - 20 * 60 })
      R.read_sessions()
      assert.has_no.errors(function() draw() end)
      assert.has_no.errors(function() draw({ static = true, private = true }) end)
    end)
  end)

  describe("shared-resource links", function()
    local function link(kind, label, ts) return { kind = kind, label = label, ts = ts or os.time() } end

    it("links two sessions that drive the same tmux session", function()
      H.session(data, "a", { links = { ["tmux:0"] = link("shell", "tmux 0") } })
      H.session(data, "b", { links = { ["tmux:0"] = link("shell", "tmux 0") } })
      R.read_sessions()
      assert.is_true(draw().has_text("⇄ tmux 0"))
    end)

    it("joins up to two shared resources in one label", function()
      local shared = {
        ["file:/x/deploy.yml"] = link("file", "deploy.yml"),
        ["tmux:0"] = link("shell", "tmux 0"),
        ["tmux:1"] = link("shell", "tmux 1"),
      }
      H.session(data, "a", { links = shared })
      H.session(data, "b", { links = shared })
      R.read_sessions()
      assert.is_true(draw().has_text("⇄ deploy.yml · tmux 0"))
    end)

    it("shows only the resource kind in private mode", function()
      H.session(data, "a", { links = { ["file:/secret/plan.md"] = link("file", "plan.md") } })
      H.session(data, "b", { links = { ["file:/secret/plan.md"] = link("file", "plan.md") } })
      R.read_sessions()
      local rec = draw({ private = true })
      assert.is_true(rec.has_text("⇄ file"))
      assert.is_nil(rec.text_matching("plan"))
    end)

    it("does not link different resources or a lone session", function()
      H.session(data, "a", { links = { ["tmux:0"] = link("shell", "tmux 0") } })
      H.session(data, "b", { links = { ["tmux:1"] = link("shell", "tmux 1") } })
      R.read_sessions()
      assert.is_nil(draw().text_matching("⇄"))
    end)

    it("ignores uses older than 30 minutes", function()
      H.session(data, "a", { links = { ["tmux:0"] = link("shell", "tmux 0", os.time() - 31 * 60) } })
      H.session(data, "b", { links = { ["tmux:0"] = link("shell", "tmux 0") } })
      R.read_sessions()
      assert.is_nil(draw().text_matching("⇄"))
    end)

    it("draws one link per pair of sessions", function()
      for _, sid in ipairs({ "a", "b", "c" }) do
        H.session(data, sid, { links = { ["tmux:0"] = link("shell", "tmux 0") } })
      end
      R.read_sessions()
      local n = 0
      for _, t in ipairs(draw().texts) do if t == "⇄ tmux 0" then n = n + 1 end end
      assert.are.equal(3, n)
    end)
  end)

  describe("battery freeze (static)", function()
    -- Where the labels are drawn: they follow the nodes.
    local function node_positions(rec)
      assert.is_true(#rec.text_pos > 0)
      return table.concat(rec.text_pos, ";")
    end

    before_each(function()
      H.session(data, "a", { state = "thinking" })
      H.session(data, "b", { state = "tool", kind = "shell" })
      R.read_sessions()
    end)

    it("keeps nodes still over time", function()
      local first = node_positions(draw({ static = true }))
      GLib.usleep(300000)
      assert.are.equal(first, node_positions(draw({ static = true })))
    end)

    it("lets nodes drift and pulse when not static", function()
      draw()
      local first = node_positions(draw())
      GLib.usleep(300000)
      assert.are_not.equal(first, node_positions(draw()))
    end)
  end)

  describe("eco mode (still)", function()
    -- The surfaces painted in a frame: glows and the Clawd emote frames, in order.
    local function painted(opts)
      local cr = H.recorder()
      local seen = {}
      function cr.set_source_surface(_, surf) seen[#seen + 1] = tostring(surf) end
      R.draw(cr, 1920, 1080, opts)
      assert.is_true(#seen > 0)
      return table.concat(seen, ";")
    end

    before_each(function()
      H.session(data, "a", { state = "thinking" })
      R.read_sessions()
    end)

    it("freezes the Clawd emotes too", function()
      local first = painted({ still = true })
      GLib.usleep(300000)
      assert.are.equal(first, painted({ still = true }))
    end)

    it("static alone still animates them", function()
      local first = painted({ static = true })
      GLib.usleep(300000)
      assert.are_not.equal(first, painted({ static = true }))
    end)

    it("is on when asked, or in auto on battery", function()
      assert.is_true(R.eco_active("on", false))
      assert.is_true(R.eco_active("auto", true))
      assert.is_false(R.eco_active("auto", false))
      assert.is_false(R.eco_active("off", true))
    end)
  end)

  describe("layouts", function()
    local function link(kind, label) return { kind = kind, label = label, ts = os.time() } end
    local now = os.time()

    before_each(function()
      local shared = { ["file:/w/ci/deploy.yml"] = link("file", "deploy.yml") }
      H.session(data, "a", {
        project = "api", state = "tool", tool = "Bash", kind = "shell", target = "cargo test",
        links = shared,
        history = {
          { kind = "file", target = "…/ci/deploy.yml", ts = now },
          { kind = "shell", target = "cargo test", ts = now },
        },
        timeline = { { k = "file", s = now - 300, e = now - 290 }, { k = "shell", s = now - 5 } },
      })
      H.session(data, "b", {
        project = "infra", state = "permission", links = shared,
        history = { { kind = "file", target = "…/ci/deploy.yml", ts = now } },
      })
      H.session(data, "c", { project = "docs", state = "waiting", ts = now - 240 })
      H.session(data, "d", { project = "dots", state = "done", ts = now - 20 * 60 })
      R.read_sessions()
    end)

    it("lists the layouts, constellation first", function()
      assert.are.same({ "constellation", "lanes", "cards", "resources", "kanban", "radar", "strip", "hud",
        "popup" }, R.LAYOUTS)
    end)

    it("kanban, strip, hud and popup put the session that needs you first", function()
      for _, layout in ipairs({ "kanban", "strip", "hud", "popup" }) do
        local texts = draw({ layout = layout }).texts
        local first_name
        for _, t in ipairs(texts) do
          if t == "api" or t == "infra" or t == "docs" or t == "dots" then first_name = t; break end
        end
        assert.are.equal("infra", first_name, layout)
      end
    end)

    it("radar centres the most urgent session", function()
      assert.is_true(draw({ layout = "radar" }).has_text("infra needs you"))
    end)

    it("draws every layout, animated or static and private", function()
      for _, layout in ipairs(R.LAYOUTS) do
        local rec = draw({ layout = layout })
        assert.is_true(rec.has_text("api"), layout)
        assert.is_true(rec.has_text("infra"), layout)
        assert.has_no.errors(function() draw({ layout = layout, static = true, private = true }) end)
      end
    end)

    it("hides targets and commands in private mode, in every layout", function()
      for _, layout in ipairs(R.LAYOUTS) do
        local rec = draw({ layout = layout, private = true })
        assert.is_nil(rec.text_matching("cargo"), layout)
        assert.is_nil(rec.text_matching("deploy"), layout)
      end
    end)

    it("falls back to the constellation for an unknown layout", function()
      assert.are.same(draw().texts, draw({ layout = "nope" }).texts)
    end)

    it("lanes show how long a session has been waiting", function()
      assert.is_true(draw({ layout = "lanes" }).has_text("waiting 4m"))
    end)

    it("cards add a summary tile in a free slot", function()
      assert.is_nil(draw({ layout = "cards" }).text_matching("sessions$")) -- 2x2 grid, full
      H.session(data, "e", { project = "web" })
      R.read_sessions()
      local rec = draw({ layout = "cards" })
      assert.is_true(rec.has_text("5 sessions"))
      assert.is_true(rec.has_text("1 awaiting permission"))
    end)

    it("resources put a shared file between its sessions", function()
      local rec = draw({ layout = "resources" })
      assert.is_true(rec.has_text("deploy.yml"))
      assert.is_true(rec.has_text("⇄ 2 sessions"))
    end)
  end)

  describe("chosen layout", function()
    local cache
    before_each(function()
      cache = H.tmpdir()
      R.set_cache_dir(cache)
    end)
    after_each(function() H.rmrf(cache) end)

    it("defaults to the constellation", function()
      assert.are.equal("constellation", R.read_layout())
    end)

    it("backend defaults to auto, is remembered, and an unknown value falls back to auto", function()
      assert.are.equal("auto", R.read_backend())
      assert.is_true(R.write_backend("cpu"))
      assert.are.equal("cpu", R.read_backend())
      H.write(cache .. "backend", "tpu\n")
      assert.are.equal("auto", R.read_backend())
    end)

    it("eco mode defaults to auto, is remembered, and an unknown value falls back to auto", function()
      assert.are.equal("auto", R.read_eco())
      assert.is_true(R.write_eco("on"))
      assert.are.equal("on", R.read_eco())
      H.write(cache .. "eco", "max\n")
      assert.are.equal("auto", R.read_eco())
    end)

    it("is remembered, and an unknown value falls back to the default", function()
      assert.is_true(R.write_layout("cards"))
      assert.are.equal("cards", R.read_layout())
      H.write(cache .. "layout", "bogus\n")
      assert.are.equal("constellation", R.read_layout())
    end)
  end)

  describe("with real cairo", function()
    it("renders every layout", function()
      H.session(data, "s1", { state = "tool", kind = "shell", target = "ls",
        history = { { kind = "file", target = "a.txt", ts = os.time() } },
        timeline = { { k = "shell", s = os.time() - 5 } } })
      H.session(data, "s2", { state = "permission" })
      R.read_sessions()
      local surf = cairo.ImageSurface.create(cairo.Format.RGB24, 640, 360)
      local cr = cairo.Context(surf)
      for _, layout in ipairs(R.LAYOUTS) do
        R.draw(cr, 640, 360, { layout = layout })
        R.draw(cr, 640, 360, { layout = layout, static = true, private = true })
        assert.are.equal("SUCCESS", cr.status, layout)
      end
    end)

    it("renders every layout on either backend, onto image and non-image targets", function()
      H.session(data, "s1", { state = "tool", kind = "shell", target = "ls",
        history = { { kind = "file", target = "a.txt", ts = os.time() } } })
      H.session(data, "s2", { state = "permission" })
      R.read_sessions()
      for _, backend in ipairs({ "gpu", "cpu" }) do
        local surf = cairo.ImageSurface.create(cairo.Format.RGB24, 320, 200)
        local rec = cairo.RecordingSurface.create(cairo.Content.COLOR_ALPHA,
          cairo.Rectangle { x = 0, y = 0, width = 320, height = 200 })
        for _, target in ipairs({ surf, rec }) do
          local cr = cairo.Context(target)
          for _, layout in ipairs(R.LAYOUTS) do
            R.draw(cr, 320, 200, { layout = layout, backend = backend })
            assert.are.equal("SUCCESS", cr.status, backend .. " " .. layout)
          end
        end
      end
    end)

    it("renders a frame with the palette background", function()
      R.set_palette({ bg = "#204060" })
      H.session(data, "s1", { state = "thinking" })
      R.read_sessions()
      local surf = cairo.ImageSurface.create(cairo.Format.RGB24, 320, 200)
      R.draw(cairo.Context(surf), 320, 200, {})
      surf:flush()
      local path = data .. "frame.png"
      assert.are.equal("SUCCESS", surf:write_to_png(path))
      local pb = GdkPixbuf.Pixbuf.new_from_file(path)
      assert.are.equal(320, pb:get_width())
      assert.are.same({ 0x20, 0x40, 0x60 }, { pb:get_pixels():byte(1, 3) }) -- top-left RGB
    end)
  end)
end)

describe("sprite assets", function()
  local frames = H.MODULE_DIR .. "frames/"
  local json = dofile(H.MODULE_DIR .. "json.lua")
  local f = assert(io.open(frames .. "sprites.json"))
  local manifest = json.decode(f:read("*a"))
  f:close()

  for _, name in ipairs({ "clawd/thinking", "clawd/typing", "clawd/listening", "clawd/birthday",
    "clawd/sleeping", "crab" }) do
    it(name .. " is listed and its strip splits into equal cells", function()
      local n = manifest[name]
      assert.is_number(n)
      local sheet = cairo.ImageSurface.create_from_png(frames .. name .. ".png")
      assert.are.equal("SUCCESS", sheet.status)
      assert.are.equal(0, sheet:get_width() % n)
    end)
  end
end)
