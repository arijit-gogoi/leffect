--- Effect: constructors, combinators and runners.
---
--- Constructors and combinators only build instruction tables; nothing runs
--- until `runSync` / `runSyncExit`. Combinators are available both as module
--- functions (`Effect.map(eff, f)`) and as methods (`eff:map(f)`).

local Cause = require("leffect.cause")
local core = require("leffect.core")
local runtime = require("leffect.runtime")

local error, setmetatable = error, setmetatable

local EffectMT = core.EffectMT
local exitSucceed, exitFailCause = core.exitSucceed, core.exitFailCause

local Effect = {}

-- succeed, fail, die and failCause return Exits (which are effects), but are
-- typed as plain effects, as in Effect TS.

--- An effect that succeeds with `value`.
---@param value any
---@return leffect.Effect
function Effect.succeed(value)
  return exitSucceed(value)
end

--- An effect that fails with the expected error `err`.
---@param err any
---@return leffect.Effect
function Effect.fail(err)
  return exitFailCause(Cause.fail(err))
end

--- An effect that dies with the defect `defect`.
---@param defect any
---@return leffect.Effect
function Effect.die(defect)
  return exitFailCause(Cause.die(defect))
end

--- An effect that fails with `cause`.
---@param cause leffect.Cause
---@return leffect.Effect
function Effect.failCause(cause)
  return exitFailCause(cause)
end

--- An effect that calls `thunk` each time it runs and succeeds with its first
--- return value. A throw inside `thunk` is a defect.
---@param thunk fun(): any
---@return leffect.Effect
function Effect.sync(thunk)
  return setmetatable({ _op = core.OP_SYNC, thunk = thunk }, EffectMT)
end

--- Transforms the success value with `f`. A throw inside `f` is a defect.
---@generic A, B
---@param self leffect.Effect
---@param f fun(value: A): B
---@return leffect.Effect
function Effect.map(self, f)
  return setmetatable({ _op = core.OP_MAP, first = self, f = f }, EffectMT)
end

--- Continues with the effect returned by `f(value)`. A throw inside `f`, or a
--- return value that is not an effect, is a defect.
---@generic A
---@param self leffect.Effect
---@param f fun(value: A): leffect.Effect
---@return leffect.Effect
function Effect.flatMap(self, f)
  return setmetatable({ _op = core.OP_ON_SUCCESS, first = self, f = f }, EffectMT)
end

--- Recovers from an expected failure with the effect returned by `f(err)`.
--- Uses the first `Fail` of the cause. Defects and interruptions are not
--- caught; they keep propagating.
---@generic E
---@param self leffect.Effect
---@param f fun(err: E): leffect.Effect
---@return leffect.Effect
function Effect.catchAll(self, f)
  return setmetatable({
    _op = core.OP_ON_FAILURE,
    first = self,
    f = function(cause)
      local found, err = Cause.findError(cause)
      if found then
        return f(err)
      end
      return exitFailCause(cause)
    end,
  }, EffectMT)
end

--- True if `value` is an effect (Exits included).
Effect.isEffect = core.isEffect

--- Runs `effect` synchronously and returns its Exit. Never throws.
Effect.runSyncExit = runtime.runSyncExit

--- Runs `effect` synchronously and returns its success value. On failure it
--- throws `Cause.squash` of the cause: the first error, else the first defect.
---@param effect leffect.Effect
---@return any
function Effect.runSync(effect)
  local exit = runtime.runSyncExit(effect)
  if exit._op == core.OP_FAILURE then
    error(Cause.squash(exit.cause), 0)
  end
  return exit.value
end

local methods = core.methods
methods.map = Effect.map
methods.flatMap = Effect.flatMap
methods.catchAll = Effect.catchAll

return Effect
