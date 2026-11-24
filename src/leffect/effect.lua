--- Effect: constructors, combinators and runners.
---
--- Constructors and combinators only build instruction tables; nothing runs
--- until a runner runs them on a fiber. Combinators are available both as
--- module functions (`Effect.map(eff, f)`) and as methods (`eff:map(f)`).

local Cause = require("leffect.cause")
local Fiber = require("leffect.fiber")
local core = require("leffect.core")

local error, setmetatable, time = error, setmetatable, os.time

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
Effect.sync = core.sync

--- Transforms the success value with `f`. A throw inside `f` is a defect.
Effect.map = core.map

--- Continues with the effect returned by `f(value)`. A throw inside `f`, or a
--- return value that is not an effect, is a defect.
Effect.flatMap = core.flatMap

--- Recovers from an expected failure with the effect returned by `f(err)`.
--- Uses the first `Fail` of the cause. Defects and interruptions are not
--- caught; they keep propagating.
---@generic E
---@param self leffect.Effect
---@param f fun(err: E): leffect.Effect
---@return leffect.Effect
function Effect.catchAll(self, f)
  return core.catchCause(self, function(cause)
    local found, err = Cause.findError(cause)
    if found then
      return f(err)
    end
    return exitFailCause(cause)
  end)
end

--- True if `value` is an effect (Exits included).
Effect.isEffect = core.isEffect

-- Runners -------------------------------------------------------------------

-- The private scheduler of runSync: tasks run when the runner flushes, and
-- timers never fire, so any timer makes the effect asynchronous.
---@class leffect.SyncScheduler : leffect.Scheduler
---@field queue fun()[]
---@field head integer
---@field tail integer
local SyncScheduler = {}
SyncScheduler.__index = SyncScheduler

local function noop() end

---@return leffect.SyncScheduler
local function newSyncScheduler()
  return setmetatable({ queue = {}, head = 1, tail = 0 }, SyncScheduler)
end

---@param task fun()
function SyncScheduler:schedule(task)
  local tail = self.tail + 1
  self.tail = tail
  self.queue[tail] = task
end

---@return fun() cancel
function SyncScheduler.after(_)
  return noop
end

---@return number
function SyncScheduler.now(_)
  return time() * 1000
end

-- Runs queued tasks until none are left, including tasks queued meanwhile.
function SyncScheduler:flush()
  local queue = self.queue
  while self.head <= self.tail do
    local head = self.head
    local task = queue[head]
    queue[head] = nil
    self.head = head + 1
    task()
  end
end

--- A root fiber running `effect` on `scheduler`, started on the next tick.
---@param effect any
---@param scheduler leffect.Scheduler
---@return leffect.Fiber
local function startRoot(effect, scheduler)
  local fiber = Fiber.new(scheduler, true)
  scheduler:schedule(function()
    fiber:evaluate(effect)
  end)
  return fiber
end

--- Runs `effect` synchronously on a fiber of its own and returns its Exit.
--- An Exit is returned as is. Never throws.
---@param effect leffect.Effect
---@return leffect.Exit
function Effect.runSyncExit(effect)
  if core.isExit(effect) then
    return effect --[[@as leffect.Exit]]
  end
  local scheduler = newSyncScheduler()
  local fiber = startRoot(effect, scheduler)
  scheduler:flush()
  local exit = fiber.exit
  if exit then
    return exit
  end
  return exitFailCause(Cause.die(Cause.AsyncFiberError(fiber)))
end

--- Runs `effect` synchronously and returns its success value. On failure it
--- throws `Cause.squash` of the cause: the first error, else the first defect.
---@param effect leffect.Effect
---@return any
function Effect.runSync(effect)
  local exit = Effect.runSyncExit(effect)
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
