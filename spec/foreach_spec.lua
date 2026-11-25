-- forEach and all (specifications/22-foreach.md §22): one item at a time by
-- default, or up to `concurrency` items at once on worker fibers. Results keep
-- input order and carry `n`.

local leffect = require("leffect")
local Cause = leffect.Cause
local Effect = leffect.Effect
local Fiber = leffect.Fiber
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

local max = math.max

describe("forEach", function()
  local scheduler, log, record
  before_each(function()
    scheduler = TestScheduler.new()
    log, record = h.recorder()
  end)

  describe("one item at a time, the default", function()
    it("calls f in order, only when the item's turn comes", function()
      local result = Effect.runSync(Effect.forEach({ "a", "b", "c" }, function(item, i)
        log[#log + 1] = "f" .. i
        return record("run " .. item):as(item .. i)
      end))
      assert.are.same({ "f1", "run a", "f2", "run b", "f3", "run c" }, log)
      assert.are.same({ "a1", "b2", "c3", n = 3 }, result)
    end)

    it("stops at the first failure: later items never start", function()
      local exit = Effect.runSyncExit(Effect.forEach({ 1, 2, 3 }, function(i)
        log[#log + 1] = "f" .. i
        if i == 2 then
          return Effect.fail("item 2 failed")
        end
        return Effect.void
      end))
      assert.are.same({ "item 2 failed" }, (Cause.failures(h.causeOf(exit))))
      assert.are.same({ "f1", "f2" }, log)
    end)

    it("doesn't overflow with 1e5 items", function()
      local items = {}
      for i = 1, 100000 do
        items[i] = i
      end
      local result = Effect.runSync(Effect.forEach(items, function(item)
        return Effect.succeed(item * 2)
      end))
      assert.are.equal(100000, result.n)
      assert.are.equal(200000, result[100000])
    end)

    it("treats a concurrency below 1 as 1", function()
      Effect.runSync(Effect.forEach({ 1, 2 }, function(i)
        log[#log + 1] = "f" .. i
        return record("run " .. i)
      end, { concurrency = 0 }))
      assert.are.same({ "f1", "run 1", "f2", "run 2" }, log)
    end)
  end)

  describe("the result", function()
    local function both(run)
      run(nil)
      run({ concurrency = 2 })
    end

    it("counts nil results in n", function()
      both(function(options)
        local exit = scheduler:run(Effect.forEach({ 1, 2, 3 }, function(i)
          return Effect.succeed(i ~= 2 and i or nil)
        end, options))
        assert.are.same({ 1, nil, 3, n = 3 }, h.valueOf(exit))
      end)
    end)

    it("is nil with discard", function()
      both(function(options)
        local discard = { discard = true, concurrency = options and options.concurrency }
        local exit = scheduler:run(Effect.forEach({ 1, 2 }, Effect.succeed, discard))
        assert.is_nil(h.valueOf(exit))
      end)
    end)

    it("is { n = 0 } for an empty list", function()
      both(function(options)
        assert.are.same(
          { n = 0 },
          h.valueOf(scheduler:run(Effect.forEach({}, Effect.succeed, options)))
        )
      end)
    end)

    it("comes from indexes that count from 1, up to list.n", function()
      both(function(options)
        local seen = {}
        local exit = scheduler:run(Effect.forEach({ "a", nil, "c", n = 3 }, function(item, i)
          seen[#seen + 1] = i
          return Effect.succeed(item)
        end, options))
        assert.are.same({ "a", nil, "c", n = 3 }, h.valueOf(exit))
        assert.are.same({ 1, 2, 3 }, seen)
      end)
    end)
  end)

  describe("concurrently", function()
    local running, mostRunning
    before_each(function()
      running, mostRunning = 0, 0
    end)

    -- Takes `ms` milliseconds, tracking how many items run at once.
    local function item(ms, value)
      return Effect.sync(function()
        running = running + 1
        mostRunning = max(mostRunning, running)
      end)
        :flatMap(function()
          return Effect.sleep(ms)
        end)
        :ensuring(Effect.sync(function()
          running = running - 1
        end))
        :as(value)
    end

    local durations = { 30, 10, 20, 10 }
    local function timed(_, i)
      return item(durations[i], "v" .. i)
    end

    it("never runs more than `concurrency` items at once, and keeps input order", function()
      local exit = scheduler:run(Effect.forEach(durations, timed, { concurrency = 2 }))
      assert.are.same({ "v1", "v2", "v3", "v4", n = 4 }, h.valueOf(exit))
      assert.are.equal(2, mostRunning)
      assert.are.equal(40, scheduler:now())
    end)

    it("starts every item at once when unbounded", function()
      local exit = scheduler:run(Effect.forEach(durations, timed, { concurrency = "unbounded" }))
      assert.are.same({ "v1", "v2", "v3", "v4", n = 4 }, h.valueOf(exit))
      assert.are.equal(4, mostRunning)
      assert.are.equal(30, scheduler:now())
    end)

    it("runs its workers as daemons, inheriting the parent's interruptibility", function()
      local seen = {}
      local exit = scheduler:run(Effect.uninterruptible(Effect.forEach({ 1, 2 }, function()
        return Effect.withFiber(function(fiber)
          seen[#seen + 1] = fiber.interruptible
          return Effect.void
        end)
      end, { concurrency = 2 })))
      h.valueOf(exit)
      assert.are.same({ false, false }, seen)
    end)

    it("interrupts the running workers on a failure, and waits for their finalizers", function()
      local items = {
        Effect.sleep(10):flatMap(function()
          return Effect.fail("boom")
        end),
        Effect.never:ensuring(Effect.sleep(5):flatMap(function()
          return record("2 cleaned up")
        end)),
        record("3 started"),
      }
      local exit = scheduler:run(Effect.forEach(items, function(effect)
        return effect
      end, { concurrency = 2 }))
      assert.are.same({ "Fail" }, h.tags(h.causeOf(exit)))
      assert.are.same({ "boom" }, (Cause.failures(h.causeOf(exit))))
      assert.are.same({ "2 cleaned up" }, log)
      assert.are.equal(15, scheduler:now())
    end)

    it("adds a later worker's failure, and elects the defects", function()
      local items = {
        Effect.sleep(10):flatMap(function()
          return Effect.fail("a")
        end),
        Effect.uninterruptible(Effect.sleep(20):flatMap(function()
          return Effect.die("b")
        end)),
      }
      local exit = scheduler:run(Effect.forEach(items, function(effect)
        return effect
      end, { concurrency = 2 }))
      local cause = h.causeOf(exit)
      assert.are.same({ "Die", "Die" }, h.tags(cause))
      assert.are.same({ "a", "b" }, (Cause.defects(cause)))
    end)

    it("interrupts every worker when the parent is interrupted, and waits for them", function()
      local function cleansUp(name)
        return Effect.never:ensuring(Effect.sleep(10):flatMap(function()
          return record(name .. " cleaned up")
        end))
      end
      local fiber =
        h.started(scheduler, Effect.forEach({ "a", "b" }, cleansUp, { concurrency = "unbounded" }))
      fiber:interruptUnsafe()
      scheduler:advance(9)
      assert.is_nil(fiber:poll())
      scheduler:advance(1)
      assert.are.same({ "a cleaned up", "b cleaned up" }, log)
      h.assertInterrupted(fiber:poll())
    end)

    it("launches nothing more once the parent is interrupted", function()
      local items = {
        Effect.never,
        Effect.never:ensuring(record("2 cleaned up")),
        record("3 started"),
      }
      local fiber = h.started(
        scheduler,
        Effect.forEach(items, function(effect)
          return effect
        end, { concurrency = 2 })
      )
      fiber:interruptUnsafe()
      scheduler:runAll()
      h.assertInterrupted(fiber:poll())
      assert.are.same({ "2 cleaned up" }, log)
    end)

    it("inside uninterruptible, doesn't cut the other workers short on a failure", function()
      local items = {
        Effect.sleep(10):flatMap(function()
          return Effect.fail("a")
        end),
        Effect.sleep(20):flatMap(function()
          return record("2 finished")
        end),
      }
      local exit = scheduler:run(Effect.uninterruptible(Effect.forEach(items, function(effect)
        return effect
      end, { concurrency = 2 })))
      assert.are.same({ "a" }, (Cause.failures(h.causeOf(exit))))
      assert.are.same({ "2 finished" }, log)
      assert.are.equal(20, scheduler:now())
    end)

    it("fails with the Die when f throws in the first batch, after stopping the workers", function()
      local exit = scheduler:run(Effect.forEach({ 1, 2, 3 }, function(i)
        if i == 2 then
          error("bad item")
        end
        return record("item " .. i .. " ran"):flatMap(function()
          return Effect.never
        end)
      end, { concurrency = 3 }))
      local cause = h.causeOf(exit)
      assert.are.same({ "Die" }, h.tags(cause))
      assert.matches("bad item", cause.reasons[1].defect, 1, true)
      assert.matches("stack traceback:", cause.reasons[1].trace, 1, true)
      assert.are.same({}, log)
    end)

    it("fails with the Die when f throws on the first item", function()
      local exit = scheduler:run(Effect.forEach({ 1, 2 }, function()
        error("bad first item")
      end, { concurrency = 2 }))
      assert.matches("bad first item", h.causeOf(exit).reasons[1].defect, 1, true)
    end)

    it("stops the running workers, and runs their finalizers, when f throws in a refill", function()
      local exit = scheduler:run(Effect.forEach({ 1, 2, 3 }, function(i)
        if i == 1 then
          return Effect.sleep(10)
        elseif i == 2 then
          return Effect.never:ensuring(record("2 cleaned up"))
        end
        error("bad refill")
      end, { concurrency = 2 }))
      local cause = h.causeOf(exit)
      assert.are.same({ "Die" }, h.tags(cause))
      assert.matches("bad refill", cause.reasons[1].defect, 1, true)
      assert.are.same({ "2 cleaned up" }, log)
      assert.are.equal(10, scheduler:now())
    end)
  end)

  it("dies on an invalid concurrency", function()
    for _, concurrency in ipairs({ "lots", true, 0 / 0 }) do
      local exit = Effect.runSyncExit(Effect.forEach({ 1 }, Effect.succeed, {
        ---@diagnostic disable-next-line: assign-type-mismatch
        concurrency = concurrency,
      }))
      local reason = h.causeOf(exit).reasons[1]
      assert.are.equal("Die", reason._tag)
      assert.matches("concurrency", reason.defect, 1, true)
    end
  end)
end)

describe("all", function()
  local log, record
  before_each(function()
    log, record = h.recorder()
  end)

  it("runs a list of effects, and gives their values with n", function()
    local result =
      Effect.runSync(Effect.all({ Effect.succeed(1), Effect.succeed(nil), Effect.succeed(3) }))
    assert.are.same({ 1, nil, 3, n = 3 }, result)
  end)

  it("gives { n = 0 } for an empty table", function()
    assert.are.same({ n = 0 }, Effect.runSync(Effect.all({})))
  end)

  it("treats a table with a number n as a list of n effects", function()
    local result = Effect.runSync(Effect.all({ Effect.succeed(1), Effect.succeed(2), n = 1 }))
    assert.are.same({ 1, n = 1 }, result)
  end)

  it("runs a record in sorted key order, numbers first, and keeps its keys", function()
    local function entry(key)
      return record(key):as("value " .. key)
    end
    local result = Effect.runSync(Effect.all({
      b = entry("b"),
      [10] = entry(10),
      a = entry("a"),
      [2] = entry(2),
    }))
    assert.are.same({ 2, 10, "a", "b" }, log)
    assert.are.same({ [2] = "value 2", [10] = "value 10", a = "value a", b = "value b" }, result)
  end)

  it("dies on a record key that is neither a number nor a string", function()
    local exit = Effect.runSyncExit(Effect.all({ [true] = Effect.void, a = Effect.void }))
    assert.are.same({ "Die" }, h.tags(h.causeOf(exit)))
  end)

  it("supports discard and concurrency, for lists and records", function()
    local scheduler = TestScheduler.new()
    local list = { Effect.sleep(10):as(1), Effect.sleep(10):as(2) }
    assert.is_nil(h.valueOf(scheduler:run(Effect.all(list, { discard = true }))))
    assert.are.equal(20, scheduler:now())
    local both = Effect.all(list, { concurrency = "unbounded" })
    assert.are.same({ 1, 2, n = 2 }, h.valueOf(scheduler:run(both)))
    assert.are.equal(30, scheduler:now())
    local fields = { a = Effect.sleep(10):as(1), b = Effect.sleep(10):as(2) }
    local together = Effect.all(fields, { concurrency = 2 })
    assert.are.same({ a = 1, b = 2 }, h.valueOf(scheduler:run(together)))
    assert.are.equal(40, scheduler:now())
    assert.is_nil(h.valueOf(scheduler:run(Effect.all(fields, { discard = true }))))
  end)

  it("fails like forEach", function()
    local exit = Effect.runSyncExit(Effect.all({ a = Effect.fail("e"), b = record("b ran") }))
    assert.are.same({ "e" }, (Cause.failures(h.causeOf(exit))))
    assert.are.same({}, log)
  end)
end)

describe("Fiber.forkUnsafe", function()
  it('with "inherit" copies the parent\'s interruptibility', function()
    local seen = {}
    local function forkInheriting()
      return Effect.withFiber(function(parent)
        local child = Fiber.forkUnsafe(parent, Effect.void, true, "inherit")
        seen[#seen + 1] = child.interruptible
        return child:await()
      end)
    end
    Effect.runSync(forkInheriting())
    Effect.runSync(Effect.uninterruptible(forkInheriting()))
    assert.are.same({ true, false }, seen)
  end)
end)
