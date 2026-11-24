-- The run loop iterates over an explicit stack of frames and never recurses,
-- so chains of any depth run in constant Lua/C stack space. runSync runs
-- them on a fiber that yields to its scheduler every 2048 ops.

local Effect = require("leffect").Effect

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
