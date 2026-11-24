-- As in Effect v4, a Cause is a flat list of reasons (Fail, Die and
-- Interrupt) in the order they happened.

local Cause = require("leffect").Cause

local function tags(cause)
  local out = {}
  for i, reason in ipairs(cause.reasons) do
    out[i] = reason._tag
  end
  return out
end

describe("Cause", function()
  describe("constructors", function()
    it("build a cause with a single reason", function()
      assert.are.same({ { _tag = "Fail", error = "e" } }, Cause.fail("e").reasons)
      assert.are.same({ { _tag = "Die", defect = "d", trace = "t" } }, Cause.die("d", "t").reasons)
      assert.are.same({ { _tag = "Die", defect = "d" } }, Cause.die("d").reasons)
      assert.are.same({ { _tag = "Interrupt", fiberId = 7 } }, Cause.interrupt(7).reasons)
      assert.are.same({ { _tag = "Interrupt" } }, Cause.interrupt().reasons)
    end)

    it("empty has no reasons", function()
      assert.are.same({}, Cause.empty.reasons)
      assert.is_true(Cause.isEmpty(Cause.empty))
      assert.is_false(Cause.isEmpty(Cause.fail("e")))
    end)

    it("fromReasons keeps every reason, duplicates included", function()
      local reason = { _tag = "Fail", error = "a" }
      local cause = Cause.fromReasons({ reason, reason })
      assert.is_true(Cause.isCause(cause))
      assert.are.equal(2, #cause.reasons)
      assert.are.equal(reason, cause.reasons[2])
    end)

    it("isCause recognises causes only", function()
      for _, cause in ipairs({ Cause.empty, Cause.fail("e"), Cause.die("d"), Cause.interrupt(1) }) do
        assert.is_true(Cause.isCause(cause))
      end
      assert.is_false(Cause.isCause({ reasons = {} }))
      assert.is_false(Cause.isCause("Fail"))
      assert.is_false(Cause.isCause(nil))
    end)
  end)

  describe("combine", function()
    it("appends the reasons of the second cause, keeping their order", function()
      local cause =
        Cause.combine(Cause.combine(Cause.fail("a"), Cause.die("x")), Cause.interrupt(1))
      assert.are.same({ "Fail", "Die", "Interrupt" }, tags(cause))
    end)

    it("treats the empty cause as the identity", function()
      local fail = Cause.fail("a")
      assert.are.equal(fail, Cause.combine(fail, Cause.empty))
      assert.are.equal(fail, Cause.combine(Cause.empty, fail))
    end)

    it("skips reasons the first cause already has", function()
      assert.are.equal(1, #Cause.combine(Cause.fail("a"), Cause.fail("a")).reasons)
      assert.are.equal(1, #Cause.combine(Cause.die("x", "t1"), Cause.die("x", "t2")).reasons)
      local cause =
        Cause.combine(Cause.interrupt(1), Cause.combine(Cause.interrupt(1), Cause.interrupt(2)))
      assert.are.same({ "Interrupt", "Interrupt" }, tags(cause))
      assert.are.same({ 1, 2 }, Cause.interruptors(cause))
    end)

    it("returns the first cause when the second adds nothing", function()
      local cause = Cause.combine(Cause.fail("a"), Cause.die("x"))
      assert.are.equal(cause, Cause.combine(cause, Cause.fail("a")))
    end)

    it("keeps reasons of different kinds with equal payloads", function()
      assert.are.same({ "Fail", "Die" }, tags(Cause.combine(Cause.fail("x"), Cause.die("x"))))
    end)

    it("leaves its arguments unchanged", function()
      local a, b = Cause.fail("a"), Cause.fail("b")
      assert.are.same({ "Fail", "Fail" }, tags(Cause.combine(a, b)))
      assert.are.equal(1, #a.reasons)
      assert.are.equal(1, #b.reasons)
    end)
  end)

  describe("failures and defects", function()
    local cause = Cause.fromReasons({
      { _tag = "Fail", error = "a" },
      { _tag = "Die", defect = "x" },
      { _tag = "Interrupt", fiberId = 1 },
      { _tag = "Fail", error = "b" },
      { _tag = "Die", defect = "y" },
    })

    it("list errors and defects in order", function()
      assert.are.same({ "a", "b" }, (Cause.failures(cause)))
      assert.are.same({ "x", "y" }, (Cause.defects(cause)))
    end)

    it("return empty lists when there are none", function()
      assert.are.same({}, (Cause.failures(Cause.die("x"))))
      assert.are.same({}, (Cause.defects(Cause.fail("a"))))
    end)

    it("also return the count, so nil values are not lost", function()
      local errors, n = Cause.failures(Cause.combine(Cause.fail(nil), Cause.fail("b")))
      assert.are.equal(2, n)
      assert.is_nil(errors[1])
      assert.are.equal("b", errors[2])
    end)
  end)

  describe("interruptors", function()
    it("lists the distinct interrupting fiber IDs in order", function()
      local cause = Cause.fromReasons({
        { _tag = "Interrupt", fiberId = 3 },
        { _tag = "Fail", error = "a" },
        { _tag = "Interrupt" },
        { _tag = "Interrupt", fiberId = 1 },
        { _tag = "Interrupt", fiberId = 3 },
      })
      assert.are.same({ 3, 1 }, Cause.interruptors(cause))
      assert.are.same({}, Cause.interruptors(Cause.fail("a")))
    end)
  end)

  describe("findError and findDefect", function()
    it("return true and the first match", function()
      local cause = Cause.fromReasons({
        { _tag = "Die", defect = "x" },
        { _tag = "Fail", error = "a" },
        { _tag = "Die", defect = "y" },
      })
      assert.are.same({ true, "a" }, { Cause.findError(cause) })
      assert.are.same({ true, "x" }, { Cause.findDefect(cause) })
    end)

    it("return true for a nil value", function()
      local found, err = Cause.findError(Cause.fail(nil))
      assert.is_true(found)
      assert.is_nil(err)
    end)

    it("return false when there is no match", function()
      assert.is_false((Cause.findError(Cause.die("x"))))
      assert.is_false((Cause.findDefect(Cause.interrupt(1))))
      assert.is_false((Cause.findError(Cause.empty)))
    end)
  end)

  describe("predicates", function()
    it("hasFails, hasDies and hasInterrupts look at every reason", function()
      local cause = Cause.fromReasons({
        { _tag = "Interrupt", fiberId = 1 },
        { _tag = "Die", defect = "x" },
        { _tag = "Fail", error = "a" },
      })
      assert.is_true(Cause.hasFails(cause))
      assert.is_true(Cause.hasDies(cause))
      assert.is_true(Cause.hasInterrupts(cause))

      assert.is_false(Cause.hasFails(Cause.die("x")))
      assert.is_false(Cause.hasDies(Cause.fail("a")))
      assert.is_false(Cause.hasInterrupts(Cause.fail("a")))
    end)

    it("hasInterruptsOnly needs at least one reason, and only interrupts", function()
      assert.is_true(Cause.hasInterruptsOnly(Cause.interrupt(1)))
      assert.is_true(Cause.hasInterruptsOnly(Cause.combine(Cause.interrupt(1), Cause.interrupt(2))))
      assert.is_false(Cause.hasInterruptsOnly(Cause.combine(Cause.interrupt(1), Cause.fail("a"))))
      assert.is_false(Cause.hasInterruptsOnly(Cause.die("x")))
      assert.is_false(Cause.hasInterruptsOnly(Cause.empty))
    end)
  end)

  describe("squash", function()
    it("prefers the first failure", function()
      local cause = Cause.fromReasons({
        { _tag = "Die", defect = "x" },
        { _tag = "Fail", error = "a" },
        { _tag = "Fail", error = "b" },
      })
      assert.are.equal("a", Cause.squash(cause))
    end)

    it("falls back to the first defect", function()
      local cause = Cause.fromReasons({
        { _tag = "Interrupt", fiberId = 1 },
        { _tag = "Die", defect = "x" },
        { _tag = "Die", defect = "y" },
      })
      assert.are.equal("x", Cause.squash(cause))
    end)

    it("reports interruption when there is nothing else", function()
      assert.are.equal("All fibers interrupted without error", Cause.squash(Cause.interrupt(1)))
    end)

    it("reports an empty cause", function()
      assert.are.equal("Empty cause", Cause.squash(Cause.empty))
    end)
  end)

  describe("error values", function()
    it("TimeoutError is a tagged table with a message", function()
      local err = Cause.TimeoutError()
      assert.are.equal("TimeoutError", err._tag)
      assert.are.equal("string", type(err.message))
      assert.matches("^TimeoutError: ", tostring(err))
      assert.are.equal("too slow", Cause.TimeoutError("too slow").message)
    end)

    it("AsyncFiberError is a tagged table holding the fiber", function()
      local fiber = {}
      local err = Cause.AsyncFiberError(fiber)
      assert.are.equal("AsyncFiberError", err._tag)
      assert.are.equal(fiber, err.fiber)
      assert.matches("^AsyncFiberError: ", tostring(err))
    end)
  end)
end)
