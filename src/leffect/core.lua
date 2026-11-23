--- Internal: the representation shared by every effect.
---
--- An effect is a plain table: `_op` names the instruction and the other fields
--- are its operands. All effects share one metatable, so `eff:map(f)` works
--- and `isEffect` is a metatable check. As in Effect TS, an Exit is an effect
--- too: the `Success` and `Failure` instructions are exits.
---
--- `leffect.effect` adds the methods to `methods`.

---@alias leffect.Op "Success"|"Failure"|"Sync"|"Map"|"OnSuccess"|"OnFailure"

---A lazy description of a computation that succeeds with a value or fails with
---a Cause. Nothing runs until a runtime runs it.
---@class leffect.Effect
---@field _op leffect.Op
---@field map fun(self: leffect.Effect, f: fun(value: any): any): leffect.Effect
---@field flatMap fun(self: leffect.Effect, f: fun(value: any): leffect.Effect): leffect.Effect
---@field catchAll fun(self: leffect.Effect, f: fun(err: any): leffect.Effect): leffect.Effect

---@class leffect.Exit.Success : leffect.Effect
---@field _tag "Success"
---@field value any

---@class leffect.Exit.Failure : leffect.Effect
---@field _tag "Failure"
---@field cause leffect.Cause

---The outcome of running an effect.
---@alias leffect.Exit leffect.Exit.Success|leffect.Exit.Failure

---Internal: an effect seen by the run loop, with every operand an `_op` uses.
---@class leffect.Instruction : leffect.Effect
---@field value any
---@field cause leffect.Cause
---@field thunk fun(): any
---@field first leffect.Instruction
---@field f fun(arg: any): any

local getmetatable, setmetatable = getmetatable, setmetatable

local core = {}

core.OP_SUCCESS = "Success" -- { value }: an Exit
core.OP_FAILURE = "Failure" -- { cause }: an Exit
core.OP_SYNC = "Sync" -- { thunk }
core.OP_MAP = "Map" -- { first, f }: f(value) becomes the new value
core.OP_ON_SUCCESS = "OnSuccess" -- { first, f }: flatMap, f(value) is the next effect
core.OP_ON_FAILURE = "OnFailure" -- { first, f }: f(cause) is the next effect

core.methods = {}

core.EffectMT = { __index = core.methods, __name = "leffect.Effect" }

local EffectMT = core.EffectMT
local OP_SUCCESS, OP_FAILURE = core.OP_SUCCESS, core.OP_FAILURE

---@param value any
---@return boolean
function core.isEffect(value)
  return getmetatable(value) == EffectMT
end

---@param value any
---@return boolean
function core.isExit(value)
  if getmetatable(value) ~= EffectMT then
    return false
  end
  local op = value._op
  return op == OP_SUCCESS or op == OP_FAILURE
end

---@param value any
---@return leffect.Exit.Success
function core.exitSucceed(value)
  return setmetatable({ _op = OP_SUCCESS, _tag = "Success", value = value }, EffectMT)
end

---@param cause leffect.Cause
---@return leffect.Exit.Failure
function core.exitFailCause(cause)
  return setmetatable({ _op = OP_FAILURE, _tag = "Failure", cause = cause }, EffectMT)
end

return core
