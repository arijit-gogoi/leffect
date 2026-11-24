-- Finalizers (FIBER-DESIGN.md §7.5): onExit, ensuring and onInterrupt run
-- uninterruptibly, and a finalizer's failure is added to the cause.

local leffect = require("leffect")
local Cause = leffect.Cause
local Effect = leffect.Effect
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

describe("finalizers", function()
  local scheduler
  before_each(function()
    scheduler = TestScheduler.new()
  end)

  describe("ensuring", function()
    it("runs after a success, a failure and a defect, and keeps the result", function()
      local log, record = h.recorder()
      assert.are.equal(1, Effect.runSync(Effect.succeed(1):ensuring(record("after success"))))
      local failed = Effect.runSyncExit(Effect.fail("e"):ensuring(record("after failure")))
      assert.are.same({ "e" }, (Cause.failures(h.causeOf(failed))))
      local died = Effect.runSyncExit(Effect.die("d"):ensuring(record("after defect")))
      assert.are.same({ "d" }, (Cause.defects(h.causeOf(died))))
      assert.are.same({ "after success", "after failure", "after defect" }, log)
    end)

    it("runs finalizers in reverse order on interrupt", function()
      local log, record = h.recorder()
      local fiber =
        h.started(scheduler, Effect.never:ensuring(record("inner")):ensuring(record("outer")))
      fiber:interruptUnsafe()
      scheduler:flush()
      assert.are.same({ "inner", "outer" }, log)
      h.assertInterrupted(fiber:poll())
    end)
  end)

  describe("onExit", function()
    it("passes the exit to the finalizer, which may return nothing", function()
      local seen = {}
      local function remember(exit)
        seen[#seen + 1] = exit
      end
      assert.are.equal(1, Effect.runSync(Effect.succeed(1):onExit(remember)))
      Effect.runSyncExit(Effect.fail("e"):onExit(remember))
      assert.are.equal(1, h.valueOf(seen[1]))
      assert.are.same({ "e" }, (Cause.failures(h.causeOf(seen[2]))))
    end)
  end)

  describe("a failing finalizer", function()
    it("after a success, fails with the finalizer's cause", function()
      local exit = Effect.runSyncExit(Effect.succeed(1):ensuring(Effect.fail("cleanup failed")))
      assert.are.same({ "cleanup failed" }, (Cause.failures(h.causeOf(exit))))
    end)

    it("after a failure, adds its cause after the original one", function()
      local exit =
        Effect.runSyncExit(Effect.fail("body failed"):ensuring(Effect.fail("cleanup failed")))
      assert.are.same({ "body failed", "cleanup failed" }, (Cause.failures(h.causeOf(exit))))
    end)

    it("during an interrupt, keeps the interrupt next to its own reason", function()
      local fiber = h.started(scheduler, Effect.never:ensuring(Effect.die("cleanup bug")))
      fiber:interruptUnsafe()
      scheduler:flush()
      assert.are.same({ "Interrupt", "Die" }, h.tags(h.causeOf(fiber:poll())))
    end)

    it("that throws keeps the original cause next to the defect", function()
      local exit = Effect.runSyncExit(Effect.fail("body failed"):onExit(function()
        error("finalizer exploded")
      end))
      local cause = h.causeOf(exit)
      assert.are.same({ "Fail", "Die" }, h.tags(cause))
      assert.are.same({ "body failed" }, (Cause.failures(cause)))
      assert.matches("finalizer exploded", cause.reasons[2].defect, 1, true)
    end)

    it("doesn't double the reasons when it fails with the same exit", function()
      local exit = Effect.runSyncExit(Effect.fail("e"):onExit(function(e)
        return e
      end))
      assert.are.same({ "Fail" }, h.tags(h.causeOf(exit)))
    end)
  end)

  it("a failing canceler adds its cause to the interrupt", function()
    local fiber = h.started(
      scheduler,
      Effect.async(function()
        return Effect.fail("cancel failed")
      end)
    )
    fiber:interruptUnsafe()
    scheduler:flush()
    assert.are.same({ "Interrupt", "Fail" }, h.tags(h.causeOf(fiber:poll())))
  end)

  it("run uninterruptibly: a second interrupt doesn't cut one short", function()
    local log, record = h.recorder()
    local fiber = h.started(
      scheduler,
      Effect.never:ensuring(Effect.sleep(100):flatMap(function()
        return record("cleanup done")
      end))
    )
    fiber:interruptUnsafe(1)
    scheduler:advance(50)
    fiber:interruptUnsafe(2)
    scheduler:advance(49)
    assert.is_nil(fiber:poll())
    scheduler:advance(1)
    assert.are.same({ "cleanup done" }, log)
    h.assertInterrupted(fiber:poll())
  end)

  describe("onInterrupt", function()
    it("runs only when the cause has an interrupt, and gets the interruptor IDs", function()
      local seen
      local function onInterrupt(ids)
        seen = ids
        return Effect.void
      end
      Effect.runSync(Effect.succeed(1):onInterrupt(onInterrupt))
      Effect.runSyncExit(Effect.fail("e"):onInterrupt(onInterrupt))
      assert.is_nil(seen)

      local target = h.started(scheduler, Effect.never:onInterrupt(onInterrupt))
      local interrupter = scheduler:fork(target:interrupt())
      scheduler:runAll()
      assert.are.same({ interrupter.id }, seen)
    end)

    it("also runs when the cause mixes an interrupt with other reasons", function()
      local ran = false
      local mixed = Cause.combine(Cause.fail("e"), Cause.interrupt(7))
      Effect.runSyncExit(Effect.failCause(mixed):onInterrupt(function()
        ran = true
        return Effect.void
      end))
      assert.is_true(ran)
    end)
  end)
end)
