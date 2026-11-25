--- A scheduler for tests: a FIFO task queue, and a virtual clock that only
--- moves when the test says so (specifications/10-scheduler.md §10.2).
---
--- ```lua
--- local TestScheduler = require("leffect.scheduler.test")
--- local scheduler = TestScheduler.new()
--- local fiber = scheduler:fork(Effect.sleep(100))
--- scheduler:advance(100) -- fires the timer, then runs the woken fiber
--- ```

local Effect = require("leffect.effect")

local error, setmetatable, tostring = error, setmetatable, tostring
local insert, remove = table.insert, table.remove

---@class leffect.TestScheduler.Options
---@field maxOpsBeforeYield integer? Loop steps before a fiber yields; default 2048.
---@field maxTasks integer? Tasks one `flush` may run before it errors; default 1e6.

---@class leffect.TestScheduler.Timer
---@field due number
---@field task fun()

---@class leffect.TestScheduler : leffect.Scheduler
---@field time number
---@field queue fun()[]
---@field head integer
---@field tail integer
---@field timers leffect.TestScheduler.Timer[] Sorted by due time, then insertion.
---@field maxTasks integer
local methods = {}

local SchedulerMT = { __index = methods, __name = "leffect.TestScheduler" }

local TestScheduler = {}

---@param options leffect.TestScheduler.Options?
---@return leffect.TestScheduler
function TestScheduler.new(options)
  options = options or {}
  return setmetatable({
    time = 0,
    queue = {},
    head = 1,
    tail = 0,
    timers = {},
    maxOpsBeforeYield = options.maxOpsBeforeYield,
    maxTasks = options.maxTasks or 1000000,
  }, SchedulerMT)
end

--- Queues `task` to run at the next `flush`.
---@param task fun()
function methods:schedule(task)
  local tail = self.tail + 1
  self.tail = tail
  self.queue[tail] = task
end

--- Fires `task` once the clock reaches now + `ms`. Returns a function that
--- cancels the timer; calling it again, or after the timer fired, does
--- nothing.
---@param ms number
---@param task fun()
---@return fun() cancel
function methods:after(ms, task)
  local timers = self.timers
  local timer = { due = self.time + ms, task = task }
  local i = #timers
  while i > 0 and timers[i].due > timer.due do
    i = i - 1
  end
  insert(timers, i + 1, timer)
  return function()
    for j = 1, #timers do
      if timers[j] == timer then
        remove(timers, j)
        return
      end
    end
  end
end

--- The virtual time, in milliseconds.
---@return number
function methods:now()
  return self.time
end

--- Runs queued tasks until the queue is empty, including tasks queued while
--- flushing. Never advances time. Errors after `maxTasks` tasks, to catch a
--- livelock.
function methods:flush()
  local queue, limit, count = self.queue, self.maxTasks, 0
  while self.head <= self.tail do
    count = count + 1
    if count > limit then
      error(
        "TestScheduler: more than "
          .. tostring(limit)
          .. " tasks in one flush; is a fiber livelocked?",
        2
      )
    end
    local head = self.head
    local task = queue[head]
    queue[head] = nil
    self.head = head + 1
    task()
  end
end

-- Removes the first timer, moves the clock to its due time, fires it, then
-- flushes.
---@param self leffect.TestScheduler
local function fireFirst(self)
  local timer = remove(self.timers, 1)
  if timer.due > self.time then
    self.time = timer.due
  end
  timer.task()
  self:flush()
end

--- Flushes, then fires the timers due within `ms`, in order, flushing after
--- each. The clock ends at its start + `ms`.
---@param ms number
function methods:advance(ms)
  local target = self.time + ms
  self:flush()
  local timers = self.timers
  while timers[1] and timers[1].due <= target do
    fireFirst(self)
  end
  self.time = target
end

--- Flushes and fires timers, moving the clock forward, until no task or
--- timer is left.
function methods:runAll()
  self:flush()
  local timers, limit, count = self.timers, self.maxTasks, 0
  while timers[1] do
    count = count + 1
    if count > limit then
      error(
        "TestScheduler: more than "
          .. tostring(limit)
          .. " timers in one runAll; is a fiber livelocked?",
        2
      )
    end
    fireFirst(self)
  end
end

---@return integer
function methods:pendingTasks()
  return self.tail - self.head + 1
end

---@return integer
function methods:pendingTimers()
  return #self.timers
end

--- `Effect.runFork(effect, { scheduler = self })`.
---@param effect leffect.Effect
---@return leffect.Fiber
function methods:fork(effect)
  return Effect.runFork(effect, { scheduler = self })
end

--- Forks `effect`, runs everything, and returns the fiber's exit (nil if it
--- never finished) and the fiber.
---@param effect leffect.Effect
---@return leffect.Exit? exit
---@return leffect.Fiber fiber
function methods:run(effect)
  local fiber = self:fork(effect)
  self:runAll()
  return fiber.exit, fiber
end

return TestScheduler
