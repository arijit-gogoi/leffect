--- Semaphore: a number of permits that fibers take, wait for, and give back
--- (specifications/36-semaphore.md §36, 4.1.5's `Semaphore` module).
---
--- ```lua
--- local sem = Semaphore.makeUnsafe(2)
--- local guarded = sem:withPermits(1, Effect.sleep(10))
--- ```
---
--- Waiters keep their place in line until they take their permits or leave
--- (specifications/33-primitives.md §33.2). The first waiter whose request
--- fits is served, so a smaller, later request can overtake a larger one. A
--- wake pass budgets the free permits over the waiters, and a waiter that
--- leaves runs the pass again, so its turn passes on.

local Effect = require("leffect.effect")
local Scope = require("leffect.scope")
local Waitlist = require("leffect.waitlist")
local core = require("leffect.core")
local runtime = require("leffect.runtime")

local error, floor, getmetatable, huge, setmetatable, type =
  error, math.floor, getmetatable, math.huge, setmetatable, type

local describe = runtime.describe
local exitSucceed, exitVoid = core.exitSucceed, core.exitVoid

---A number of permits.
---@class leffect.Semaphore
---@field permits integer
---@field taken integer free = permits - taken, which can be negative
---@field waiters leffect.Waitlist
---@field withPermits fun(self: leffect.Semaphore, n: integer, effect: leffect.Effect): leffect.Effect
---@field withPermit fun(self: leffect.Semaphore, effect: leffect.Effect): leffect.Effect
---@field take fun(self: leffect.Semaphore, n: integer): leffect.Effect
---@field takeScoped fun(self: leffect.Semaphore, n: integer): leffect.Effect
---@field takeIfAvailable fun(self: leffect.Semaphore, n: integer): leffect.Effect
---@field release fun(self: leffect.Semaphore, n: integer): leffect.Effect
---@field releaseAll fun(self: leffect.Semaphore): leffect.Effect
---@field resize fun(self: leffect.Semaphore, permits: integer): leffect.Effect

---@class leffect.Semaphore.Waiter
---@field n integer
---@field resume fun(effect: leffect.Effect)? Cleared once woken.

local methods = {}

local SemaphoreMT = { __index = methods, __name = "leffect.Semaphore" }

local Semaphore = {}

---@param value any
---@param name string
local function checkSemaphore(value, name)
  if getmetatable(value) ~= SemaphoreMT then
    error(name .. ": expected a Semaphore, got " .. describe(value), 3)
  end
end

---@param value any
---@param name string
---@param what string
local function checkCount(value, name, what)
  if type(value) ~= "number" or value < 0 or value == huge or floor(value) ~= value then
    error(name .. ": " .. what .. " must be a non-negative integer, got " .. describe(value), 3)
  end
end

---@param value any
---@param name string
local function checkEffect(value, name)
  if not core.isEffect(value) then
    error(name .. ": expected an effect, got " .. describe(value), 3)
  end
end

--- A semaphore with `permits` permits, all free, outside an effect.
---@param permits integer
---@return leffect.Semaphore
function Semaphore.makeUnsafe(permits)
  checkCount(permits, "Semaphore.makeUnsafe", "permits")
  return setmetatable({ permits = permits, taken = 0, waiters = Waitlist.new() }, SemaphoreMT)
end

--- An effect that succeeds with a semaphore with `permits` permits.
---@param permits integer
---@return leffect.Effect
function Semaphore.make(permits)
  checkCount(permits, "Semaphore.make", "permits")
  return core.sync(function()
    return Semaphore.makeUnsafe(permits)
  end)
end

---@param value any
---@return boolean
function Semaphore.isSemaphore(value)
  return getmetatable(value) == SemaphoreMT
end

--- The first waiter, in arrival order, whose request fits in the free
--- permits (v4's `firstAvailableWaiter`).
---@param sem leffect.Semaphore
---@return leffect.Semaphore.Waiter?
local function firstAvailable(sem)
  local free = sem.permits - sem.taken
  local node = sem.waiters.head
  while node do
    if node.n <= free then
      return node
    end
    node = node._next
  end
  return nil
end

--- The wake pass: walks the waiters in order, with the free permits as its
--- budget, and wakes each one that fits. Waiters woken earlier, which
--- haven't taken yet, count against the budget too.
---@param sem leffect.Semaphore
local function wake(sem)
  local remaining = sem.permits - sem.taken
  local node = sem.waiters.head
  while node do
    local n = node.n
    if n <= remaining then
      remaining = remaining - n
      local resume = node.resume
      if resume then
        node.resume = nil
        resume(exitVoid)
      end
    end
    node = node._next
  end
end

--- Gives `n` permits back, and runs the wake pass. Returns the free permits.
---@param sem leffect.Semaphore
---@param n integer
---@return integer
local function releaseUnsafe(sem, n)
  sem.taken = sem.taken - n
  if sem.waiters.size > 0 then
    wake(sem)
  end
  return sem.permits - sem.taken
end

--- Waits for `n` permits, takes them, and continues with `onAcquire()`
--- (v4's `takePermits`). The wait runs under `restore`. Taking and running
--- `onAcquire` happen in one step, so a caller that is uninterruptible
--- around this can register the release before any interrupt lands.
---@param sem leffect.Semaphore
---@param n integer
---@param onAcquire fun(): leffect.Effect
---@param restore (fun(effect: leffect.Effect): leffect.Effect)?
---@return leffect.Effect
local function takePermits(sem, n, onAcquire, restore)
  return core.withFiber(function(fiber)
    if sem.permits - sem.taken >= n and firstAvailable(sem) == nil then
      sem.taken = sem.taken + n
      return onAcquire()
    end
    local waiters = sem.waiters
    ---@type leffect.Semaphore.Waiter
    local node = { n = n }
    Waitlist.push(waiters, node)
    local function remove()
      if Waitlist.remove(waiters, node) then
        wake(sem)
      end
      return nil
    end
    -- However the wait ends, a waiter still in line leaves, and passes its
    -- turn on (invariant 24).
    runtime.onExitUnsafe(fiber, remove)
    local wait = core.async(function(resume)
      if firstAvailable(sem) == node then
        resume(exitVoid)
      else
        node.resume = resume
      end
    end)
    if restore then
      wait = restore(wait)
    end
    local loop
    loop = core.flatMap(wait, function()
      if firstAvailable(sem) ~= node then
        return loop
      end
      sem.taken = sem.taken + n
      remove()
      return onAcquire()
    end)
    return loop
  end)
end

--- Waits for `n` permits, takes them, runs `effect`, and gives them back
--- however `effect` ends. The wait is as interruptible as the caller.
---@param sem leffect.Semaphore
---@param n integer
---@param effect leffect.Effect
---@return leffect.Effect
function Semaphore.withPermits(sem, n, effect)
  checkSemaphore(sem, "Semaphore.withPermits")
  checkCount(n, "Semaphore.withPermits", "the number of permits")
  checkEffect(effect, "Semaphore.withPermits")
  return runtime.uninterruptibleMask(function(restore)
    return takePermits(sem, n, function()
      return core.onExit(restore(effect), function()
        releaseUnsafe(sem, n)
        return nil
      end)
    end, restore)
  end)
end

--- `withPermits` with one permit.
---@param sem leffect.Semaphore
---@param effect leffect.Effect
---@return leffect.Effect
function Semaphore.withPermit(sem, effect)
  checkSemaphore(sem, "Semaphore.withPermit")
  checkEffect(effect, "Semaphore.withPermit")
  return Semaphore.withPermits(sem, 1, effect)
end

--- Waits for `n` permits, and takes them. Succeeds with `n`.
---@param sem leffect.Semaphore
---@param n integer
---@return leffect.Effect
function Semaphore.take(sem, n)
  checkSemaphore(sem, "Semaphore.take")
  checkCount(n, "Semaphore.take", "the number of permits")
  local exit = exitSucceed(n)
  return takePermits(sem, n, function()
    return exit
  end, nil)
end

--- Takes `n` permits until the current scope closes. Without a scope, it dies
--- before taking anything.
---@param sem leffect.Semaphore
---@param n integer
---@return leffect.Effect
function Semaphore.takeScoped(sem, n)
  checkSemaphore(sem, "Semaphore.takeScoped")
  checkCount(n, "Semaphore.takeScoped", "the number of permits")
  return runtime.uninterruptibleMask(function(restore)
    return core.flatMap(Effect.scope, function(scope)
      return takePermits(sem, n, function()
        return Scope.addFinalizer(scope, Semaphore.release(sem, n))
      end, restore)
    end)
  end)
end

--- Takes `n` permits if they are free, without waiting, and whatever the
--- waiters. Succeeds with whether it took them.
---@param sem leffect.Semaphore
---@param n integer
---@return leffect.Effect
function Semaphore.takeIfAvailable(sem, n)
  checkSemaphore(sem, "Semaphore.takeIfAvailable")
  checkCount(n, "Semaphore.takeIfAvailable", "the number of permits")
  return core.sync(function()
    if sem.permits - sem.taken < n then
      return false
    end
    sem.taken = sem.taken + n
    return true
  end)
end

--- Gives `n` permits back. Succeeds with the number of free permits.
---@param sem leffect.Semaphore
---@param n integer
---@return leffect.Effect
function Semaphore.release(sem, n)
  checkSemaphore(sem, "Semaphore.release")
  checkCount(n, "Semaphore.release", "the number of permits")
  return core.sync(function()
    return releaseUnsafe(sem, n)
  end)
end

--- Gives back every taken permit. Succeeds with the number of free permits.
---@param sem leffect.Semaphore
---@return leffect.Effect
function Semaphore.releaseAll(sem)
  checkSemaphore(sem, "Semaphore.releaseAll")
  return core.sync(function()
    return releaseUnsafe(sem, sem.taken)
  end)
end

--- Changes the number of permits. Taken permits stay taken.
---@param sem leffect.Semaphore
---@param permits integer
---@return leffect.Effect
function Semaphore.resize(sem, permits)
  checkSemaphore(sem, "Semaphore.resize")
  checkCount(permits, "Semaphore.resize", "permits")
  return core.sync(function()
    sem.permits = permits
    if sem.permits - sem.taken >= 0 and sem.waiters.size > 0 then
      wake(sem)
    end
  end)
end

for _, name in ipairs({
  "withPermits",
  "withPermit",
  "take",
  "takeScoped",
  "takeIfAvailable",
  "release",
  "releaseAll",
  "resize",
}) do
  methods[name] = Semaphore[name]
end

return Semaphore
