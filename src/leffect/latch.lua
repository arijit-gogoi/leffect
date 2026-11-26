--- Latch: a gate that fibers wait at until it opens
--- (specifications/35-deferred.md §35.2, 4.1.5's `Latch`).
---
--- ```lua
--- local gate = Latch.makeUnsafe()
--- local worker = gate:whenOpen(Effect.sync(work))
--- -- elsewhere: run(gate:open())
--- ```
---
--- Waiters resume in the order they started waiting. Waking them only
--- schedules their wakeups, so `open` and `openUnsafe` wake at once, and
--- `openUnsafe` may be called from any callback.

local Waitlist = require("leffect.waitlist")
local core = require("leffect.core")
local runtime = require("leffect.runtime")

local error, getmetatable, setmetatable = error, getmetatable, setmetatable

local describe = runtime.describe
local exitVoid = core.exitVoid

---A gate that fibers wait at.
---@class leffect.Latch
---@field opened boolean
---@field waiters leffect.Waitlist
---@field await fun(self: leffect.Latch): leffect.Effect
---@field open fun(self: leffect.Latch): leffect.Effect
---@field openUnsafe fun(self: leffect.Latch): boolean
---@field release fun(self: leffect.Latch): leffect.Effect
---@field close fun(self: leffect.Latch): leffect.Effect
---@field closeUnsafe fun(self: leffect.Latch): boolean
---@field whenOpen fun(self: leffect.Latch, effect: leffect.Effect): leffect.Effect
---@field isOpen fun(self: leffect.Latch): boolean

local methods = {}

local LatchMT = { __index = methods, __name = "leffect.Latch" }

local Latch = {}

---@param value any
---@param name string
local function checkLatch(value, name)
  if getmetatable(value) ~= LatchMT then
    error(name .. ": expected a Latch, got " .. describe(value), 3)
  end
end

--- A new latch, outside an effect. It is closed unless `open` is true.
---@param open boolean?
---@return leffect.Latch
function Latch.makeUnsafe(open)
  return setmetatable({ opened = open == true, waiters = Waitlist.new() }, LatchMT)
end

--- An effect that succeeds with a new latch, closed unless `open` is true.
---@param open boolean?
---@return leffect.Effect
function Latch.make(open)
  return core.sync(function()
    return Latch.makeUnsafe(open)
  end)
end

---@param value any
---@return boolean
function Latch.isLatch(value)
  return getmetatable(value) == LatchMT
end

--- Wakes every current waiter.
---@param latch leffect.Latch
local function wakeAll(latch)
  local nodes = Waitlist.clear(latch.waiters)
  for i = 1, #nodes do
    nodes[i].resume(exitVoid)
  end
end

--- Opens the latch, and wakes every waiter. Returns false if it was already
--- open.
---@param latch leffect.Latch
---@return boolean
function Latch.openUnsafe(latch)
  checkLatch(latch, "Latch.openUnsafe")
  if latch.opened then
    return false
  end
  latch.opened = true
  wakeAll(latch)
  return true
end

--- Opens the latch, and wakes every waiter. Succeeds with true, or with false
--- if it was already open.
---@param latch leffect.Latch
---@return leffect.Effect
function Latch.open(latch)
  checkLatch(latch, "Latch.open")
  return core.sync(function()
    return Latch.openUnsafe(latch)
  end)
end

--- Wakes the current waiters, and leaves the latch closed. Succeeds with
--- false if the latch was open, and with true otherwise.
---@param latch leffect.Latch
---@return leffect.Effect
function Latch.release(latch)
  checkLatch(latch, "Latch.release")
  return core.sync(function()
    if latch.opened then
      return false
    end
    wakeAll(latch)
    return true
  end)
end

--- Closes the latch, so later awaits wait. Returns false if it was already
--- closed.
---@param latch leffect.Latch
---@return boolean
function Latch.closeUnsafe(latch)
  checkLatch(latch, "Latch.closeUnsafe")
  if not latch.opened then
    return false
  end
  latch.opened = false
  return true
end

--- Closes the latch. Succeeds with true, or with false if it was already
--- closed.
---@param latch leffect.Latch
---@return leffect.Effect
function Latch.close(latch)
  checkLatch(latch, "Latch.close")
  return core.sync(function()
    return Latch.closeUnsafe(latch)
  end)
end

--- Waits until the latch opens. Continues at once if it is open. An
--- interrupted waiter removes itself.
---@param latch leffect.Latch
---@return leffect.Effect
function Latch.await(latch)
  checkLatch(latch, "Latch.await")
  return core.async(function(resume)
    if latch.opened then
      resume(exitVoid)
      return nil
    end
    local node = { resume = resume }
    Waitlist.push(latch.waiters, node)
    return function()
      Waitlist.remove(latch.waiters, node)
    end
  end)
end

--- Waits until the latch opens, then runs `effect`.
---@param latch leffect.Latch
---@param effect leffect.Effect
---@return leffect.Effect
function Latch.whenOpen(latch, effect)
  checkLatch(latch, "Latch.whenOpen")
  if not core.isEffect(effect) then
    error("Latch.whenOpen: expected an effect, got " .. describe(effect), 2)
  end
  return core.flatMap(Latch.await(latch), function()
    return effect
  end)
end

--- Whether the latch is open. A plain function, not an effect, as in v4.
---@param latch leffect.Latch
---@return boolean
function Latch.isOpen(latch)
  checkLatch(latch, "Latch.isOpen")
  return latch.opened
end

for _, name in ipairs({
  "await",
  "open",
  "openUnsafe",
  "release",
  "close",
  "closeUnsafe",
  "whenOpen",
  "isOpen",
}) do
  methods[name] = Latch[name]
end

return Latch
