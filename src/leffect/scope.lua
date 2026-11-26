--- Scope: collects finalizers and runs them when it closes
--- (specifications/19-scope.md §19, 4.1.5's `Scope` module).
---
--- ```lua
--- local scope = Scope.makeUnsafe()
--- Effect.runSync(Scope.addFinalizer(scope, Effect.sync(function() print("closed") end)))
--- Effect.runSync(Scope.close(scope, Exit.void)) --> closed
--- ```
---
--- Finalizers run newest first, uninterruptibly, and each gets the exit the
--- scope was closed with. A failing finalizer doesn't stop the others. A
--- `"parallel"` scope runs them at the same time instead. Most code uses
--- `Effect.scoped`, which gives an effect a fresh current scope and closes it
--- when the effect ends.

local Cause = require("leffect.cause")
local Context = require("leffect.context")
local Fiber = require("leffect.fiber")
local core = require("leffect.core")
local runtime = require("leffect.runtime")

local error, setmetatable = error, setmetatable

local exitFailCause, exitVoid = core.exitFailCause, core.exitVoid
local OP_FAILURE = core.OP_FAILURE

---@alias leffect.Scope.Strategy "sequential"|"parallel"

---@alias leffect.Scope.Finalizer fun(exit: leffect.Exit): leffect.Effect?

---A set of finalizers, run when the scope closes.
---@class leffect.Scope
---@field strategy leffect.Scope.Strategy
---@field parent leffect.Scope? Set for a scope made by `Scope.fork`.
---@field state "open"|"closed"
---@field exit leffect.Exit? The exit the scope was closed with.
---@field keys (table|false)[] The finalizers' keys, in the order they were added; false marks a hole.
---@field finalizers (leffect.Scope.Finalizer|false)[]
---@field slots table<table, integer> Each key's position in `keys`.
---@field size integer The number of positions in use, holes included.
---@field live integer The number of finalizers.

local ScopeMT = { __name = "leffect.Scope" }

local Scope = {}

--- The key of the current scope (4.1.5's `Scope.Scope`). `Effect.scoped` puts
--- a fresh scope under it. Running it gives the current scope, or dies with
--- "Service not found: leffect/Scope"; `Effect.scope` dies with a hint.
Scope.Scope = Context.Service("leffect/Scope")

---@param strategy any
---@param parent leffect.Scope?
---@return leffect.Scope
local function make(strategy, parent)
  if strategy == nil then
    strategy = "sequential"
  elseif strategy ~= "sequential" and strategy ~= "parallel" then
    error(
      'Scope: the finalizer strategy must be "sequential" or "parallel", got '
        .. runtime.describe(strategy),
      3
    )
  end
  return setmetatable({
    strategy = strategy,
    parent = parent,
    state = "open",
    keys = {},
    finalizers = {},
    slots = {},
    size = 0,
    live = 0,
  }, ScopeMT)
end

--- A new open scope, outside an effect.
---@param strategy leffect.Scope.Strategy? Defaults to "sequential".
---@return leffect.Scope
function Scope.makeUnsafe(strategy)
  return make(strategy, nil)
end

--- An effect that succeeds with a new open scope.
---@param strategy leffect.Scope.Strategy? Defaults to "sequential".
---@return leffect.Effect
function Scope.make(strategy)
  return core.sync(function()
    return make(strategy, nil)
  end)
end

--- Adds `finalizer` to an open scope under `key`; a key already there keeps its
--- position and gets the new finalizer. Does nothing to a closed scope.
---@param scope leffect.Scope
---@param key table
---@param finalizer leffect.Scope.Finalizer
function Scope.addFinalizerUnsafe(scope, key, finalizer)
  if scope.state == "closed" then
    return
  end
  local i = scope.slots[key]
  if i then
    scope.finalizers[i] = finalizer
    return
  end
  local size = scope.size + 1
  scope.size = size
  scope.keys[size] = key
  scope.finalizers[size] = finalizer
  scope.slots[key] = size
  scope.live = scope.live + 1
end

-- Moves the finalizers over the holes, keeping their order.
---@param scope leffect.Scope
local function compact(scope)
  local keys, finalizers, slots = scope.keys, scope.finalizers, scope.slots
  local size, n = scope.size, 0
  for i = 1, size do
    local key = keys[i]
    if key then
      n = n + 1
      keys[n] = key
      finalizers[n] = finalizers[i]
      slots[key] = n
    end
  end
  for i = n + 1, size do
    keys[i] = nil
    finalizers[i] = nil
  end
  scope.size = n
end

--- Removes the finalizer under `key` from an open scope, in constant time.
--- Does nothing if there is none, or if the scope is closed.
---@param scope leffect.Scope
---@param key table
function Scope.removeFinalizerUnsafe(scope, key)
  if scope.state == "closed" then
    return
  end
  local slots = scope.slots
  local i = slots[key]
  if not i then
    return
  end
  slots[key] = nil
  scope.keys[i] = false
  scope.finalizers[i] = false
  local live = scope.live - 1
  scope.live = live
  if scope.size - live > live then
    compact(scope)
  end
end

--- An effect that adds `finalizer` to `scope`. If the scope is already closed,
--- it runs `finalizer(exit)` at once instead, with the close exit.
---@param scope leffect.Scope
---@param finalizer leffect.Scope.Finalizer
---@return leffect.Effect
function Scope.addFinalizerExit(scope, finalizer)
  return core.suspend(function()
    if scope.state == "closed" then
      local effect = finalizer(scope.exit --[[@as leffect.Exit]])
      if effect == nil then
        return exitVoid
      end
      return core.asVoid(effect)
    end
    Scope.addFinalizerUnsafe(scope, {}, finalizer)
    return exitVoid
  end)
end

--- An effect that adds `effect` to `scope` as a finalizer that ignores the
--- exit.
---@param scope leffect.Scope
---@param effect leffect.Effect
---@return leffect.Effect
function Scope.addFinalizer(scope, effect)
  return Scope.addFinalizerExit(scope, function()
    return effect
  end)
end

--- The effect of running `finalizer(exit)`. A finalizer may return nil, and a
--- throw becomes a Die with a traceback.
---@param finalizer leffect.Scope.Finalizer
---@param exit leffect.Exit
---@return leffect.Effect
local function finalizerEffect(finalizer, exit)
  return core.suspend(function()
    local effect = finalizer(exit)
    if effect == nil then
      return exitVoid
    end
    return effect
  end)
end

--- Appends the reasons of a failed `result` to `reasons[1..count]`, and
--- returns the new count.
---@param reasons leffect.Cause.Reason[]
---@param count integer
---@param result leffect.Exit
---@return integer
local function addReasons(reasons, count, result)
  if result._op == OP_FAILURE then
    local lost = result.cause.reasons
    for j = 1, #lost do
      count = count + 1
      reasons[count] = lost[j]
    end
  end
  return count
end

--- Fails with `reasons[1..count]`, duplicates included, or succeeds with nil
--- (v4's `exitAsVoidAll`).
---@param reasons leffect.Cause.Reason[]
---@param count integer
---@return leffect.Exit
local function voidAll(reasons, count)
  if count == 0 then
    return exitVoid
  end
  return exitFailCause(Cause.fromReasons(reasons))
end

--- Runs `finalizers[1..count]` one after the other, each isolated with
--- `Effect.exit`, so a failure or a throw doesn't stop the next one. Fails
--- with every finalizer's reasons in run order. A flatMap chain, so a long
--- list grows neither stack.
---@param finalizers leffect.Scope.Finalizer[]
---@param count integer
---@param exit leffect.Exit
---@return leffect.Effect
local function runInTurn(finalizers, count, exit)
  return core.suspend(function()
    local reasons, failed = {}, 0
    local function step(i)
      if i > count then
        return voidAll(reasons, failed)
      end
      return core.flatMap(core.exit(finalizerEffect(finalizers[i], exit)), function(result)
        failed = addReasons(reasons, failed, result)
        return step(i + 1)
      end)
    end
    return step(1)
  end)
end

--- Runs `finalizers[1..count]` at the same time, each on a daemon fork of the
--- closing fiber that inherits its interruptibility, so the forks are
--- uninterruptible. Waits for them all, then fails with their reasons in
--- fork order. Skips the finalizer keyed by the closing fiber: that is its
--- own `forkIn` finalizer, which would wait for it to exit.
---@param finalizers leffect.Scope.Finalizer[]
---@param keys table[]
---@param count integer
---@param exit leffect.Exit
---@return leffect.Effect
local function runTogether(finalizers, keys, count, exit)
  return core.withFiber(function(fiber)
    local forks, n = {}, 0
    for i = 1, count do
      if keys[i] ~= fiber then
        n = n + 1
        forks[n] = Fiber.forkUnsafe(fiber, finalizerEffect(finalizers[i], exit), true, "inherit")
      end
    end
    return core.flatMap(Fiber.awaitAll(forks), function(exits)
      local reasons, failed = {}, 0
      for i = 1, n do
        failed = addReasons(reasons, failed, exits[i])
      end
      return voidAll(reasons, failed)
    end)
  end)
end

--- Closes `scope` with `exit`, outside an effect. Returns the effect that runs
--- its finalizers, newest first, or nil if there is nothing to run. Run that
--- effect uninterruptibly. A closed scope stays as it is.
---@param scope leffect.Scope
---@param exit leffect.Exit
---@return leffect.Effect?
function Scope.closeUnsafe(scope, exit)
  if scope.state == "closed" then
    return nil
  end
  local parent = scope.parent
  if parent then
    Scope.removeFinalizerUnsafe(parent, scope)
  end
  local keys, finalizers = scope.keys, scope.finalizers
  local newestFirst, newestKeys, count = {}, {}, 0
  for i = scope.size, 1, -1 do
    local key = keys[i]
    if key then
      count = count + 1
      newestFirst[count] = finalizers[i]
      newestKeys[count] = key
    end
  end
  scope.state, scope.exit = "closed", exit
  scope.keys, scope.finalizers, scope.slots, scope.size, scope.live = {}, {}, {}, 0, 0
  if count == 0 then
    return nil
  elseif scope.strategy == "parallel" then
    return runTogether(newestFirst, newestKeys, count, exit)
  end
  return runInTurn(newestFirst, count, exit)
end

--- An effect that closes `scope` with `exit`, uninterruptibly, and fails with
--- the reasons of the finalizers that failed. A closed scope stays as it is.
---@param scope leffect.Scope
---@param exit leffect.Exit
---@return leffect.Effect
function Scope.close(scope, exit)
  return core.withFiber(function(fiber)
    runtime.enterUninterruptible(fiber)
    return Scope.closeUnsafe(scope, exit) or exitVoid
  end)
end

--- A child of `scope`, outside an effect. The child closes when `scope`
--- closes, at its position among `scope`'s finalizers; closed first, it
--- detaches. Forking a closed scope gives a closed scope with the same exit.
---@param scope leffect.Scope
---@param strategy leffect.Scope.Strategy? Defaults to "sequential".
---@return leffect.Scope
function Scope.forkUnsafe(scope, strategy)
  local child = make(strategy, scope)
  if scope.state == "closed" then
    child.state, child.exit = "closed", scope.exit
    return child
  end
  Scope.addFinalizerUnsafe(scope, child, function(exit)
    return Scope.close(child, exit)
  end)
  return child
end

--- An effect that succeeds with `Scope.forkUnsafe(scope, strategy)`.
---@param scope leffect.Scope
---@param strategy leffect.Scope.Strategy? Defaults to "sequential".
---@return leffect.Effect
function Scope.fork(scope, strategy)
  return core.sync(function()
    return Scope.forkUnsafe(scope, strategy)
  end)
end

--- Runs `effect` with `scope` as the current scope, without closing it.
---@param effect leffect.Effect
---@param scope leffect.Scope
---@return leffect.Effect
function Scope.provide(effect, scope)
  return runtime.updateContext(effect, function(context)
    return Context.add(context, Scope.Scope, scope)
  end)
end

--- Runs `effect` with `scope` as the current scope, then closes the scope with
--- `effect`'s exit. The finalizers' failures are added to the exit.
---@param effect leffect.Effect
---@param scope leffect.Scope
---@return leffect.Effect
function Scope.use(effect, scope)
  return core.onExit(Scope.provide(effect, scope), function(exit)
    return Scope.closeUnsafe(scope, exit)
  end)
end

return Scope
