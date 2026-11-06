-- Specs for obsidian.lua (vaults, wikilinks, the vault graph, touched notes) and the
-- obsi-constellation layout.
local H = require("spec.helpers")

local function obsidian() return dofile(H.MODULE_DIR .. "obsidian.lua") end

describe("obsidian.lua", function()
  local O, dir
  before_each(function()
    O, dir = obsidian(), H.tmpdir()
    O.CONF, O.OBSIDIAN_JSON = dir .. "obsidian.conf", dir .. "obsidian.json"
  end)
  after_each(function() H.rmrf(dir) end)

  describe("pinned vault", function()
    it("is auto with no file, and kept across reads once pinned", function()
      O.PIN = dir .. "obsidian-vault"
      assert.is_nil(O.pinned())
      local gen = O.pin_gen
      assert.is_true(O.set_pinned("/home/me/work/"))
      assert.are.equal("/home/me/work", O.pinned())
      assert.are.equal(gen + 1, O.pin_gen)
      O.set_pinned(nil)
      assert.is_nil(O.pinned())
    end)

    it("shows the pinned vault while it is one, else the one touched last, else the first", function()
      local list = { "/v/a", "/v/b", "/v/c" }
      assert.are.equal("/v/c", O.pick(list, "/v/b", "/v/c"))
      assert.are.equal("/v/b", O.pick(list, "/v/b", "/v/gone"))
      assert.are.equal("/v/b", O.pick(list, "/v/b", nil))
      assert.are.equal("/v/a", O.pick(list, nil, nil))
      assert.is_nil(O.pick({}, nil, "/v/a"))
    end)
  end)

  describe("vaults", function()
    it("lists Obsidian's vaults, the open one first, then the most recent", function()
      H.write(O.OBSIDIAN_JSON, H.encode({ vaults = {
        a = { path = "/v/old", ts = 1 }, b = { path = "/v/recent/", ts = 5 },
        c = { path = "/v/open", ts = 2, open = true },
      } }))
      assert.are.same({ "/v/open", "/v/recent", "/v/old" }, O.vaults())
    end)

    it("prefers the vault lines of obsidian.conf", function()
      H.write(O.OBSIDIAN_JSON, H.encode({ vaults = { a = { path = "/v/a", ts = 1 } } }))
      H.write(O.CONF, "# my brain\nvault = /home/me/brain/   # main\nvault=/home/me/work\n")
      assert.are.same({ "/home/me/brain", "/home/me/work" }, O.vaults())
    end)

    it("is empty without Obsidian nor config", function()
      assert.are.same({}, O.vaults())
    end)
  end)

  it("parses wikilinks, aliases, headings, embeds and markdown links", function()
    local links = O.parse_links("See [[Alpha]], [[Beta|the beta]], [[Gamma#Intro]], ![[Delta.md]]\n"
      .. "and [doc](Folder/Epsilon%20Two.md), not [site](https://x.io/a.md) nor [[ ]].")
    assert.are.same({ "Alpha", "Beta", "Gamma", "Delta", "Folder/Epsilon Two" }, links)
  end)

  describe("graph", function()
    local vault
    before_each(function()
      vault = dir .. "vault"
      H.write(vault .. "/Home.md", "[[Alpha]] [[Ideas/Beta]] [[missing]]")
      H.write(vault .. "/Ideas/Alpha.md", "back to [[home]]") -- names match case-insensitively
      H.write(vault .. "/Ideas/Beta.md", "[[Alpha]]")
      H.write(vault .. "/Deep/More/Alpha.md", "a second Alpha, deeper: bare links don't pick it")
      H.write(vault .. "/.obsidian/workspace.md", "[[Home]]")
    end)

    local function edge_set(g)
      local out = {}
      for _, e in ipairs(g.edges) do
        local a, b = g.notes[e[1]].rel, g.notes[e[2]].rel
        if a > b then a, b = b, a end
        out[#out + 1] = a .. " - " .. b
      end
      table.sort(out)
      return out
    end

    it("reads every note and resolves links like Obsidian, once per pair", function()
      local g = O.graph(vault, 0)
      assert.are.equal(4, #g.notes) -- .obsidian left out
      assert.are.same({ "Home.md - Ideas/Alpha.md", "Home.md - Ideas/Beta.md",
        "Ideas/Alpha.md - Ideas/Beta.md" }, edge_set(g))
      assert.are.equal(2, g.by_rel["Home.md"].degree)
      assert.are.equal("Ideas", g.by_rel["Ideas/Beta.md"].folder)
    end)

    it("rescans after RESCAN seconds, and only bumps the version on a change", function()
      local g = O.graph(vault, 0)
      local v = g.version
      H.write(vault .. "/New.md", "[[Home]]")
      assert.are.equal(v, O.graph(vault, 1).version) -- not yet
      local g2 = O.graph(vault, O.RESCAN + 1)
      assert.are.equal(v + 1, g2.version)
      assert.are.equal(5, #g2.notes)
      assert.are.equal(v + 1, O.graph(vault, 2 * O.RESCAN + 2).version) -- unchanged
    end)

    it("keeps the version when a note is edited without its links changing", function()
      local v = O.graph(vault, 0).version
      H.write(vault .. "/Home.md", "[[Alpha]] [[Ideas/Beta]] [[missing]] and more text")
      os.execute("touch -d '+5 seconds' '" .. vault .. "/Home.md'")
      assert.are.equal(v, O.graph(vault, O.RESCAN + 1).version)
      H.write(vault .. "/Home.md", "[[Alpha]]")
      os.execute("touch -d '+10 seconds' '" .. vault .. "/Home.md'")
      assert.are.equal(v + 1, O.graph(vault, 2 * O.RESCAN + 2).version)
    end)
  end)

  it("groups the touched notes by vault, oldest first, and names the vault touched last", function()
    H.write(dir .. "b/Note.md", "")
    local s1 = { notes = { ["/v/a/One.md"] = { r = 10 }, ["/v/a/Two.md"] = { r = 30, w = 40 },
      ["/elsewhere/x.md"] = { r = 50 } } }
    local s2 = { notes = { ["obsidian:Note"] = { r = 60 } } }
    local by, last = O.touched({ s1, s2 }, { "/v/a", dir .. "b" })
    assert.are.equal(dir .. "b", last)
    assert.are.same({ "One.md", "Two.md" }, { by["/v/a"][1].rel, by["/v/a"][2].rel })
    assert.are.equal(40, by["/v/a"][2].edit)
    assert.are.equal("Note.md", by[dir .. "b"][1].rel)
    assert.are.equal(s2, by[dir .. "b"][1].s)
  end)
end)

describe("obsi-constellation layout", function()
  local R, data, e, vault
  local now = os.time()
  before_each(function()
    data, e = H.tmpdir(), H.tmpdir()
    R = H.renderer()
    R.set_dirs(data, e, e, e)
    vault = e .. "brain"
    R.obsidian.CONF, R.obsidian.OBSIDIAN_JSON = e .. "obsidian.conf", e .. "none.json"
    H.write(R.obsidian.CONF, "vault = " .. vault .. "\n")
    H.write(vault .. "/Home.md", "[[Alpha]] [[Beta]] [[Gamma]]")
    H.write(vault .. "/Alpha.md", "[[Beta]]")
    H.write(vault .. "/Beta.md", "")
    H.write(vault .. "/Gamma.md", "")
    H.session(data, "a", { project = "research", state = "tool", tool = "Read", kind = "file",
      target = "Beta.md", notes = { [vault .. "/Alpha.md"] = { r = now - 60 },
        [vault .. "/Beta.md"] = { r = now - 1, w = now } } })
    H.session(data, "b", { project = "api", state = "done" })
    R.read_sessions()
  end)
  after_each(function() H.rmrf(data); H.rmrf(e) end)

  local function draw(opts)
    opts = opts or {}
    opts.layout = "obsi-constellation"
    local cr, rec = H.recorder()
    R.draw(cr, 1920, 1080, opts)
    return rec
  end

  it("draws the vault's graph with the touched notes and their neighbours named", function()
    local rec = draw()
    assert.is_true(rec.has_text("brain"))
    assert.is_true(rec.has_text("4 notes · 4 links · 2 touched"))
    assert.is_true(rec.has_text("Alpha"))
    assert.is_true(rec.has_text("Beta"))
    assert.is_true(rec.has_text("Home")) -- a neighbour
    assert.is_true(rec.has_text("research"))
    assert.is_true(rec.has_text("2 notes"))
    assert.is_true(rec.has_text("api"))
  end)

  it("starts every dot on a fresh path after a label (no wedge from the text to it)", function()
    local cr = H.recorder()
    local after_text, bad = false, 0
    function cr.show_text() after_text = true end
    function cr.new_path() after_text = false end
    function cr.new_sub_path() after_text = false end
    function cr.arc() if after_text then bad = bad + 1 end end
    function cr.line_to() if after_text then bad = bad + 1 end end
    function cr.move_to() after_text = false end
    R.draw(cr, 1920, 1080, { layout = "obsi-constellation" })
    assert.are.equal(0, bad)
  end)

  it("keeps note names off the lock screen", function()
    local rec = draw({ private = true, static = true })
    assert.is_true(rec.has_text("obsidian"))
    assert.is_nil(rec.text_matching("Alpha"))
    assert.is_nil(rec.text_matching("Beta"))
    assert.is_nil(rec.text_matching("brain"))
  end)

  it("says how to point it at a vault when there is none", function()
    H.write(R.obsidian.CONF, "")
    R = H.renderer()
    R.set_dirs(data, e, e, e)
    R.obsidian.CONF, R.obsidian.OBSIDIAN_JSON = e .. "obsidian.conf", e .. "none.json"
    R.read_sessions()
    local rec = draw()
    assert.is_true(rec.has_text("No Obsidian vault found"))
    assert.is_true(rec.has_text("research"))
  end)
end)
