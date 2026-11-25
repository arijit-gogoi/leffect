--- Internal: the representation shared by every effect.
---
--- An effect is a plain table: `_op` names the instruction and the other fields
--- are its operands. All effects share one metatable, so `eff:map(f)` works
--- and `isEffect` is a metatable check. As in Effect TS, an Exit is an effect
--- too: the `Success` and `Failure` instructions are exits.
---
--- This module holds the primitive constructors. `leffect.effect` builds the
--- public API on them and adds the methods to `methods`.

---@alias leffect.Op
---| "Success"
---| "Failure"
---| "Sync"
---| "Suspend"
---| "Map"
---| "OnSuccess"
---| "OnFailure"
---| "OnExit"
---| "WithFiber"
---| "Async"
---| "Yield"

---A canceler: a function or an effect, run when an async operation is
---interrupted.
---@alias leffect.Canceler fun()|leffect.Effect

---A lazy description of a computation that succeeds with a value or fails with
---a Cause. Nothing runs until a runtime runs it.
---@class leffect.Effect
---@field _op leffect.Op
---@field map fun(self: leffect.Effect, f: fun(value: any): any): leffect.Effect
---@field flatMap fun(self: leffect.Effect, f: fun(value: any): leffect.Effect): leffect.Effect
---@field catchAll fun(self: leffect.Effect, f: fun(err: any): leffect.Effect): leffect.Effect
---@field catchCause fun(self: leffect.Effect, f: fun(cause: leffect.Cause): leffect.Effect): leffect.Effect
---@field catchIf fun(self: leffect.Effect, predicate: function, f: function, orElse: function?): leffect.Effect
---@field catchTag fun(self: leffect.Effect, tag: string|string[], f: function, orElse: function?): leffect.Effect
---@field catchTags fun(self: leffect.Effect, cases: table<string, function>, orElse: function?): leffect.Effect
---@field exit fun(self: leffect.Effect): leffect.Effect
---@field onExit fun(self: leffect.Effect, f: fun(exit: leffect.Exit): leffect.Effect?): leffect.Effect
---@field ensuring fun(self: leffect.Effect, finalizer: leffect.Effect): leffect.Effect
---@field onInterrupt fun(self: leffect.Effect, f: fun(interruptors: integer[]): leffect.Effect?): leffect.Effect
---@field uninterruptible fun(self: leffect.Effect): leffect.Effect
---@field interruptible fun(self: leffect.Effect): leffect.Effect
---@field fork fun(self: leffect.Effect): leffect.Effect
---@field forkDaemon fun(self: leffect.Effect): leffect.Effect
---@field race fun(self: leffect.Effect, that: leffect.Effect): leffect.Effect
---@field raceFirst fun(self: leffect.Effect, that: leffect.Effect): leffect.Effect
---@field timeout fun(self: leffect.Effect, ms: number): leffect.Effect
---@field timeoutOrElse fun(self: leffect.Effect, ms: number, orElse: fun(): leffect.Effect): leffect.Effect
---@field as fun(self: leffect.Effect, value: any): leffect.Effect
---@field asVoid fun(self: leffect.Effect): leffect.Effect

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
---@field f fun(arg: any, ...): any
---@field register fun(resume: fun(effect: leffect.Effect)): leffect.Canceler?

local getmetatable, setmetatable = getmetatable, setmetatable

local core = {}

core.OP_SUCCESS = "Success" -- { value }: an Exit
core.OP_FAILURE = "Failure" -- { cause }: an Exit
core.OP_SYNC = "Sync" -- { thunk }
core.OP_MAP = "Map" -- { first, f }: f(value) becomes the new value
core.OP_ON_SUCCESS = "OnSuccess" -- { first, f }: flatMap, f(value) is the next effect
core.OP_ON_FAILURE = "OnFailure" -- { first, f }: catchCause, f(cause) is the next effect
core.OP_SUSPEND = "Suspend" -- { thunk }: thunk() is the next effect
core.OP_ON_EXIT = "OnExit" -- { first, f }: finalizer, f(exit) returns an effect or nil
core.OP_WITH_FIBER = "WithFiber" -- { f }: f(fiber) is the next effect
core.OP_ASYNC = "Async" -- { register }: register(resume) returns a canceler or nil
core.OP_YIELD = "Yield" -- {}: lets other fibers run, then succeeds with nil

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

--- A Success holding nil.
core.exitVoid = core.exitSucceed(nil)

---@param thunk fun(): any
---@return leffect.Effect
function core.sync(thunk)
  return setmetatable({ _op = core.OP_SYNC, thunk = thunk }, EffectMT)
end

---@param self leffect.Effect
---@param f fun(value: any): any
---@return leffect.Effect
function core.map(self, f)
  return setmetatable({ _op = core.OP_MAP, first = self, f = f }, EffectMT)
end

---@param self leffect.Effect
---@param f fun(value: any): leffect.Effect
---@return leffect.Effect
function core.flatMap(self, f)
  return setmetatable({ _op = core.OP_ON_SUCCESS, first = self, f = f }, EffectMT)
end

---@param self leffect.Effect
---@param f fun(cause: leffect.Cause): leffect.Effect
---@return leffect.Effect
function core.catchCause(self, f)
  return setmetatable({ _op = core.OP_ON_FAILURE, first = self, f = f }, EffectMT)
end

---@param thunk fun(): leffect.Effect
---@return leffect.Effect
function core.suspend(thunk)
  return setmetatable({ _op = core.OP_SUSPEND, thunk = thunk }, EffectMT)
end

---@param self leffect.Effect
---@param f fun(exit: leffect.Exit): leffect.Effect?
---@return leffect.Effect
function core.onExit(self, f)
  return setmetatable({ _op = core.OP_ON_EXIT, first = self, f = f }, EffectMT)
end

---@param f fun(fiber: leffect.Fiber): leffect.Effect
---@return leffect.Effect
function core.withFiber(f)
  return setmetatable({ _op = core.OP_WITH_FIBER, f = f }, EffectMT)
end

---@param register fun(resume: fun(effect: leffect.Effect)): leffect.Canceler?
---@return leffect.Effect
function core.async(register)
  return setmetatable({ _op = core.OP_ASYNC, register = register }, EffectMT)
end

--- Lets the other fibers run, then succeeds with nil.
core.yieldNow = setmetatable({ _op = core.OP_YIELD }, EffectMT)

local function noop() end

---@param self leffect.Effect
---@return leffect.Effect
function core.asVoid(self)
  return core.map(self, noop)
end

---@param cause leffect.Cause
---@return leffect.Exit.Success
local function succeedWithFailure(cause)
  return core.exitSucceed(core.exitFailCause(cause))
end

--- Succeeds with the exit of `self`: never fails (4.1.5's `Effect.exit`). An
--- Exit given as `self` becomes the success value at once. Otherwise this is a
--- recovery handler, so it doesn't run while its fiber is interrupted and
--- interruptible.
---@param self leffect.Effect
---@return leffect.Effect
function core.exit(self)
  if core.isExit(self) then
    return core.exitSucceed(self)
  end
  return core.catchCause(core.map(self, core.exitSucceed), succeedWithFailure)
end

return core
