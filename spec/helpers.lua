-- Helpers shared by the fiber specs. Not a spec file itself: busted only
-- runs files whose names contain "_spec".

-- Busted gives spec files luassert as `assert`; a required module sees the
-- plain global, so it fetches luassert itself.
local assert = require("luassert")
local leffect = require("leffect")
local Cause = leffect.Cause
local Effect = leffect.Effect

local helpers = {}

--- A fresh log, and a function that builds an effect appending `entry` to it.
---@return any[] log
---@return fun(entry: any): leffect.Effect record
function helpers.recorder()
  local log = {}
  return log,
    function(entry)
      return Effect.sync(function()
        log[#log + 1] = entry
      end)
    end
end

--- Forks `effect` on `scheduler` and runs it until it suspends or finishes.
---@param scheduler leffect.TestScheduler
---@param effect leffect.Effect
---@return leffect.Fiber
function helpers.started(scheduler, effect)
  local fiber = scheduler:fork(effect)
  scheduler:flush()
  return fiber
end

--- The tags of a cause's reasons, in order.
---@param cause leffect.Cause
---@return string[]
function helpers.tags(cause)
  local tags = {}
  for i, reason in ipairs(cause.reasons) do
    tags[i] = reason._tag
  end
  return tags
end

--- Asserts that `exit` is a Success, and returns its value.
---@param exit any
---@return any
function helpers.valueOf(exit)
  assert.is_not_nil(exit)
  assert.are.equal("Success", exit._tag)
  return exit.value
end

--- Asserts that `exit` is a Failure, and returns its cause.
---@param exit any
---@return leffect.Cause
function helpers.causeOf(exit)
  assert.is_not_nil(exit)
  assert.are.equal("Failure", exit._tag)
  return exit.cause
end

--- Asserts that `exit` failed because of interruption, and nothing else.
---@param exit any
function helpers.assertInterrupted(exit)
  local cause = helpers.causeOf(exit)
  assert.is_true(Cause.hasInterruptsOnly(cause))
end

return helpers
