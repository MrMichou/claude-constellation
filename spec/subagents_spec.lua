-- Specs for the subagent runners of render.lua: one mini Clawd per subagent, grouped by agent
-- type past 6 running, the smallest groups merged into "+k agents", finished ones fading.
local H = require("spec.helpers")

describe("subagent runners", function()
  local R, data, power
  local now = os.time()

  before_each(function()
    data, power = H.tmpdir(), H.tmpdir()
    R = H.renderer()
    R.set_dirs(data, power)
  end)

  after_each(function()
    H.rmrf(data)
    H.rmrf(power)
  end)

  local function agent(type, state, fields)
    local a = { type = type, label = "", state = state or "tool", kind = "file", target = "x",
      history = {}, started = now - 60, ts = now }
    for k, v in pairs(fields or {}) do a[k] = v end
    return a
  end

  -- `spec` = { {type, count, state}, ... } -> agents table with unique ids, created in order.
  local function fanout(spec)
    local agents, n = {}, 0
    for _, g in ipairs(spec) do
      for _ = 1, g[2] do
        n = n + 1
        agents[("a%02d"):format(n)] = agent(g[1], g[3], { started = now - 100 + n })
      end
    end
    return agents
  end

  local function by_type(list)
    local out = {}
    for _, r in ipairs(list) do out[r.merged and "+" or r.type] = r end
    return out
  end

  local function draw(opts)
    local cr, rec = H.recorder()
    R.draw(cr, 1920, 1080, opts)
    return rec
  end

  describe("R.runners", function()
    it("gives each subagent its own runner up to 6, oldest first", function()
      local list = R.runners({ agents = fanout({ { "Explore", 4 }, { "Plan", 2 } }) }, now)
      assert.are.equal(6, #list)
      for _, r in ipairs(list) do assert.are.equal(1, r.count) end
      assert.are.equal("Explore", list[1].type)
      assert.are.equal("Plan", list[6].type)
    end)

    it("groups by agent type past 6 running subagents", function()
      local list = R.runners({ agents = fanout({ { "general-purpose", 10 }, { "Explore", 3 } }) }, now)
      assert.are.equal(2, #list)
      local g = by_type(list)
      assert.are.equal(10, g["general-purpose"].count)
      assert.are.equal(3, g.Explore.count)
    end)

    it("gives a group its most urgent member's state", function()
      local agents = fanout({ { "Explore", 8, "thinking" } })
      agents.a03.state = "tool"
      agents.a05.state = "permission"
      assert.are.equal("permission", R.runners({ agents = agents }, now)[1].state)
    end)

    it("merges the smallest groups into one past 6 types, keeping creation order", function()
      local list = R.runners({ agents = fanout({
        { "a", 1 }, { "big", 9 }, { "b", 2 }, { "c", 3 }, { "d", 1 }, { "e", 4 }, { "f", 1 }, { "g", 5 },
      }) }, now)
      assert.are.equal(6, #list)
      local names = {}
      for _, r in ipairs(list) do names[#names + 1] = r.merged and "+" or r.type end
      assert.are.same({ "big", "b", "c", "e", "g", "+" }, names) -- a, d, f (1 each) merged
      assert.are.equal(3, list[6].count)
    end)

    it("leaves finished subagents out of groups", function()
      local agents = fanout({ { "Explore", 7 }, { "Plan", 3, "done" } })
      local g = by_type(R.runners({ agents = agents }, now))
      assert.are.equal(7, g.Explore.count)
      assert.is_nil(g.Plan)
    end)

    it("shows finished subagents while they fade, if there is room", function()
      local agents = fanout({ { "Explore", 2 } })
      agents.done = agent("Plan", "done", { ts = now - 5 })
      agents.gone = agent("Plan", "done", { ts = now - 25 })
      local list = R.runners({ agents = agents }, now)
      assert.are.equal(3, #list)
      assert.are.equal("done", by_type(list).Plan.state)
    end)

    it("copes with no or malformed agents", function()
      assert.are.same({}, R.runners({}, now))
      assert.are.same({}, R.runners({ agents = { x = "nope" } }, now))
    end)
  end)

  describe("draw", function()
    it("labels single runners with their description, groups with type and count", function()
      H.session(data, "s1", { project = "solo", agents = {
        a1 = agent("Explore", "tool", { label = "map imports", target = "…/src/app.ts" }),
      } })
      H.session(data, "s2", { project = "fanout", agents = fanout({ { "general-purpose", 12 } }) })
      R.read_sessions()
      local rec = draw()
      assert.is_true(rec.has_text("map imports"))
      assert.is_true(rec.has_text("…/src/app.ts"))
      assert.is_true(rec.has_text("general-purpose ×12"))
    end)

    it("labels the merged group with its agent count", function()
      H.session(data, "s1", { agents = fanout({
        { "a", 1 }, { "b", 2 }, { "c", 2 }, { "d", 2 }, { "e", 2 }, { "f", 1 }, { "g", 1 },
      }) })
      R.read_sessions()
      assert.is_true(draw().has_text("+2 agents")) -- f and g; a is the oldest of the 1-agent groups
    end)

    it("private mode shows the agent type only", function()
      H.session(data, "s1", { agents = {
        a1 = agent("Explore", "tool", { label = "audit secrets.env", target = "…/secrets.env" }),
      } })
      R.read_sessions()
      local rec = draw({ private = true })
      assert.is_true(rec.has_text("Explore"))
      assert.is_nil(rec.text_matching("secrets"))
    end)

    it("keeps the frame rate up while a subagent works under a finished session", function()
      H.session(data, "s1", { state = "done", agents = { a1 = agent("Explore", "thinking") } })
      assert.is_true(R.read_sessions())
      H.session(data, "s1", { state = "done", agents = { a1 = agent("Explore", "done") } })
      assert.is_false(R.read_sessions())
    end)

    it("draws every runner state, static or private, sprites or not", function()
      local agents = {}
      for _, st in ipairs({ "tool", "thinking", "permission", "waiting", "done" }) do
        agents[st] = agent("Explore", st, { history = { { kind = "file", target = "x", ts = now } } })
      end
      H.session(data, "s1", { agents = agents })
      R.read_sessions()
      assert.has_no.errors(function() draw() end)
      assert.has_no.errors(function() draw({ static = true, private = true }) end)
    end)
  end)
end)
