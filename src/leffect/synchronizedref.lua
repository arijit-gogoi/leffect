--- SynchronizedRef: a Ref whose updates may run effects, one at a time
--- (specifications/34-ref.md §34.1, 4.1.5's `SynchronizedRef` module).
---
--- ```lua
--- local ref = SynchronizedRef.makeUnsafe(0)
--- local bump = ref:updateEffect(function(n)
---   return Effect.sleep(10):as(n + 1)
--- end)
--- ```
---
--- It is a value plus a Semaphore with one permit. Each update takes the
--- permit first, and gives it back however it ends. If the update's effect
--- fails or is interrupted, the value doesn't change. `get` doesn't wait for
--- an update that is running.

local Semaphore = require("leffect.semaphore")
local core = require("leffect.core")
local runtime = require("leffect.runtime")

local error, getmetatable, select, setmetatable, type =
  error, getmetatable, select, setmetatable, type

local describe = runtime.describe
local exitSucceed = core.exitSucceed

---A Ref whose updates run one at a time.
---@class leffect.SynchronizedRef
---@field current any
---@field permit leffect.Semaphore
---@field get fun(self: leffect.SynchronizedRef): leffect.Effect
---@field getUnsafe fun(self: leffect.SynchronizedRef): any
---@field set fun(self: leffect.SynchronizedRef, value: any): leffect.Effect
---@field getAndSet fun(self: leffect.SynchronizedRef, value: any): leffect.Effect
---@field setAndGet fun(self: leffect.SynchronizedRef, value: any): leffect.Effect
---@field update fun(self: leffect.SynchronizedRef, f: fun(value: any): any): leffect.Effect
---@field getAndUpdate fun(self: leffect.SynchronizedRef, f: fun(value: any): any): leffect.Effect
---@field updateAndGet fun(self: leffect.SynchronizedRef, f: fun(value: any): any): leffect.Effect
---@field modify fun(self: leffect.SynchronizedRef, f: fun(value: any): (any, any)): leffect.Effect
---@field updateEffect fun(self: leffect.SynchronizedRef, f: fun(value: any): leffect.Effect): leffect.Effect
---@field getAndUpdateEffect fun(self: leffect.SynchronizedRef, f: fun(value: any): leffect.Effect): leffect.Effect
---@field updateAndGetEffect fun(self: leffect.SynchronizedRef, f: fun(value: any): leffect.Effect): leffect.Effect
---@field modifyEffect fun(self: leffect.SynchronizedRef, f: fun(value: any): leffect.Effect): leffect.Effect

local methods = {}

local SynchronizedRefMT = { __index = methods, __name = "leffect.SynchronizedRef" }

local SynchronizedRef = {}

---@param value any
---@param name string
local function checkRef(value, name)
  if getmetatable(value) ~= SynchronizedRefMT then
    error(name .. ": expected a SynchronizedRef, got " .. describe(value), 3)
  end
end

---@param f any
---@param name string
local function checkFunction(f, name)
  if type(f) ~= "function" then
    error(name .. ": expected a function, got " .. describe(f), 3)
  end
end

--- A new SynchronizedRef holding `value`, outside an effect.
---@param value any
---@return leffect.SynchronizedRef
function SynchronizedRef.makeUnsafe(value)
  return setmetatable({ current = value, permit = Semaphore.makeUnsafe(1) }, SynchronizedRefMT)
end

--- An effect that succeeds with a new SynchronizedRef holding `value`.
---@param value any
---@return leffect.Effect
function SynchronizedRef.make(value)
  return core.sync(function()
    return SynchronizedRef.makeUnsafe(value)
  end)
end

---@param value any
---@return boolean
function SynchronizedRef.isSynchronizedRef(value)
  return getmetatable(value) == SynchronizedRefMT
end

--- The value, outside an effect. Doesn't wait for a running update.
---@param ref leffect.SynchronizedRef
---@return any
function SynchronizedRef.getUnsafe(ref)
  checkRef(ref, "SynchronizedRef.getUnsafe")
  return ref.current
end

--- Succeeds with the value. Doesn't wait for a running update.
---@param ref leffect.SynchronizedRef
---@return leffect.Effect
function SynchronizedRef.get(ref)
  checkRef(ref, "SynchronizedRef.get")
  return core.sync(function()
    return ref.current
  end)
end

--- Runs `step(value)` while holding the permit. `step` returns an effect
--- that succeeds with the result and the new value, as a pair.
---@param ref leffect.SynchronizedRef
---@param step fun(value: any): leffect.Effect
---@return leffect.Effect
local function locked(ref, step)
  return Semaphore.withPermit(
    ref.permit,
    core.suspend(function()
      return core.map(step(ref.current), function(pair)
        ref.current = pair[2]
        return pair[1]
      end)
    end)
  )
end

---@param ref leffect.SynchronizedRef
---@param f fun(value: any): (any, any) Returns the result, then the new value.
---@return leffect.Effect
local function lockedSync(ref, f)
  return locked(ref, function(value)
    local result, new = f(value)
    return exitSucceed({ result, new })
  end)
end

--- Sets the value, once the permit is free.
---@param ref leffect.SynchronizedRef
---@param value any
---@return leffect.Effect
function SynchronizedRef.set(ref, value)
  checkRef(ref, "SynchronizedRef.set")
  return lockedSync(ref, function()
    return nil, value
  end)
end

---@param ref leffect.SynchronizedRef
---@param value any
---@return leffect.Effect
function SynchronizedRef.getAndSet(ref, value)
  checkRef(ref, "SynchronizedRef.getAndSet")
  return lockedSync(ref, function(old)
    return old, value
  end)
end

---@param ref leffect.SynchronizedRef
---@param value any
---@return leffect.Effect
function SynchronizedRef.setAndGet(ref, value)
  checkRef(ref, "SynchronizedRef.setAndGet")
  return lockedSync(ref, function()
    return value, value
  end)
end

---@param ref leffect.SynchronizedRef
---@param f fun(value: any): any
---@return leffect.Effect
function SynchronizedRef.update(ref, f)
  checkRef(ref, "SynchronizedRef.update")
  checkFunction(f, "SynchronizedRef.update")
  return lockedSync(ref, function(old)
    return nil, f(old)
  end)
end

---@param ref leffect.SynchronizedRef
---@param f fun(value: any): any
---@return leffect.Effect
function SynchronizedRef.getAndUpdate(ref, f)
  checkRef(ref, "SynchronizedRef.getAndUpdate")
  checkFunction(f, "SynchronizedRef.getAndUpdate")
  return lockedSync(ref, function(old)
    return old, f(old)
  end)
end

---@param ref leffect.SynchronizedRef
---@param f fun(value: any): any
---@return leffect.Effect
function SynchronizedRef.updateAndGet(ref, f)
  checkRef(ref, "SynchronizedRef.updateAndGet")
  checkFunction(f, "SynchronizedRef.updateAndGet")
  return lockedSync(ref, function(old)
    local new = f(old)
    return new, new
  end)
end

local MODIFY_ARITY = "SynchronizedRef.modify: f must return the result and the new value"

---@return integer count
---@return any result
---@return any new
local function counted(...)
  return select("#", ...), ...
end

--- `f(value)` returns a result and a new value, as for `Ref.modify`.
---@param ref leffect.SynchronizedRef
---@param f fun(value: any): (any, any)
---@return leffect.Effect
function SynchronizedRef.modify(ref, f)
  checkRef(ref, "SynchronizedRef.modify")
  checkFunction(f, "SynchronizedRef.modify")
  return lockedSync(ref, function(old)
    local count, result, new = counted(f(old))
    if count < 2 then
      error(MODIFY_ARITY, 0)
    end
    return result, new
  end)
end

---@param name string
---@param f any
---@param value any
---@return leffect.Effect
local function effectOf(name, f, value)
  local effect = f(value)
  if not core.isEffect(effect) then
    error(name .. ": f must return an effect, got " .. describe(effect), 0)
  end
  return effect
end

--- `f(value)` returns an effect. Runs it while holding the permit, and sets
--- the value it succeeds with.
---@param ref leffect.SynchronizedRef
---@param f fun(value: any): leffect.Effect
---@return leffect.Effect
function SynchronizedRef.updateEffect(ref, f)
  checkRef(ref, "SynchronizedRef.updateEffect")
  checkFunction(f, "SynchronizedRef.updateEffect")
  return locked(ref, function(old)
    return core.map(effectOf("SynchronizedRef.updateEffect", f, old), function(new)
      return { nil, new }
    end)
  end)
end

--- As `updateEffect`, and succeeds with the old value.
---@param ref leffect.SynchronizedRef
---@param f fun(value: any): leffect.Effect
---@return leffect.Effect
function SynchronizedRef.getAndUpdateEffect(ref, f)
  checkRef(ref, "SynchronizedRef.getAndUpdateEffect")
  checkFunction(f, "SynchronizedRef.getAndUpdateEffect")
  return locked(ref, function(old)
    return core.map(effectOf("SynchronizedRef.getAndUpdateEffect", f, old), function(new)
      return { old, new }
    end)
  end)
end

--- As `updateEffect`, and succeeds with the new value.
---@param ref leffect.SynchronizedRef
---@param f fun(value: any): leffect.Effect
---@return leffect.Effect
function SynchronizedRef.updateAndGetEffect(ref, f)
  checkRef(ref, "SynchronizedRef.updateAndGetEffect")
  checkFunction(f, "SynchronizedRef.updateAndGetEffect")
  return locked(ref, function(old)
    return core.map(effectOf("SynchronizedRef.updateAndGetEffect", f, old), function(new)
      return { new, new }
    end)
  end)
end

--- `f(value)` returns an effect that succeeds with a pair `{ result,
--- newValue }`. Sets `newValue`, and succeeds with `result`. A success that
--- isn't a table is a defect.
---@param ref leffect.SynchronizedRef
---@param f fun(value: any): leffect.Effect
---@return leffect.Effect
function SynchronizedRef.modifyEffect(ref, f)
  checkRef(ref, "SynchronizedRef.modifyEffect")
  checkFunction(f, "SynchronizedRef.modifyEffect")
  return locked(ref, function(old)
    return core.map(effectOf("SynchronizedRef.modifyEffect", f, old), function(pair)
      if type(pair) ~= "table" then
        error(
          "SynchronizedRef.modifyEffect: the effect must succeed with a pair { result, newValue }, got "
            .. describe(pair),
          0
        )
      end
      return pair
    end)
  end)
end

for _, name in ipairs({
  "get",
  "getUnsafe",
  "set",
  "getAndSet",
  "setAndGet",
  "update",
  "getAndUpdate",
  "updateAndGet",
  "modify",
  "updateEffect",
  "getAndUpdateEffect",
  "updateAndGetEffect",
  "modifyEffect",
}) do
  methods[name] = SynchronizedRef[name]
end

return SynchronizedRef
