-- Semaphore (specifications/36-semaphore.md §36): permits that fibers take,
-- wait for, and give back. Waiters keep their place in line (§33.2).

local leffect = require("leffect")
local Effect = leffect.Effect
local Semaphore = leffect.Semaphore
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

describe("Semaphore", function()
  local scheduler
  before_each(function()
    scheduler = TestScheduler.new()
  end)

  -- Forks a fiber that takes `n` permits, then records `name`.
  local function taker(sem, n, log, name)
    return scheduler:fork(sem:take(n):flatMap(function()
      return Effect.sync(function()
        log[#log + 1] = name
      end)
    end))
  end

  describe("withPermit", function()
    local function finishTimes(permits)
      local sem = Semaphore.makeUnsafe(permits)
      local times = {}
      for i = 1, 3 do
        scheduler:fork(sem:withPermit(Effect.sleep(10)):flatMap(function()
          return Effect.sync(function()
            times[i] = scheduler:now()
          end)
        end))
      end
      scheduler:runAll()
      return times
    end

    it("with one permit, runs three effects one after the other, in order", function()
      assert.are.same({ 10, 20, 30 }, finishTimes(1))
    end)

    it("with two permits, runs two at a time", function()
      assert.are.same({ 10, 10, 20 }, finishTimes(2))
    end)
  end)

  describe("withPermits gives the permits back", function()
    local function freeAfter(effect)
      local sem = Semaphore.makeUnsafe(3)
      scheduler:run(Effect.exit(sem:withPermits(2, effect)))
      return Effect.runSync(sem:release(0))
    end

    it("after a success, a failure and a defect", function()
      assert.are.equal(3, freeAfter(Effect.void))
      assert.are.equal(3, freeAfter(Effect.fail("e")))
      assert.are.equal(3, freeAfter(Effect.die("d")))
    end)

    it("after an interrupt", function()
      local sem = Semaphore.makeUnsafe(3)
      local fiber = h.started(scheduler, sem:withPermits(2, Effect.never))
      assert.are.equal(1, Effect.runSync(sem:release(0)))
      fiber:interruptUnsafe()
      scheduler:flush()
      h.assertInterrupted(fiber.exit)
      assert.are.equal(3, Effect.runSync(sem:release(0)))
    end)
  end)

  it("take succeeds with n, release with the free permits, takeIfAvailable never waits", function()
    local sem = Semaphore.makeUnsafe(3)
    assert.are.equal(2, Effect.runSync(sem:take(2)))
    assert.is_false(Effect.runSync(sem:takeIfAvailable(2)))
    assert.is_true(Effect.runSync(sem:takeIfAvailable(1)))
    assert.are.equal(2, Effect.runSync(sem:release(2)))
  end)

  it("lets a smaller, later request overtake a larger one", function()
    local sem = Semaphore.makeUnsafe(2)
    local log = {}
    Effect.runSync(sem:take(2))
    local two = taker(sem, 2, log, "two")
    local one = taker(sem, 1, log, "one")
    scheduler:flush()
    Effect.runSync(sem:release(1))
    scheduler:flush()
    assert.are.same({ "one" }, log)
    assert.is_nil(two.exit)
    h.valueOf(one.exit)
    Effect.runSync(sem:release(2))
    scheduler:flush()
    assert.are.same({ "one", "two" }, log)
  end)

  it("doesn't let a new request barge past a woken waiter", function()
    local sem = Semaphore.makeUnsafe(1)
    local log = {}
    Effect.runSync(sem:take(1))
    local woken = taker(sem, 1, log, "woken")
    scheduler:flush()
    -- In one step, a permit comes back and wakes `woken`, then the same
    -- fiber asks for a permit before `woken` has run.
    local late = scheduler:fork(sem
      :release(1)
      :flatMap(function()
        return sem:take(1)
      end)
      :flatMap(function()
        return Effect.sync(function()
          log[#log + 1] = "late"
        end)
      end))
    scheduler:flush()
    assert.are.same({ "woken" }, log)
    h.valueOf(woken.exit)
    assert.is_nil(late.exit)
  end)

  it("removes an interrupted waiter, and gives its permits to the next one", function()
    local sem = Semaphore.makeUnsafe(1)
    local log = {}
    Effect.runSync(sem:take(1))
    local a = taker(sem, 1, log, "a")
    taker(sem, 1, log, "b")
    scheduler:flush()
    a:interruptUnsafe()
    scheduler:flush()
    h.assertInterrupted(a.exit)
    assert.are.equal(0, Effect.runSync(sem:release(0)))
    Effect.runSync(sem:release(1))
    scheduler:flush()
    assert.are.same({ "b" }, log)
    assert.are.equal(0, Effect.runSync(sem:release(0)))
  end)

  it("passes the turn of a woken waiter interrupted before it runs (invariant 24)", function()
    local sem = Semaphore.makeUnsafe(1)
    local log = {}
    Effect.runSync(sem:take(1))
    local a = taker(sem, 1, log, "a")
    local b = taker(sem, 1, log, "b")
    scheduler:flush()
    -- One step: the release wakes a, then a is interrupted before it runs.
    Effect.runSync(sem:release(1))
    a:interruptUnsafe()
    scheduler:flush()
    h.assertInterrupted(a.exit)
    h.valueOf(b.exit)
    assert.are.same({ "b" }, log)
    assert.are.equal(0, Effect.runSync(sem:release(0)))
  end)

  it("takeScoped holds its permits until the scope closes", function()
    local sem = Semaphore.makeUnsafe(2)
    local inside
    Effect.runSync(Effect.scoped(sem:takeScoped(2):flatMap(function()
      return Effect.sync(function()
        inside = sem.permits - sem.taken
      end)
    end)))
    assert.are.equal(0, inside)
    assert.are.equal(2, Effect.runSync(sem:release(0)))
  end)

  it("takeScoped dies without a scope, before taking anything", function()
    local sem = Semaphore.makeUnsafe(2)
    local exit = Effect.runSyncExit(sem:takeScoped(1))
    assert.are.same({ "Die" }, h.tags(h.causeOf(exit)))
    assert.are.equal(2, Effect.runSync(sem:release(0)))
  end)

  it("releaseAll frees every permit; running withPermits give theirs back later", function()
    local sem = Semaphore.makeUnsafe(2)
    local fiber = h.started(scheduler, sem:withPermits(2, Effect.sleep(10)))
    assert.are.equal(2, Effect.runSync(sem:releaseAll()))
    scheduler:runAll()
    h.valueOf(fiber.exit)
    assert.are.equal(4, Effect.runSync(sem:release(0)))
  end)

  it("resize upwards wakes waiters", function()
    local sem = Semaphore.makeUnsafe(1)
    local log = {}
    Effect.runSync(sem:take(1))
    taker(sem, 1, log, "a")
    scheduler:flush()
    Effect.runSync(sem:resize(2))
    scheduler:flush()
    assert.are.same({ "a" }, log)
  end)

  it("resize below the taken count makes new requests wait", function()
    local sem = Semaphore.makeUnsafe(3)
    local log = {}
    Effect.runSync(sem:take(3))
    Effect.runSync(sem:resize(1))
    taker(sem, 1, log, "a")
    scheduler:flush()
    Effect.runSync(sem:release(2))
    scheduler:flush()
    assert.are.same({}, log)
    Effect.runSync(sem:release(1))
    scheduler:flush()
    assert.are.same({ "a" }, log)
  end)

  it("with 0 permits, take(1) waits until release(1)", function()
    local sem = Effect.runSync(Semaphore.make(0))
    local log = {}
    taker(sem, 1, log, "a")
    scheduler:flush()
    assert.are.same({}, log)
    Effect.runSync(sem:release(1))
    scheduler:flush()
    assert.are.same({ "a" }, log)
  end)

  it("has every function as a method", function()
    local sem = Semaphore.makeUnsafe(1)
    for _, name in ipairs({
      "withPermits",
      "withPermit",
      "take",
      "takeScoped",
      "takeIfAvailable",
      "release",
      "releaseAll",
      "resize",
    }) do
      assert.are.equal(Semaphore[name], sem[name], name)
    end
    assert.is_true(Semaphore.isSemaphore(sem))
  end)

  it("raises on a non-Semaphore or a bad number of permits", function()
    ---@diagnostic disable-next-line: missing-fields
    local ok, err = pcall(Semaphore.take, {}, 1)
    assert.is_false(ok)
    ---@diagnostic disable-next-line: param-type-mismatch
    assert.matches("Semaphore.take: expected a Semaphore", err)
    for _, bad in ipairs({ -1, 1.5, 0 / 0, math.huge, "2" }) do
      assert.has_error(function()
        Semaphore.makeUnsafe(bad)
      end)
      assert.has_error(function()
        Semaphore.make(bad)
      end)
      assert.has_error(function()
        Semaphore.makeUnsafe(1):take(bad)
      end)
    end
  end)
end)
