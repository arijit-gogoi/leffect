-- The test scheduler: a FIFO task queue and a virtual clock that only moves
-- when the test says so (specifications/10-scheduler.md §10.2).

local Effect = require("leffect").Effect
local TestScheduler = require("leffect.scheduler.test")

describe("TestScheduler", function()
  local scheduler
  before_each(function()
    scheduler = TestScheduler.new()
  end)

  describe("schedule and flush", function()
    it("runs nothing until flushed", function()
      local ran = false
      scheduler:schedule(function()
        ran = true
      end)
      assert.is_false(ran)
      assert.are.equal(1, scheduler:pendingTasks())
      scheduler:flush()
      assert.is_true(ran)
      assert.are.equal(0, scheduler:pendingTasks())
    end)

    it("runs tasks in FIFO order, including tasks queued while flushing", function()
      local log = {}
      scheduler:schedule(function()
        log[#log + 1] = 1
        scheduler:schedule(function()
          log[#log + 1] = 3
        end)
      end)
      scheduler:schedule(function()
        log[#log + 1] = 2
      end)
      scheduler:flush()
      assert.are.same({ 1, 2, 3 }, log)
    end)

    it("never advances time or fires timers", function()
      local fired = false
      scheduler:after(0, function()
        fired = true
      end)
      scheduler:flush()
      assert.is_false(fired)
      assert.are.equal(0, scheduler:now())
    end)

    it("errors when tasks keep scheduling tasks", function()
      local small = TestScheduler.new({ maxTasks = 100 })
      local function again()
        small:schedule(again)
      end
      small:schedule(again)
      assert.has_error(function()
        small:flush()
      end)
    end)
  end)

  describe("timers", function()
    it("advance fires due timers by due time, then insertion order", function()
      local log = {}
      scheduler:after(20, function()
        log[#log + 1] = "b"
      end)
      scheduler:after(10, function()
        log[#log + 1] = "a"
      end)
      scheduler:after(20, function()
        log[#log + 1] = "c"
      end)
      scheduler:advance(15)
      assert.are.same({ "a" }, log)
      scheduler:advance(5)
      assert.are.same({ "a", "b", "c" }, log)
    end)

    it("sets now to each timer's due time while firing it, and ends at start + ms", function()
      local seen = {}
      local function record()
        seen[#seen + 1] = scheduler:now()
      end
      scheduler:after(10, record)
      scheduler:after(30, record)
      scheduler:advance(50)
      assert.are.same({ 10, 30 }, seen)
      assert.are.equal(50, scheduler:now())
    end)

    it("flushes the tasks a timer schedules before firing the next timer", function()
      local log = {}
      scheduler:after(10, function()
        log[#log + 1] = "timer 1"
        scheduler:schedule(function()
          log[#log + 1] = "task"
        end)
      end)
      scheduler:after(10, function()
        log[#log + 1] = "timer 2"
      end)
      scheduler:advance(10)
      assert.are.same({ "timer 1", "task", "timer 2" }, log)
    end)

    it("counts a timer's delay from the current time", function()
      scheduler:advance(100)
      local fired = false
      scheduler:after(10, function()
        fired = true
      end)
      scheduler:advance(9)
      assert.is_false(fired)
      scheduler:advance(1)
      assert.is_true(fired)
    end)

    it("fires a timer added by a timer if it falls due within the same advance", function()
      local log = {}
      scheduler:after(10, function()
        log[#log + 1] = scheduler:now()
        scheduler:after(5, function()
          log[#log + 1] = scheduler:now()
        end)
      end)
      scheduler:advance(20)
      assert.are.same({ 10, 15 }, log)
    end)

    it("never fires a cancelled timer, which stops counting as pending", function()
      local fired = false
      local cancel = scheduler:after(10, function()
        fired = true
      end)
      assert.are.equal(1, scheduler:pendingTimers())
      cancel()
      cancel()
      assert.are.equal(0, scheduler:pendingTimers())
      scheduler:advance(10)
      assert.is_false(fired)
    end)

    it("ignores the cancellation of a timer that already fired", function()
      local count = 0
      local cancel = scheduler:after(10, function()
        count = count + 1
      end)
      scheduler:after(20, function() end)
      scheduler:advance(10)
      cancel()
      assert.are.equal(1, count)
      assert.are.equal(1, scheduler:pendingTimers())
    end)
  end)

  describe("runAll", function()
    it("runs every task and timer, moving the clock to each timer", function()
      local log = {}
      scheduler:schedule(function()
        log[#log + 1] = "task"
      end)
      scheduler:after(100, function()
        log[#log + 1] = "timer at " .. scheduler:now()
        scheduler:schedule(function()
          log[#log + 1] = "late task"
        end)
      end)
      scheduler:runAll()
      assert.are.same({ "task", "timer at 100", "late task" }, log)
      assert.are.equal(100, scheduler:now())
      assert.are.equal(0, scheduler:pendingTasks())
      assert.are.equal(0, scheduler:pendingTimers())
    end)
  end)

  describe("running effects", function()
    it("Effect.runFork starts a root fiber on the next tick", function()
      local ran = false
      local fiber = Effect.runFork(
        Effect.sync(function()
          ran = true
          return 42
        end),
        { scheduler = scheduler }
      )
      assert.is_false(ran)
      assert.is_nil(fiber:poll())
      scheduler:flush()
      assert.is_true(ran)
      assert.are.equal(42, fiber:poll().value)
    end)

    it("Effect.runFork needs a scheduler", function()
      assert.has_error(function()
        ---@diagnostic disable-next-line: missing-parameter
        Effect.runFork(Effect.succeed(1))
      end)
    end)

    it("fork and run are shortcuts for tests", function()
      local fiber = scheduler:fork(Effect.succeed("forked"))
      scheduler:flush()
      assert.are.equal("forked", fiber:poll().value)

      local exit, other = TestScheduler.new():run(Effect.succeed("done"))
      ---@cast exit -nil
      assert.are.equal("done", exit.value)
      assert.are.equal(exit, other:poll())
    end)
  end)
end)
