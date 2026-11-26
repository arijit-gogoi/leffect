--- A scheduler on luv, the Lua binding of libuv (specifications/29-luv.md
--- §29).
---
--- ```lua
--- local LuvScheduler = require("leffect.scheduler.luv")
--- local scheduler = LuvScheduler.new() -- in Neovim: LuvScheduler.new({ uv = vim.uv })
--- local exit = scheduler:run(Effect.sleep(100)) -- runs the loop until the fiber ends
--- ```
---
--- Each loop iteration runs the tasks that were queued when it started, so
--- I/O and timers get a turn between batches, and a busy fiber yields to them
--- every `maxOpsBeforeYield` steps. luv is optional: `new` requires it only
--- when `options.uv` doesn't give a luv module.

local Effect = require("leffect.effect")

local ceil, error, pcall, require, setmetatable = math.ceil, error, pcall, require, setmetatable

---@class leffect.LuvScheduler.Options
---@field uv table? A luv module, such as Neovim's `vim.uv`; defaults to `require("luv")`.
---@field maxOpsBeforeYield integer? Loop steps before a fiber yields; default 2048.

---@class leffect.LuvScheduler : leffect.Scheduler
---@field uv table The luv module.
---@field queue fun()[]
---@field head integer
---@field tail integer
---@field idle table? The idle handle, created on first use.
---@field idleActive boolean
---@field onIdle fun() The idle callback.
local methods = {}

local SchedulerMT = { __index = methods, __name = "leffect.LuvScheduler" }

local LuvScheduler = {}

--- The idle callback. Runs the batch: the tasks that were queued when it
--- started. A task queued meanwhile waits for the next iteration. Each task
--- leaves the queue before it runs, and errors aren't caught: after one, the
--- idle handle is still active, and the next iteration runs the rest.
---@param self leffect.LuvScheduler
local function drain(self)
  local queue, last = self.queue, self.tail
  while self.head <= last do
    local head = self.head
    local task = queue[head]
    queue[head] = nil
    self.head = head + 1
    task()
  end
  if self.head > self.tail then
    self.idle:stop()
    self.idleActive = false
  end
end

---@param options leffect.LuvScheduler.Options?
---@return leffect.LuvScheduler
function LuvScheduler.new(options)
  options = options or {}
  local uv = options.uv
  if uv == nil then
    uv = require("luv")
  end
  local self = setmetatable({
    uv = uv,
    queue = {},
    head = 1,
    tail = 0,
    idle = nil,
    idleActive = false,
    maxOpsBeforeYield = options.maxOpsBeforeYield,
  }, SchedulerMT)
  self.onIdle = function()
    drain(self)
  end
  return self
end

--- Queues `task` for the next loop iteration. While tasks are queued, the
--- idle handle is active, so libuv polls without blocking.
---@param task fun()
function methods:schedule(task)
  local tail = self.tail + 1
  self.tail = tail
  self.queue[tail] = task
  if not self.idleActive then
    local idle = self.idle
    if idle == nil then
      idle = self.uv.new_idle()
      self.idle = idle
    end
    idle:start(self.onIdle)
    self.idleActive = true
  end
end

local MAX_DELAY = 2 ^ 53

--- `ms` as a delay luv accepts: an integer, rounded up so that a timer never
--- fires early, from 0 to 2^53. NaN counts as 0.
---@param ms number
---@return number
local function toDelay(ms)
  if ms ~= ms or ms <= 0 then
    return 0
  elseif ms >= MAX_DELAY then
    return MAX_DELAY
  end
  return ceil(ms)
end

--- Fires `task` after `ms` milliseconds, on a luv timer. Returns a function
--- that cancels the timer; calling it again, or after the timer fired, does
--- nothing.
---@param ms number
---@param task fun()
---@return fun() cancel
function methods:after(ms, task)
  local timer = self.uv.new_timer()
  timer:start(toDelay(ms), 0, function()
    timer:close()
    task()
  end)
  return function()
    if not timer:is_closing() then
      timer:close()
    end
  end
end

--- `uv.now()`: milliseconds from an arbitrary start, cached at the start of
--- each loop iteration.
---@return number
function methods:now()
  return self.uv.now()
end

--- `Effect.runFork(effect, { scheduler = self })`.
---@param effect leffect.Effect
---@return leffect.Fiber
function methods:fork(effect)
  return Effect.runFork(effect, { scheduler = self })
end

--- Forks `effect` and runs the luv loop until the fiber ends, then returns
--- its exit and the fiber. If the loop runs out of work first, the exit is
--- nil. Other handles stay as they are. Raises inside a running loop: use
--- `fork` or `Effect.runCallback` there, and in Neovim.
---@param effect leffect.Effect
---@return leffect.Exit? exit
---@return leffect.Fiber fiber
function methods:run(effect)
  local uv = self.uv
  if uv.loop_mode() then
    error(
      "LuvScheduler:run: the luv loop is already running; use fork or Effect.runCallback inside it",
      2
    )
  end
  local fiber = self:fork(effect)
  local remove = fiber:addObserver(function()
    uv.stop()
  end)
  -- The observer goes however the loop returns, so that a fiber ending in a
  -- later loop run doesn't stop that loop.
  local ok, err = pcall(uv.run, "default")
  remove()
  if not ok then
    error(err, 0)
  end
  return fiber.exit, fiber
end

return LuvScheduler
