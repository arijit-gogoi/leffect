--- Context: the services a fiber runs with (specifications/26-services.md
--- §26, 4.1.5's `Context` module).
---
--- ```lua
--- local Database = Context.Service("app/Database")
--- local LogLevel = Context.Reference("app/LogLevel", {
---   defaultValue = function() return "info" end,
--- })
---
--- local program = Effect.gen(function(run)
---   local db = run(Database) -- a key is an effect
---   local level = run(LogLevel) -- "info", unless a region provides another
---   return db.query("select 1")
--- end)
--- Effect.runSync(Effect.provideService(program, Database, db))
--- ```
---
--- A context is an immutable map from key strings to services: adding a
--- service copies it. A fork starts with its parent's context. A key is an
--- effect that succeeds with its service in the running fiber's context. A
--- missing Service is a defect; a missing Reference gives its default, which
--- is computed once.

local Cause = require("leffect.cause")
local core = require("leffect.core")
local runtime = require("leffect.runtime")

local error, getmetatable, next, pairs, rawget, select, setmetatable, type =
  error, getmetatable, next, pairs, rawget, select, setmetatable, type

local EffectMT = core.EffectMT
local exitSucceed, exitFailCause = core.exitSucceed, core.exitFailCause
local describe = runtime.describe

---Services by key string. Never changed once built.
---@class leffect.Context
---@field map table<string, any>

---A key: an effect that succeeds with its service in the fiber's context.
---@class leffect.Context.Key : leffect.Effect
---@field key string The string that names the service.
---@field defaultValue (fun(): any)? Set for a Reference.
---@field use fun(self: leffect.Context.Key, f: fun(service: any): leffect.Effect): leffect.Effect
---@field useSync fun(self: leffect.Context.Key, f: fun(service: any): any): leffect.Effect

local ContextMT = { __name = "leffect.Context" }

--- Marks keys, so that `isKey` can tell them from other WithFiber effects.
local KEY = setmetatable({}, { __name = "leffect.Context.KEY" })

local NIL_SERVICE = "Context.add: a service can't be nil"

local Context = {}

---@param map table<string, any>
---@return leffect.Context
local function make(map)
  return setmetatable({ map = map }, ContextMT)
end

local EMPTY = make({})

--- The context with no services, which root fibers start with. Always the
--- same value.
---@return leffect.Context
function Context.empty()
  return EMPTY
end

---@param value any
---@return boolean
function Context.isContext(value)
  return getmetatable(value) == ContextMT
end

--- True for a key: a Service or a Reference.
---@param value any
---@return boolean
function Context.isKey(value)
  return getmetatable(value) == EffectMT and rawget(value, KEY) == true
end

--- True for a Reference: a key with a default value.
---@param value any
---@return boolean
function Context.isReference(value)
  return Context.isKey(value) and rawget(value, "defaultValue") ~= nil
end

---@param value any
---@param name string The public function, for the message.
local function checkContext(value, name)
  if getmetatable(value) ~= ContextMT then
    error(name .. ": expected a Context, got " .. describe(value), 3)
  end
end

---@param value any
---@param name string The public function, for the message.
local function checkKey(value, name)
  if not Context.isKey(value) then
    error(name .. ": expected a key, got " .. describe(value), 3)
  end
end

--- Each Reference's default, boxed so that a nil default is cached too. The
--- cache isn't on the Reference itself: a key is an effect, and the run loop
--- never mutates an effect (invariant 13). Weak keys let a Reference go.
---@type table<leffect.Context.Key, { [1]: any }>
local defaults = setmetatable({}, { __mode = "k" })

--- Looks `key` up in `context`. Returns true and the service, true and the
--- default for a missing Reference, or false for a missing Service. A
--- `defaultValue` that throws caches nothing, and the error goes on.
---@param context leffect.Context
---@param key leffect.Context.Key
---@return boolean found
---@return any service
local function find(context, key)
  local service = context.map[key.key]
  if service ~= nil then
    return true, service
  end
  local defaultValue = key.defaultValue
  if defaultValue == nil then
    return false, nil
  end
  local box = defaults[key]
  if box == nil then
    box = { (defaultValue()) }
    defaults[key] = box
  end
  return true, box[1]
end

---@param key leffect.Context.Key
---@return string
local function notFound(key)
  return "Service not found: " .. key.key
end

---@param self leffect.Context.Key
---@param f fun(service: any): leffect.Effect
---@return leffect.Effect
local function use(self, f)
  return core.flatMap(self, f)
end

---@param self leffect.Context.Key
---@param f fun(service: any): any
---@return leffect.Effect
local function useSync(self, f)
  return core.map(self, f)
end

---@param name string
---@param defaultValue (fun(): any)?
---@return leffect.Context.Key
local function makeKey(name, defaultValue)
  local key
  key = setmetatable({
    _op = core.OP_WITH_FIBER,
    f = function(fiber)
      local found, service = find(fiber.context, key)
      if found then
        return exitSucceed(service)
      end
      -- No traceback: the lookup runs inside the loop, far from user code.
      return exitFailCause(Cause.die(notFound(key)))
    end,
    key = name,
    defaultValue = defaultValue,
    use = use,
    useSync = useSync,
    [KEY] = true,
  }, EffectMT)
  return key
end

--- A key for the service named `key`, such as `"app/Database"`. Running it
--- succeeds with the service, or dies with "Service not found: app/Database".
--- Two keys with the same string name the same service.
---@param key string
---@return leffect.Context.Key
function Context.Service(key)
  if type(key) ~= "string" then
    error("Context.Service: the key must be a string, got " .. describe(key), 2)
  end
  return makeKey(key, nil)
end

---@class leffect.Context.ReferenceOptions
---@field defaultValue fun(): any Computed the first time a lookup needs it, then cached.

--- A key with a default value, for a context that doesn't have it. The
--- default is computed once, the first time a lookup needs it, and may be
--- nil. A value is changed only for a region, by `Effect.provideService` and
--- `Effect.updateService`.
---@param key string
---@param options leffect.Context.ReferenceOptions
---@return leffect.Context.Key
function Context.Reference(key, options)
  if type(key) ~= "string" then
    error("Context.Reference: the key must be a string, got " .. describe(key), 2)
  end
  local defaultValue
  if type(options) == "table" then
    defaultValue = options.defaultValue
  end
  if type(defaultValue) ~= "function" then
    error(
      "Context.Reference: options.defaultValue must be a function, got " .. describe(defaultValue),
      2
    )
  end
  return makeKey(key, defaultValue)
end

--- A context with one service. Raises if `service` is nil.
---@param key leffect.Context.Key
---@param service any
---@return leffect.Context
function Context.make(key, service)
  checkKey(key, "Context.make")
  if service == nil then
    error(NIL_SERVICE, 2)
  end
  return make({ [key.key] = service })
end

--- A copy of `context` with `service` under `key`. Raises if `service` is
--- nil.
---@param context leffect.Context
---@param key leffect.Context.Key
---@param service any
---@return leffect.Context
function Context.add(context, key, service)
  checkContext(context, "Context.add")
  checkKey(key, "Context.add")
  if service == nil then
    error(NIL_SERVICE, 2)
  end
  local map = {}
  for k, v in pairs(context.map) do
    map[k] = v
  end
  map[key.key] = service
  return make(map)
end

--- The service under `key`. For a missing Reference, its default. For a
--- missing Service, raises "Service not found: " followed by the key.
---@param context leffect.Context
---@param key leffect.Context.Key
---@return any
function Context.get(context, key)
  checkContext(context, "Context.get")
  checkKey(key, "Context.get")
  local found, service = find(context, key)
  if not found then
    error(notFound(key), 2)
  end
  return service
end

--- The service under `key`. For a missing Reference, its default. For a
--- missing Service, `orElse()`.
---@param context leffect.Context
---@param key leffect.Context.Key
---@param orElse fun(): any
---@return any
function Context.getOrElse(context, key, orElse)
  checkContext(context, "Context.getOrElse")
  checkKey(key, "Context.getOrElse")
  local found, service = find(context, key)
  if found then
    return service
  end
  return orElse()
end

--- The services of `a` and `b`. Where both have a key, `b`'s service wins.
---@param a leffect.Context
---@param b leffect.Context
---@return leffect.Context
function Context.merge(a, b)
  checkContext(a, "Context.merge")
  checkContext(b, "Context.merge")
  if next(a.map) == nil then
    return b
  elseif next(b.map) == nil then
    return a
  end
  local map = {}
  for k, v in pairs(a.map) do
    map[k] = v
  end
  for k, v in pairs(b.map) do
    map[k] = v
  end
  return make(map)
end

--- The services of all the given contexts. Where several have a key, the
--- last one's service wins.
---@param ... leffect.Context
---@return leffect.Context
function Context.mergeAll(...)
  local contexts, count = { ... }, select("#", ...)
  local map = {}
  for i = 1, count do
    local context = contexts[i]
    checkContext(context, "Context.mergeAll")
    for k, v in pairs(context.map) do
      map[k] = v
    end
  end
  if next(map) == nil then
    return EMPTY
  end
  return make(map)
end

return Context
