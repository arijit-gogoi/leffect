-- Typed error recovery and Effect.exit (specifications/21-typed-errors.md
-- §21). Every typed catch goes through Cause.findRecoverableError, so none of
-- them recovers a defect, an interrupt, or a cause that holds a Die.

local leffect = require("leffect")
local Cause = leffect.Cause
local Effect = leffect.Effect
local Exit = leffect.Exit
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

local NotFound = { _tag = "NotFound", id = 7 }
local Timeout = { _tag = "Timeout" }

-- Returns a handler that records the error it gets in `seen`, and succeeds
-- with `result`.
local function recovers(seen, result)
  return function(err)
    seen[#seen + 1] = err
    return Effect.succeed(result)
  end
end

describe("typed catches", function()
  local seen
  before_each(function()
    seen = {}
  end)

  describe("catchTag", function()
    it("recovers a matching _tag and passes the error to the handler", function()
      local effect = Effect.fail(NotFound):catchTag("NotFound", recovers(seen, "recovered"))
      assert.are.equal("recovered", Effect.runSync(effect))
      assert.are.same({ NotFound }, seen)
      assert.are.equal(NotFound, seen[1])
    end)

    it("works as a function", function()
      local effect = Effect.catchTag(Effect.fail(NotFound), "NotFound", recovers(seen, 1))
      assert.are.equal(1, Effect.runSync(effect))
    end)

    it("accepts a list of tags", function()
      local tags = { "NotFound", "Timeout" }
      assert.are.equal(1, Effect.runSync(Effect.fail(Timeout):catchTag(tags, recovers(seen, 1))))
      assert.are.equal(2, Effect.runSync(Effect.fail(NotFound):catchTag(tags, recovers(seen, 2))))
      assert.are.same({ Timeout, NotFound }, seen)
    end)

    it("lets other errors keep failing", function()
      local exit = Effect.runSyncExit(Effect.fail(Timeout):catchTag("NotFound", recovers(seen)))
      assert.are.same({ Timeout }, (Cause.failures(h.causeOf(exit))))
      assert.are.same({}, seen)
    end)

    it("sends other errors to orElse when it is given", function()
      local others = {}
      local effect = Effect.fail(Timeout)
        :catchTag("NotFound", recovers(seen, 1), recovers(others, "else"))
      assert.are.equal("else", Effect.runSync(effect))
      assert.are.same({}, seen)
      assert.are.same({ Timeout }, others)
    end)

    it("never matches, and never raises on, errors that are not tables", function()
      for _, err in ipairs({ "NotFound", 42, true }) do
        local exit = Effect.runSyncExit(Effect.fail(err):catchTag("NotFound", recovers(seen)))
        assert.are.same({ err }, (Cause.failures(h.causeOf(exit))))
      end
      local exit = Effect.runSyncExit(Effect.fail(nil):catchTag("NotFound", recovers(seen)))
      assert.are.same({ "Fail" }, h.tags(h.causeOf(exit)))
      assert.are.same({}, seen)
    end)

    it("never matches a table without a _tag", function()
      local exit = Effect.runSyncExit(Effect.fail({}):catchTag("NotFound", recovers(seen)))
      assert.are.same({ "Fail" }, h.tags(h.causeOf(exit)))
      assert.are.same({}, seen)
    end)

    it("matches an error whose _tag comes from a metatable class", function()
      local NotFoundError = { _tag = "NotFound" }
      NotFoundError.__index = NotFoundError
      local err = setmetatable({ id = 1 }, NotFoundError)
      local effect = Effect.fail(err):catchTag("NotFound", recovers(seen, "recovered"))
      assert.are.equal("recovered", Effect.runSync(effect))
      assert.are.equal(err, seen[1])
    end)
  end)

  describe("catchTags", function()
    it("dispatches on _tag", function()
      local cases = {
        NotFound = function(e)
          return Effect.succeed("not found " .. e.id)
        end,
        Timeout = function()
          return Effect.succeed("timed out")
        end,
      }
      assert.are.equal("not found 7", Effect.runSync(Effect.fail(NotFound):catchTags(cases)))
      assert.are.equal("timed out", Effect.runSync(Effect.catchTags(Effect.fail(Timeout), cases)))
    end)

    it("lets a tag with no case keep failing, or sends it to orElse", function()
      local cases = { NotFound = recovers(seen, 1) }
      local exit = Effect.runSyncExit(Effect.fail(Timeout):catchTags(cases))
      assert.are.same({ Timeout }, (Cause.failures(h.causeOf(exit))))
      local others = {}
      assert.are.equal(
        "else",
        Effect.runSync(Effect.fail(Timeout):catchTags(cases, recovers(others, "else")))
      )
      assert.are.same({ Timeout }, others)
      assert.are.same({}, seen)
    end)

    it("ignores errors whose _tag is not a string", function()
      local cases = { [1] = recovers(seen, 1) }
      local exit = Effect.runSyncExit(Effect.fail({ _tag = 1 }):catchTags(cases))
      assert.are.same({ "Fail" }, h.tags(h.causeOf(exit)))
      assert.are.same({}, seen)
    end)
  end)

  describe("catchIf", function()
    local function isTimeout(e)
      return e == Timeout
    end

    it("recovers the errors its predicate accepts", function()
      assert.are.equal(
        1,
        Effect.runSync(Effect.fail(Timeout):catchIf(isTimeout, recovers(seen, 1)))
      )
      local exit = Effect.runSyncExit(Effect.fail(NotFound):catchIf(isTimeout, recovers(seen)))
      assert.are.same({ NotFound }, (Cause.failures(h.causeOf(exit))))
      assert.are.same({ Timeout }, seen)
    end)

    it("sends the other errors to orElse", function()
      local others = {}
      local effect = Effect.catchIf(
        Effect.fail(NotFound),
        isTimeout,
        recovers(seen, 1),
        recovers(others, "else")
      )
      assert.are.equal("else", Effect.runSync(effect))
      assert.are.same({ NotFound }, others)
    end)
  end)

  describe("none of them", function()
    local function always()
      return true
    end

    local catches = {
      catchTag = function(effect, handler)
        return effect:catchTag("NotFound", handler, handler)
      end,
      catchTags = function(effect, handler)
        return effect:catchTags({ NotFound = handler }, handler)
      end,
      catchIf = function(effect, handler)
        return effect:catchIf(always, handler, handler)
      end,
    }

    for name, catch in pairs(catches) do
      it(name .. " recovers a defect, an interrupt, or a cause that holds a Die", function()
        local died = Effect.runSyncExit(catch(Effect.die(NotFound), recovers(seen)))
        assert.are.same({ "Die" }, h.tags(h.causeOf(died)))

        local interrupted = Effect.runSyncExit(catch(Effect.interrupt, recovers(seen)))
        h.assertInterrupted(interrupted)

        local mixed = Cause.combine(Cause.fail(NotFound), Cause.die("bug"))
        local elected = Effect.runSyncExit(catch(Effect.failCause(mixed), recovers(seen)))
        local cause = h.causeOf(elected)
        assert.are.same({ "Die", "Die" }, h.tags(cause))
        assert.are.same({ NotFound, "bug" }, (Cause.defects(cause)))

        assert.are.same({}, seen)
      end)
    end
  end)
end)

describe("Effect.exit", function()
  it("succeeds with the exit of a success, a failure and a defect", function()
    local succeeded = Effect.runSync(Effect.sync(function()
      return 1
    end):exit())
    assert.are.equal(1, h.valueOf(succeeded))
    local failed = Effect.runSync(Effect.exit(Effect.fail("e"):map(tostring)))
    assert.are.same({ "e" }, (Cause.failures(h.causeOf(failed))))
    local died = Effect.runSync(Effect.sync(function()
      error("boom")
    end):exit())
    local cause = h.causeOf(died)
    assert.are.same({ "Die" }, h.tags(cause))
    assert.matches("boom", cause.reasons[1].defect, 1, true)
  end)

  it("returns an exit it is given as the success value", function()
    local exit = Exit.fail("e")
    assert.are.equal(exit, Effect.runSync(Effect.exit(exit)))
  end)

  it("doesn't run while its fiber is interrupted and interruptible", function()
    local scheduler = TestScheduler.new()
    local fiber = h.started(scheduler, Effect.never:exit())
    fiber:interruptUnsafe()
    scheduler:flush()
    h.assertInterrupted(fiber:poll())
  end)
end)
