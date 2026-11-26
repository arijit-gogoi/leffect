-- The run loop iterates over an explicit stack of frames and never recurses,
-- so chains of any depth run in constant Lua/C stack space. runSync runs
-- them on a fiber that yields to its scheduler every 2048 ops.
--
-- Also the runners' options and runCallback (specifications/28-running.md
-- §28).

local leffect = require("leffect")
local Cause = leffect.Cause
local Effect = leffect.Effect
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

local N = 1000000

local function inc(n)
  return n + 1
end

local function succeedInc(n)
  return Effect.succeed(n + 1)
end

describe("run loop", function()
  it("runs 1e6 left-nested flatMaps without overflowing", function()
    local effect = Effect.succeed(0)
    for _ = 1, N do
      effect = effect:flatMap(succeedInc)
    end
    assert.are.equal(N, Effect.runSync(effect))
  end)

  it("runs 1e6 recursive (right-nested) flatMaps without overflowing", function()
    local function countdown(n)
      if n == 0 then
        return Effect.succeed("done")
      end
      return Effect.succeed(n - 1):flatMap(countdown)
    end
    assert.are.equal("done", Effect.runSync(countdown(N)))
  end)

  it("runs 1e6 maps without overflowing", function()
    local effect = Effect.succeed(0)
    for _ = 1, N do
      effect = effect:map(inc)
    end
    assert.are.equal(N, Effect.runSync(effect))
  end)

  it("short-circuits a failure past 1e6 flatMaps without calling them", function()
    local calls = 0
    local function never()
      calls = calls + 1
      return Effect.succeed(nil)
    end
    local effect = Effect.fail("early")
    for _ = 1, N do
      effect = effect:flatMap(never)
    end
    local exit = Effect.runSyncExit(effect)
    assert.are.equal("Failure", exit._tag)
    assert.are.equal("early", exit.cause.reasons[1].error)
    assert.are.equal(0, calls)
  end)

  it("passes a success through 1e6 catchAll frames without calling them", function()
    local calls = 0
    local function never()
      calls = calls + 1
      return Effect.succeed(nil)
    end
    local effect = Effect.succeed("value")
    for _ = 1, N do
      effect = effect:catchAll(never)
    end
    assert.are.equal("value", Effect.runSync(effect))
    assert.are.equal(0, calls)
  end)

  it("runs 1e6 nested catchAll handlers that each fail again", function()
    local function failAgain(n)
      return Effect.fail(n + 1)
    end
    local effect = Effect.fail(0)
    for _ = 1, N do
      effect = effect:catchAll(failAgain)
    end
    local exit = Effect.runSyncExit(effect)
    assert.are.equal("Failure", exit._tag)
    assert.are.equal(N, exit.cause.reasons[1].error)
  end)

  it("recovers from a failure beneath 1e6 pending flatMaps", function()
    local effect = Effect.fail(41)
    for _ = 1, N do
      effect = effect:flatMap(succeedInc)
    end
    assert.are.equal(42, Effect.runSync(effect:catchAll(succeedInc)))
  end)
end)

describe("Effect.runCallback", function()
  local scheduler
  before_each(function()
    scheduler = TestScheduler.new()
  end)

  -- Run options whose onExit appends to `exits`.
  local function collecting(exits, extra)
    local options = {
      scheduler = scheduler,
      onExit = function(exit)
        exits[#exits + 1] = exit
      end,
    }
    for k, v in pairs(extra or {}) do
      options[k] = v
    end
    return options
  end

  it("calls onExit with the exit of a success, a failure and a defect", function()
    local exits = {}
    Effect.runCallback(Effect.succeed(1), collecting(exits))
    Effect.runCallback(Effect.fail("e"), collecting(exits))
    Effect.runCallback(
      Effect.sync(function()
        error("boom")
      end),
      collecting(exits)
    )
    assert.are.equal(0, #exits)
    scheduler:runAll()
    assert.are.equal(3, #exits)
    assert.are.equal(1, h.valueOf(exits[1]))
    assert.are.equal("e", h.causeOf(exits[2]).reasons[1].error)
    assert.are.same({ "Die" }, h.tags(h.causeOf(exits[3])))
  end)

  it("returns an interruptor; the fiber's finalizers run, and onExit gets the interrupt", function()
    local log, record = h.recorder()
    local exits = {}
    local interrupt =
      Effect.runCallback(Effect.never:ensuring(record("finalized")), collecting(exits))
    scheduler:flush()
    interrupt(7)
    scheduler:runAll()
    assert.are.same({ "finalized" }, log)
    local cause = h.causeOf(exits[1])
    assert.is_true(Cause.hasInterruptsOnly(cause))
    assert.are.same({ 7 }, Cause.interruptors(cause))

    local anonymous = {}
    local interruptAnonymously = Effect.runCallback(Effect.never, collecting(anonymous))
    scheduler:flush()
    interruptAnonymously()
    scheduler:runAll()
    local anonymousCause = h.causeOf(anonymous[1])
    assert.is_true(Cause.hasInterruptsOnly(anonymousCause))
    assert.are.same({}, Cause.interruptors(anonymousCause))
  end)

  it("stops a fiber interrupted before it starts, before any of its code runs", function()
    local ran = false
    local exits = {}
    local interrupt = Effect.runCallback(
      Effect.sync(function()
        ran = true
      end),
      collecting(exits)
    )
    interrupt()
    scheduler:runAll()
    assert.is_false(ran)
    h.assertInterrupted(exits[1])
  end)

  it("ignores the interruptor once the fiber has ended", function()
    local exits = {}
    local interrupt = Effect.runCallback(Effect.succeed(1), collecting(exits))
    scheduler:runAll()
    interrupt()
    scheduler:runAll()
    assert.are.equal(1, #exits)
    assert.are.equal(1, h.valueOf(exits[1]))
  end)

  it("runs the effect without onExit", function()
    local ran = false
    Effect.runCallback(
      Effect.sync(function()
        ran = true
      end),
      { scheduler = scheduler }
    )
    scheduler:runAll()
    assert.is_true(ran)
  end)

  it("can't stop an uninterruptible effect that has no interruptible region", function()
    local exits = {}
    local options = collecting(exits, { uninterruptible = true })
    local interrupt = Effect.runCallback(Effect.sleep(10):as("done"), options)
    scheduler:flush()
    interrupt()
    scheduler:runAll()
    assert.are.equal("done", h.valueOf(exits[1]))

    local stopped = {}
    local inner = Effect.sleep(10):flatMap(function()
      return Effect.interruptible(Effect.never)
    end)
    local interruptInner =
      Effect.runCallback(inner, collecting(stopped, { uninterruptible = true }))
    scheduler:flush()
    interruptInner()
    scheduler:runAll()
    h.assertInterrupted(stopped[1])
  end)
end)

describe("run options", function()
  it("call onFiberStart with the fiber before runFork returns", function()
    local scheduler = TestScheduler.new()
    local started
    local fiber = Effect.runFork(Effect.void, {
      scheduler = scheduler,
      onFiberStart = function(f)
        started = f
      end,
    })
    assert.are.equal(fiber, started)
    assert.are.equal("pending", fiber.status)
  end)

  it("start the root fiber uninterruptible with uninterruptible = true", function()
    local scheduler = TestScheduler.new()
    local readInterruptible = Effect.withFiber(function(fiber)
      return Effect.succeed(fiber.interruptible)
    end)
    local fiber =
      Effect.runFork(readInterruptible, { scheduler = scheduler, uninterruptible = true })
    scheduler:runAll()
    assert.is_false(h.valueOf(fiber.exit))
    local default = Effect.runFork(readInterruptible, { scheduler = scheduler })
    scheduler:runAll()
    assert.is_true(h.valueOf(default.exit))
  end)

  it("require a scheduler, in runFork and in runCallback", function()
    assert.has_error(function()
      ---@diagnostic disable-next-line: missing-parameter
      Effect.runFork(Effect.void)
    end, "Effect.runFork: options.scheduler is required")
    assert.has_error(function()
      ---@diagnostic disable-next-line: missing-fields
      Effect.runCallback(Effect.void, {})
    end, "Effect.runCallback: options.scheduler is required")
  end)
end)
