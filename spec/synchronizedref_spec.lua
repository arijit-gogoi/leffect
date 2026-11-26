-- SynchronizedRef (specifications/34-ref.md §34.1): a Ref whose updates may
-- run effects, one at a time.

local leffect = require("leffect")
local Effect = leffect.Effect
local SynchronizedRef = leffect.SynchronizedRef
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

local run = Effect.runSync

describe("SynchronizedRef", function()
  local scheduler
  before_each(function()
    scheduler = TestScheduler.new()
  end)

  local function slowIncrement(seen)
    return function(n)
      seen[#seen + 1] = n
      return Effect.sleep(10):as(n + 1)
    end
  end

  it("runs two effectful updates one after the other", function()
    local ref = SynchronizedRef.makeUnsafe(0)
    local seen = {}
    local a = scheduler:fork(ref:updateEffect(slowIncrement(seen)))
    local b = scheduler:fork(ref:updateEffect(slowIncrement(seen)))
    scheduler:runAll()
    h.valueOf(a.exit)
    h.valueOf(b.exit)
    assert.are.same({ 0, 1 }, seen)
    assert.are.equal(2, ref:getUnsafe())
    assert.are.equal(20, scheduler:now())
  end)

  it("leaves the value after a failing or interrupted update, and the next one runs", function()
    local ref = SynchronizedRef.makeUnsafe(1)
    local exit = Effect.runSyncExit(ref:updateEffect(function()
      return Effect.fail("e")
    end))
    h.causeOf(exit)
    assert.are.equal(1, ref:getUnsafe())
    local slow = h.started(
      scheduler,
      ref:updateEffect(function()
        return Effect.never
      end)
    )
    local queued = h.started(
      scheduler,
      ref:updateEffect(function(n)
        return Effect.succeed(n + 10)
      end)
    )
    assert.is_nil(queued.exit)
    slow:interruptUnsafe()
    scheduler:flush()
    h.assertInterrupted(slow.exit)
    h.valueOf(queued.exit)
    assert.are.equal(11, ref:getUnsafe())
  end)

  it("get doesn't wait for a running update", function()
    local ref = SynchronizedRef.makeUnsafe("old")
    h.started(
      scheduler,
      ref:updateEffect(function()
        return Effect.sleep(10):as("new")
      end)
    )
    assert.are.equal("old", run(ref:get()))
    scheduler:runAll()
    assert.are.equal("new", run(ref:get()))
  end)

  it("modifyEffect sets the pair's second value, and succeeds with its first", function()
    local ref = SynchronizedRef.makeUnsafe(5)
    local result = run(ref:modifyEffect(function(n)
      return Effect.succeed({ "was " .. n, n * 2 })
    end))
    assert.are.equal("was 5", result)
    assert.are.equal(10, ref:getUnsafe())
  end)

  it("modifyEffect dies when the effect succeeds with something other than a table", function()
    local ref = SynchronizedRef.makeUnsafe(5)
    local exit = Effect.runSyncExit(ref:modifyEffect(function()
      return Effect.succeed(3)
    end))
    assert.are.same({ "Die" }, h.tags(h.causeOf(exit)))
    assert.are.equal(5, ref:getUnsafe())
  end)

  it("has Ref's functions, each taking the permit", function()
    local ref = run(SynchronizedRef.make(1))
    assert.is_nil(run(ref:set(2)))
    assert.are.equal(2, run(ref:getAndSet(3)))
    assert.are.equal(4, run(ref:setAndGet(4)))
    assert.is_nil(run(ref:update(function(n)
      return n + 1
    end)))
    assert.are.equal(
      5,
      run(ref:getAndUpdate(function(n)
        return n + 1
      end))
    )
    assert.are.equal(
      7,
      run(ref:updateAndGet(function(n)
        return n + 1
      end))
    )
    assert.are.equal(
      "r",
      run(ref:modify(function(n)
        return "r", n * 2
      end))
    )
    assert.are.equal(14, ref:getUnsafe())
    assert.are.equal(
      14,
      run(ref:getAndUpdateEffect(function(n)
        return Effect.succeed(n + 1)
      end))
    )
    assert.are.equal(
      16,
      run(ref:updateAndGetEffect(function(n)
        return Effect.succeed(n + 1)
      end))
    )
    local exit = Effect.runSyncExit(ref:modify(function()
      return "only one"
    end))
    assert.are.same({ "Die" }, h.tags(h.causeOf(exit)))
    assert.are.equal(16, ref:getUnsafe())
  end)

  it("has every function as a method, and raises on a non-SynchronizedRef", function()
    local ref = SynchronizedRef.makeUnsafe(1)
    for _, name in ipairs({
      "get",
      "getUnsafe",
      "set",
      "getAndSet",
      "setAndGet",
      "update",
      "getAndUpdate",
      "updateAndGet",
      "modify",
      "updateEffect",
      "getAndUpdateEffect",
      "updateAndGetEffect",
      "modifyEffect",
    }) do
      assert.are.equal(SynchronizedRef[name], ref[name], name)
    end
    assert.is_true(SynchronizedRef.isSynchronizedRef(ref))
    ---@diagnostic disable-next-line: missing-fields
    local ok, err = pcall(SynchronizedRef.get, {})
    assert.is_false(ok)
    ---@diagnostic disable-next-line: param-type-mismatch
    assert.matches("SynchronizedRef.get: expected a SynchronizedRef", err)
  end)
end)
