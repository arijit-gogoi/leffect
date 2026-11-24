--- Fibers: lightweight threads of execution. Each fiber runs one effect on a
--- scheduler, with its own stack of frames (FIBER-DESIGN.md §4 and §5.1).

local runtime = require("leffect.runtime")

local getmetatable, setmetatable = getmetatable, setmetatable
local remove = table.remove

local YIELD, runLoop = runtime.YIELD, runtime.runLoop

---A running or finished effect.
---@class leffect.Fiber : leffect.FiberState
---@field id integer Unique and increasing, across every runtime in the process.
---@field status "pending"|"running"|"suspended"|"done"
---@field exit leffect.Exit? Set once the fiber is done.
---@field observers fun(exit: leffect.Exit)[]
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
  }, FiberMT)
end

---@param value any
---@return boolean
function Fiber.isFiber(value)
  return getmetatable(value) == FiberMT
end

--- Runs `effect` on this fiber until it finishes or suspends.
---@param effect any
function methods:evaluate(effect)
  if self.exit then
    return
  end
  self.status = "running"
  self.opCount = 0
  local exit = runLoop(self, effect)
  if exit == YIELD then
    self.status = "suspended"
    return
  end
  ---@cast exit leffect.Exit
  self:complete(exit)
end

--- Publishes the fiber's exit and runs its observers once.
---@param exit leffect.Exit
function methods:complete(exit)
  self.exit = exit
  self.status = "done"
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

return Fiber
