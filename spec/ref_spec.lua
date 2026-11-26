-- Ref (specifications/34-ref.md §34): one value that fibers share, updated
-- atomically.

local leffect = require("leffect")
local Effect = leffect.Effect
local Ref = leffect.Ref
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

local function inc(n)
  return n + 1
end

describe("Ref", function()
  it("make succeeds with a new Ref holding the value, and get reads it", function()
    local make = Ref.make(1)
    local a, b = Effect.runSync(make), Effect.runSync(make)
    assert.are_not.equal(a, b)
    assert.are.equal(1, Effect.runSync(Ref.get(a)))
  end)

  it("set, getAndSet and setAndGet", function()
    local ref = Ref.makeUnsafe(1)
    assert.is_nil(Effect.runSync(Ref.set(ref, 2)))
    assert.are.equal(2, Ref.getUnsafe(ref))
    assert.are.equal(2, Effect.runSync(Ref.getAndSet(ref, 3)))
    assert.are.equal(4, Effect.runSync(Ref.setAndGet(ref, 4)))
    assert.are.equal(4, Ref.getUnsafe(ref))
  end)

  it("update, getAndUpdate and updateAndGet", function()
    local ref = Ref.makeUnsafe(1)
    assert.is_nil(Effect.runSync(Ref.update(ref, inc)))
    assert.are.equal(2, Ref.getUnsafe(ref))
    assert.are.equal(2, Effect.runSync(Ref.getAndUpdate(ref, inc)))
    assert.are.equal(4, Effect.runSync(Ref.updateAndGet(ref, inc)))
  end)

  describe("modify", function()
    it("sets the second value f returns, and succeeds with the first", function()
      local ref = Ref.makeUnsafe(10)
      local result = Effect.runSync(Ref.modify(ref, function(n)
        return "was " .. n, n * 2
      end))
      assert.are.equal("was 10", result)
      assert.are.equal(20, Ref.getUnsafe(ref))
    end)

    it("return b, nil sets nil", function()
      local ref = Ref.makeUnsafe(10)
      assert.are.equal(
        "b",
        Effect.runSync(Ref.modify(ref, function()
          return "b", nil
        end))
      )
      assert.is_nil(Ref.getUnsafe(ref))
    end)

    it("dies if f returns one value, and the Ref keeps its value", function()
      local ref = Ref.makeUnsafe(10)
      local exit = Effect.runSyncExit(Ref.modify(ref, function()
        return "b"
      end))
      local cause = h.causeOf(exit)
      assert.are.same({ "Die" }, h.tags(cause))
      assert.are.equal(
        "Ref.modify: f must return the result and the new value",
        cause.reasons[1].defect
      )
      assert.are.equal(10, Ref.getUnsafe(ref))
    end)
  end)

  it("holds nil", function()
    local ref = Ref.makeUnsafe(nil)
    assert.is_nil(Effect.runSync(Ref.get(ref)))
    Effect.runSync(Ref.set(ref, 1))
    Effect.runSync(Ref.set(ref, nil))
    assert.is_nil(Ref.getUnsafe(ref))
  end)

  it("a hundred concurrent updates leave a hundred", function()
    local scheduler = TestScheduler.new()
    local ref = Ref.makeUnsafe(0)
    local items = {}
    for i = 1, 100 do
      items[i] = i
    end
    local exit = scheduler:run(Effect.forEach(items, function()
      return Effect.yieldNow:flatMap(function()
        return ref:update(inc)
      end)
    end, { concurrency = "unbounded", discard = true }))
    h.valueOf(exit)
    assert.are.equal(100, Ref.getUnsafe(ref))
  end)

  it("keeps its value when f throws, and the effect dies with the error", function()
    local ref = Ref.makeUnsafe(1)
    local exit = Effect.runSyncExit(Ref.update(ref, function()
      error("boom", 0)
    end))
    local cause = h.causeOf(exit)
    assert.are.equal("boom", cause.reasons[1].defect)
    assert.are.equal(1, Ref.getUnsafe(ref))
  end)

  it("building an update calls nothing, and running it twice calls f twice", function()
    local ref = Ref.makeUnsafe(0)
    local calls = 0
    local update = Ref.update(ref, function(n)
      calls = calls + 1
      return n + 1
    end)
    assert.are.equal(0, calls)
    Effect.runSync(update)
    Effect.runSync(update)
    assert.are.equal(2, calls)
    assert.are.equal(2, Ref.getUnsafe(ref))
  end)

  it("isn't an effect: running it dies with Not a valid effect", function()
    local ref = Ref.makeUnsafe(1)
    local exit = Effect.runSyncExit(Effect.gen(function(run)
      return run(ref)
    end))
    assert.matches("^Not a valid effect", h.causeOf(exit).reasons[1].defect)
  end)

  it("has every function as a method", function()
    local ref = Ref.makeUnsafe(1)
    for _, name in ipairs({
      "get",
      "set",
      "getAndSet",
      "setAndGet",
      "update",
      "getAndUpdate",
      "updateAndGet",
      "modify",
      "getUnsafe",
    }) do
      assert.are.equal(Ref[name], ref[name], name)
    end
    assert.are.equal(1, Effect.runSync(ref:get()))
    assert.are.equal(1, ref:getUnsafe())
  end)

  it("raises when given something other than a Ref or a function", function()
    local ok, err = pcall(Ref.get, {})
    assert.is_false(ok)
    assert.matches("Ref.get: expected a Ref, got table", err)
    assert.has_error(function()
      Ref.update(Ref.makeUnsafe(1), 5)
    end)
    assert.is_true(Ref.isRef(Ref.makeUnsafe(1)))
    assert.is_false(Ref.isRef({}))
  end)
end)
