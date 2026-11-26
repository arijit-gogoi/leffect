-- Deferred (specifications/35-deferred.md §35.1): completed once, by any
-- fiber, and awaited by any number of fibers.

local leffect = require("leffect")
local Cause = leffect.Cause
local Deferred = leffect.Deferred
local Effect = leffect.Effect
local Exit = leffect.Exit
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

describe("Deferred", function()
  local scheduler
  before_each(function()
    scheduler = TestScheduler.new()
  end)

  describe("await", function()
    it("waits until the Deferred succeeds, then succeeds with the value", function()
      local d = Deferred.makeUnsafe()
      local fiber = h.started(scheduler, Deferred.await(d))
      assert.is_nil(fiber.exit)
      Effect.runSync(Deferred.succeed(d, "v"))
      scheduler:flush()
      assert.are.equal("v", h.valueOf(fiber.exit))
    end)

    it("fails with the error, or dies with the defect", function()
      local failed, died = Deferred.makeUnsafe(), Deferred.makeUnsafe()
      local a = h.started(scheduler, failed:await())
      local b = h.started(scheduler, died:await())
      Effect.runSync(failed:fail("e"))
      Effect.runSync(died:die("d"))
      scheduler:flush()
      assert.are.same({ "e" }, Cause.failures(h.causeOf(a.exit)))
      assert.are.same({ "d" }, Cause.defects(h.causeOf(b.exit)))
    end)

    it("succeeds with nil", function()
      local d = Deferred.makeUnsafe()
      local fiber = h.started(scheduler, d:await())
      Effect.runSync(d:succeed(nil))
      scheduler:flush()
      assert.is_nil(h.valueOf(fiber.exit))
    end)

    it("resumes three awaiters in the order they started waiting", function()
      local d = Deferred.makeUnsafe()
      local log, record = h.recorder()
      for i = 1, 3 do
        scheduler:fork(d:await():flatMap(function()
          return record(i)
        end))
      end
      scheduler:flush()
      Effect.runSync(d:succeed(true))
      scheduler:flush()
      assert.are.same({ 1, 2, 3 }, log)
    end)

    it("doesn't suspend after completion", function()
      local d = Deferred.makeUnsafe()
      Effect.runSync(d:succeed(5))
      assert.are.equal(5, Effect.runSync(d:await()))
    end)
  end)

  it("a second completion succeeds with false, and awaiters see the first", function()
    local d = Deferred.makeUnsafe()
    local fiber = h.started(scheduler, d:await())
    assert.is_true(Effect.runSync(d:succeed(1)))
    assert.is_false(Effect.runSync(d:succeed(2)))
    assert.is_false(Effect.runSync(d:fail("x")))
    scheduler:flush()
    assert.are.equal(1, h.valueOf(fiber.exit))
    assert.are.equal(1, Effect.runSync(d:await()))
  end)

  describe("completeWith and complete", function()
    local function counting()
      local runs = 0
      return function()
        return runs
      end,
        Effect.sync(function()
          runs = runs + 1
          return runs
        end)
    end

    it("with completeWith, each awaiter runs the effect", function()
      local runs, eff = counting()
      local d = Deferred.makeUnsafe()
      local a = h.started(scheduler, d:await())
      local b = h.started(scheduler, d:await())
      assert.is_true(Effect.runSync(Deferred.completeWith(d, eff)))
      assert.are.equal(0, runs())
      scheduler:flush()
      assert.are.equal(2, runs())
      assert.are.same({ 1, 2 }, { h.valueOf(a.exit), h.valueOf(b.exit) })
    end)

    it("complete runs the effect once, and awaiters share its exit", function()
      local runs, eff = counting()
      local d = Deferred.makeUnsafe()
      local a = h.started(scheduler, d:await())
      local b = h.started(scheduler, d:await())
      assert.is_true(Effect.runSync(Deferred.complete(d, eff)))
      scheduler:flush()
      assert.are.equal(1, runs())
      assert.are.same({ 1, 1 }, { h.valueOf(a.exit), h.valueOf(b.exit) })
    end)

    it("complete doesn't run the effect on a completed Deferred", function()
      local runs, eff = counting()
      local d = Deferred.makeUnsafe()
      Effect.runSync(d:succeed(0))
      assert.is_false(Effect.runSync(d:complete(eff)))
      assert.are.equal(0, runs())
    end)
  end)

  describe("interrupt", function()
    it("fails awaiters with an interrupt holding the completing fiber's id", function()
      local d = Deferred.makeUnsafe()
      local caught = false
      local awaiter = h.started(
        scheduler,
        d:await():catchAll(function()
          caught = true
          return Effect.void
        end)
      )
      local completer = scheduler:fork(d:interrupt())
      scheduler:flush()
      assert.is_true(h.valueOf(completer.exit))
      local cause = h.causeOf(awaiter.exit)
      assert.is_true(Cause.hasInterruptsOnly(cause))
      assert.are.same({ completer.id }, Cause.interruptors(cause))
      assert.is_false(caught)
    end)

    it("interruptWith uses the given id", function()
      local d = Deferred.makeUnsafe()
      Effect.runSync(d:interruptWith(42))
      local cause = h.causeOf(Effect.runSyncExit(d:await()))
      assert.are.same({ 42 }, Cause.interruptors(cause))
    end)
  end)

  it("removes an interrupted awaiter; the others still resume", function()
    local d = Deferred.makeUnsafe()
    local a = h.started(scheduler, d:await())
    local b = h.started(scheduler, d:await())
    Effect.runSync(a:interruptFork())
    scheduler:flush()
    h.assertInterrupted(a.exit)
    local interruptedExit = a.exit
    Effect.runSync(d:succeed("v"))
    scheduler:flush()
    assert.are.equal(interruptedExit, a.exit)
    assert.are.equal("v", h.valueOf(b.exit))
  end)

  describe("into", function()
    it("completes the Deferred with a success", function()
      local d = Deferred.makeUnsafe()
      assert.is_true(Effect.runSync(Deferred.into(Effect.succeed(3), d)))
      assert.are.equal(3, Effect.runSync(d:await()))
    end)

    it("completes the Deferred with a failure", function()
      local d = Deferred.makeUnsafe()
      assert.is_true(Effect.runSync(Deferred.into(Effect.fail("e"), d)))
      local cause = h.causeOf(Effect.runSyncExit(d:await()))
      assert.are.same({ "e" }, Cause.failures(cause))
    end)

    it("completes the Deferred with the interrupt when the effect is interrupted", function()
      local d = Deferred.makeUnsafe()
      local fiber = h.started(scheduler, Deferred.into(Effect.never, d))
      fiber:interruptUnsafe(7)
      scheduler:flush()
      h.assertInterrupted(fiber.exit)
      local cause = h.causeOf(Effect.runSyncExit(d:await()))
      assert.are.same({ 7 }, Cause.interruptors(cause))
    end)
  end)

  it("the Sync variants compute their value when they run", function()
    local calls = 0
    local function f()
      calls = calls + 1
      return calls
    end
    local d1, d2, d3, d4 =
      Deferred.makeUnsafe(), Deferred.makeUnsafe(), Deferred.makeUnsafe(), Deferred.makeUnsafe()
    local effects = {
      Deferred.sync(d1, f),
      Deferred.failSync(d2, f),
      Deferred.dieSync(d3, f),
      Deferred.failCauseSync(d4, function()
        return Cause.fail(f())
      end),
    }
    assert.are.equal(0, calls)
    for _, eff in ipairs(effects) do
      assert.is_true(Effect.runSync(eff))
    end
    assert.are.equal(4, calls)
    assert.are.equal(1, Effect.runSync(d1:await()))
    assert.are.same({ 2 }, Cause.failures(h.causeOf(Effect.runSyncExit(d2:await()))))
    assert.are.same({ 3 }, Cause.defects(h.causeOf(Effect.runSyncExit(d3:await()))))
    assert.are.same({ 4 }, Cause.failures(h.causeOf(Effect.runSyncExit(d4:await()))))
  end)

  it("done and failCause complete with an Exit and a cause", function()
    local a, b = Deferred.makeUnsafe(), Deferred.makeUnsafe()
    assert.is_true(Effect.runSync(Deferred.done(a, Exit.succeed("x"))))
    assert.is_true(Effect.runSync(Deferred.failCause(b, Cause.fail("y"))))
    assert.are.equal("x", Effect.runSync(a:await()))
    assert.are.same({ "y" }, Cause.failures(h.causeOf(Effect.runSyncExit(b:await()))))
  end)

  it("isDone, isDoneUnsafe and isDeferred", function()
    local d = Effect.runSync(Deferred.make())
    assert.is_true(Deferred.isDeferred(d))
    assert.is_false(Deferred.isDeferred({}))
    assert.is_false(Effect.runSync(d:isDone()))
    assert.is_false(d:isDoneUnsafe())
    Effect.runSync(d:succeed(1))
    assert.is_true(Effect.runSync(d:isDone()))
    assert.is_true(d:isDoneUnsafe())
  end)

  it("doneUnsafe never runs fiber code: the awaiter waits for the next flush", function()
    local d = Deferred.makeUnsafe()
    local log, record = h.recorder()
    h.started(
      scheduler,
      d:await():flatMap(function()
        return record("resumed")
      end)
    )
    assert.is_true(Deferred.doneUnsafe(d, Exit.succeed(1)))
    assert.is_false(Deferred.doneUnsafe(d, Exit.succeed(2)))
    assert.are.same({}, log)
    scheduler:flush()
    assert.are.same({ "resumed" }, log)
  end)

  it("has every function as a method", function()
    local d = Deferred.makeUnsafe()
    for _, name in ipairs({
      "await",
      "completeWith",
      "done",
      "succeed",
      "fail",
      "failCause",
      "die",
      "interrupt",
      "interruptWith",
      "sync",
      "failSync",
      "failCauseSync",
      "dieSync",
      "complete",
      "isDone",
      "isDoneUnsafe",
      "doneUnsafe",
    }) do
      assert.are.equal(Deferred[name], d[name], name)
    end
  end)

  it("raises when given something other than a Deferred", function()
    ---@diagnostic disable-next-line: missing-fields
    local ok, err = pcall(Deferred.await, {})
    assert.is_false(ok)
    ---@diagnostic disable-next-line: param-type-mismatch
    assert.matches("Deferred.await: expected a Deferred", err)
    assert.has_error(function()
      ---@diagnostic disable-next-line: param-type-mismatch
      Deferred.completeWith(Deferred.makeUnsafe(), 5)
    end)
    assert.has_error(function()
      ---@diagnostic disable-next-line: missing-fields
      Deferred.into(Effect.void, {})
    end)
  end)
end)
