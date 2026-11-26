-- The luv scheduler (specifications/29-luv.md §29), driven by a fake luv
-- module, so these specs run without luv. spec/luv_live_spec.lua uses the
-- real one.

local leffect = require("leffect")
local Effect = leffect.Effect
local LuvScheduler = require("leffect.scheduler.luv")
local h = require("spec.helpers")

local remove, sort = table.remove, table.sort

-- A fake luv module. It records the idle handles and timers, and runs a loop
-- iteration when the spec calls `iterate`, in libuv's order: the due timers,
-- then the active idle callbacks. `run` iterates until the loop has no
-- active handle or `stop` was called; without an active idle handle, it
-- moves the clock to the next timer, as a blocking poll would.
local function fakeUv()
  local uv = { time = 0, idles = {}, timers = {}, started = 0, running = false, stopped = false }

  function uv.new_idle()
    local idle = { active = false, starts = 0, stops = 0 }
    function idle.start(self, callback)
      self.active, self.callback = true, callback
      self.starts = self.starts + 1
      return 0
    end
    function idle.stop(self)
      self.active = false
      self.stops = self.stops + 1
      return 0
    end
    uv.idles[#uv.idles + 1] = idle
    return idle
  end

  function uv.new_timer()
    local timer = { closing = false }
    function timer.start(self, timeout, repeat_, callback)
      uv.started = uv.started + 1
      self.timeout, self.repeat_, self.callback = timeout, repeat_, callback
      self.due, self.order = uv.time + timeout, uv.started
      uv.timers[#uv.timers + 1] = self
      return 0
    end
    function timer.close(self)
      -- luv raises on a handle that is already closing.
      assert(not self.closing, "handle is already closing")
      self.closing = true
      for i = #uv.timers, 1, -1 do
        if uv.timers[i] == self then
          remove(uv.timers, i)
        end
      end
    end
    function timer.is_closing(self)
      return self.closing
    end
    return timer
  end

  function uv.now()
    return uv.time
  end

  function uv.loop_mode()
    if uv.running then
      return "default"
    end
    return nil
  end

  function uv.stop()
    uv.stopped = true
  end

  local function idleActive()
    for _, idle in ipairs(uv.idles) do
      if idle.active then
        return true
      end
    end
    return false
  end

  function uv.iterate()
    local due = {}
    for _, timer in ipairs(uv.timers) do
      if timer.due <= uv.time then
        due[#due + 1] = timer
      end
    end
    sort(due, function(a, b)
      if a.due ~= b.due then
        return a.due < b.due
      end
      return a.order < b.order
    end)
    for _, timer in ipairs(due) do
      if not timer.closing then
        timer.callback()
      end
    end
    for _, idle in ipairs(uv.idles) do
      if idle.active then
        idle.callback()
      end
    end
  end

  function uv.run()
    uv.running = true
    while not uv.stopped and (idleActive() or #uv.timers > 0) do
      uv.iterate()
      if not uv.stopped and not idleActive() and #uv.timers > 0 then
        local next = uv.timers[1].due
        for _, timer in ipairs(uv.timers) do
          if timer.due < next then
            next = timer.due
          end
        end
        if next > uv.time then
          uv.time = next
        end
      end
    end
    uv.running, uv.stopped = false, false
    return false
  end

  return uv
end

describe("LuvScheduler", function()
  local uv, scheduler
  before_each(function()
    uv = fakeUv()
    scheduler = LuvScheduler.new({ uv = uv })
  end)

  describe("schedule", function()
    it("runs tasks in FIFO order at the next idle callback, not before", function()
      local log = {}
      for i = 1, 3 do
        scheduler:schedule(function()
          log[#log + 1] = i
        end)
      end
      assert.are.same({}, log)
      uv.iterate()
      assert.are.same({ 1, 2, 3 }, log)
    end)

    it("runs a task queued during a batch in the next iteration", function()
      local log = {}
      scheduler:schedule(function()
        log[#log + 1] = "first"
        scheduler:schedule(function()
          log[#log + 1] = "queued meanwhile"
        end)
      end)
      uv.iterate()
      assert.are.same({ "first" }, log)
      uv.iterate()
      assert.are.same({ "first", "queued meanwhile" }, log)
    end)

    it("keeps one idle handle active exactly while tasks are queued", function()
      assert.are.equal(0, #uv.idles)
      scheduler:schedule(function() end)
      scheduler:schedule(function() end)
      assert.are.equal(1, #uv.idles)
      local idle = uv.idles[1]
      assert.is_true(idle.active)
      assert.are.equal(1, idle.starts)
      uv.iterate()
      assert.is_false(idle.active)
      assert.are.equal(1, idle.stops)
      scheduler:schedule(function() end)
      assert.is_true(idle.active)
      assert.are.equal(2, idle.starts)
      uv.iterate()
      assert.is_false(idle.active)
      assert.are.equal(1, #uv.idles)
    end)

    it("lets a task's error leave the idle callback, and runs the rest next time", function()
      local log = {}
      scheduler:schedule(function()
        error("task failed")
      end)
      scheduler:schedule(function()
        log[#log + 1] = "after"
      end)
      assert.has_error(function()
        uv.iterate()
      end)
      assert.are.same({}, log)
      assert.is_true(uv.idles[1].active)
      uv.iterate()
      assert.are.same({ "after" }, log)
      assert.is_false(uv.idles[1].active)
    end)
  end)

  describe("after", function()
    it("passes integer delays, rounded up and clamped, to the timer", function()
      local delays = {}
      for _, ms in ipairs({ 1.5, 10, 0, -5, 0 / 0, math.huge }) do
        scheduler:after(ms, function() end)
        delays[#delays + 1] = uv.timers[#uv.timers].timeout
      end
      assert.are.same({ 2, 10, 0, 0, 0, 2 ^ 53 }, delays)
      assert.are.equal(0, uv.timers[1].repeat_)
    end)

    it("fires the task once the timer is due", function()
      local fired = 0
      scheduler:after(10, function()
        fired = fired + 1
      end)
      uv.time = 9
      uv.iterate()
      assert.are.equal(0, fired)
      uv.time = 10
      uv.iterate()
      assert.are.equal(1, fired)
      assert.are.equal(0, #uv.timers)
    end)

    it("returns a cancel that stops the timer, and does nothing a second time", function()
      local fired = false
      local cancel = scheduler:after(10, function()
        fired = true
      end)
      cancel()
      cancel()
      uv.time = 20
      uv.iterate()
      assert.is_false(fired)
      assert.are.equal(0, #uv.timers)
    end)

    it("returns a cancel that does nothing after the timer fired", function()
      local cancel = scheduler:after(0, function() end)
      uv.iterate()
      cancel()
      assert.are.equal(0, #uv.timers)
    end)
  end)

  it("gives uv.now() as now", function()
    uv.time = 1234
    assert.are.equal(1234, scheduler:now())
  end)

  it("runs fibers, with the op budget it was given", function()
    local budget = LuvScheduler.new({ uv = uv, maxOpsBeforeYield = 7 })
    assert.are.equal(7, budget.maxOpsBeforeYield)
    local fiber = budget:fork(Effect.succeed(1))
    uv.run()
    assert.are.equal(1, h.valueOf(fiber.exit))
  end)

  describe("run", function()
    it("returns the exit, and stops the loop when the fiber ends", function()
      local fired = false
      local other = uv.new_timer()
      other:start(100, 0, function()
        fired = true
      end)
      local exit, fiber = scheduler:run(Effect.sleep(10):as("done"))
      assert.are.equal("done", h.valueOf(exit))
      assert.are.equal(exit, fiber.exit)
      assert.is_false(fired)
      assert.are.equal(10, uv.now())
      assert.is_false(uv.running)
    end)

    it("returns nil and the fiber when the loop runs out of work first", function()
      local exit, fiber = scheduler:run(Effect.never)
      assert.is_nil(exit)
      assert.is_nil(fiber.exit)
      assert.are.equal("suspended", fiber.status)
    end)

    it("raises when the loop is already running", function()
      uv.running = true
      assert.has_error(
        function()
          scheduler:run(Effect.void)
        end,
        "LuvScheduler:run: the luv loop is already running; use fork or Effect.runCallback inside it"
      )
    end)

    it("removes its observer before it returns", function()
      local resume
      local waiting = Effect.async(function(r)
        resume = r
      end)
      local exit, fiber = scheduler:run(waiting)
      assert.is_nil(exit)
      -- A later loop run: the fiber ends at 10 ms; a timer at 20 ms must
      -- still fire, so nothing may stop this loop when the fiber ends.
      local log = {}
      local wake = uv.new_timer()
      wake:start(10, 0, function()
        wake:close()
        resume(Effect.succeed("late"))
      end)
      local later = uv.new_timer()
      later:start(20, 0, function()
        later:close()
        log[#log + 1] = "later"
      end)
      uv.run()
      assert.are.equal("late", h.valueOf(fiber.exit))
      assert.are.same({ "later" }, log)
    end)
  end)

  it("doesn't load luv when required, nor in new when options.uv is given", function()
    local savedLoaded, savedPreload = package.loaded.luv, package.preload.luv
    local savedModule = package.loaded["leffect.scheduler.luv"]
    local loads = 0
    package.loaded.luv = nil
    package.loaded["leffect.scheduler.luv"] = nil
    package.preload.luv = function()
      loads = loads + 1
      return fakeUv()
    end
    local ok, err = pcall(function()
      local Fresh = require("leffect.scheduler.luv")
      assert.are.equal(0, loads)
      Fresh.new({ uv = fakeUv() })
      assert.are.equal(0, loads)
      Fresh.new()
      assert.are.equal(1, loads)
    end)
    package.loaded.luv, package.preload.luv = savedLoaded, savedPreload
    package.loaded["leffect.scheduler.luv"] = savedModule
    assert(ok, err)
  end)
end)
