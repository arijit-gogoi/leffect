--- The run loop.
---
--- A fiber runs an effect with a `while` loop over its own explicit stack of
--- frames (FIBER-DESIGN.md §3 and §5). Ops that wait for a result push
--- themselves as frames, and `Success`, `Failure` and `Sync` pop frames until
--- one supplies the next effect. The loop never recurses, so chains of any
--- depth are safe. It never mutates an effect table, so one effect can run
--- many times.
---
--- Each op's behavior lives in private tables keyed by `_op`: `evaluate`,
--- `onSuccess`, `onFailure` and `onPop`. A Lua error thrown by user code
--- escapes the loop to a single `xpcall`, which restarts the loop with a
--- defect: a `Die` holding the thrown value and its traceback.

local Cause = require("leffect.cause")
local core = require("leffect.core")

local getmetatable, pcall, setmetatable, tostring, type, xpcall =
  getmetatable, pcall, setmetatable, tostring, type, xpcall
local traceback = debug.traceback

local EffectMT = core.EffectMT
local exitSucceed, exitFailCause = core.exitSucceed, core.exitFailCause

---The host interface the runtime runs on (FIBER-DESIGN.md §10.1).
---@class leffect.Scheduler
---@field schedule fun(self: leffect.Scheduler, task: fun()) Runs `task` on the next tick, FIFO.
---@field after fun(self: leffect.Scheduler, ms: number, task: fun()): fun() Returns a cancel function.
---@field now fun(self: leffect.Scheduler): number Milliseconds.
---@field maxOpsBeforeYield integer? Loop steps before a fiber yields; default 2048.

---Internal: the fiber state the run loop reads and writes. `leffect.fiber`
---owns the full fiber.
---@class leffect.FiberState
---@field stack table[]
---@field top integer
---@field scheduler leffect.Scheduler
---@field interruptible boolean
---@field interruptCause leffect.Cause?
---@field pendingInterrupt boolean
---@field opCount integer
---@field finalExit leffect.Exit?
---@field evaluate fun(self: leffect.FiberState, effect: leffect.Effect)

---@alias leffect.Handler fun(frame: table?, arg: any, fiber: leffect.FiberState): any

local runtime = {}

--- Returned by an op that suspended the fiber.
local YIELD = setmetatable({}, { __name = "leffect.YIELD" })
--- Returned when the stack is empty; the exit is in `fiber.finalExit`.
local DONE = setmetatable({}, { __name = "leffect.DONE" })

runtime.YIELD = YIELD

--- How many loop steps a fiber may take before it yields (v4's default).
runtime.MAX_OPS_BEFORE_YIELD = 2048

---@type table<string, fun(op: leffect.Instruction, fiber: leffect.FiberState): any>
local evaluate = {}
---@type table<string, leffect.Handler>
local onSuccess = {}
---@type table<string, leffect.Handler>
local onFailure = {}
---@type table<string, fun(frame: table, fiber: leffect.FiberState): leffect.Handler?>
local onPop = {}

runtime.evaluate = evaluate
runtime.onSuccess = onSuccess
runtime.onFailure = onFailure
runtime.onPop = onPop

---@param fiber leffect.FiberState
---@param frame table
local function push(fiber, frame)
  local top = fiber.top + 1
  fiber.top = top
  fiber.stack[top] = frame
end

runtime.push = push

--- Pops frames until one has a handler in `handlers` (the `onSuccess` or the
--- `onFailure` table), running each popped frame's `onPop` first. An `onPop`
--- may push frames, and may return an override handler.
---@param fiber leffect.FiberState
---@param handlers table<string, leffect.Handler>
---@return leffect.Handler? handler
---@return table? frame
local function nextHandler(fiber, handlers)
  local stack, top = fiber.stack, fiber.top
  while top > 0 do
    local frame = stack[top]
    stack[top] = nil
    top = top - 1
    local op = frame._op
    local pop = onPop[op]
    if pop then
      fiber.top = top
      local override = pop(frame, fiber)
      if override then
        return override, nil
      end
      top = fiber.top
    end
    local handler = handlers[op]
    if handler then
      fiber.top = top
      return handler, frame
    end
  end
  fiber.top = 0
  return nil, nil
end

-- Defects -------------------------------------------------------------------

local Captured = { __name = "leffect.CapturedDefect" }

--- The `xpcall` message handler: keeps the thrown value and adds a traceback.
--- `debug.traceback` returns non-strings unchanged, and LuaJIT returns nil for
--- a nil message, so non-strings get the traceback of an empty message.
---@param err any
---@return table
local function captureDefect(err)
  local trace
  if type(err) == "string" then
    trace = traceback(err, 2)
  else
    trace = traceback("", 2):sub(2)
  end
  return setmetatable({ defect = err, trace = trace }, Captured)
end

runtime.captureDefect = captureDefect

--- The cause for a value caught by `xpcall` with `captureDefect`.
---@param caught any
---@return leffect.Cause
local function defectCause(caught)
  if getmetatable(caught) == Captured then
    return Cause.die(caught.defect, caught.trace)
  end
  -- The message handler itself failed.
  return Cause.die(caught)
end

runtime.defectCause = defectCause

--- `tostring` that can't throw, for error messages.
---@param value any
---@return string
local function describe(value)
  local ok, text = pcall(tostring, value)
  if not ok or type(text) ~= "string" then
    text = type(value)
  end
  return text
end

runtime.describe = describe

-- Ops -----------------------------------------------------------------------

evaluate.Success = function(op, fiber)
  local handler, frame = nextHandler(fiber, onSuccess)
  if handler then
    return handler(frame, op.value, fiber)
  end
  fiber.finalExit = op --[[@as leffect.Exit]]
  return DONE
end

-- While the fiber is interruptible and interrupted, recovery handlers are
-- skipped (FIBER-DESIGN.md §5.3). Finalizer frames escape this, because
-- their onPop makes the fiber uninterruptible first.
evaluate.Failure = function(op, fiber)
  local handler, frame = nextHandler(fiber, onFailure)
  while handler and fiber.interruptible and fiber.interruptCause do
    handler, frame = nextHandler(fiber, onFailure)
  end
  if handler then
    return handler(frame, op.cause, fiber)
  end
  fiber.finalExit = op --[[@as leffect.Exit]]
  return DONE
end

-- Like Success, but without allocating an exit for the thunk's result.
evaluate.Sync = function(op, fiber)
  local value = op.thunk()
  local handler, frame = nextHandler(fiber, onSuccess)
  if handler then
    return handler(frame, value, fiber)
  end
  fiber.finalExit = exitSucceed(value)
  return DONE
end

---@param op leffect.Instruction
---@param fiber leffect.FiberState
local function pushSelf(op, fiber)
  push(fiber, op)
  return op.first
end

evaluate.Map = pushSelf
evaluate.OnSuccess = pushSelf
evaluate.OnFailure = pushSelf

onSuccess.Map = function(frame, value)
  ---@cast frame leffect.Instruction
  return exitSucceed(frame.f(value))
end

onSuccess.OnSuccess = function(frame, value)
  ---@cast frame leffect.Instruction
  return frame.f(value)
end

onFailure.OnFailure = function(frame, cause)
  ---@cast frame leffect.Instruction
  return frame.f(cause)
end

-- The loop ------------------------------------------------------------------

--- Schedules `fiber:evaluate(effect)` on the next tick and suspends the fiber.
---@param fiber leffect.FiberState
---@param effect any
---@return table YIELD
local function yieldWith(fiber, effect)
  fiber.scheduler:schedule(function()
    fiber:evaluate(effect)
  end)
  return YIELD
end

runtime.yieldWith = yieldWith

---@param fiber leffect.FiberState
---@param cur any
---@return leffect.Exit|table exit The exit, or YIELD if the fiber suspended.
local function loop(fiber, cur)
  local maxOps = fiber.scheduler.maxOpsBeforeYield or runtime.MAX_OPS_BEFORE_YIELD
  while true do
    -- Deliver an interrupt requested while the fiber ran or was queued.
    if fiber.pendingInterrupt then
      fiber.pendingInterrupt = false
      if fiber.interruptible then
        cur = exitFailCause(fiber.interruptCause --[[@as leffect.Cause]])
      end
    end
    -- Fairness: give other fibers a turn.
    local ops = fiber.opCount + 1
    fiber.opCount = ops
    if ops > maxOps then
      return yieldWith(fiber, cur)
    end
    -- M0's contract: a non-effect is a defect, and it unwinds like a failure.
    if getmetatable(cur) ~= EffectMT then
      cur = exitFailCause(Cause.die("Not a valid effect: " .. describe(cur)))
    end
    cur = evaluate[cur._op](cur, fiber)
    if cur == YIELD then
      return YIELD
    elseif cur == DONE then
      if not (fiber.pendingInterrupt and fiber.interruptible) then
        return fiber.finalExit --[[@as leffect.Exit]]
      end
      -- Interrupted during the last step: the next step delivers it.
      cur = fiber.finalExit
    end
  end
end

--- Runs `effect` on `fiber` until the fiber finishes or suspends. A Lua error
--- from user code restarts the loop with a defect. The frame being processed
--- was already popped, so unwinding continues correctly. The restart is a
--- proper tail call, and the op count lives on the fiber, so a fiber that
--- keeps failing can't dodge the op budget.
---@param fiber leffect.FiberState
---@param effect any
---@return leffect.Exit|table exit The exit, or YIELD if the fiber suspended.
local function runLoop(fiber, effect)
  local ok, result = xpcall(loop, captureDefect, fiber, effect)
  if ok then
    return result
  end
  return runLoop(fiber, exitFailCause(defectCause(result)))
end

runtime.runLoop = runLoop

return runtime
