-- Cause = Fail | Die | Interrupt | Sequential | Parallel. Queries walk the
-- tree left to right (Effect TS order) without recursion.

local Cause = require("leffect").Cause

describe("Cause", function()
  describe("constructors", function()
    it("build the five cause shapes", function()
      local fail = Cause.fail("e")
      assert.are.equal("Fail", fail._tag)
      assert.are.equal("e", fail.error)

      local die = Cause.die("d")
      assert.are.equal("Die", die._tag)
      assert.are.equal("d", die.defect)

      local interrupt = Cause.interrupt(7)
      assert.are.equal("Interrupt", interrupt._tag)
      assert.are.equal(7, interrupt.fiberId)

      local sequential = Cause.sequential(fail, die)
      assert.are.equal("Sequential", sequential._tag)
      assert.are.equal(fail, sequential.left)
      assert.are.equal(die, sequential.right)

      local parallel = Cause.parallel(fail, die)
      assert.are.equal("Parallel", parallel._tag)
      assert.are.equal(fail, parallel.left)
      assert.are.equal(die, parallel.right)
    end)

    it("isCause recognises causes only", function()
      local fail = Cause.fail("e")
      for _, cause in ipairs({
        fail,
        Cause.die("d"),
        Cause.interrupt(1),
        Cause.sequential(fail, fail),
        Cause.parallel(fail, fail),
      }) do
        assert.is_true(Cause.isCause(cause))
      end
      assert.is_false(Cause.isCause({ _tag = "Fail", error = "e" }))
      assert.is_false(Cause.isCause("Fail"))
      assert.is_false(Cause.isCause(nil))
    end)
  end)

  describe("failures and defects", function()
    local cause = Cause.sequential(
      Cause.parallel(Cause.fail("a"), Cause.die("x")),
      Cause.sequential(Cause.interrupt(1), Cause.parallel(Cause.fail("b"), Cause.die("y")))
    )

    it("list errors and defects left to right", function()
      assert.are.same({ "a", "b" }, (Cause.failures(cause)))
      assert.are.same({ "x", "y" }, (Cause.defects(cause)))
    end)

    it("return empty lists when there are none", function()
      assert.are.same({}, (Cause.failures(Cause.die("x"))))
      assert.are.same({}, (Cause.defects(Cause.fail("a"))))
    end)

    it("also return the count, so nil values are not lost", function()
      local errors, n = Cause.failures(Cause.sequential(Cause.fail(nil), Cause.fail("b")))
      assert.are.equal(2, n)
      assert.is_nil(errors[1])
      assert.are.equal("b", errors[2])
    end)
  end)

  describe("findError and findDefect", function()
    it("return true and the first match", function()
      local cause =
        Cause.parallel(Cause.die("x"), Cause.sequential(Cause.fail("a"), Cause.die("y")))
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
    end)
  end)

  describe("predicates", function()
    it("isFailure, isDie and isInterrupted look anywhere in the cause", function()
      local cause =
        Cause.sequential(Cause.interrupt(1), Cause.parallel(Cause.die("x"), Cause.fail("a")))
      assert.is_true(Cause.isFailure(cause))
      assert.is_true(Cause.isDie(cause))
      assert.is_true(Cause.isInterrupted(cause))

      assert.is_false(Cause.isFailure(Cause.die("x")))
      assert.is_false(Cause.isDie(Cause.fail("a")))
      assert.is_false(Cause.isInterrupted(Cause.fail("a")))
    end)

    it("isInterruptedOnly holds only when every leaf is an Interrupt", function()
      assert.is_true(Cause.isInterruptedOnly(Cause.interrupt(1)))
      assert.is_true(
        Cause.isInterruptedOnly(Cause.parallel(Cause.interrupt(1), Cause.interrupt(2)))
      )
      assert.is_false(
        Cause.isInterruptedOnly(Cause.sequential(Cause.interrupt(1), Cause.fail("a")))
      )
      assert.is_false(Cause.isInterruptedOnly(Cause.die("x")))
    end)
  end)

  describe("squash", function()
    it("prefers the first failure", function()
      local cause =
        Cause.sequential(Cause.die("x"), Cause.parallel(Cause.fail("a"), Cause.fail("b")))
      assert.are.equal("a", Cause.squash(cause))
    end)

    it("falls back to the first defect", function()
      local cause =
        Cause.sequential(Cause.interrupt(1), Cause.parallel(Cause.die("x"), Cause.die("y")))
      assert.are.equal("x", Cause.squash(cause))
    end)

    it("reports interruption when there is nothing else", function()
      assert.are.equal("All fibers interrupted without error", Cause.squash(Cause.interrupt(1)))
    end)
  end)

  describe("deep causes", function()
    local depth = 100000

    it("are walked without recursion when left-nested", function()
      local cause = Cause.fail(0) ---@type leffect.Cause
      for i = 1, depth do
        cause = Cause.sequential(cause, Cause.fail(i))
      end
      local errors, n = Cause.failures(cause)
      assert.are.equal(depth + 1, n)
      assert.are.equal(0, errors[1])
      assert.are.equal(depth, errors[depth + 1])
    end)

    it("are walked without recursion when right-nested", function()
      local cause = Cause.die(depth) ---@type leffect.Cause
      for i = depth - 1, 0, -1 do
        cause = Cause.parallel(Cause.die(i), cause)
      end
      local defects, n = Cause.defects(cause)
      assert.are.equal(depth + 1, n)
      assert.are.equal(0, defects[1])
      assert.are.equal(depth, defects[depth + 1])
      assert.are.equal(0, Cause.squash(cause))
    end)
  end)
end)
