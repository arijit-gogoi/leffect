-- Exit = Success | Failure(Cause). As in Effect TS, an Exit is itself an
-- effect: it can be run, chained and returned from flatMap.

local leffect = require("leffect")
local Cause = leffect.Cause
local Effect = leffect.Effect
local Exit = leffect.Exit

describe("Exit", function()
  it("succeed builds a Success holding the value", function()
    local exit = Exit.succeed(1)
    assert.are.equal("Success", exit._tag)
    assert.are.equal(1, exit.value)
  end)

  it("fail builds a Failure whose cause is a Fail", function()
    local err = { _tag = "NotFound" }
    local exit = Exit.fail(err)
    assert.are.equal("Failure", exit._tag)
    assert.are.equal("Fail", exit.cause._tag)
    assert.are.equal(err, exit.cause.error)
  end)

  it("die builds a Failure whose cause is a Die", function()
    local exit = Exit.die("bug")
    assert.are.equal("Failure", exit._tag)
    assert.are.equal("Die", exit.cause._tag)
    assert.are.equal("bug", exit.cause.defect)
  end)

  it("failCause builds a Failure holding the cause", function()
    local cause = Cause.interrupt(3)
    local exit = Exit.failCause(cause)
    assert.are.equal("Failure", exit._tag)
    assert.are.equal(cause, exit.cause)
  end)

  it("isSuccess and isFailure tell the two apart", function()
    assert.is_true(Exit.isSuccess(Exit.succeed(nil)))
    assert.is_false(Exit.isFailure(Exit.succeed(nil)))
    assert.is_true(Exit.isFailure(Exit.fail("e")))
    assert.is_false(Exit.isSuccess(Exit.fail("e")))
  end)

  it("isExit recognises exits only", function()
    assert.is_true(Exit.isExit(Exit.succeed(1)))
    assert.is_true(Exit.isExit(Exit.die("d")))
    assert.is_false(Exit.isExit(Effect.sync(function() end)))
    assert.is_false(Exit.isExit(Effect.succeed(1):map(tostring)))
    assert.is_false(Exit.isExit({ _tag = "Success", value = 1 }))
    assert.is_false(Exit.isExit(nil))
    assert.is_false(Exit.isSuccess({ _tag = "Success" }))
  end)

  describe("is an effect", function()
    it("that can be run", function()
      assert.is_true(Effect.isEffect(Exit.succeed(1)))
      assert.are.equal(1, Effect.runSync(Exit.succeed(1)))
      local exit = Effect.runSyncExit(Exit.fail("e"))
      assert.are.equal("e", exit.cause.error)
    end)

    it("that has the effect methods", function()
      local effect = Exit.succeed(1):map(function(n)
        return n + 1
      end)
      assert.are.equal(2, Effect.runSync(effect))
      assert.are.equal("e", Effect.runSync(Exit.fail("e"):catchAll(Effect.succeed)))
    end)

    it("that can be returned from flatMap", function()
      local exit = Effect.runSyncExit(Effect.succeed(1):flatMap(function()
        return Exit.fail("late")
      end))
      assert.are.equal("Failure", exit._tag)
      assert.are.equal("late", exit.cause.error)
    end)
  end)
end)
