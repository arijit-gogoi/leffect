--- Exit: the outcome of running an effect, `Success` or `Failure(Cause)`.
---
--- An Exit is also an effect (it shares the effect metatable), as in Effect TS.

local Cause = require("leffect.cause")
local core = require("leffect.core")

-- Exits carry the effect methods, which leffect.effect installs.
require("leffect.effect")

local exitFailCause = core.exitFailCause

local Exit = {}

--- A successful Exit holding `value`.
Exit.succeed = core.exitSucceed

--- A failed Exit holding `cause`.
Exit.failCause = exitFailCause

--- A failed Exit whose cause is the expected error `err`.
---@param err any
---@return leffect.Exit.Failure
function Exit.fail(err)
  return exitFailCause(Cause.fail(err))
end

--- A failed Exit whose cause is the defect `defect`.
---@param defect any
---@return leffect.Exit.Failure
function Exit.die(defect)
  return exitFailCause(Cause.die(defect))
end

--- True if `value` is an Exit.
Exit.isExit = core.isExit

---@param value any
---@return boolean
function Exit.isSuccess(value)
  return core.isExit(value) and value._op == core.OP_SUCCESS
end

---@param value any
---@return boolean
function Exit.isFailure(value)
  return core.isExit(value) and value._op == core.OP_FAILURE
end

return Exit
