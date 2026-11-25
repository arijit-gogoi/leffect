--- Effect: constructors, combinators and runners.
---
--- Constructors and combinators only build instruction tables; nothing runs
--- until a runner runs them on a fiber. Combinators are available both as
--- module functions (`Effect.map(eff, f)`) and as methods (`eff:map(f)`).

local Cause = require("leffect.cause")
local Context = require("leffect.context")
local Fiber = require("leffect.fiber")
local Scope = require("leffect.scope")
local core = require("leffect.core")
local runtime = require("leffect.runtime")

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

--- Recovers from an expected failure with the effect returned by `f(err)`,
--- where `err` is the first `Fail` of the cause. Interruptions are not caught.
--- A cause with a defect is not recoverable: it keeps failing, with its
--- failures elected to defects (`Cause.findRecoverableError`).
---@generic E
---@param self leffect.Effect
---@param f fun(err: E): leffect.Effect
---@return leffect.Effect
function Effect.catchAll(self, f)
  return core.catchCause(self, function(cause)
    local found, value = Cause.findRecoverableError(cause)
    if found then
      return f(value)
    end
    return exitFailCause(value)
  end)
end

--- Recovers from the expected errors for which `predicate(err)` is true, with
--- the effect returned by `f(err)`. Other errors go to `orElse(err)` if it is
--- given, and otherwise keep failing. Like `catchAll`, it never recovers an
--- interruption or a cause that holds a defect.
---@generic E
---@param self leffect.Effect
---@param predicate fun(err: E): boolean
---@param f fun(err: E): leffect.Effect
---@param orElse (fun(err: E): leffect.Effect)?
---@return leffect.Effect
function Effect.catchIf(self, predicate, f, orElse)
  return core.catchCause(self, function(cause)
    local found, value = Cause.findRecoverableError(cause)
    if not found then
      return exitFailCause(value)
    end
    if predicate(value) then
      return f(value)
    end
    if orElse then
      return orElse(value)
    end
    return exitFailCause(cause)
  end)
end

--- Recovers from the expected errors whose `_tag` is `tag`, or is one of the
--- tags when `tag` is a list, with the effect returned by `f(err)`. Errors
--- that are not tables never match. Other errors go to `orElse(err)` if it is
--- given, and otherwise keep failing.
---@param self leffect.Effect
---@param tag string|string[]
---@param f fun(err: table): leffect.Effect
---@param orElse (fun(err: any): leffect.Effect)?
---@return leffect.Effect
function Effect.catchTag(self, tag, f, orElse)
  local predicate
  if type(tag) == "table" then
    local tags = tag
    predicate = function(err)
      if type(err) ~= "table" then
        return false
      end
      local errTag = err._tag
      if errTag == nil then
        return false
      end
      for i = 1, #tags do
        if tags[i] == errTag then
          return true
        end
      end
      return false
    end
  else
    predicate = function(err)
      if type(err) ~= "table" then
        return false
      end
      local errTag = err._tag
      return errTag ~= nil and errTag == tag
    end
  end
  return Effect.catchIf(self, predicate, f, orElse)
end

--- Recovers from the expected errors whose `_tag` has a handler in `cases`, as
--- in `{ NotFound = function(err) ... end }`. Other errors go to `orElse(err)`
--- if it is given, and otherwise keep failing.
---@param self leffect.Effect
---@param cases table<string, fun(err: table): leffect.Effect>
---@param orElse (fun(err: any): leffect.Effect)?
---@return leffect.Effect
function Effect.catchTags(self, cases, orElse)
  return Effect.catchIf(self, function(err)
    if type(err) ~= "table" then
      return false
    end
    local errTag = err._tag
    return type(errTag) == "string" and cases[errTag] ~= nil
  end, function(err)
    return cases[err._tag](err)
  end, orElse)
end

--- Succeeds with the exit of `self`, so it never fails. While its fiber is
--- interrupted and interruptible, it doesn't run, like any recovery handler.
Effect.exit = core.exit

--- True if `value` is an effect (Exits included).
Effect.isEffect = core.isEffect

--- An effect that succeeds with nil.
---@type leffect.Effect
Effect.void = core.exitVoid

--- Recovers from any failure (errors, defects, interruptions) with the effect
--- returned by `f(cause)`. While the fiber is being interrupted, the handler
--- is skipped.
Effect.catchCause = core.catchCause

--- An effect built by `thunk()` each time it runs. A throw is a defect.
Effect.suspend = core.suspend

--- An effect built by `f(fiber)` from the fiber running it.
Effect.withFiber = core.withFiber

--- An effect that runs `body(run)` on a coroutine (FIBER-DESIGN.md §9).
--- Inside the body, `run(eff)` runs an effect and returns its value; helper
--- functions can call `require("leffect").run`, which is the same function.
--- The body's first return value is the result. If a `run(eff)` fails or the
--- fiber is interrupted, `run` never returns and the coroutine is abandoned,
--- so clean up with effects (`ensuring`, `acquireRelease`), not `pcall`.
Effect.gen = core.gen

--- Replaces the success value with `value`.
---@param self leffect.Effect
---@param value any
---@return leffect.Effect
function Effect.as(self, value)
  return core.map(self, function()
    return value
  end)
end

--- Replaces the success value with nil.
Effect.asVoid = core.asVoid

-- Async ---------------------------------------------------------------------

--- An effect that suspends the fiber until `register` calls `resume(effect)`;
--- it then continues with `effect`. Only the first resume counts. `register`
--- may return a canceler, a function or an effect, which runs if the fiber is
--- interrupted before the operation completes.
Effect.async = core.async

--- An effect that never completes.
Effect.never = core.async(function() end)

--- An effect that lets the other fibers run, then succeeds with nil.
Effect.yieldNow = core.yieldNow

--- An effect that succeeds with nil after `ms` milliseconds of the fiber's
--- scheduler.
---@param ms number
---@return leffect.Effect
function Effect.sleep(ms)
  return core.withFiber(function(fiber)
    local scheduler = fiber.scheduler
    return core.async(function(resume)
      return scheduler:after(ms, function()
        resume(core.exitVoid)
      end)
    end)
  end)
end

-- Interruption --------------------------------------------------------------

--- An effect that interrupts the fiber running it. Finalizers run, and the
--- exit's cause is an interruption by this fiber. As in v4, `catchCause` can
--- catch it, but `catchAll` can't.
Effect.interrupt = core.withFiber(function(fiber)
  return exitFailCause(Cause.interrupt(fiber.id))
end)

Effect.uninterruptible = runtime.uninterruptible
Effect.interruptible = runtime.interruptible
Effect.uninterruptibleMask = runtime.uninterruptibleMask

-- Finalizers ----------------------------------------------------------------

--- Runs `f(exit)` after `self` finishes, however it finishes, and
--- uninterruptibly. `f` returns an effect or nil. The result is `self`'s exit;
--- a failure of the finalizer is added to it.
Effect.onExit = core.onExit

--- Runs `finalizer` after `self` finishes, however it finishes.
---@param self leffect.Effect
---@param finalizer leffect.Effect
---@return leffect.Effect
function Effect.ensuring(self, finalizer)
  return core.onExit(self, function()
    return finalizer
  end)
end

--- Runs `f(interruptors)` if `self` is interrupted: when its cause has an
--- Interrupt reason. `interruptors` lists the interrupting fiber IDs.
---@param self leffect.Effect
---@param f fun(interruptors: integer[]): leffect.Effect?
---@return leffect.Effect
function Effect.onInterrupt(self, f)
  return core.onExit(self, function(exit)
    if exit._op == core.OP_FAILURE and Cause.hasInterrupts(exit.cause) then
      return f(Cause.interruptors(exit.cause))
    end
    return nil
  end)
end

-- Scope (FIBER-DESIGN.md §19) -----------------------------------------------

local push = runtime.push
local SCOPE_KEY = Scope.contextKey

--- An effect that succeeds with the current scope, the one `Effect.scoped` or
--- `Scope.provide` set. Without one, it dies.
Effect.scope = core.withFiber(function(fiber)
  local scope = Context.get(fiber.context, SCOPE_KEY)
  if scope == nil then
    return exitFailCause(
      Cause.die("Effect.scope: no Scope in context; wrap the effect in Effect.scoped")
    )
  end
  return exitSucceed(scope)
end)

--- Runs `self` with a fresh current scope, then closes the scope with
--- `self`'s exit. The finalizers run in the outer context, uninterruptibly,
--- and their failures are added to the exit.
---@param self leffect.Effect
---@return leffect.Effect
function Effect.scoped(self)
  return core.withFiber(function(fiber)
    local previous = fiber.context
    local scope = Scope.makeUnsafe()
    -- Both frames are pushed in the step that changes the context, so no
    -- interrupt can land in between. Unwinding pops SetContext first, so the
    -- scope closes in the outer context.
    push(fiber, {
      _op = core.OP_ON_EXIT,
      f = function(exit)
        return Scope.closeUnsafe(scope, exit)
      end,
    })
    push(fiber, { _op = "SetContext", context = previous })
    fiber.context = Context.add(previous, SCOPE_KEY, scope)
    return self
  end)
end

--- Adds `f(exit)` to the current scope as a finalizer. `f` returns an effect
--- or nil.
---@param f leffect.Scope.Finalizer
---@return leffect.Effect
function Effect.addFinalizer(f)
  return core.flatMap(Effect.scope, function(scope)
    return Scope.addFinalizerExit(scope, f)
  end)
end

-- Fibers --------------------------------------------------------------------

--- Starts `self` on a child fiber, on the next tick, and succeeds with the
--- fiber. The parent interrupts its children before it exits.
---@param self leffect.Effect
---@return leffect.Effect
function Effect.fork(self)
  return core.withFiber(function(parent)
    return exitSucceed(Fiber.forkUnsafe(parent, self, false, false))
  end)
end

--- Like `fork`, but the fiber isn't attached to the parent and can outlive it.
---@param self leffect.Effect
---@return leffect.Effect
function Effect.forkDaemon(self)
  return core.withFiber(function(parent)
    return exitSucceed(Fiber.forkUnsafe(parent, self, true, false))
  end)
end

--- Races `effects` on child fibers (FIBER-DESIGN.md §8.1). A winner is the
--- first success, or the first exit if `firstExitWins`. The losers are
--- interrupted and awaited before the race returns. Without a winner, the
--- race fails with every racer's reasons.
---@param effects leffect.Effect[]
---@param firstExitWins boolean
---@return leffect.Effect
local function race(effects, firstExitWins)
  local count = #effects
  if count == 0 then
    return Effect.die("Effect.raceAll: there are no effects to race")
  end
  return core.withFiber(function(parent)
    return core.async(function(resume)
      local racers, running = {}, {}
      for i = 1, count do
        local racer = Fiber.forkUnsafe(parent, effects[i], true, false)
        racers[i] = racer
        running[racer] = true
      end
      local function stillRunning()
        local list = {}
        for i = 1, count do
          local racer = racers[i]
          if running[racer] then
            list[#list + 1] = racer
          end
        end
        return list
      end
      local reasons, failed = {}, 0
      for i = 1, count do
        local racer = racers[i]
        racer:addObserver(function(exit)
          running[racer] = nil
          if firstExitWins or exit._op == core.OP_SUCCESS then
            local losers = stillRunning()
            if #losers == 0 then
              resume(exit)
            else
              local stopLosers = runtime.uninterruptible(Fiber.interruptAllAs(losers, parent.id))
              resume(core.flatMap(stopLosers, function()
                return exit
              end))
            end
          else
            failed = failed + 1
            local lost = exit.cause.reasons
            for j = 1, #lost do
              reasons[#reasons + 1] = lost[j]
            end
            if failed == count then
              resume(exitFailCause(Cause.electDefects(Cause.fromReasons(reasons))))
            end
          end
        end)
      end
      -- If the racing fiber is interrupted, stop every racer and wait for them.
      return core.suspend(function()
        return Fiber.interruptAllAs(stillRunning(), parent.id)
      end)
    end)
  end)
end

--- Succeeds with the first of `effects` to succeed, and fails only if all of
--- them fail. The losers are interrupted and awaited before it returns.
---@param effects leffect.Effect[]
---@return leffect.Effect
function Effect.raceAll(effects)
  return race(effects, false)
end

--- `raceAll({ self, that })`.
---@param self leffect.Effect
---@param that leffect.Effect
---@return leffect.Effect
function Effect.race(self, that)
  return race({ self, that }, false)
end

--- Finishes like the first of `self` and `that` to finish, success or
--- failure. The loser is interrupted and awaited before it returns.
---@param self leffect.Effect
---@param that leffect.Effect
---@return leffect.Effect
function Effect.raceFirst(self, that)
  return race({ self, that }, true)
end

--- Runs `self`, but if it takes longer than `ms` milliseconds, interrupts it
--- and continues with `orElse()` instead.
---@param self leffect.Effect
---@param ms number
---@param orElse fun(): leffect.Effect
---@return leffect.Effect
function Effect.timeoutOrElse(self, ms, orElse)
  return Effect.raceFirst(self, core.flatMap(Effect.sleep(ms), orElse))
end

--- Runs `self`, but if it takes longer than `ms` milliseconds, interrupts it
--- and fails with `Cause.TimeoutError()`.
---@param self leffect.Effect
---@param ms number
---@return leffect.Effect
function Effect.timeout(self, ms)
  return Effect.timeoutOrElse(self, ms, function()
    return Effect.fail(Cause.TimeoutError())
  end)
end

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

---@class leffect.RunForkOptions
---@field scheduler leffect.Scheduler

--- Starts `effect` on a new root fiber on `options.scheduler`, on the next
--- tick, and returns the fiber.
---@param effect leffect.Effect
---@param options leffect.RunForkOptions
---@return leffect.Fiber
function Effect.runFork(effect, options)
  local scheduler = options and options.scheduler
  if not scheduler then
    error("Effect.runFork: options.scheduler is required", 2)
  end
  return startRoot(effect, scheduler)
end

--- Runs `effect` synchronously on a fiber of its own and returns its Exit.
--- An Exit is returned as is. Never throws. An effect that doesn't finish
--- synchronously (it waits for a timer, say) is interrupted, so that its
--- finalizers run, and the result is `Die(Cause.AsyncFiberError(fiber))`.
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
  -- Nothing will ever run this private scheduler again: interrupt the fiber
  -- now, so that its finalizers run.
  fiber:interruptUnsafe(nil)
  scheduler:flush()
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
methods.catchCause = Effect.catchCause
methods.catchIf = Effect.catchIf
methods.catchTag = Effect.catchTag
methods.catchTags = Effect.catchTags
methods.exit = Effect.exit
methods.as = Effect.as
methods.asVoid = Effect.asVoid
methods.uninterruptible = Effect.uninterruptible
methods.interruptible = Effect.interruptible
methods.onExit = Effect.onExit
methods.ensuring = Effect.ensuring
methods.onInterrupt = Effect.onInterrupt
methods.scoped = Effect.scoped
methods.fork = Effect.fork
methods.forkDaemon = Effect.forkDaemon
methods.race = Effect.race
methods.raceFirst = Effect.raceFirst
methods.timeout = Effect.timeout
methods.timeoutOrElse = Effect.timeoutOrElse

return Effect
