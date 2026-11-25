-- race, raceFirst and timeout (FIBER-DESIGN.md §8.1), as in Effect v4: the
-- losers are interrupted and awaited before the race returns.

local leffect = require("leffect")
local Cause = leffect.Cause
local Effect = leffect.Effect
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

local function failAfter(ms, err)
  return Effect.sleep(ms):flatMap(function()
    return Effect.fail(err)
  end)
end

describe("race", function()
  local scheduler
  before_each(function()
    scheduler = TestScheduler.new()
  end)

  it("returns the first success, after the loser's finalizer has run", function()
    local log, record = h.recorder()
    local fast = Effect.sleep(10):as("fast")
    local slow = Effect.sleep(100):as("slow"):ensuring(record("slow cleaned up"))
    local exit = scheduler:run(Effect.race(fast, slow):flatMap(function(winner)
      return record("race returned " .. winner)
    end))
    h.valueOf(exit)
    assert.are.same({ "slow cleaned up", "race returned fast" }, log)
    assert.are.equal(10, scheduler:now())
    assert.are.equal(0, scheduler:pendingTimers())
  end)

  it("works as a method", function()
    local exit = scheduler:run(Effect.sleep(20):as("a"):race(Effect.sleep(10):as("b")))
    assert.are.equal("b", h.valueOf(exit))
  end)

  it("doesn't let an early failure win", function()
    local exit = scheduler:run(Effect.race(failAfter(10, "early"), Effect.sleep(20):as("late")))
    assert.are.equal("late", h.valueOf(exit))
    assert.are.equal(20, scheduler:now())
  end)

  it("fails with the reasons of every racer when all of them fail", function()
    local exit = scheduler:run(Effect.race(Effect.fail("a"), Effect.fail("b")))
    assert.are.same({ "a", "b" }, (Cause.failures(h.causeOf(exit))))
  end)

  it("elects defects when every racer fails and one of them dies (4.1.5)", function()
    local exit = scheduler:run(Effect.race(Effect.fail("a"), Effect.die("b")))
    local cause = h.causeOf(exit)
    assert.are.same({ "Die", "Die" }, h.tags(cause))
    assert.are.same({ "a", "b" }, (Cause.defects(cause)))
  end)

  it("raceAll races any number of effects", function()
    local exit = scheduler:run(Effect.raceAll({
      Effect.sleep(30):as(3),
      Effect.sleep(10):as(1),
      Effect.sleep(20):as(2),
    }))
    assert.are.equal(1, h.valueOf(exit))
    assert.are.equal(0, scheduler:pendingTimers())
  end)

  it("raceAll of no effects is a defect", function()
    local exit = Effect.runSyncExit(Effect.raceAll({}))
    assert.are.same({ "Die" }, h.tags(h.causeOf(exit)))
  end)

  it("raceFirst returns the first exit, even a failure", function()
    local log, record = h.recorder()
    local exit = scheduler:run(
      Effect.raceFirst(
        failAfter(10, "early"),
        Effect.sleep(20):as("late"):ensuring(record("late cleaned up"))
      )
    )
    assert.are.same({ "early" }, (Cause.failures(h.causeOf(exit))))
    assert.are.same({ "late cleaned up" }, log)
    assert.are.equal(10, scheduler:now())
  end)

  it("interrupting the racing fiber interrupts the racers", function()
    local log, record = h.recorder()
    local fiber = h.started(
      scheduler,
      Effect.race(
        Effect.never:ensuring(record("a cleaned up")),
        Effect.never:ensuring(record("b cleaned up"))
      )
    )
    fiber:interruptUnsafe()
    scheduler:flush()
    assert.are.same({ "a cleaned up", "b cleaned up" }, log)
    h.assertInterrupted(fiber:poll())
  end)
end)

describe("timeout", function()
  local scheduler
  before_each(function()
    scheduler = TestScheduler.new()
  end)

  it("fails with TimeoutError at the deadline, after the slow effect's cleanup", function()
    local log, record = h.recorder()
    local exit = scheduler:run(Effect.sleep(1000):ensuring(record("slow cleaned up")):timeout(100))
    local err = (Cause.failures(h.causeOf(exit)))[1]
    assert.are.equal("TimeoutError", err._tag)
    assert.are.same({ "slow cleaned up" }, log)
    assert.are.equal(100, scheduler:now())
  end)

  it("returns the value of a fast effect and cancels the timer", function()
    local fiber = scheduler:fork(Effect.sleep(10):as("fast"):timeout(100))
    scheduler:advance(10)
    assert.are.equal("fast", h.valueOf(fiber:poll()))
    assert.are.equal(0, scheduler:pendingTimers())
  end)

  it("fails at once with the error of an effect that fails before the deadline", function()
    local exit = scheduler:run(failAfter(10, "boom"):timeout(100))
    assert.are.same({ "boom" }, (Cause.failures(h.causeOf(exit))))
    assert.are.equal(10, scheduler:now())
  end)

  it("timeoutOrElse runs the fallback at the deadline", function()
    local exit = scheduler:run(Effect.never:timeoutOrElse(50, function()
      return Effect.succeed("fallback")
    end))
    assert.are.equal("fallback", h.valueOf(exit))
    assert.are.equal(50, scheduler:now())
  end)
end)
