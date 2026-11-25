--- Fibers: lightweight threads of execution. Each fiber runs one effect on a
--- scheduler, with its own stack of frames (FIBER-DESIGN.md §4, §5.1, §7 and
--- §8).
---
--- A fiber publishes its exit only after interrupting and awaiting its
--- children. Interruption is cooperative: `interruptUnsafe` records the
--- request, and the fiber delivers it at the next point where it is
--- interruptible.

local Cause = require("leffect.cause")
local Context = require("leffect.context")
local core = require("leffect.core")
local runtime = require("leffect.runtime")

local getmetatable, next, pairs, setmetatable = getmetatable, next, pairs, setmetatable
local remove, sort = table.remove, table.sort

local YIELD, runLoop = runtime.YIELD, runtime.runLoop
local exitSucceed, exitFailCause, exitVoid = core.exitSucceed, core.exitFailCause, core.exitVoid

---A running or finished effect.
---@class leffect.Fiber : leffect.FiberState
---@field id integer Unique and increasing, across every runtime in the process.
---@field status "pending"|"running"|"suspended"|"done"
---@field exit leffect.Exit? Set once the fiber is done.
---@field observers fun(exit: leffect.Exit)[]
---@field children table<leffect.Fiber, true>? Running non-daemon children.
local methods = {}

local FiberMT = { __index = methods, __name = "leffect.Fiber" }

local Fiber = {}

local lastId = 0

local function noop() end

--- A new fiber on `scheduler`. It runs nothing until `evaluate` is called.
---@param scheduler leffect.Scheduler
---@param interruptible boolean? Defaults to true.
---@return leffect.Fiber
function Fiber.new(scheduler, interruptible)
  lastId = lastId + 1
  return setmetatable({
    id = lastId,
    status = "pending",
    scheduler = scheduler,
    stack = {},
    top = 0,
    interruptible = interruptible ~= false,
    pendingInterrupt = false,
    observers = {},
    opCount = 0,
    context = Context.empty,
  }, FiberMT)
end

---@param value any
---@return boolean
function Fiber.isFiber(value)
  return getmetatable(value) == FiberMT
end

--- Wakes `fiber` on the next tick with its interrupt cause.
---@param fiber leffect.Fiber
local function wakeWithInterrupt(fiber)
  fiber.scheduler:schedule(function()
    fiber:evaluate(exitFailCause(fiber.interruptCause --[[@as leffect.Cause]]))
  end)
end

--- The fibers of a set, in fork order, so that shutdowns are deterministic.
---@param set table<leffect.Fiber, true>
---@return leffect.Fiber[]
local function sortedById(set)
  local list = {}
  for fiber in pairs(set) do
    list[#list + 1] = fiber
  end
  sort(list, function(a, b)
    return a.id < b.id
  end)
  return list
end

--- An effect that waits until every fiber in `fibers` is done.
---@param fibers leffect.Fiber[]
---@return leffect.Effect
local function awaitAll(fibers)
  return core.async(function(resume)
    local remaining = 0
    for i = 1, #fibers do
      if not fibers[i].exit then
        remaining = remaining + 1
      end
    end
    if remaining == 0 then
      resume(exitVoid)
      return nil
    end
    local function onExit()
      remaining = remaining - 1
      if remaining == 0 then
        resume(exitVoid)
      end
    end
    local removers = {}
    for i = 1, #fibers do
      local fiber = fibers[i]
      if not fiber.exit then
        removers[#removers + 1] = fiber:addObserver(onExit)
      end
    end
    return function()
      for i = 1, #removers do
        removers[i]()
      end
    end
  end)
end

--- Interrupts every fiber in `fibers` on behalf of `fiberId`, then waits for
--- all of them, finalizers included.
---@param fibers leffect.Fiber[]
---@param fiberId integer?
---@return leffect.Effect
function Fiber.interruptAllAs(fibers, fiberId)
  return core.suspend(function()
    for i = 1, #fibers do
      fibers[i]:interruptUnsafe(fiberId)
    end
    return awaitAll(fibers)
  end)
end

--- Interrupts every fiber in `fibers` on behalf of the current fiber, then
--- waits for all of them, finalizers included.
---@param fibers leffect.Fiber[]
---@return leffect.Effect
function Fiber.interruptAll(fibers)
  return core.withFiber(function(fiber)
    return Fiber.interruptAllAs(fibers, fiber.id)
  end)
end

--- Creates a child of `parent` running `effect`, started on the next tick. A
--- non-daemon child is attached to the parent, which interrupts it before
--- publishing its own exit. Children start interruptible unless asked
--- otherwise, whatever the parent's state (as in v4), and with the parent's
--- context.
---@param parent leffect.Fiber
---@param effect any
---@param daemon boolean?
---@param uninterruptible boolean?
---@return leffect.Fiber
function Fiber.forkUnsafe(parent, effect, daemon, uninterruptible)
  local child = Fiber.new(parent.scheduler, not uninterruptible)
  child.context = parent.context
  parent.scheduler:schedule(function()
    child:evaluate(effect)
  end)
  if not daemon then
    local children = parent.children
    if not children then
      children = {}
      parent.children = children
    end
    children[child] = true
    child:addObserver(function()
      children[child] = nil
    end)
  end
  return child
end

--- Runs `effect` on this fiber until it finishes or suspends.
---@param effect any
function methods:evaluate(effect)
  if self.exit then
    return
  end
  self.suspension = nil
  self.status = "running"
  self.opCount = 0
  local exit = runLoop(self, effect)
  if exit == YIELD then
    self.status = "suspended"
    -- An interrupt requested during the step that suspended (by user code in
    -- register, say) has no loop step left to deliver it: wake the fiber.
    local suspension = self.suspension
    if self.pendingInterrupt and self.interruptible and suspension and not suspension.resumed then
      self.pendingInterrupt = false
      suspension.resumed = true
      wakeWithInterrupt(self)
    end
    return
  end
  ---@cast exit leffect.Exit
  local children = self.children
  if children and next(children) ~= nil then
    -- Children exit before the parent publishes its exit. Shutting them down
    -- can't itself be interrupted. Exits are effects, so returning `exit`
    -- makes it the final instruction once the children are gone.
    self.interruptible = false
    return self:evaluate(
      core.flatMap(Fiber.interruptAllAs(sortedById(children), self.id), function()
        return exit
      end)
    )
  end
  self:complete(exit)
end

--- Publishes the fiber's exit and runs its observers once.
---@param exit leffect.Exit
function methods:complete(exit)
  self.exit = exit
  self.status = "done"
  self.suspension = nil
  local observers = self.observers
  self.observers = {}
  for i = 1, #observers do
    observers[i](exit)
  end
end

--- Calls `observer(exit)` once the fiber is done, at once if it already is.
--- Returns a function that removes the observer.
---@param observer fun(exit: leffect.Exit)
---@return fun() remove
function methods:addObserver(observer)
  local exit = self.exit
  if exit then
    observer(exit)
    return noop
  end
  local observers = self.observers
  observers[#observers + 1] = observer
  return function()
    local list = self.observers
    for i = 1, #list do
      if list[i] == observer then
        remove(list, i)
        return
      end
    end
  end
end

--- The fiber's exit, or nil while it is still running.
---@return leffect.Exit?
function methods:poll()
  return self.exit
end

--- Asks the fiber to stop, on behalf of the fiber `fiberId`. The request is
--- delivered at the next point where the fiber is interruptible. Doesn't wait.
---@param fiberId integer?
function methods:interruptUnsafe(fiberId)
  if self.exit then
    return
  end
  local cause = Cause.interrupt(fiberId)
  local previous = self.interruptCause
  self.interruptCause = previous and Cause.addInterrupts(previous, cause) or cause
  if not self.interruptible then
    return -- delivered later, by a Restore frame
  end
  local suspension = self.suspension
  if self.status == "suspended" and suspension and not suspension.resumed then
    suspension.resumed = true -- win the race against the operation's own resume
    wakeWithInterrupt(self)
  else
    -- Running, not started yet, or a wakeup is already queued: the loop
    -- delivers it at its next step.
    self.pendingInterrupt = true
  end
end

--- An effect that waits for the fiber and succeeds with its exit.
---@return leffect.Effect
function methods:await()
  local fiber = self
  return core.async(function(resume)
    local exit = fiber.exit
    if exit then
      resume(exitSucceed(exit))
      return nil
    end
    return fiber:addObserver(function(e)
      resume(exitSucceed(e))
    end)
  end)
end

--- An effect that waits for the fiber and continues with its exit: the
--- child's value, or its failure.
---@return leffect.Effect
function methods:join()
  local fiber = self
  return core.async(function(resume)
    local exit = fiber.exit
    if exit then
      resume(exit)
      return nil
    end
    return fiber:addObserver(resume)
  end)
end

--- An effect that interrupts the fiber, then waits until it is done,
--- finalizers included.
---@return leffect.Effect
function methods:interrupt()
  local target = self
  return core.withFiber(function(fiber)
    target:interruptUnsafe(fiber.id)
    return core.asVoid(target:await())
  end)
end

--- An effect that asks the fiber to stop, without waiting for it.
---@return leffect.Effect
function methods:interruptFork()
  local target = self
  return core.withFiber(function(fiber)
    target:interruptUnsafe(fiber.id)
    return exitVoid
  end)
end

return Fiber
