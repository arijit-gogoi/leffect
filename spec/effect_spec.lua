-- Behaviour of the M0 constructors, combinators and runners, following
-- Effect TS (v4): succeed/fail/die build Exits, a throw anywhere in user code
-- is a defect, catchAll only recovers from expected failures, and runSync
-- throws Cause.squash of the failure.

local leffect = require("leffect")
local Cause = leffect.Cause
local Effect = leffect.Effect
local Exit = leffect.Exit

-- Runs `effect`, checks that it failed and returns the Cause.
local function causeOf(effect)
  local exit = Effect.runSyncExit(effect)
  assert.are.equal("Failure", exit._tag)
  return exit.cause
end

-- Returns a function that counts its calls in `counter.n` and returns `result`.
local function counted(counter, result)
  return function()
    counter.n = counter.n + 1
    return result
  end
end

local function shallowCopy(t)
  local copy = {}
  for k, v in pairs(t) do
    copy[k] = v
  end
  return copy
end

describe("Effect", function()
  describe("effects are data", function()
    it("are tables with an _op field", function()
      local effects = {
        Effect.succeed(1),
        Effect.fail("e"),
        Effect.die("d"),
        Effect.failCause(Cause.fail("e")),
        Effect.sync(function() end),
        Effect.succeed(1):map(tostring),
        Effect.succeed(1):flatMap(Effect.succeed),
        Effect.fail("e"):catchAll(Effect.succeed),
      }
      for _, effect in ipairs(effects) do
        assert.are.equal("table", type(effect))
        assert.are.equal("string", type(effect._op))
        assert.is_true(Effect.isEffect(effect))
      end
    end)

    it("isEffect rejects everything else", function()
      for _, value in ipairs({ 1, "Success", true, {}, { _op = "Success" }, print }) do
        assert.is_false(Effect.isEffect(value))
      end
      assert.is_false(Effect.isEffect(nil))
    end)

    it("run nothing while being built", function()
      local calls = { n = 0 }
      local effect = Effect.sync(counted(calls, 1))
        :map(counted(calls, 2))
        :flatMap(counted(calls, Effect.fail("e")))
        :catchAll(counted(calls, Effect.succeed(3)))
      assert.are.equal(0, calls.n)
      assert.are.equal(3, Effect.runSync(effect))
      assert.are.equal(4, calls.n)
    end)

    it("are reusable descriptions: each run re-runs the side effects", function()
      local runs = 0
      local effect = Effect.sync(function()
        runs = runs + 1
        return runs
      end):map(function(n)
        return n * 10
      end)
      assert.are.equal(10, Effect.runSync(effect))
      assert.are.equal(20, Effect.runSync(effect))
      assert.are.equal(2, runs)
    end)

    it("are not modified by running them", function()
      local nodes = { Effect.sync(function()
        return 1
      end) }
      nodes[2] = nodes[1]:map(function(n)
        return n + 1
      end)
      nodes[3] = nodes[2]:flatMap(Effect.fail)
      nodes[4] = nodes[3]:catchAll(Effect.succeed)
      local before = {}
      for i, node in ipairs(nodes) do
        before[i] = shallowCopy(node)
      end

      assert.are.equal(2, Effect.runSync(nodes[4]))

      for i, node in ipairs(nodes) do
        assert.are.same(before[i], shallowCopy(node))
      end
    end)
  end)

  describe("succeed", function()
    it("succeeds with the value", function()
      assert.are.equal(42, Effect.runSync(Effect.succeed(42)))
      local exit = Effect.runSyncExit(Effect.succeed(42))
      assert.are.equal("Success", exit._tag)
      assert.are.equal(42, exit.value)
    end)

    it("can succeed with nil", function()
      local exit = Effect.runSyncExit(Effect.succeed(nil))
      assert.are.equal("Success", exit._tag)
      assert.is_nil(exit.value)
    end)

    it("keeps the identity of a table value", function()
      local value = {}
      assert.are.equal(value, Effect.runSync(Effect.succeed(value)))
    end)
  end)

  describe("fail", function()
    it("fails with a Fail cause holding the error", function()
      local err = { _tag = "NotFound", id = 7 }
      local cause = causeOf(Effect.fail(err))
      assert.are.equal("Fail", cause._tag)
      assert.are.equal(err, cause.error)
    end)

    it("short-circuits: map, flatMap and the effects after it never run", function()
      local calls = { n = 0 }
      local effect =
        Effect.fail("boom"):map(counted(calls)):flatMap(counted(calls, Effect.sync(counted(calls))))
      local cause = causeOf(effect)
      assert.are.equal(0, calls.n)
      assert.are.equal("Fail", cause._tag)
      assert.are.equal("boom", cause.error)
    end)

    it("stops a chain at the failing step", function()
      local steps = {}
      local function step(n, result)
        return function()
          steps[#steps + 1] = n
          return result
        end
      end
      local effect = Effect.sync(step(1))
        :flatMap(step(2, Effect.fail("stop")))
        :flatMap(step(3, Effect.succeed(nil)))
        :map(step(4))
      assert.are.equal("stop", causeOf(effect).error)
      assert.are.same({ 1, 2 }, steps)
    end)
  end)

  describe("die", function()
    it("fails with a Die cause holding the defect", function()
      local defect = { message = "bug" }
      local cause = causeOf(Effect.die(defect))
      assert.are.equal("Die", cause._tag)
      assert.are.equal(defect, cause.defect)
    end)

    it("short-circuits like fail", function()
      local calls = { n = 0 }
      local cause = causeOf(Effect.die("bug"):map(counted(calls)):flatMap(counted(calls)))
      assert.are.equal(0, calls.n)
      assert.are.equal("bug", cause.defect)
    end)
  end)

  describe("failCause", function()
    it("fails with the given cause", function()
      local cause = Cause.parallel(Cause.fail("a"), Cause.die("b"))
      assert.are.equal(cause, causeOf(Effect.failCause(cause)))
    end)
  end)

  describe("sync", function()
    it("runs the thunk and succeeds with its result", function()
      assert.are.equal(
        3,
        Effect.runSync(Effect.sync(function()
          return 1 + 2
        end))
      )
    end)

    it("succeeds with nil when the thunk returns nothing", function()
      local exit = Effect.runSyncExit(Effect.sync(function() end))
      assert.are.equal("Success", exit._tag)
      assert.is_nil(exit.value)
    end)

    it("keeps only the first return value", function()
      local function two()
        return "a", "b"
      end
      assert.are.equal("a", Effect.runSync(Effect.sync(two)))
      local argCount = Effect.runSync(Effect.sync(two):map(function(...)
        return select("#", ...)
      end))
      assert.are.equal(1, argCount)
    end)

    it("turns a thrown error into a defect carrying a traceback", function()
      local cause = causeOf(Effect.sync(function()
        error("boom")
      end))
      assert.are.equal("Die", cause._tag)
      assert.are.equal("string", type(cause.defect))
      assert.matches("boom", cause.defect, 1, true)
      assert.matches("stack traceback:", cause.defect, 1, true)
      assert.matches("effect_spec.lua", cause.defect, 1, true)
    end)

    it("keeps a thrown table as the defect itself", function()
      local thrown = { code = 42 }
      local cause = causeOf(Effect.sync(function()
        error(thrown)
      end))
      assert.are.equal("Die", cause._tag)
      assert.are.equal(thrown, cause.defect)
    end)

    it("treats a throw as a defect, not a failure", function()
      local handled = { n = 0 }
      local cause = causeOf(Effect.sync(function()
        error("boom")
      end):catchAll(counted(handled, Effect.succeed("recovered"))))
      assert.are.equal(0, handled.n)
      assert.are.equal("Die", cause._tag)
      assert.are.same({}, (Cause.failures(cause)))
    end)
  end)

  describe("map", function()
    local function double(n)
      return n * 2
    end

    it("transforms the success value, as a method or a function", function()
      assert.are.equal(4, Effect.runSync(Effect.succeed(2):map(double)))
      assert.are.equal(4, Effect.runSync(Effect.map(Effect.succeed(2), double)))
    end)

    it("applies the functions in order", function()
      local effect = Effect.succeed(2)
        :map(function(n)
          return n + 1
        end)
        :map(function(n)
          return n * 10
        end)
      assert.are.equal(30, Effect.runSync(effect))
    end)

    it("can map to nil", function()
      local exit = Effect.runSyncExit(Effect.succeed(1):map(function()
        return nil
      end))
      assert.are.equal("Success", exit._tag)
      assert.is_nil(exit.value)
    end)

    it("does not run on failure", function()
      local calls = { n = 0 }
      assert.are.equal("e", causeOf(Effect.fail("e"):map(counted(calls))).error)
      assert.are.equal(0, calls.n)
    end)

    it("turns a throw into a defect carrying a traceback", function()
      local calls = { n = 0 }
      local cause = causeOf(Effect.succeed(1)
        :map(function()
          error("bad map")
        end)
        :map(counted(calls)))
      assert.are.equal("Die", cause._tag)
      assert.matches("bad map", cause.defect, 1, true)
      assert.matches("stack traceback:", cause.defect, 1, true)
      assert.are.equal(0, calls.n)
    end)
  end)

  describe("flatMap", function()
    local function addOne(n)
      return Effect.succeed(n + 1)
    end

    it("passes the value on to the next effect, as a method or a function", function()
      assert.are.equal(2, Effect.runSync(Effect.succeed(1):flatMap(addOne)))
      assert.are.equal(2, Effect.runSync(Effect.flatMap(Effect.succeed(1), addOne)))
    end)

    it("runs effects in sequence", function()
      local log = {}
      local function record(x)
        return Effect.sync(function()
          log[#log + 1] = x
          return x
        end)
      end
      local effect = record("a")
        :flatMap(function()
          return record("b")
        end)
        :flatMap(function()
          return record("c")
        end)
      assert.are.equal("c", Effect.runSync(effect))
      assert.are.same({ "a", "b", "c" }, log)
    end)

    it("fails when the returned effect fails", function()
      local cause = causeOf(Effect.succeed(1):flatMap(Effect.fail))
      assert.are.equal("Fail", cause._tag)
      assert.are.equal(1, cause.error)
    end)

    it("does not run on failure", function()
      local calls = { n = 0 }
      causeOf(Effect.fail("e"):flatMap(counted(calls, Effect.succeed(1))))
      assert.are.equal(0, calls.n)
    end)

    it("turns a throw into a defect carrying a traceback", function()
      local cause = causeOf(Effect.succeed(1):flatMap(function()
        error("bad flatMap")
      end))
      assert.are.equal("Die", cause._tag)
      assert.matches("bad flatMap", cause.defect, 1, true)
      assert.matches("stack traceback:", cause.defect, 1, true)
    end)

    it("dies when the function returns a value that is not an effect", function()
      local cause = causeOf(Effect.succeed(1):flatMap(function()
        ---@diagnostic disable-next-line: return-type-mismatch
        return 42
      end))
      assert.are.equal("Die", cause._tag)
      assert.matches("Not a valid effect: 42", cause.defect, 1, true)
    end)

    it("dies when the function returns nothing", function()
      ---@diagnostic disable-next-line: missing-return
      local cause = causeOf(Effect.succeed(1):flatMap(function() end))
      assert.are.equal("Die", cause._tag)
      assert.matches("Not a valid effect: nil", cause.defect, 1, true)
    end)

    it("still dies cleanly when the returned value has a broken __tostring", function()
      local broken = setmetatable({}, {
        __tostring = function()
          error("no string for you")
        end,
      })
      local cause = causeOf(Effect.succeed(1):flatMap(function()
        return broken
      end))
      assert.are.equal("Die", cause._tag)
      assert.matches("Not a valid effect: table", cause.defect, 1, true)
    end)
  end)

  describe("catchAll", function()
    it("recovers from a failure, passing the error to the handler", function()
      local err = { _tag = "NotFound" }
      local seen
      local function handler(e)
        seen = e
        return Effect.succeed("recovered")
      end
      assert.are.equal("recovered", Effect.runSync(Effect.fail(err):catchAll(handler)))
      assert.are.equal(err, seen)
      seen = nil
      assert.are.equal("recovered", Effect.runSync(Effect.catchAll(Effect.fail(err), handler)))
      assert.are.equal(err, seen)
    end)

    it("leaves a success alone and never calls the handler", function()
      local calls = { n = 0 }
      local effect = Effect.succeed(1):catchAll(counted(calls, Effect.succeed(2)))
      assert.are.equal(1, Effect.runSync(effect))
      assert.are.equal(0, calls.n)
    end)

    it("recovers even when the error is nil", function()
      local effect = Effect.fail(nil):catchAll(function(e)
        return Effect.succeed(e == nil)
      end)
      assert.is_true(Effect.runSync(effect))
    end)

    it("lets the chain continue after recovering", function()
      local calls = { n = 0 }
      local effect = Effect.fail(1)
        :map(counted(calls))
        :catchAll(function(e)
          return Effect.succeed(e + 1)
        end)
        :map(function(n)
          return n * 10
        end)
      assert.are.equal(20, Effect.runSync(effect))
      assert.are.equal(0, calls.n)
    end)

    it("catches a failure raised anywhere upstream", function()
      local calls = { n = 0 }
      local effect = Effect.succeed(1)
        :flatMap(function()
          return Effect.fail("deep")
        end)
        :flatMap(counted(calls, Effect.succeed(2)))
        :map(counted(calls))
        :catchAll(Effect.succeed)
      assert.are.equal("deep", Effect.runSync(effect))
      assert.are.equal(0, calls.n)
    end)

    it("replaces the original error when the handler fails", function()
      local cause = causeOf(Effect.fail("first"):catchAll(function()
        return Effect.fail("second")
      end))
      assert.are.equal("Fail", cause._tag)
      assert.are.equal("second", cause.error)
    end)

    it("lets an outer catchAll catch a failure from an inner handler", function()
      local effect = Effect.fail("first")
        :catchAll(function(e)
          return Effect.fail(e .. "+second")
        end)
        :catchAll(Effect.succeed)
      assert.are.equal("first+second", Effect.runSync(effect))
    end)

    it("uses the innermost handler only", function()
      local outer = { n = 0 }
      local effect = Effect.fail("e")
        :catchAll(function()
          return Effect.succeed("inner")
        end)
        :catchAll(counted(outer, Effect.succeed("outer")))
      assert.are.equal("inner", Effect.runSync(effect))
      assert.are.equal(0, outer.n)
    end)

    it("does not catch defects", function()
      local calls = { n = 0 }
      local defect = { message = "bug" }
      local cause = causeOf(Effect.die(defect):catchAll(counted(calls, Effect.succeed(1))))
      assert.are.equal(0, calls.n)
      assert.are.equal("Die", cause._tag)
      assert.are.equal(defect, cause.defect)
    end)

    it("does not catch interruption", function()
      local calls = { n = 0 }
      local interrupted = Effect.failCause(Cause.interrupt(7))
      local cause = causeOf(interrupted:catchAll(counted(calls, Effect.succeed(1))))
      assert.are.equal(0, calls.n)
      assert.are.equal("Interrupt", cause._tag)
      assert.are.equal(7, cause.fiberId)
    end)

    it("recovers with the first failure of a composite cause, even next to a defect", function()
      local mixed =
        Cause.sequential(Cause.die("bug"), Cause.parallel(Cause.fail("a"), Cause.fail("b")))
      local effect = Effect.failCause(mixed):catchAll(Effect.succeed)
      assert.are.equal("a", Effect.runSync(effect))
    end)

    it("turns a throw in the handler into a defect that replaces the error", function()
      local cause = causeOf(Effect.fail("e"):catchAll(function()
        error("bad handler")
      end))
      assert.are.equal("Die", cause._tag)
      assert.matches("bad handler", cause.defect, 1, true)
      assert.matches("stack traceback:", cause.defect, 1, true)
      assert.are.same({}, (Cause.failures(cause)))
    end)

    it("dies when the handler returns a value that is not an effect", function()
      local cause = causeOf(Effect.fail("e"):catchAll(function()
        ---@diagnostic disable-next-line: return-type-mismatch
        return "oops"
      end))
      assert.are.equal("Die", cause._tag)
      assert.matches("Not a valid effect: oops", cause.defect, 1, true)
    end)
  end)

  describe("runSync", function()
    it("returns the success value", function()
      assert.are.equal("ok", Effect.runSync(Effect.succeed("ok")))
    end)

    it("throws the error itself, without position information", function()
      local err = { _tag = "NotFound" }
      local ok, thrown = pcall(Effect.runSync, Effect.fail(err))
      assert.is_false(ok)
      assert.are.equal(err, thrown)
      ok, thrown = pcall(Effect.runSync, Effect.fail("nope"))
      assert.is_false(ok)
      assert.are.equal("nope", thrown)
    end)

    it("throws the defect when the effect dies", function()
      local defect = { message = "bug" }
      local ok, thrown = pcall(Effect.runSync, Effect.die(defect))
      assert.is_false(ok)
      assert.are.equal(defect, thrown)
    end)

    it("throws the first failure when the cause also has defects", function()
      local cause = Cause.parallel(Cause.die("bug"), Cause.fail("e"))
      local ok, thrown = pcall(Effect.runSync, Effect.failCause(cause))
      assert.is_false(ok)
      assert.are.equal("e", thrown)
    end)

    it("throws a message when the effect was only interrupted", function()
      local ok, thrown = pcall(Effect.runSync, Effect.failCause(Cause.interrupt(1)))
      assert.is_false(ok)
      assert.are.equal("All fibers interrupted without error", thrown)
    end)

    it("can be nested inside a running effect", function()
      local effect = Effect.sync(function()
        return Effect.runSync(Effect.succeed(20):map(function(n)
          return n + 1
        end))
      end):map(function(n)
        return n * 2
      end)
      assert.are.equal(42, Effect.runSync(effect))
    end)
  end)

  describe("runSyncExit", function()
    it("returns a Success", function()
      local exit = Effect.runSyncExit(Effect.succeed(1):map(tostring))
      assert.is_true(Exit.isSuccess(exit))
      assert.are.equal("1", exit.value)
    end)

    it("returns a Failure instead of throwing, for failures and defects", function()
      assert.is_true(Exit.isFailure(Effect.runSyncExit(Effect.fail("e"))))
      assert.is_true(Exit.isFailure(Effect.runSyncExit(Effect.sync(function()
        error("boom")
      end))))
    end)

    it("returns an Exit it is given unchanged", function()
      local exit = Exit.succeed(1)
      assert.are.equal(exit, Effect.runSyncExit(exit))
    end)

    it("fails with a defect when given something that is not an effect", function()
      local cause = causeOf(42)
      assert.are.equal("Die", cause._tag)
      assert.matches("Not a valid effect: 42", cause.defect, 1, true)
    end)
  end)
end)
