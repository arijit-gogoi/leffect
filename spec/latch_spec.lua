-- Latch (specifications/35-deferred.md §35.2): a gate that fibers wait at.

local leffect = require("leffect")
local Effect = leffect.Effect
local Latch = leffect.Latch
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

describe("Latch", function()
  local scheduler
  before_each(function()
    scheduler = TestScheduler.new()
  end)

  it("await waits until open; open wakes every waiter, in order", function()
    local latch = Latch.makeUnsafe()
    local log, record = h.recorder()
    for i = 1, 3 do
      scheduler:fork(latch:await():flatMap(function()
        return record(i)
      end))
    end
    scheduler:flush()
    assert.are.same({}, log)
    assert.is_true(Effect.runSync(latch:open()))
    scheduler:flush()
    assert.are.same({ 1, 2, 3 }, log)
  end)

  it("later awaits continue at once, until close", function()
    local latch = Latch.makeUnsafe()
    Effect.runSync(latch:open())
    assert.is_nil(Effect.runSync(latch:await()))
    assert.is_true(Effect.runSync(latch:close()))
    local fiber = h.started(scheduler, latch:await())
    assert.is_nil(fiber.exit)
  end)

  it("open and close succeed with whether they changed the latch", function()
    local latch = Latch.makeUnsafe()
    assert.is_false(Effect.runSync(latch:close()))
    assert.is_true(Effect.runSync(latch:open()))
    assert.is_false(Effect.runSync(latch:open()))
    assert.is_true(Effect.runSync(latch:close()))
    assert.is_true(latch:openUnsafe())
    assert.is_false(latch:openUnsafe())
    assert.is_true(latch:closeUnsafe())
    assert.is_false(latch:closeUnsafe())
  end)

  it("release wakes the current waiters, and leaves the latch closed", function()
    local latch = Latch.makeUnsafe()
    local waiter = h.started(scheduler, latch:await())
    assert.is_true(Effect.runSync(latch:release()))
    scheduler:flush()
    h.valueOf(waiter.exit)
    assert.is_false(latch:isOpen())
    local later = h.started(scheduler, latch:await())
    assert.is_nil(later.exit)
    Effect.runSync(latch:open())
    assert.is_false(Effect.runSync(latch:release()))
  end)

  it("whenOpen runs its effect after the latch opens", function()
    local latch = Latch.makeUnsafe()
    local log, record = h.recorder()
    local fiber = h.started(scheduler, latch:whenOpen(record("ran")))
    assert.are.same({}, log)
    latch:openUnsafe()
    scheduler:flush()
    h.valueOf(fiber.exit)
    assert.are.same({ "ran" }, log)
  end)

  it("removes an interrupted waiter", function()
    local latch = Latch.makeUnsafe()
    local a = h.started(scheduler, latch:await())
    local b = h.started(scheduler, latch:await())
    a:interruptUnsafe()
    scheduler:flush()
    h.assertInterrupted(a.exit)
    assert.are.equal(1, latch.waiters.size)
    latch:openUnsafe()
    scheduler:flush()
    h.valueOf(b.exit)
  end)

  it("isOpen works, and make(true) starts open", function()
    assert.is_false(Latch.makeUnsafe():isOpen())
    assert.is_true(Latch.makeUnsafe(true):isOpen())
    local latch = Effect.runSync(Latch.make(true))
    assert.is_true(Latch.isLatch(latch))
    assert.is_true(latch:isOpen())
    assert.is_false(Effect.runSync(Latch.make()):isOpen())
  end)

  it("openUnsafe never runs fiber code: the waiter waits for the next flush", function()
    local latch = Latch.makeUnsafe()
    local log, record = h.recorder()
    h.started(scheduler, latch:whenOpen(record("resumed")))
    latch:openUnsafe()
    assert.are.same({}, log)
    scheduler:flush()
    assert.are.same({ "resumed" }, log)
  end)

  it("has every function as a method, and raises on a non-Latch", function()
    local latch = Latch.makeUnsafe()
    for _, name in ipairs({
      "await",
      "open",
      "openUnsafe",
      "release",
      "close",
      "closeUnsafe",
      "whenOpen",
      "isOpen",
    }) do
      assert.are.equal(Latch[name], latch[name], name)
    end
    ---@diagnostic disable-next-line: missing-fields
    local ok, err = pcall(Latch.open, {})
    assert.is_false(ok)
    ---@diagnostic disable-next-line: param-type-mismatch
    assert.matches("Latch.open: expected a Latch", err)
  end)
end)
