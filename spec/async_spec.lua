-- Effect.async is a one-shot suspension with an optional canceler
-- (FIBER-DESIGN.md §6). Every wakeup goes through the scheduler.

local leffect = require("leffect")
local Cause = leffect.Cause
local Effect = leffect.Effect
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

describe("Effect.async", function()
  local scheduler
  before_each(function()
    scheduler = TestScheduler.new()
  end)

  it("suspends until resume is called, then continues with the effect", function()
    local resume
    local fiber = h.started(
      scheduler,
      Effect.async(function(r)
        resume = r
      end):map(function(n)
        return n + 1
      end)
    )
    assert.are.equal("suspended", fiber.status)
    resume(Effect.succeed(41))
    assert.is_nil(fiber:poll())
    scheduler:flush()
    assert.are.equal(42, h.valueOf(fiber:poll()))
  end)

  it("resumes with any effect, a failure included", function()
    local exit = scheduler:run(Effect.async(function(resume)
      scheduler:schedule(function()
        resume(Effect.fail("nope"))
      end)
    end))
    assert.are.same({ "nope" }, (Cause.failures(h.causeOf(exit))))
  end)

  it("doesn't suspend when resumed during register, and drops the canceler", function()
    local cancelled = false
    local exit = Effect.runSyncExit(Effect.async(function(resume)
      resume(Effect.succeed("now"))
      return function()
        cancelled = true
      end
    end))
    assert.are.equal("now", h.valueOf(exit))
    assert.is_false(cancelled)
  end)

  it("ignores every resume after the first", function()
    local exit = Effect.runSyncExit(Effect.async(function(resume)
      resume(Effect.succeed(1))
      resume(Effect.succeed(2))
    end))
    assert.are.equal(1, h.valueOf(exit))

    local later
    local fiber = h.started(
      scheduler,
      Effect.async(function(resume)
        later = resume
      end)
    )
    later(Effect.succeed("first"))
    later(Effect.fail("second"))
    scheduler:flush()
    assert.are.equal("first", h.valueOf(fiber:poll()))
    assert.are.equal(0, scheduler:pendingTasks())
  end)

  it("turns a throw in register into a defect, and ignores a later resume", function()
    local later
    local fiber = h.started(
      scheduler,
      Effect.async(function(resume)
        later = resume
        error("register failed")
      end)
    )
    local reason = h.causeOf(fiber:poll()).reasons[1]
    assert.are.equal("Die", reason._tag)
    assert.matches("register failed", reason.defect, 1, true)
    assert.matches("stack traceback:", reason.trace, 1, true)
    later(Effect.succeed(1))
    assert.are.equal(0, scheduler:pendingTasks())
  end)

  it("dies instead of hanging when resumed with nil during register", function()
    local exit = Effect.runSyncExit(Effect.async(function(resume)
      ---@diagnostic disable-next-line: param-type-mismatch
      resume(nil)
    end))
    local reason = h.causeOf(exit).reasons[1]
    assert.are.equal("Die", reason._tag)
    assert.matches("Not a valid effect: nil", reason.defect, 1, true)
  end)

  it("dies when register returns something other than a canceler", function()
    local exit = Effect.runSyncExit(Effect.async(function()
      ---@diagnostic disable-next-line: return-type-mismatch
      return 42
    end))
    local reason = h.causeOf(exit).reasons[1]
    assert.are.equal("Die", reason._tag)
    assert.matches("canceler", reason.defect, 1, true)
  end)
end)

describe("Effect.sleep", function()
  it("completes at the virtual time it asks for, not before", function()
    local scheduler = TestScheduler.new()
    local fiber = scheduler:fork(Effect.sleep(100))
    scheduler:advance(99)
    assert.is_nil(fiber:poll())
    assert.are.equal(1, scheduler:pendingTimers())
    scheduler:advance(1)
    h.valueOf(fiber:poll())
    assert.are.equal(100, scheduler:now())
    assert.are.equal(0, scheduler:pendingTimers())
  end)
end)

describe("Effect.yieldNow", function()
  it("lets another fiber run before continuing", function()
    local scheduler = TestScheduler.new()
    local log, record = h.recorder()
    scheduler:fork(record("a1")
      :flatMap(function()
        return Effect.yieldNow
      end)
      :flatMap(function()
        return record("a2")
      end))
    scheduler:fork(record("b1"))
    scheduler:runAll()
    assert.are.same({ "a1", "b1", "a2" }, log)
  end)
end)

describe("Effect.never", function()
  it("never completes", function()
    local exit, fiber = TestScheduler.new():run(Effect.never)
    assert.is_nil(exit)
    assert.are.equal("suspended", fiber.status)
  end)
end)
