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

local error, getmetatable, pairs, setmetatable, time, type, xpcall =
  error, getmetatable, pairs, setmetatable, os.time, type, xpcall

local exitSucceed, exitFailCause = core.exitSucceed, core.exitFailCause
local describe = runtime.describe

local function noop() end

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

--- An effect that runs `body(run)` on a coroutine (specifications/09-gen.md
--- §9). Inside the body, `run(eff)` runs an effect and returns its value;
--- helper functions can call `require("leffect").run`, which is the same
--- function. The body's first return value is the result. If a `run(eff)`
--- fails or the fiber is interrupted, `run` never returns and the coroutine is
--- abandoned, so clean up with effects (`ensuring`, `acquireRelease`), not
--- `pcall`.
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

-- Services (specifications/26-services.md §26) ------------------------------

-- Context.add's message, for the effects that die instead of raising.
local NIL_SERVICE = "Context.add: a service can't be nil"

local NO_SCOPE = "Effect.scope: no Scope in context; wrap the effect in Effect.scoped"

---@param key any
---@param name string The public function, for the message.
local function checkKey(key, name)
  if not Context.isKey(key) then
    error(name .. ": expected a key, got " .. describe(key), 3)
  end
end

--- The key itself: running a key succeeds with its service, or dies if the
--- context has none (4.1.5's `Effect.service`).
---@param key leffect.Context.Key
---@return leffect.Effect
function Effect.service(key)
  checkKey(key, "Effect.service")
  return key
end

--- Runs `self` with the context `f(context)`. When `self` ends, however it
--- ends, the fiber's context is what it was before. `f` must return a
--- Context, or the effect dies.
---@param self leffect.Effect
---@param f fun(context: leffect.Context): leffect.Context
---@return leffect.Effect
function Effect.updateContext(self, f)
  return runtime.updateContext(self, function(context)
    local updated = f(context)
    if not Context.isContext(updated) then
      error("Effect.updateContext: f must return a Context, got " .. describe(updated), 0)
    end
    return updated
  end)
end

--- Runs `self` with `service` under `key`, for `self` only. A fork started
--- inside keeps the service. If `service` is nil, the effect dies.
---@param self leffect.Effect
---@param key leffect.Context.Key
---@param service any
---@return leffect.Effect
function Effect.provideService(self, key, service)
  checkKey(key, "Effect.provideService")
  if service == nil then
    return exitFailCause(Cause.die(NIL_SERVICE))
  end
  return runtime.updateContext(self, function(context)
    return Context.add(context, key, service)
  end)
end

--- Runs `acquire`, then runs `self` with its value under `key`. If `acquire`
--- fails, so does the effect, and `self` never runs.
---@param self leffect.Effect
---@param key leffect.Context.Key
---@param acquire leffect.Effect
---@return leffect.Effect
function Effect.provideServiceEffect(self, key, acquire)
  checkKey(key, "Effect.provideServiceEffect")
  return core.flatMap(acquire, function(service)
    return Effect.provideService(self, key, service)
  end)
end

--- Runs `self` with `f(current)` under `key`. For a missing Reference, `f`
--- gets the default; for a missing Service, the effect dies.
---@param self leffect.Effect
---@param key leffect.Context.Key
---@param f fun(current: any): any
---@return leffect.Effect
function Effect.updateService(self, key, f)
  checkKey(key, "Effect.updateService")
  return core.flatMap(key, function(current)
    local updated = f(current)
    if updated == current then
      return self
    end
    return Effect.provideService(self, key, updated)
  end)
end

local MISSING = setmetatable({}, { __name = "leffect.MISSING" })

local function missing()
  return MISSING
end

---@class leffect.UpdateServiceScopedOptions
---@field reset (fun(original: any, updated: any, current: any): any)? The value to put back when the scope closes.

--- Sets `f(current)` under `key` for the rest of the current scope, on the
--- fiber's own context. When the scope closes, the finalizer puts the
--- original back, unless the fiber's value has changed since;
--- `options.reset(original, updated, current)` replaces that rule. Dies for a
--- missing Service, and outside a scope. The one context change that no
--- frame undoes (invariant 15).
---@param key leffect.Context.Key
---@param f fun(current: any): any
---@param options leffect.UpdateServiceScopedOptions?
---@return leffect.Effect
function Effect.updateServiceScoped(key, f, options)
  checkKey(key, "Effect.updateServiceScoped")
  local reset = options and options.reset
  return runtime.uninterruptible(core.withFiber(function(fiber)
    local original = Context.getOrElse(fiber.context, key, missing)
    if original == MISSING then
      return exitFailCause(Cause.die("Service not found: " .. key.key))
    end
    local scope = Context.getOrElse(fiber.context, Scope.Scope, noop)
    if scope == nil then
      return exitFailCause(Cause.die(NO_SCOPE))
    end
    local updated = f(original)
    if updated == nil then
      return exitFailCause(Cause.die(NIL_SERVICE))
    end
    fiber.context = Context.add(fiber.context, key, updated)
    return Scope.addFinalizerExit(scope, function()
      local current = Context.getOrElse(fiber.context, key, missing)
      if current == MISSING then
        return nil
      end
      local value
      if reset then
        value = reset(original, updated, current)
      elseif current == updated then
        value = original
      else
        return nil
      end
      fiber.context = Context.add(fiber.context, key, value)
      return nil
    end)
  end))
end

local getContext = core.withFiber(function(fiber)
  return exitSucceed(fiber.context)
end)

--- An effect that succeeds with the fiber's context.
---@return leffect.Effect
function Effect.context()
  return getContext
end

--- Continues with the effect `f(context)`, given the fiber's context.
---@param f fun(context: leffect.Context): leffect.Effect
---@return leffect.Effect
function Effect.contextWith(f)
  return core.withFiber(function(fiber)
    return f(fiber.context)
  end)
end

--- Runs `self` with the services of `context` added to the fiber's, winning
--- where both have a key. An Exit is returned as it is.
---@param self leffect.Effect
---@param context leffect.Context
---@return leffect.Effect
function Effect.provideContext(self, context)
  if not Context.isContext(context) then
    error("Effect.provideContext: expected a Context, got " .. describe(context), 2)
  end
  if core.isExit(self) then
    return self
  end
  return runtime.updateContext(self, function(current)
    return Context.merge(current, context)
  end)
end

-- leffect.layer requires this module, so it is required on first use.
local Layer

-- Feature-detected: LuaJIT has the global, Lua 5.4 the table field.
local unpack = table.unpack or unpack -- luacheck: ignore 113 143

local PROVIDE_EXPECTED = "Effect.provide: expected a Layer, a list of layers or a Context"

--- The number of layers in `source` if it is a list of layers: a table with
--- no metatable whose keys are 1 to n. Nil otherwise.
---@param source any
---@return integer?
local function layerCount(source)
  if type(source) ~= "table" or getmetatable(source) ~= nil then
    return nil
  end
  local count = 0
  for _ in pairs(source) do
    count = count + 1
  end
  for i = 1, count do
    if not Layer.isLayer(source[i]) then
      return nil
    end
  end
  return count
end

--- Runs `self` with the services of `source`: a Layer, a list of layers
--- (merged), or a Context (specifications/27-layers.md §27.5). A layer is
--- built into a new scope, which closes with `self`'s exit after `self`
--- ends; if the build fails, `self` never runs. The build shares the layers
--- of an outer `provide`, unless `options.fresh` is set. Anything else makes
--- the effect die.
---@param self leffect.Effect
---@param source leffect.Layer|leffect.Layer[]|leffect.Context
---@param options { fresh: boolean? }?
---@return leffect.Effect
function Effect.provide(self, source, options)
  if Context.isContext(source) then
    ---@cast source leffect.Context
    return Effect.provideContext(self, source)
  end
  Layer = Layer or require("leffect.layer")
  local layer = source
  if not Layer.isLayer(source) then
    local count = layerCount(source)
    if count == nil then
      return exitFailCause(Cause.die(PROVIDE_EXPECTED))
    end
    layer = Layer.mergeAll(unpack(source, 1, count))
  end
  ---@cast layer leffect.Layer
  return Effect.scopedWith(function(scope)
    local built
    if options and options.fresh then
      built = Layer.buildWithMemoMap(layer, Layer.makeMemoMapUnsafe(), scope)
    else
      built = Layer.buildWithScope(layer, scope)
    end
    return core.flatMap(built, function(context)
      return Effect.provideContext(self, context)
    end)
  end)
end

-- Scope (specifications/19-scope.md §19) ------------------------------------

local push = runtime.push

--- An effect that succeeds with the current scope, the one `Effect.scoped` or
--- `Scope.provide` set. Without one, it dies.
Effect.scope = core.withFiber(function(fiber)
  local scope = Context.getOrElse(fiber.context, Scope.Scope, noop)
  if scope == nil then
    return exitFailCause(Cause.die(NO_SCOPE))
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
    fiber.context = Context.add(previous, Scope.Scope, scope)
    return self
  end)
end

--- Runs `f(scope)` with a fresh scope passed as an argument, then closes the
--- scope with the exit of the effect `f` returned. The scope doesn't become
--- the current scope: the context stays as it is.
---@param f fun(scope: leffect.Scope): leffect.Effect
---@return leffect.Effect
function Effect.scopedWith(f)
  return core.suspend(function()
    local scope = Scope.makeUnsafe()
    return core.onExit(f(scope), function(exit)
      return Scope.closeUnsafe(scope, exit)
    end)
  end)
end

--- Adds `f(exit)` to the current scope as a finalizer. `f` returns an effect
--- or nil. The finalizer runs in the context where it was added (v4's release
--- context, specifications/26-services.md §26.5): those services win over the
--- closing fiber's, and `Effect.scope` inside it is the scope it belongs to.
---@param f leffect.Scope.Finalizer
---@return leffect.Effect
function Effect.addFinalizer(f)
  return core.flatMap(Effect.scope, function(scope)
    return core.withFiber(function(fiber)
      local captured = fiber.context
      return Scope.addFinalizerExit(scope, function(exit)
        return Effect.provideContext(f(exit) or core.exitVoid, captured)
      end)
    end)
  end)
end

-- Resources (specifications/20-resources.md §20) ----------------------------

--- Acquires a resource with `acquire`, uninterruptibly, and adds
--- `release(resource, exit)` to the current scope, before any interrupt can
--- be delivered. The release runs when the scope closes, with the close exit,
--- in the context `acquireRelease` started in (§26.5). If acquire fails,
--- nothing is released. With `options.interruptible`, acquire may be
--- interrupted, and then there is nothing to release. Without a current
--- scope, it dies before acquiring anything.
---@param acquire leffect.Effect
---@param release fun(resource: any, exit: leffect.Exit): leffect.Effect?
---@param options { interruptible: boolean? }?
---@return leffect.Effect
function Effect.acquireRelease(acquire, release, options)
  return core.withFiber(function(fiber)
    local captured = fiber.context
    return runtime.uninterruptibleMask(function(restore)
      return core.flatMap(Effect.scope, function(scope)
        local run = acquire
        if options and options.interruptible then
          run = restore(acquire)
        end
        return core.flatMap(run, function(resource)
          local added = Scope.addFinalizerExit(scope, function(exit)
            return Effect.provideContext(release(resource, exit) or core.exitVoid, captured)
          end)
          return core.map(added, function()
            return resource
          end)
        end)
      end)
    end)
  end)
end

--- Acquires a resource with `acquire`, uninterruptibly, runs `use(resource)`
--- as interruptibly as the caller, then runs `release(resource, exit)` however
--- `use` ends. The release's failure is added to the exit. Needs no scope.
---@param acquire leffect.Effect
---@param use fun(resource: any): leffect.Effect
---@param release fun(resource: any, exit: leffect.Exit): leffect.Effect?
---@return leffect.Effect
function Effect.acquireUseRelease(acquire, use, release)
  return runtime.uninterruptibleMask(function(restore)
    return core.flatMap(acquire, function(resource)
      local used = core.suspend(function()
        return restore(use(resource))
      end)
      return core.onExit(used, function(exit)
        return release(resource, exit)
      end)
    end)
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

--- Starts `self` on a daemon fiber tied to `scope`, on the next tick, and
--- succeeds with the fiber. Closing the scope interrupts the fiber and waits
--- for it; a fiber that ends first removes itself from the scope. On a closed
--- scope, the fiber is interrupted before it starts, so it runs none of
--- `self`.
---@param self leffect.Effect
---@param scope leffect.Scope
---@return leffect.Effect
function Effect.forkIn(self, scope)
  return core.withFiber(function(parent)
    local fiber = Fiber.forkUnsafe(parent, self, true, false)
    if scope.state == "closed" then
      fiber:interruptUnsafe(parent.id)
    else
      -- Keyed by the fiber, so that a fiber closing its own scope skips it
      -- instead of waiting for itself.
      Scope.addFinalizerUnsafe(scope, fiber, function()
        return core.withFiber(function(current)
          if current == fiber then
            return core.exitVoid
          end
          return fiber:interrupt()
        end)
      end)
      fiber:addObserver(function()
        Scope.removeFinalizerUnsafe(scope, fiber)
      end)
    end
    return exitSucceed(fiber)
  end)
end

--- `forkIn` with the current scope. Dies without one.
---@param self leffect.Effect
---@return leffect.Effect
function Effect.forkScoped(self)
  return core.flatMap(Effect.scope, function(scope)
    return Effect.forkIn(self, scope)
  end)
end

--- Races `effects` on child fibers (specifications/08-structured-concurrency.md
--- §8.1). A winner is the first success, or the first exit if
--- `firstExitWins`. The losers are interrupted and awaited before the race
--- returns. Without a winner, the race fails with every racer's reasons.
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

-- forEach and all (specifications/22-foreach.md §22) ------------------------

local floor, huge = math.floor, math.huge
local sort = table.sort
local OP_FAILURE = core.OP_FAILURE

--- The most items that may run at once, or nil if `concurrency` is invalid.
---@param concurrency any
---@return number?
local function concurrencyLimit(concurrency)
  if concurrency == nil then
    return 1
  elseif concurrency == "unbounded" then
    return huge
  end
  if type(concurrency) ~= "number" or concurrency ~= concurrency then
    return nil
  end
  if concurrency < 1 then
    return 1
  end
  return floor(concurrency)
end

--- Runs `f(items[i], i)` for i = 1..count, one after the other, storing each
--- value in `out` if there is one. A flatMap chain: each step returns the next
--- from a continuation, so neither stack grows, and `f` is called only when
--- the item's turn comes.
---@param items table
---@param count integer
---@param f fun(item: any, index: integer): leffect.Effect
---@param out table?
---@return leffect.Effect
local function forEachInTurn(items, count, f, out)
  local function step(i)
    if i > count then
      return exitSucceed(out)
    end
    return core.flatMap(f(items[i], i), function(value)
      if out then
        out[i] = value
      end
      return step(i + 1)
    end)
  end
  return step(1)
end

--- Runs `f(items[i], i)` on daemon workers, at most `limit` at once, as
--- 4.1.5's `forEachConcurrent` does. The parent waits in one async:
--- - each worker's exit stores its value and launches the next item;
--- - the first failure, or a throw from `f`, stops the launches and
---   interrupts the running workers in fork order; the run then fails once
---   they have all exited, with the later workers' non-interrupt reasons
---   added and the defects elected;
--- - the canceler handles an interrupt of the parent: it stops the launches,
---   then interrupts the workers and waits for them.
---@param items table
---@param count integer
---@param f fun(item: any, index: integer): leffect.Effect
---@param out table?
---@param limit number
---@return leffect.Effect
local function forEachConcurrently(items, count, f, out, limit)
  return core.withFiber(function(parent)
    return core.async(function(resume)
      local workers, launched, running = {}, 0, 0
      local stopped = false -- no more launches
      local failure -- the cause the run fails with
      local resumed = false

      local function addFailure(cause)
        if failure then
          failure = Cause.electDefects(Cause.combine(failure, cause))
        else
          failure = cause
        end
      end

      -- Stops the launches, and interrupts the running workers in fork order.
      local function stop()
        stopped = true
        for i = 1, launched do
          local worker = workers[i]
          if not worker.exit then
            worker:interruptUnsafe(parent.id)
          end
        end
      end

      local function finish()
        if resumed or running > 0 or not (stopped or launched == count) then
          return
        end
        resumed = true
        if failure then
          resume(exitFailCause(failure))
        else
          resume(exitSucceed(out))
        end
      end

      local launch

      local function onWorkerExit(index, exit)
        running = running - 1
        if exit._op == OP_FAILURE then
          if stopped then
            local reasons, kept, n = exit.cause.reasons, {}, 0
            for i = 1, #reasons do
              if reasons[i]._tag ~= "Interrupt" then
                n = n + 1
                kept[n] = reasons[i]
              end
            end
            if n > 0 then
              addFailure(Cause.fromReasons(kept))
            end
          else
            failure = exit.cause
            stop()
          end
        elseif out then
          out[index] = exit.value
        end
        if not stopped then
          launch()
        end
        finish()
      end

      local function launchUnprotected()
        while not stopped and running < limit and launched < count do
          local index = launched + 1
          local effect = f(items[index], index)
          local worker = Fiber.forkUnsafe(parent, effect, true, "inherit")
          launched = index
          workers[index] = worker
          running = running + 1
          worker:addObserver(function(exit)
            onWorkerExit(index, exit)
          end)
        end
      end

      -- The one launch path, for the first batch and for the refills. A
      -- refill runs in a worker's observer, outside any loop, so a throw
      -- from `f` must not escape: it fails the run like a worker failure.
      launch = function()
        local ok, caught = xpcall(launchUnprotected, runtime.captureDefect)
        if not ok then
          addFailure(runtime.defectCause(caught))
          stop()
        end
      end

      launch()
      finish()
      return core.suspend(function()
        stopped = true -- before the interrupts, so no worker exit refills
        local stillRunning = {}
        for i = 1, launched do
          local worker = workers[i]
          if not worker.exit then
            stillRunning[#stillRunning + 1] = worker
          end
        end
        return core.flatMap(Fiber.interruptAllAs(stillRunning, parent.id), function()
          if failure then
            return exitFailCause(failure)
          end
          return core.exitVoid
        end)
      end)
    end)
  end)
end

---@class leffect.ForEachOptions
---@field concurrency (number|"unbounded")? How many items may run at once; default 1.
---@field discard boolean? Succeed with nil instead of the results.

--- Runs `f(item, index)` for each item of `items`, with indexes from 1, and
--- succeeds with the values in input order: a list with a field `n`, so nil
--- values count. The length is `items.n` if it is a number, else `#items`.
--- `f` is called only when the item's turn comes. By default the items run
--- one at a time, and the first failure stops the run. With a
--- `concurrency` above 1, or `"unbounded"`, they run on worker fibers; a
--- failure interrupts the running workers and waits for them. With `discard`,
--- succeeds with nil.
---@param items table
---@param f fun(item: any, index: integer): leffect.Effect
---@param options leffect.ForEachOptions?
---@return leffect.Effect
function Effect.forEach(items, f, options)
  return core.suspend(function()
    local concurrency = options and options.concurrency
    local limit = concurrencyLimit(concurrency)
    if limit == nil then
      return exitFailCause(
        Cause.die(
          'Effect.forEach: concurrency must be a number or "unbounded", got '
            .. runtime.describe(concurrency)
        )
      )
    end
    local count = items.n
    if type(count) ~= "number" then
      count = #items
    end
    local out
    if not (options and options.discard) then
      out = { n = count }
    end
    if limit == 1 then
      return forEachInTurn(items, count, f, out)
    elseif count == 0 then
      return exitSucceed(out)
    end
    return forEachConcurrently(items, count, f, out, limit)
  end)
end

local function identity(value)
  return value
end

-- Numbers first, then strings; a number is never compared with a string.
local function keyOrder(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then
    return ta == "number"
  end
  return a < b
end

--- Runs a table of effects, like `forEach` with the identity. The keys decide
--- what the table is (specifications/22-foreach.md §22.3):
--- - with a number `n`, a list of `n` effects;
--- - with keys 1 to the number of keys, a list; `{}` gives `{ n = 0 }`;
--- - otherwise a record: it runs in sorted key order, numbers then strings,
---   and succeeds with a table with the same keys.
---@param effects table
---@param options leffect.ForEachOptions?
---@return leffect.Effect
function Effect.all(effects, options)
  return core.suspend(function()
    if type(effects) ~= "table" then
      return exitFailCause(
        Cause.die("Effect.all: expected a table of effects, got " .. runtime.describe(effects))
      )
    end
    if type(effects.n) == "number" then
      return Effect.forEach(effects, identity, options)
    end
    local keys, count = {}, 0
    for key in pairs(effects) do
      count = count + 1
      keys[count] = key
    end
    local isList = true
    for i = 1, count do
      if effects[i] == nil then
        isList = false
        break
      end
    end
    if isList then
      return Effect.forEach(effects, identity, options)
    end
    for i = 1, count do
      local kind = type(keys[i])
      if kind ~= "number" and kind ~= "string" then
        return exitFailCause(
          Cause.die(
            "Effect.all: a record's keys must be numbers or strings, got "
              .. runtime.describe(keys[i])
          )
        )
      end
    end
    sort(keys, keyOrder)
    local values = Effect.forEach(keys, function(key)
      return effects[key]
    end, options)
    if options and options.discard then
      return values
    end
    return core.map(values, function(list)
      local record = {}
      for i = 1, count do
        record[keys[i]] = list[i]
      end
      return record
    end)
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

--- A root fiber running `effect` on `scheduler`, started on the next tick,
--- with `context`.
---@param effect any
---@param scheduler leffect.Scheduler
---@param context leffect.Context
---@param interruptible boolean
---@return leffect.Fiber
local function startRoot(effect, scheduler, context, interruptible)
  local fiber = Fiber.new(scheduler, interruptible)
  fiber.context = context
  scheduler:schedule(function()
    fiber:evaluate(effect)
  end)
  return fiber
end

---The options of `runFork` and `runCallback` (specifications/28-running.md
---§28.1).
---@class leffect.RunOptions
---@field scheduler leffect.Scheduler Required.
---@field uninterruptible boolean? Start the root fiber uninterruptible.
---@field onFiberStart (fun(fiber: leffect.Fiber))? Called with the fiber before the runner returns.

---@class leffect.RunCallbackOptions : leffect.RunOptions
---@field onExit (fun(exit: leffect.Exit))? Called once with the fiber's exit.

--- `runFork` with root context `context`; `name` is the runner, for the
--- error.
---@param effect leffect.Effect
---@param options leffect.RunOptions
---@param context leffect.Context
---@param name string
---@param level integer Where the missing-scheduler error points.
---@return leffect.Fiber
local function fork(effect, options, context, name, level)
  local scheduler = options and options.scheduler
  if not scheduler then
    error(name .. ": options.scheduler is required", level)
  end
  local fiber = startRoot(effect, scheduler, context, not options.uninterruptible)
  local onFiberStart = options.onFiberStart
  if onFiberStart then
    onFiberStart(fiber)
  end
  return fiber
end

--- Starts `effect` on a new root fiber on `options.scheduler`, on the next
--- tick, and returns the fiber.
---@param effect leffect.Effect
---@param options leffect.RunOptions
---@return leffect.Fiber
function Effect.runFork(effect, options)
  return fork(effect, options, Context.empty(), "Effect.runFork", 3)
end

--- `runCallback` with root context `context`.
---@param effect leffect.Effect
---@param options leffect.RunCallbackOptions
---@param context leffect.Context
---@param name string
---@param level integer Where the missing-scheduler error points.
---@return fun(fiberId: integer?) interrupt
local function runCallback(effect, options, context, name, level)
  local fiber = fork(effect, options, context, name, level + 1)
  local onExit = options.onExit
  if onExit then
    fiber:addObserver(onExit)
  end
  return function(fiberId)
    fiber:interruptUnsafe(fiberId)
  end
end

--- `runFork`, then `options.onExit(exit)` once the fiber ends (v4's
--- `runCallback`). Returns a function that interrupts the fiber, on behalf of
--- the fiber ID it is given, if any, without waiting. Called before the fiber
--- starts, it stops the fiber before any of `effect` runs; called after the
--- fiber ended, it does nothing. `onExit` must not throw: its error would
--- reach the host.
---@param effect leffect.Effect
---@param options leffect.RunCallbackOptions
---@return fun(fiberId: integer?) interrupt
function Effect.runCallback(effect, options)
  return runCallback(effect, options, Context.empty(), "Effect.runCallback", 3)
end

--- `runSyncExit` with root context `context`.
---@param effect leffect.Effect
---@param context leffect.Context
---@return leffect.Exit
local function runSyncExit(effect, context)
  if core.isExit(effect) then
    return effect --[[@as leffect.Exit]]
  end
  local scheduler = newSyncScheduler()
  local fiber = startRoot(effect, scheduler, context, true)
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

--- Runs `effect` synchronously on a fiber of its own and returns its Exit.
--- An Exit is returned as is. Never throws. An effect that doesn't finish
--- synchronously (it waits for a timer, say) is interrupted, so that its
--- finalizers run, and the result is `Die(Cause.AsyncFiberError(fiber))`.
---@param effect leffect.Effect
---@return leffect.Exit
function Effect.runSyncExit(effect)
  return runSyncExit(effect, Context.empty())
end

--- The success value of `exit`; for a failure, throws `Cause.squash` of the
--- cause.
---@param exit leffect.Exit
---@return any
local function valueOrThrow(exit)
  if exit._op == core.OP_FAILURE then
    error(Cause.squash(exit.cause), 0)
  end
  return exit.value
end

--- Runs `effect` synchronously and returns its success value. On failure it
--- throws `Cause.squash` of the cause: the first error, else the first defect.
---@param effect leffect.Effect
---@return any
function Effect.runSync(effect)
  return valueOrThrow(runSyncExit(effect, Context.empty()))
end

-- Runners with a context (specifications/28-running.md §28.3) ----------------

---@param context any
---@param name string The public function, for the message.
local function checkRunContext(context, name)
  if not Context.isContext(context) then
    error(name .. ": expected a Context, got " .. describe(context), 3)
  end
end

--- A `runFork` whose root fibers start with `context`, such as services
--- built once with `Layer.buildWithScope`.
---@param context leffect.Context
---@return fun(effect: leffect.Effect, options: leffect.RunOptions): leffect.Fiber
function Effect.runForkWith(context)
  checkRunContext(context, "Effect.runForkWith")
  return function(effect, options)
    return fork(effect, options, context, "Effect.runForkWith", 3)
  end
end

--- A `runCallback` whose root fibers start with `context`.
---@param context leffect.Context
---@return fun(effect: leffect.Effect, options: leffect.RunCallbackOptions): fun(fiberId: integer?)
function Effect.runCallbackWith(context)
  checkRunContext(context, "Effect.runCallbackWith")
  return function(effect, options)
    return runCallback(effect, options, context, "Effect.runCallbackWith", 3)
  end
end

--- A `runSyncExit` whose root fibers start with `context`.
---@param context leffect.Context
---@return fun(effect: leffect.Effect): leffect.Exit
function Effect.runSyncExitWith(context)
  checkRunContext(context, "Effect.runSyncExitWith")
  return function(effect)
    return runSyncExit(effect, context)
  end
end

--- A `runSync` whose root fibers start with `context`.
---@param context leffect.Context
---@return fun(effect: leffect.Effect): any
function Effect.runSyncWith(context)
  checkRunContext(context, "Effect.runSyncWith")
  return function(effect)
    return valueOrThrow(runSyncExit(effect, context))
  end
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
methods.provideService = Effect.provideService
methods.provideServiceEffect = Effect.provideServiceEffect
methods.updateService = Effect.updateService
methods.provideContext = Effect.provideContext
methods.updateContext = Effect.updateContext
methods.provide = Effect.provide
methods.scoped = Effect.scoped
methods.fork = Effect.fork
methods.forkDaemon = Effect.forkDaemon
methods.forkIn = Effect.forkIn
methods.forkScoped = Effect.forkScoped
methods.race = Effect.race
methods.raceFirst = Effect.raceFirst
methods.timeout = Effect.timeout
methods.timeoutOrElse = Effect.timeoutOrElse

return Effect
