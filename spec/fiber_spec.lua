-- Fibers: fork, join, await, observers, fairness, structured concurrency,
-- and running effects synchronously (specifications/03-run-loop.md §4 and §5,
-- and specifications/08-structured-concurrency.md §8).

local leffect = require("leffect")
local Cause = leffect.Cause
local Effect = leffect.Effect
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

local function joinIt(fiber)
  return fiber:join()
end

describe("Fiber", function()
  local scheduler
  before_each(function()
    scheduler = TestScheduler.new()
  end)

  describe("fork and join", function()
    it("join returns the child's value", function()
      local child = Effect.succeed(21):map(function(n)
        return n * 2
      end)
      assert.are.equal(42, h.valueOf(scheduler:run(Effect.fork(child):flatMap(joinIt))))
    end)

    it("work as methods", function()
      assert.are.equal("m", h.valueOf(scheduler:run(Effect.succeed("m"):fork():flatMap(joinIt))))
    end)

    it("a failing child fails the joiner, which can recover", function()
      local child = Effect.fail("child failed")
      local exit = scheduler:run(Effect.fork(child):flatMap(joinIt))
      assert.are.same({ "child failed" }, (Cause.failures(h.causeOf(exit))))

      local recovered = scheduler:run(Effect.fork(child):flatMap(joinIt):catchAll(function(e)
        return Effect.succeed("recovered from " .. e)
      end))
      assert.are.equal("recovered from child failed", h.valueOf(recovered))
    end)

    it("the joiner can catch a child's interruption, as it wasn't interrupted itself", function()
      local effect = Effect.fork(Effect.interrupt):flatMap(joinIt):catchCause(function(cause)
        return Effect.succeed(Cause.hasInterruptsOnly(cause))
      end)
      assert.is_true(h.valueOf(scheduler:run(effect)))
    end)

    it("await returns the child's exit without failing", function()
      local exit = scheduler:run(Effect.fork(Effect.fail("boom")):flatMap(function(fiber)
        return fiber:await()
      end))
      local childExit = h.valueOf(exit)
      assert.are.same({ "boom" }, (Cause.failures(h.causeOf(childExit))))
    end)

    it("join on a fiber that is already done returns at once", function()
      local child = h.started(scheduler, Effect.succeed("early"))
      assert.are.equal("early", h.valueOf(scheduler:run(child:join())))
    end)
  end)

  it("Fiber.awaitAll waits for every fiber, and succeeds with their exits in order", function()
    local slow = h.started(scheduler, Effect.sleep(20):as("slow"))
    local failed = h.started(scheduler, Effect.fail("e"))
    local fast = h.started(scheduler, Effect.sleep(10):as("fast"))
    local exits = h.valueOf(scheduler:run(leffect.Fiber.awaitAll({ slow, failed, fast })))
    assert.are.equal(3, #exits)
    assert.are.equal("slow", h.valueOf(exits[1]))
    assert.are.same({ "e" }, (Cause.failures(h.causeOf(exits[2]))))
    assert.are.equal("fast", h.valueOf(exits[3]))
    assert.are.equal(20, scheduler:now())
    assert.are.same({}, h.valueOf(scheduler:run(leffect.Fiber.awaitAll({}))))
  end)

  it("gives every fiber a new, increasing ID", function()
    local a, b = scheduler:fork(Effect.void), scheduler:fork(Effect.void)
    assert.is_true(b.id > a.id)
  end)

  it("poll returns nil until the fiber is done, then its exit", function()
    local fiber = h.started(scheduler, Effect.sleep(10))
    assert.is_nil(fiber:poll())
    scheduler:advance(10)
    h.valueOf(fiber:poll())
  end)

  describe("observers", function()
    it("run once, with the final exit", function()
      local seen = {}
      local fiber = scheduler:fork(Effect.succeed("v"))
      fiber:addObserver(function(exit)
        seen[#seen + 1] = exit
      end)
      scheduler:runAll()
      assert.are.equal(1, #seen)
      assert.are.equal(fiber:poll(), seen[1])
    end)

    it("run at once when added to a fiber that is done", function()
      local fiber = h.started(scheduler, Effect.succeed("v"))
      local seen
      fiber:addObserver(function(exit)
        seen = exit
      end)
      assert.are.equal(fiber:poll(), seen)
    end)

    it("can be removed before the fiber is done", function()
      local called = false
      local fiber = scheduler:fork(Effect.succeed("v"))
      local remove = fiber:addObserver(function()
        called = true
      end)
      remove()
      scheduler:runAll()
      assert.is_false(called)
    end)
  end)

  it("interleaves fibers under the op budget", function()
    local small = TestScheduler.new({ maxOpsBeforeYield = 10 })
    local trace = {}
    local function worker(name)
      local effect = Effect.void
      for _ = 1, 50 do
        effect = effect:flatMap(function()
          trace[#trace + 1] = name
          return Effect.void
        end)
      end
      return effect
    end
    small:fork(worker("a"))
    small:fork(worker("b"))
    small:runAll()
    assert.are.equal(100, #trace)
    local switches = 0
    for i = 2, #trace do
      if trace[i] ~= trace[i - 1] then
        switches = switches + 1
      end
    end
    -- The two fibers took turns.
    assert.is_true(switches >= 4)
  end)

  describe("structured concurrency", function()
    it("a parent that finishes interrupts its running children, and exits after them", function()
      local log, record = h.recorder()
      local child = Effect.never:ensuring(record("child cleaned up"))
      local parent = Effect.fork(child)
        :flatMap(function()
          return Effect.yieldNow
        end)
        :flatMap(function()
          return record("parent body done")
        end)
      local fiber = scheduler:fork(parent)
      fiber:addObserver(function()
        log[#log + 1] = "parent exit"
      end)
      scheduler:runAll()
      assert.are.same({ "parent body done", "child cleaned up", "parent exit" }, log)
      h.valueOf(fiber:poll())
    end)

    it("daemon children outlive the parent", function()
      local log, record = h.recorder()
      local daemon
      local parent = Effect.forkDaemon(Effect.sleep(100):flatMap(function()
        return record("daemon done")
      end)):map(function(fiber)
        daemon = fiber
      end)
      local fiber = h.started(scheduler, parent)
      h.valueOf(fiber:poll())
      assert.is_nil(daemon:poll())
      scheduler:advance(100)
      assert.are.same({ "daemon done" }, log)
    end)

    it("interrupting a parent interrupts its grandchildren", function()
      local log, record = h.recorder()
      local grandchild = Effect.never:ensuring(record("grandchild cleaned up"))
      local child = Effect.fork(grandchild):flatMap(function()
        return Effect.never
      end)
      local parent = Effect.fork(child):flatMap(function()
        return Effect.never
      end)
      local fiber = h.started(scheduler, parent)
      fiber:interruptUnsafe()
      scheduler:runAll()
      assert.are.same({ "grandchild cleaned up" }, log)
      h.assertInterrupted(fiber:poll())
    end)
  end)

  describe("runSync", function()
    it("runs forked fibers to completion", function()
      assert.are.equal(1, Effect.runSync(Effect.fork(Effect.succeed(1)):flatMap(joinIt)))
    end)

    it("dies with AsyncFiberError when the effect never completes, after its finalizers", function()
      local cleaned = false
      local effect = Effect.never:ensuring(Effect.sync(function()
        cleaned = true
      end))
      local defect = h.causeOf(Effect.runSyncExit(effect)).reasons[1].defect
      assert.are.equal("AsyncFiberError", defect._tag)
      assert.is_true(cleaned)
      assert.are.equal("done", defect.fiber.status)
    end)

    it("treats a timer as asynchronous", function()
      local ok, thrown = pcall(Effect.runSync, Effect.sleep(10))
      assert.is_false(ok)
      assert.are.equal("AsyncFiberError", thrown._tag)
    end)
  end)
end)
