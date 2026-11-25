-- Effect.gen on coroutines (FIBER-DESIGN.md §9). `run(eff)` yields the effect
-- to the run loop and returns its value. On failure or interrupt the
-- coroutine is abandoned, never resumed and never thrown into.

local leffect = require("leffect")
local Cause = leffect.Cause
local Effect = leffect.Effect
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

describe("Effect.gen", function()
  it("passes values through run(), and returns the body's first return value", function()
    local program = Effect.gen(function(run)
      local a = run(Effect.succeed(20))
      local b = run(Effect.sync(function()
        return 22
      end))
      local none = run(Effect.void)
      ---@diagnostic disable-next-line: redundant-return-value
      return a + b, none, "ignored"
    end)
    local exit = Effect.runSyncExit(program)
    assert.are.equal(42, h.valueOf(exit))
  end)

  it("gives the body the same run function as Leffect.run", function()
    local given
    Effect.runSync(Effect.gen(function(run)
      given = run
    end))
    assert.are.equal(leffect.run, given)
  end)

  it("fails with the failure of a run(), which never returns", function()
    local after, caught = false, false
    local exit = Effect.runSyncExit(Effect.gen(function(run)
      pcall(function()
        run(Effect.fail("e"))
      end)
      caught = true
      after = true
    end))
    assert.are.same({ "e" }, (Cause.failures(h.causeOf(exit))))
    assert.is_false(caught)
    assert.is_false(after)
  end)

  it("turns a Lua error in the body into a Die with the raw error and a traceback", function()
    local line
    local exit = Effect.runSyncExit(Effect.gen(function()
      line = debug.getinfo(1, "l").currentline + 1
      error("boom")
    end))
    local cause = h.causeOf(exit)
    assert.are.same({ "Die" }, h.tags(cause))
    local reason = cause.reasons[1]
    assert.are.equal("string", type(reason.defect))
    assert.matches("boom$", reason.defect)
    assert.matches("stack traceback:.*gen_spec%.lua:" .. line, reason.trace)
  end)

  it("keeps a thrown table as the defect, with a traceback", function()
    local thrown = { code = 1 }
    local line
    local exit = Effect.runSyncExit(Effect.gen(function()
      line = debug.getinfo(1, "l").currentline + 1
      error(thrown)
    end))
    local reason = h.causeOf(exit).reasons[1]
    assert.are.equal(thrown, reason.defect)
    assert.matches("^stack traceback:.*gen_spec%.lua:" .. line, reason.trace)
  end)

  it("turns a raw coroutine.yield into a defect", function()
    local exit = Effect.runSyncExit(Effect.gen(function()
      coroutine.yield(1)
    end))
    local reason = h.causeOf(exit).reasons[1]
    assert.are.equal("Die", reason._tag)
    assert.matches("coroutine yielded without run()", reason.defect, 1, true)
  end)

  describe("Leffect.run", function()
    it("raises a clear error outside Effect.gen", function()
      local ok, err = pcall(leffect.run, Effect.succeed(1))
      assert.is_false(ok)
      assert.matches("called outside Effect.gen", err, 1, true)
    end)

    it("raises a clear error inside a user coroutine within the body", function()
      local result = Effect.runSync(Effect.gen(function(run)
        local co = coroutine.create(function()
          return run(Effect.succeed(1))
        end)
        local ok, err = coroutine.resume(co)
        return { ok = ok, err = err }
      end))
      assert.is_false(result.ok)
      assert.matches("called outside Effect.gen", result.err, 1, true)
    end)

    it("works in a helper function the body calls", function()
      local function double(n)
        return leffect.run(Effect.succeed(n * 2))
      end
      assert.are.equal(
        42,
        Effect.runSync(Effect.gen(function()
          return double(21)
        end))
      )
    end)
  end)

  it("dies with 'Not a valid effect' when run() gets something else", function()
    local exit = Effect.runSyncExit(Effect.gen(function(run)
      ---@diagnostic disable-next-line: param-type-mismatch
      run(42)
    end))
    local reason = h.causeOf(exit).reasons[1]
    assert.are.equal("Die", reason._tag)
    assert.matches("Not a valid effect: 42", reason.defect, 1, true)
  end)

  it("abandons the coroutine on interrupt, and runs the finalizers outside it", function()
    local scheduler = TestScheduler.new()
    local log, record = h.recorder()
    local after = false
    local fiber = h.started(
      scheduler,
      Effect.gen(function(run)
        run(Effect.sleep(100))
        after = true
      end):ensuring(record("cleaned up"))
    )
    fiber:interruptUnsafe()
    scheduler:runAll()
    h.assertInterrupted(fiber:poll())
    assert.are.same({ "cleaned up" }, log)
    assert.is_false(after)
    assert.are.equal(0, scheduler:pendingTimers())
  end)

  it("runs the body again, from the start, each time the effect runs", function()
    local runs = 0
    local program = Effect.gen(function(run)
      runs = runs + 1
      return run(Effect.succeed(10)) + runs
    end)
    assert.are.equal(11, Effect.runSync(program))
    assert.are.equal(12, Effect.runSync(program))
    assert.are.equal(2, runs)
  end)

  it("runs one gen effect on several fibers at once", function()
    local scheduler = TestScheduler.new()
    local program = Effect.gen(function(run)
      local id = run(Effect.withFiber(function(fiber)
        return Effect.succeed(fiber.id)
      end))
      run(Effect.sleep(10))
      return id
    end)
    local a = scheduler:fork(program)
    local b = scheduler:fork(program)
    scheduler:runAll()
    assert.are.equal(a.id, h.valueOf(a:poll()))
    assert.are.equal(b.id, h.valueOf(b:poll()))
  end)

  it("nests", function()
    local inner = Effect.gen(function(run)
      return run(Effect.succeed(20)) + 1
    end)
    local outer = Effect.gen(function(run)
      return run(inner) * 2
    end)
    assert.are.equal(42, Effect.runSync(outer))
  end)

  it("returns an effect from the body as a plain value, without running it", function()
    local ran = false
    local effect = Effect.sync(function()
      ran = true
    end)
    assert.are.equal(
      effect,
      Effect.runSync(Effect.gen(function()
        return effect
      end))
    )
    assert.is_false(ran)
  end)

  it("recovers inside the body with catchAll", function()
    local program = Effect.gen(function(run)
      return run(Effect.fail("e"):catchAll(function(e)
        return Effect.succeed("recovered " .. e)
      end))
    end)
    assert.are.equal("recovered e", Effect.runSync(program))
  end)

  it("doesn't overflow when the body calls run() 1e5 times", function()
    local program = Effect.gen(function(run)
      local sum = 0
      for i = 1, 100000 do
        sum = sum + run(Effect.succeed(i))
      end
      return sum
    end)
    assert.are.equal(5000050000, Effect.runSync(program))
  end)
end)
