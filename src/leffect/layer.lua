--- Layer: builds services (specifications/27-layers.md §27, 4.1.5's `Layer`
--- module).
---
--- ```lua
--- local Config = Context.Service("app/Config")
--- local Database = Context.Service("app/Database")
---
--- local ConfigLive = Layer.succeed(Config, { url = "db://local" })
--- local DatabaseLive = Layer.effect(Database, Effect.gen(function(run)
---   local config = run(Config)
---   return run(Effect.acquireRelease(connect(config.url), function(db)
---     return db.close()
---   end))
--- end))
---
--- local program = Database:use(function(db) return db.query("select 1") end)
--- local main = Effect.provide(program, DatabaseLive:provide(ConfigLive))
--- ```
---
--- Building a layer may need services, may fail, and may acquire resources,
--- which live until the scope the layer was built into closes. Within one
--- build, a layer used twice is built once: layers are told apart by
--- identity, so share the value to share the build.

local Cause = require("leffect.cause")
local Context = require("leffect.context")
local Effect = require("leffect.effect")
local Scope = require("leffect.scope")
local core = require("leffect.core")
local runtime = require("leffect.runtime")

local error, getmetatable, pairs, select, setmetatable, type =
  error, getmetatable, pairs, select, setmetatable, type
local remove = table.remove

local exitSucceed, exitFailCause, exitVoid = core.exitSucceed, core.exitFailCause, core.exitVoid
local OP_FAILURE = core.OP_FAILURE
local describe = runtime.describe

---A recipe for services: `build` gives an effect that succeeds with a Context
---of them, and ties the resources it acquires to `scope`.
---@class leffect.Layer
---@field build fun(memoMap: leffect.Layer.MemoMap, scope: leffect.Scope): leffect.Effect
---@field merge fun(self: leffect.Layer, that: leffect.Layer|leffect.Layer[]): leffect.Layer
---@field provide fun(self: leffect.Layer, that: leffect.Layer|leffect.Layer[]): leffect.Layer
---@field provideMerge fun(self: leffect.Layer, that: leffect.Layer|leffect.Layer[]): leffect.Layer
---@field flatMap fun(self: leffect.Layer, f: fun(context: leffect.Context): leffect.Layer): leffect.Layer
---@field orDie fun(self: leffect.Layer): leffect.Layer
---@field catchAll fun(self: leffect.Layer, f: fun(err: any): leffect.Layer): leffect.Layer
---@field catchCause fun(self: leffect.Layer, f: fun(cause: leffect.Cause): leffect.Layer): leffect.Layer
---@field fresh fun(self: leffect.Layer): leffect.Layer

---The builds shared within one build of a layer graph (§27.4).
---@class leffect.Layer.MemoMap
---@field parent leffect.Layer.MemoMap?
---@field entries table<leffect.Layer, leffect.Layer.MemoEntry>

---@class leffect.Layer.MemoEntry
---@field observers integer How many scopes use this build.
---@field deferred leffect.Layer.Deferred The build's exit, once there is one.
---@field scope leffect.Scope Owns the build's resources.
---@field finalizer leffect.Scope.Finalizer

---Internal: an exit that fibers can wait for, completed once.
---@class leffect.Layer.Deferred
---@field exit leffect.Exit?
---@field waiters (fun(exit: leffect.Exit))[]

local methods = {}

local LayerMT = { __index = methods, __name = "leffect.Layer" }
local MemoMapMT = { __name = "leffect.Layer.MemoMap" }

-- Context.add's message, for the builds that die instead of raising.
local NIL_SERVICE = "Context.add: a service can't be nil"

local Layer = {}

---@param value any
---@return boolean
function Layer.isLayer(value)
  return getmetatable(value) == LayerMT
end

---@param value any
---@param name string The public function, for the message.
---@param level integer
local function checkLayer(value, name, level)
  if getmetatable(value) ~= LayerMT then
    error(name .. ": expected a Layer, got " .. describe(value), level + 1)
  end
end

---@param value any
---@param name string The public function, for the message.
local function checkKey(value, name)
  if not Context.isKey(value) then
    error(name .. ": expected a key, got " .. describe(value), 3)
  end
end

--- A Layer, or a list of layers given as a table without a metatable, as a
--- list and its count. Raises for anything else, at `level`.
---@param value any
---@param name string The public function, for the message.
---@param level integer
---@return leffect.Layer[] layers
---@return integer count
---@return boolean isList
local function layerOrList(value, name, level)
  if getmetatable(value) == LayerMT then
    return { value }, 1, false
  end
  if type(value) == "table" and getmetatable(value) == nil then
    local layers, count = {}, 0
    for _ in pairs(value) do
      count = count + 1
    end
    for i = 1, count do
      checkLayer(value[i], name, level + 1)
      layers[i] = value[i]
    end
    return layers, count, true
  end
  error(name .. ": expected a Layer or a list of layers, got " .. describe(value), level + 1)
end

---@param name string
---@param value any
---@return leffect.Exit.Failure
local function dieNotLayer(name, value)
  return exitFailCause(Cause.die(name .. ": expected a Layer, got " .. describe(value)))
end

---@param build fun(memoMap: leffect.Layer.MemoMap, scope: leffect.Scope): leffect.Effect
---@return leffect.Layer
local function fromBuildUnsafe(build)
  return setmetatable({ build = build }, LayerMT)
end

-- The Deferred (§27.4) -------------------------------------------------------

---@return leffect.Layer.Deferred
local function newDeferred()
  return { exit = nil, waiters = {} }
end

--- Completes `deferred` with `exit`, once, and wakes its waiters.
---@param deferred leffect.Layer.Deferred
---@param exit leffect.Exit
local function deferredDone(deferred, exit)
  if deferred.exit then
    return
  end
  deferred.exit = exit
  local waiters = deferred.waiters
  deferred.waiters = {}
  for i = 1, #waiters do
    waiters[i](exit)
  end
end

--- Waits for `deferred`, then continues with its exit. An interrupted waiter
--- removes itself.
---@param deferred leffect.Layer.Deferred
---@return leffect.Effect
local function deferredAwait(deferred)
  return core.async(function(resume)
    local exit = deferred.exit
    if exit then
      resume(exit)
      return nil
    end
    local waiters = deferred.waiters
    waiters[#waiters + 1] = resume
    return function()
      local list = deferred.waiters
      for i = 1, #list do
        if list[i] == resume then
          remove(list, i)
          return
        end
      end
    end
  end)
end

-- The MemoMap (§27.4, 4.1.5's `MemoMapImpl`) ---------------------------------

---@param parent leffect.Layer.MemoMap?
---@return leffect.Layer.MemoMap
local function newMemoMap(parent)
  return setmetatable({ parent = parent, entries = {} }, MemoMapMT)
end

--- A new MemoMap, outside an effect.
---@return leffect.Layer.MemoMap
function Layer.makeMemoMapUnsafe()
  return newMemoMap(nil)
end

--- An effect that succeeds with a new MemoMap.
Layer.makeMemoMap = core.sync(Layer.makeMemoMapUnsafe)

--- The entry for a build of `layer` in `memoMap`. Its finalizer, added to each
--- observer's scope, releases the build after the last observer. It mustn't
--- hold on to the caller of `getOrElseMemoize`.
---@param memoMap leffect.Layer.MemoMap
---@param layer leffect.Layer
---@return leffect.Layer.MemoEntry
local function makeEntry(memoMap, layer)
  local entry
  entry = {
    observers = 0,
    deferred = newDeferred(),
    scope = Scope.makeUnsafe(),
    finalizer = function(exit)
      return core.suspend(function()
        entry.observers = entry.observers - 1
        if entry.observers > 0 then
          return exitVoid
        end
        memoMap.entries[layer] = nil
        return Scope.close(entry.scope, exit)
      end)
    end,
  }
  return entry
end

--- Makes `scope` an observer of `entry`. Counts and registers in one step, so
--- that an interrupt can't strand an observer. A closed scope can't own an
--- entry: returns false.
---@param entry leffect.Layer.MemoEntry
---@param scope leffect.Scope
---@return boolean
local function observe(entry, scope)
  if scope.state == "closed" then
    return false
  end
  entry.observers = entry.observers + 1
  Scope.addFinalizerUnsafe(scope, {}, entry.finalizer)
  return true
end

--- The build of `layer` in `memoMap` or one of its parents, observed by
--- `scope`: its exit, or an effect that waits for it. Nil if there is none.
---@param memoMap leffect.Layer.MemoMap
---@param layer leffect.Layer
---@param scope leffect.Scope
---@return leffect.Effect?
local function lookup(memoMap, layer, scope)
  local map = memoMap
  while map do
    local entry = map.entries[layer]
    if entry then
      observe(entry, scope)
      return entry.deferred.exit or deferredAwait(entry.deferred)
    end
    map = map.parent
  end
  return nil
end

--- The shared build of `layer`: an existing one, or a new one that `build`
--- makes in the entry's own scope.
---@param memoMap leffect.Layer.MemoMap
---@param layer leffect.Layer
---@param scope leffect.Scope
---@param build fun(memoMap: leffect.Layer.MemoMap, scope: leffect.Scope): leffect.Effect
---@return leffect.Effect
local function getOrElseMemoize(memoMap, layer, scope, build)
  return core.suspend(function()
    local deferred
    -- The exit handler is in place before the entry is published: it must
    -- complete the Deferred even if the first requester is interrupted.
    return core.onExit(
      core.suspend(function()
        local existing = lookup(memoMap, layer, scope)
        if existing then
          return existing
        end
        local entry = makeEntry(memoMap, layer)
        if not observe(entry, scope) then
          -- A closed scope can't own a shared entry: build in it, unshared.
          return build(memoMap, scope)
        end
        deferred = entry.deferred
        memoMap.entries[layer] = entry
        return build(memoMap, entry.scope)
      end),
      function(exit)
        if deferred then
          deferredDone(deferred, exit)
        end
        return nil
      end
    )
  end)
end

-- Wrappers (§27.1) -----------------------------------------------------------

--- A layer from a build function. The build gets a child of the scope, which
--- it closes if the build fails, so a failing layer releases what it
--- acquired.
---@param build fun(memoMap: leffect.Layer.MemoMap, scope: leffect.Scope): leffect.Effect
---@return leffect.Layer
function Layer.fromBuild(build)
  return fromBuildUnsafe(function(memoMap, scope)
    local layerScope = Scope.forkUnsafe(scope)
    return core.onExit(build(memoMap, layerScope), function(exit)
      if exit._op == OP_FAILURE then
        return Scope.close(layerScope, exit)
      end
      return nil
    end)
  end)
end

--- `fromBuild` through the MemoMap: one build per layer per MemoMap.
---@param build fun(memoMap: leffect.Layer.MemoMap, scope: leffect.Scope): leffect.Effect
---@return leffect.Layer
function Layer.fromBuildMemo(build)
  local self
  self = Layer.fromBuild(function(memoMap, scope)
    return getOrElseMemoize(memoMap, self, scope, build)
  end)
  return self
end

-- Constructors (§27.2) -------------------------------------------------------

--- Every service in `context`. Nothing to build, so not shared.
---@param context leffect.Context
---@return leffect.Layer
function Layer.succeedContext(context)
  if not Context.isContext(context) then
    error("Layer.succeedContext: expected a Context, got " .. describe(context), 2)
  end
  local built = exitSucceed(context)
  return fromBuildUnsafe(function()
    return built
  end)
end

--- The service `service` under `key`. Raises if `service` is nil.
---@param key leffect.Context.Key
---@param service any
---@return leffect.Layer
function Layer.succeed(key, service)
  checkKey(key, "Layer.succeed")
  if service == nil then
    error(NIL_SERVICE, 2)
  end
  return Layer.succeedContext(Context.make(key, service))
end

--- The layer with no services.
---@type leffect.Layer
Layer.empty = Layer.succeedContext(Context.empty())

--- A function that turns a service into a Context with it under `key`, as an
--- Exit; a nil service dies.
---@param key leffect.Context.Key
---@return fun(service: any): leffect.Exit
local function contextOf(key)
  return function(service)
    if service == nil then
      return exitFailCause(Cause.die(NIL_SERVICE))
    end
    return exitSucceed(Context.make(key, service))
  end
end

--- A function that passes a Context through as an Exit, and dies on anything
--- else.
---@param name string The public function, for the message.
---@return fun(value: any): leffect.Exit
local function checkedContext(name)
  return function(value)
    if not Context.isContext(value) then
      return exitFailCause(Cause.die(name .. ": expected a Context, got " .. describe(value)))
    end
    return exitSucceed(value)
  end
end

--- The service `thunk()` returns, under `key`. `thunk` is called once per
--- build. Shared.
---@param key leffect.Context.Key
---@param thunk fun(): any
---@return leffect.Layer
function Layer.sync(key, thunk)
  checkKey(key, "Layer.sync")
  local built = core.flatMap(core.sync(thunk), contextOf(key))
  return Layer.fromBuildMemo(function()
    return built
  end)
end

--- The services of the Context `thunk()` returns, once per build. Shared.
---@param thunk fun(): leffect.Context
---@return leffect.Layer
function Layer.syncContext(thunk)
  local built = core.flatMap(core.sync(thunk), checkedContext("Layer.syncContext"))
  return Layer.fromBuildMemo(function()
    return built
  end)
end

--- The services of the Context `effect` succeeds with. `effect` runs with the
--- layer's scope as its current scope, so the resources it acquires live as
--- long as the layer. Shared.
---@param effect leffect.Effect
---@return leffect.Layer
function Layer.effectContext(effect)
  local checked = core.flatMap(effect, checkedContext("Layer.effectContext"))
  return Layer.fromBuildMemo(function(_, scope)
    return Scope.provide(checked, scope)
  end)
end

--- The service `effect` succeeds with, under `key`. As for `effectContext`,
--- `effect` runs with the layer's scope as its current scope. Shared.
---@param key leffect.Context.Key
---@param effect leffect.Effect
---@return leffect.Layer
function Layer.effect(key, effect)
  checkKey(key, "Layer.effect")
  return Layer.effectContext(core.flatMap(effect, contextOf(key)))
end

--- Runs `effect` for its effects, with the layer's scope, and provides
--- nothing. Shared.
---@param effect leffect.Effect
---@return leffect.Layer
function Layer.effectDiscard(effect)
  return Layer.effectContext(Effect.as(effect, Context.empty()))
end

--- Builds the layer that `thunk()` returns. Shared.
---@param thunk fun(): leffect.Layer
---@return leffect.Layer
function Layer.suspend(thunk)
  return Layer.fromBuildMemo(function(memoMap, scope)
    return core.suspend(function()
      local layer = thunk()
      if not Layer.isLayer(layer) then
        return dieNotLayer("Layer.suspend", layer)
      end
      return layer.build(memoMap, scope)
    end)
  end)
end

-- Composition (§27.3) --------------------------------------------------------

--- Builds `layers[1..count]` at the same time, each into a child of a
--- parallel child of `scope`, and merges their contexts, later ones winning.
---@param layers leffect.Layer[]
---@param count integer
---@param memoMap leffect.Layer.MemoMap
---@param scope leffect.Scope
---@return leffect.Effect
local function mergeAllEffect(layers, count, memoMap, scope)
  local parent = Scope.forkUnsafe(scope, "parallel")
  local built = Effect.forEach(layers, function(layer)
    return layer.build(memoMap, Scope.forkUnsafe(parent, "sequential"))
  end, { concurrency = count })
  return core.map(built, function(contexts)
    local merged = Context.empty()
    for i = 1, contexts.n do
      merged = Context.merge(merged, contexts[i])
    end
    return merged
  end)
end

---@param layers leffect.Layer[]
---@param count integer
---@return leffect.Layer
local function mergeList(layers, count)
  return Layer.fromBuildMemo(function(memoMap, scope)
    return mergeAllEffect(layers, count, memoMap, scope)
  end)
end

--- Builds every layer at the same time, and merges their services. Where
--- several have a key, the last one wins. A failing build interrupts the
--- others. Shared.
---@param ... leffect.Layer
---@return leffect.Layer
function Layer.mergeAll(...)
  local count = select("#", ...)
  local layers = { ... }
  for i = 1, count do
    checkLayer(layers[i], "Layer.mergeAll", 2)
  end
  return mergeList(layers, count)
end

--- `mergeAll(self, that)`, where `that` may be a list of layers.
---@param self leffect.Layer
---@param that leffect.Layer|leffect.Layer[]
---@return leffect.Layer
function Layer.merge(self, that)
  checkLayer(self, "Layer.merge", 2)
  local others, count = layerOrList(that, "Layer.merge", 2)
  local layers = { self }
  for i = 1, count do
    layers[i + 1] = others[i]
  end
  return mergeList(layers, count + 1)
end

--- Builds `that`, then `self` with `that`'s services, and combines the two
--- contexts with `combine(selfContext, thatContext)`. Both use the scope;
--- `self` forks its child second, so it is released first.
---@param self leffect.Layer
---@param that leffect.Layer|leffect.Layer[]
---@param name string The public function, for the message.
---@param combine fun(selfContext: leffect.Context, thatContext: leffect.Context): leffect.Context
---@return leffect.Layer
local function provideWith(self, that, name, combine)
  checkLayer(self, name, 3)
  local layers, count, isList = layerOrList(that, name, 3)
  return Layer.fromBuildMemo(function(memoMap, scope)
    local built
    if isList then
      built = mergeAllEffect(layers, count, memoMap, scope)
    else
      built = layers[1].build(memoMap, scope)
    end
    return core.flatMap(built, function(thatContext)
      local selfBuilt = Effect.provideContext(self.build(memoMap, scope), thatContext)
      return core.map(selfBuilt, function(selfContext)
        return combine(selfContext, thatContext)
      end)
    end)
  end)
end

---@param selfContext leffect.Context
---@return leffect.Context
local function selfOnly(selfContext)
  return selfContext
end

---@param selfContext leffect.Context
---@param thatContext leffect.Context
---@return leffect.Context
local function selfOverThat(selfContext, thatContext)
  return Context.merge(thatContext, selfContext)
end

--- Builds `that` first, then `self` with `that`'s services, and gives only
--- `self`'s. A list in `that` is merged. Shared.
---@param self leffect.Layer
---@param that leffect.Layer|leffect.Layer[]
---@return leffect.Layer
function Layer.provide(self, that)
  return provideWith(self, that, "Layer.provide", selfOnly)
end

--- Like `provide`, but gives the services of both layers, `self`'s winning.
---@param self leffect.Layer
---@param that leffect.Layer|leffect.Layer[]
---@return leffect.Layer
function Layer.provideMerge(self, that)
  return provideWith(self, that, "Layer.provideMerge", selfOverThat)
end

--- Builds `self`, then the layer `f(context)`, and gives its services.
---@param self leffect.Layer
---@param f fun(context: leffect.Context): leffect.Layer
---@return leffect.Layer
function Layer.flatMap(self, f)
  checkLayer(self, "Layer.flatMap", 2)
  return Layer.fromBuild(function(memoMap, scope)
    return core.flatMap(self.build(memoMap, scope), function(context)
      local layer = f(context)
      if not Layer.isLayer(layer) then
        return dieNotLayer("Layer.flatMap", layer)
      end
      return layer.build(memoMap, scope)
    end)
  end)
end

--- Turns a build failure into a defect.
---@param self leffect.Layer
---@return leffect.Layer
function Layer.orDie(self)
  checkLayer(self, "Layer.orDie", 2)
  return fromBuildUnsafe(function(memoMap, scope)
    return Effect.catchAll(self.build(memoMap, scope), Effect.die)
  end)
end

--- When the build fails, builds the layer `f(err)` instead (v4's
--- `Layer.catch`). Like `Effect.catchAll`, it doesn't recover a defect or an
--- interrupt.
---@param self leffect.Layer
---@param f fun(err: any): leffect.Layer
---@return leffect.Layer
function Layer.catchAll(self, f)
  checkLayer(self, "Layer.catchAll", 2)
  return fromBuildUnsafe(function(memoMap, scope)
    return Effect.catchAll(self.build(memoMap, scope), function(err)
      local layer = f(err)
      if not Layer.isLayer(layer) then
        return dieNotLayer("Layer.catchAll", layer)
      end
      return layer.build(memoMap, scope)
    end)
  end)
end

--- When the build fails, builds the layer `f(cause)` instead.
---@param self leffect.Layer
---@param f fun(cause: leffect.Cause): leffect.Layer
---@return leffect.Layer
function Layer.catchCause(self, f)
  checkLayer(self, "Layer.catchCause", 2)
  return fromBuildUnsafe(function(memoMap, scope)
    return core.catchCause(self.build(memoMap, scope), function(cause)
      local layer = f(cause)
      if not Layer.isLayer(layer) then
        return dieNotLayer("Layer.catchCause", layer)
      end
      return layer.build(memoMap, scope)
    end)
  end)
end

--- Builds `self` with a new MemoMap, so it shares nothing with the rest of
--- the graph.
---@param self leffect.Layer
---@return leffect.Layer
function Layer.fresh(self)
  checkLayer(self, "Layer.fresh", 2)
  return fromBuildUnsafe(function(_, scope)
    return self.build(newMemoMap(nil), scope)
  end)
end

-- Building (§27.5) -----------------------------------------------------------

--- The key of the MemoMap that built the current services (4.1.5's
--- `Layer.CurrentMemoMap`). A build provided with services from another
--- build shares that one's layers.
Layer.CurrentMemoMap = Context.Service("leffect/Layer/CurrentMemoMap")

local CurrentMemoMap = Layer.CurrentMemoMap

local function none()
  return nil
end

--- A child of the context's MemoMap, or a new MemoMap if it has none.
---@param context leffect.Context
---@return leffect.Layer.MemoMap
local function forkOrCreate(context)
  return newMemoMap(Context.getOrElse(context, CurrentMemoMap, none))
end

--- An effect that builds `self` into `scope`, sharing builds through
--- `memoMap`, and succeeds with the Context. The Context also holds the
--- MemoMap, under `Layer.CurrentMemoMap`.
---@param self leffect.Layer
---@param memoMap leffect.Layer.MemoMap
---@param scope leffect.Scope
---@return leffect.Effect
function Layer.buildWithMemoMap(self, memoMap, scope)
  checkLayer(self, "Layer.buildWithMemoMap", 2)
  local built = core.map(
    core.suspend(function()
      return self.build(memoMap, scope)
    end),
    function(context)
      return Context.add(context, CurrentMemoMap, memoMap)
    end
  )
  return Effect.provideService(built, CurrentMemoMap, memoMap)
end

--- An effect that builds `self` into `scope`, and succeeds with the Context.
--- It shares the builds of the services the fiber got from another build.
---@param self leffect.Layer
---@param scope leffect.Scope
---@return leffect.Effect
function Layer.buildWithScope(self, scope)
  checkLayer(self, "Layer.buildWithScope", 2)
  return core.withFiber(function(fiber)
    return Layer.buildWithMemoMap(self, forkOrCreate(fiber.context), scope)
  end)
end

--- An effect that builds `self` into the current scope, and succeeds with
--- the Context. Without a scope, it dies.
---@param self leffect.Layer
---@return leffect.Effect
function Layer.build(self)
  checkLayer(self, "Layer.build", 2)
  return core.flatMap(Effect.scope, function(scope)
    return Layer.buildWithScope(self, scope)
  end)
end

--- An effect that builds `self`, then never ends. When interrupted, it
--- releases the layer. For a layer that is the whole program, such as a
--- server.
---@param self leffect.Layer
---@return leffect.Effect
function Layer.launch(self)
  checkLayer(self, "Layer.launch", 2)
  return Effect.scoped(core.flatMap(Layer.build(self), function()
    return Effect.never
  end))
end

methods.merge = Layer.merge
methods.provide = Layer.provide
methods.provideMerge = Layer.provideMerge
methods.flatMap = Layer.flatMap
methods.orDie = Layer.orDie
methods.catchAll = Layer.catchAll
methods.catchCause = Layer.catchCause
methods.fresh = Layer.fresh

return Layer
