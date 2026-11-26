--- Deferred: completed once, by any fiber, and awaited by any number of
--- fibers (specifications/35-deferred.md §35.1, 4.1.5's `Deferred` module).
---
--- ```lua
--- local ready = Deferred.makeUnsafe()
--- local worker = Effect.gen(function(run)
---   local config = run(ready:await())
---   return config.name
--- end)
--- -- elsewhere: run(ready:succeed({ name = "x" }))
--- ```
---
--- A Deferred stores the effect it was completed with, and each awaiter runs
--- that effect in its own fiber, as in v4. Completing it with an Exit, as
--- `succeed` and `fail` do, gives every awaiter the same result.
--- `doneUnsafe` is the bridge from callbacks: it never runs fiber code.

local Cause = require("leffect.cause")
local Waitlist = require("leffect.waitlist")
local core = require("leffect.core")
local runtime = require("leffect.runtime")

local error, getmetatable, setmetatable, type = error, getmetatable, setmetatable, type

local describe = runtime.describe
local exitSucceed, exitFailCause = core.exitSucceed, core.exitFailCause
local EXIT_TRUE, EXIT_FALSE = exitSucceed(true), exitSucceed(false)

---A value that is completed once, and awaited.
---@class leffect.Deferred
---@field completion leffect.Effect? The effect it was completed with.
---@field waiters leffect.Waitlist
---@field await fun(self: leffect.Deferred): leffect.Effect
---@field completeWith fun(self: leffect.Deferred, effect: leffect.Effect): leffect.Effect
---@field done fun(self: leffect.Deferred, exit: leffect.Exit): leffect.Effect
---@field succeed fun(self: leffect.Deferred, value: any): leffect.Effect
---@field fail fun(self: leffect.Deferred, err: any): leffect.Effect
---@field failCause fun(self: leffect.Deferred, cause: leffect.Cause): leffect.Effect
---@field die fun(self: leffect.Deferred, defect: any): leffect.Effect
---@field interrupt fun(self: leffect.Deferred): leffect.Effect
---@field interruptWith fun(self: leffect.Deferred, fiberId: integer?): leffect.Effect
---@field sync fun(self: leffect.Deferred, f: fun(): any): leffect.Effect
---@field failSync fun(self: leffect.Deferred, f: fun(): any): leffect.Effect
---@field failCauseSync fun(self: leffect.Deferred, f: fun(): leffect.Cause): leffect.Effect
---@field dieSync fun(self: leffect.Deferred, f: fun(): any): leffect.Effect
---@field complete fun(self: leffect.Deferred, effect: leffect.Effect): leffect.Effect
---@field isDone fun(self: leffect.Deferred): leffect.Effect
---@field isDoneUnsafe fun(self: leffect.Deferred): boolean
---@field doneUnsafe fun(self: leffect.Deferred, effect: leffect.Effect): boolean

local methods = {}

local DeferredMT = { __index = methods, __name = "leffect.Deferred" }

local Deferred = {}

---@param value any
---@param name string
local function checkDeferred(value, name)
  if getmetatable(value) ~= DeferredMT then
    error(name .. ": expected a Deferred, got " .. describe(value), 3)
  end
end

---@param value any
---@param name string
local function checkEffect(value, name)
  if not core.isEffect(value) then
    error(name .. ": expected an effect, got " .. describe(value), 3)
  end
end

---@param value any
---@param name string
local function checkFunction(value, name)
  if type(value) ~= "function" then
    error(name .. ": expected a function, got " .. describe(value), 3)
  end
end

--- A new Deferred, not yet completed, outside an effect.
---@return leffect.Deferred
function Deferred.makeUnsafe()
  return setmetatable({ completion = nil, waiters = Waitlist.new() }, DeferredMT)
end

local makeEffect = core.sync(Deferred.makeUnsafe)

--- An effect that succeeds with a new Deferred.
---@return leffect.Effect
function Deferred.make()
  return makeEffect
end

---@param value any
---@return boolean
function Deferred.isDeferred(value)
  return getmetatable(value) == DeferredMT
end

--- Completes `d` with `effect` at once, and wakes its awaiters, in the order
--- they started waiting. Returns whether this call completed it.
---@param d leffect.Deferred
---@param effect leffect.Effect
---@return boolean
function Deferred.doneUnsafe(d, effect)
  checkDeferred(d, "Deferred.doneUnsafe")
  checkEffect(effect, "Deferred.doneUnsafe")
  if d.completion then
    return false
  end
  d.completion = effect
  -- Cleared before the first resume, as in v4.
  local nodes = Waitlist.clear(d.waiters)
  for i = 1, #nodes do
    nodes[i].resume(effect)
  end
  return true
end

--- Waits until `d` is completed, then runs its effect: succeeds with the
--- value, or fails with the cause. An interrupted awaiter removes itself.
---@param d leffect.Deferred
---@return leffect.Effect
function Deferred.await(d)
  checkDeferred(d, "Deferred.await")
  return core.suspend(function()
    local completion = d.completion
    if completion then
      return completion
    end
    return core.async(function(resume)
      local node = { resume = resume }
      Waitlist.push(d.waiters, node)
      return function()
        Waitlist.remove(d.waiters, node)
      end
    end)
  end)
end

--- Completes `d` with `effect`. Succeeds with true, or with false if `d` was
--- already completed. Each awaiter runs `effect`.
---@param d leffect.Deferred
---@param effect leffect.Effect
---@return leffect.Effect
function Deferred.completeWith(d, effect)
  checkDeferred(d, "Deferred.completeWith")
  checkEffect(effect, "Deferred.completeWith")
  return core.sync(function()
    return Deferred.doneUnsafe(d, effect)
  end)
end

--- `completeWith` with an Exit.
---@param d leffect.Deferred
---@param exit leffect.Exit
---@return leffect.Effect
function Deferred.done(d, exit)
  checkDeferred(d, "Deferred.done")
  checkEffect(exit, "Deferred.done")
  return core.sync(function()
    return Deferred.doneUnsafe(d, exit)
  end)
end

---@param d leffect.Deferred
---@param value any
---@return leffect.Effect
function Deferred.succeed(d, value)
  checkDeferred(d, "Deferred.succeed")
  return Deferred.done(d, exitSucceed(value))
end

---@param d leffect.Deferred
---@param err any
---@return leffect.Effect
function Deferred.fail(d, err)
  checkDeferred(d, "Deferred.fail")
  return Deferred.done(d, exitFailCause(Cause.fail(err)))
end

---@param d leffect.Deferred
---@param cause leffect.Cause
---@return leffect.Effect
function Deferred.failCause(d, cause)
  checkDeferred(d, "Deferred.failCause")
  return Deferred.done(d, exitFailCause(cause))
end

---@param d leffect.Deferred
---@param defect any
---@return leffect.Effect
function Deferred.die(d, defect)
  checkDeferred(d, "Deferred.die")
  return Deferred.done(d, exitFailCause(Cause.die(defect)))
end

--- Completes `d` with an interrupt cause from `fiberId`.
---@param d leffect.Deferred
---@param fiberId integer?
---@return leffect.Effect
function Deferred.interruptWith(d, fiberId)
  checkDeferred(d, "Deferred.interruptWith")
  return Deferred.done(d, exitFailCause(Cause.interrupt(fiberId)))
end

--- Completes `d` with an interrupt cause from the current fiber.
---@param d leffect.Deferred
---@return leffect.Effect
function Deferred.interrupt(d)
  checkDeferred(d, "Deferred.interrupt")
  return core.withFiber(function(fiber)
    return Deferred.interruptWith(d, fiber.id)
  end)
end

--- Builds a function like `Deferred.sync`: `complete(d, f())`, with `f`
--- called when the effect runs.
---@param name string
---@param complete fun(d: leffect.Deferred, value: any): leffect.Effect
local function lazy(name, complete)
  return function(d, f)
    checkDeferred(d, name)
    checkFunction(f, name)
    return core.suspend(function()
      return complete(d, f())
    end)
  end
end

--- `succeed` with the value `f()`, computed when the effect runs.
Deferred.sync = lazy("Deferred.sync", Deferred.succeed)
--- `fail` with the error `f()`, computed when the effect runs.
Deferred.failSync = lazy("Deferred.failSync", Deferred.fail)
--- `failCause` with the cause `f()`, computed when the effect runs.
Deferred.failCauseSync = lazy("Deferred.failCauseSync", Deferred.failCause)
--- `die` with the defect `f()`, computed when the effect runs.
Deferred.dieSync = lazy("Deferred.dieSync", Deferred.die)

--- Runs `effect`, and completes `d` with its exit, even if `effect` is
--- interrupted. `effect` runs as interruptibly as the caller; completing is
--- uninterruptible. Succeeds with whether this call completed `d`.
---@param effect leffect.Effect
---@param d leffect.Deferred
---@return leffect.Effect
function Deferred.into(effect, d)
  checkEffect(effect, "Deferred.into")
  checkDeferred(d, "Deferred.into")
  return runtime.uninterruptibleMask(function(restore)
    return core.flatMap(core.exit(restore(effect)), function(exit)
      return Deferred.doneUnsafe(d, exit) and EXIT_TRUE or EXIT_FALSE
    end)
  end)
end

--- Runs `effect` once, and completes `d` with its exit. If `d` is already
--- completed, `effect` doesn't run, and this succeeds with false.
---@param d leffect.Deferred
---@param effect leffect.Effect
---@return leffect.Effect
function Deferred.complete(d, effect)
  checkDeferred(d, "Deferred.complete")
  checkEffect(effect, "Deferred.complete")
  return core.suspend(function()
    if d.completion then
      return EXIT_FALSE
    end
    return Deferred.into(effect, d)
  end)
end

--- Whether `d` is completed, outside an effect.
---@param d leffect.Deferred
---@return boolean
function Deferred.isDoneUnsafe(d)
  checkDeferred(d, "Deferred.isDoneUnsafe")
  return d.completion ~= nil
end

--- Succeeds with whether `d` is completed.
---@param d leffect.Deferred
---@return leffect.Effect
function Deferred.isDone(d)
  checkDeferred(d, "Deferred.isDone")
  return core.sync(function()
    return d.completion ~= nil
  end)
end

for _, name in ipairs({
  "await",
  "completeWith",
  "done",
  "succeed",
  "fail",
  "failCause",
  "die",
  "interrupt",
  "interruptWith",
  "sync",
  "failSync",
  "failCauseSync",
  "dieSync",
  "complete",
  "isDone",
  "isDoneUnsafe",
  "doneUnsafe",
}) do
  methods[name] = Deferred[name]
end

return Deferred
