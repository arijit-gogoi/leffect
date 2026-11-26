--- Ref: one value that fibers share (specifications/34-ref.md §34, 4.1.5's
--- `Ref` module).
---
--- ```lua
--- local counter = Ref.makeUnsafe(0)
--- local program = Effect.forEach(items, function()
---   return counter:update(function(n) return n + 1 end)
--- end, { concurrency = 4 })
--- ```
---
--- Each function is one `sync` step, so an update sees the latest value and
--- never loses a concurrent one. A function passed to an update runs inside
--- that step: it must not yield, and if it throws, the Ref keeps its value and
--- the effect dies. A Ref may hold nil. It is not an effect.

local core = require("leffect.core")
local runtime = require("leffect.runtime")

local error, getmetatable, select, setmetatable, type =
  error, getmetatable, select, setmetatable, type

local describe = runtime.describe
local sync = core.sync

---A mutable cell shared by fibers.
---@class leffect.Ref
---@field get fun(self: leffect.Ref): leffect.Effect
---@field set fun(self: leffect.Ref, value: any): leffect.Effect
---@field getAndSet fun(self: leffect.Ref, value: any): leffect.Effect
---@field setAndGet fun(self: leffect.Ref, value: any): leffect.Effect
---@field update fun(self: leffect.Ref, f: fun(value: any): any): leffect.Effect
---@field getAndUpdate fun(self: leffect.Ref, f: fun(value: any): any): leffect.Effect
---@field updateAndGet fun(self: leffect.Ref, f: fun(value: any): any): leffect.Effect
---@field modify fun(self: leffect.Ref, f: fun(value: any): (any, any)): leffect.Effect
---@field getUnsafe fun(self: leffect.Ref): any

local methods = {}

local RefMT = { __index = methods, __name = "leffect.Ref" }

local Ref = {}

---@param value any
---@param name string
local function checkRef(value, name)
  if getmetatable(value) ~= RefMT then
    error(name .. ": expected a Ref, got " .. describe(value), 3)
  end
end

---@param f any
---@param name string
local function checkFunction(f, name)
  if type(f) ~= "function" then
    error(name .. ": expected a function, got " .. describe(f), 3)
  end
end

--- A new Ref holding `value`, outside an effect.
---@param value any
---@return leffect.Ref
function Ref.makeUnsafe(value)
  -- A private field, named unlike any method, since fields shadow methods.
  return setmetatable({ current = value }, RefMT)
end

--- An effect that succeeds with a new Ref holding `value`.
---@param value any
---@return leffect.Effect
function Ref.make(value)
  return sync(function()
    return Ref.makeUnsafe(value)
  end)
end

---@param value any
---@return boolean
function Ref.isRef(value)
  return getmetatable(value) == RefMT
end

--- The value, outside an effect.
---@param ref leffect.Ref
---@return any
function Ref.getUnsafe(ref)
  checkRef(ref, "Ref.getUnsafe")
  return ref.current
end

--- Succeeds with the value.
---@param ref leffect.Ref
---@return leffect.Effect
function Ref.get(ref)
  checkRef(ref, "Ref.get")
  return sync(function()
    return ref.current
  end)
end

--- Sets the value.
---@param ref leffect.Ref
---@param value any
---@return leffect.Effect
function Ref.set(ref, value)
  checkRef(ref, "Ref.set")
  return sync(function()
    ref.current = value
  end)
end

--- Sets the value, and succeeds with the old one.
---@param ref leffect.Ref
---@param value any
---@return leffect.Effect
function Ref.getAndSet(ref, value)
  checkRef(ref, "Ref.getAndSet")
  return sync(function()
    local old = ref.current
    ref.current = value
    return old
  end)
end

--- Sets the value, and succeeds with it.
---@param ref leffect.Ref
---@param value any
---@return leffect.Effect
function Ref.setAndGet(ref, value)
  checkRef(ref, "Ref.setAndGet")
  return sync(function()
    ref.current = value
    return value
  end)
end

--- Sets the value to `f(value)`.
---@param ref leffect.Ref
---@param f fun(value: any): any
---@return leffect.Effect
function Ref.update(ref, f)
  checkRef(ref, "Ref.update")
  checkFunction(f, "Ref.update")
  return sync(function()
    ref.current = f(ref.current)
  end)
end

--- Sets the value to `f(value)`, and succeeds with the old value.
---@param ref leffect.Ref
---@param f fun(value: any): any
---@return leffect.Effect
function Ref.getAndUpdate(ref, f)
  checkRef(ref, "Ref.getAndUpdate")
  checkFunction(f, "Ref.getAndUpdate")
  return sync(function()
    local old = ref.current
    ref.current = f(old)
    return old
  end)
end

--- Sets the value to `f(value)`, and succeeds with the new value.
---@param ref leffect.Ref
---@param f fun(value: any): any
---@return leffect.Effect
function Ref.updateAndGet(ref, f)
  checkRef(ref, "Ref.updateAndGet")
  checkFunction(f, "Ref.updateAndGet")
  return sync(function()
    local new = f(ref.current)
    ref.current = new
    return new
  end)
end

local MODIFY_ARITY = "Ref.modify: f must return the result and the new value"

---@return integer count
---@return any result
---@return any new
local function counted(...)
  return select("#", ...), ...
end

--- `f(value)` returns a result and a new value. Sets the new value, and
--- succeeds with the result. If `f` returns fewer than two values, the effect
--- dies and the Ref keeps its value.
---@param ref leffect.Ref
---@param f fun(value: any): (any, any)
---@return leffect.Effect
function Ref.modify(ref, f)
  checkRef(ref, "Ref.modify")
  checkFunction(f, "Ref.modify")
  return sync(function()
    local count, result, new = counted(f(ref.current))
    if count < 2 then
      error(MODIFY_ARITY, 0)
    end
    ref.current = new
    return result
  end)
end

methods.get = Ref.get
methods.set = Ref.set
methods.getAndSet = Ref.getAndSet
methods.setAndGet = Ref.setAndGet
methods.update = Ref.update
methods.getAndUpdate = Ref.getAndUpdate
methods.updateAndGet = Ref.updateAndGet
methods.modify = Ref.modify
methods.getUnsafe = Ref.getUnsafe

return Ref
