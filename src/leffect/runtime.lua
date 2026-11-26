--- The run loop.
---
--- A fiber runs an effect with a `while` loop over its own explicit stack of
--- frames (specifications/03-run-loop.md §3 and §5). Ops that wait for a
--- result push themselves as frames, and `Success`, `Failure` and `Sync` pop
--- frames until one supplies the next effect. The loop never recurses, so
--- chains of any depth are safe. It never mutates an effect table, so one
--- effect can run many times.
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

---The host interface the runtime runs on (specifications/10-scheduler.md §10.1).
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
---@field suspension leffect.Suspension?
---@field context leffect.Context The services the fiber runs with; never mutated.
---@field evaluate fun(self: leffect.FiberState, effect: leffect.Effect)

---Internal: the state of one async wait (specifications/06-async.md §6.2).
---@class leffect.Suspension
---@field resumed boolean No further wakeup may happen: the operation or an interrupt won.
---@field completed boolean The operation itself called resume.
---@field registering boolean
---@field value any The effect passed to a resume made during register.

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

--- The cause without its Fail reasons, or the cause itself if it has none.
---@param cause leffect.Cause
---@return leffect.Cause
local function withoutFails(cause)
  local reasons = cause.reasons
  local kept, n = {}, 0
  for i = 1, #reasons do
    local reason = reasons[i]
    if reason._tag ~= "Fail" then
      n = n + 1
      kept[n] = reason
    end
  end
  if n == #reasons then
    return cause
  end
  return Cause.fromReasons(kept)
end

-- The skip rule (specifications/03-run-loop.md §5.3, 4.1.5's `exitFailCause`).
-- While the fiber is interruptible and interrupted, recovery handlers don't
-- run, and the cause that unwinds records the fiber's interrupts. If a skipped
-- handler came from a frame (a recovery handler, not a Restore override), the
-- Fail reasons are dropped too. Finalizer frames escape the skip, because
-- their onPop makes the fiber uninterruptible first; so the flag is read only
-- after the first frame is popped.
evaluate.Failure = function(op, fiber)
  local cause = op.cause
  local handler, frame = nextHandler(fiber, onFailure)
  local interrupted = fiber.interruptCause
  if interrupted and fiber.interruptible then
    local skipped = false
    while handler and fiber.interruptible do
      skipped = skipped or frame ~= nil
      handler, frame = nextHandler(fiber, onFailure)
    end
    if skipped then
      cause = withoutFails(cause)
    end
    cause = Cause.addInterrupts(cause, interrupted)
  end
  if handler then
    return handler(frame, cause, fiber)
  end
  if cause == op.cause then
    fiber.finalExit = op --[[@as leffect.Exit]]
  else
    fiber.finalExit = exitFailCause(cause)
  end
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

evaluate.Suspend = function(op)
  return op.thunk()
end

evaluate.WithFiber = function(op, fiber)
  return op.f(fiber)
end

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

evaluate.Yield = function(_, fiber)
  return yieldWith(fiber, core.exitVoid)
end

-- Interruptibility (specifications/07-interruption.md §7.4) -----------------

-- Restore frames set the interruptible flag back when popped. Restoring to
-- interruptible while an interrupt is pending delivers it right there.
local RESTORE_TRUE = { _op = "Restore", interruptible = true }
local RESTORE_FALSE = { _op = "Restore", interruptible = false }

---@type leffect.Handler
local function failWithInterrupt(_, _, fiber)
  return exitFailCause(fiber.interruptCause --[[@as leffect.Cause]])
end

onPop.Restore = function(frame, fiber)
  local interruptible = frame.interruptible
  fiber.interruptible = interruptible
  if interruptible and fiber.interruptCause then
    return failWithInterrupt
  end
  return nil
end

--- Makes the fiber uninterruptible until the frames above the pushed Restore
--- are gone. Does nothing if it already is.
---@param fiber leffect.FiberState
local function enterUninterruptible(fiber)
  if fiber.interruptible then
    fiber.interruptible = false
    push(fiber, RESTORE_TRUE)
  end
end

runtime.enterUninterruptible = enterUninterruptible

--- The onPop of finalizer and canceler frames: they always run
--- uninterruptibly.
---@param fiber leffect.FiberState
local function makeUninterruptible(_, fiber)
  enterUninterruptible(fiber)
  return nil
end

--- Runs `effect` uninterruptibly. An interrupt that arrives meanwhile is
--- delivered when the region ends.
---@param effect leffect.Effect
---@return leffect.Effect
function runtime.uninterruptible(effect)
  return core.withFiber(function(fiber)
    enterUninterruptible(fiber)
    return effect
  end)
end

--- Runs `effect` interruptibly. If the fiber was already interrupted, fails
--- at once instead.
---@param effect leffect.Effect
---@return leffect.Effect
function runtime.interruptible(effect)
  return core.withFiber(function(fiber)
    if fiber.interruptible then
      return effect
    end
    fiber.interruptible = true
    push(fiber, RESTORE_FALSE)
    local cause = fiber.interruptCause
    if cause then
      return exitFailCause(cause)
    end
    return effect
  end)
end

local function identity(effect)
  return effect
end

--- Runs `body(restore)` uninterruptibly. `restore(e)` runs `e` with the
--- interruptibility the mask was entered with, so nested masks compose.
---@param body fun(restore: fun(effect: leffect.Effect): leffect.Effect): leffect.Effect
---@return leffect.Effect
function runtime.uninterruptibleMask(body)
  return core.withFiber(function(fiber)
    if not fiber.interruptible then
      return body(identity)
    end
    fiber.interruptible = false
    push(fiber, RESTORE_TRUE)
    return body(runtime.interruptible)
  end)
end

-- Finalizers (specifications/07-interruption.md §7.5) -----------------------

-- A FinalizerResult frame sits under a running finalizer. When the finalizer
-- succeeds it returns the original exit; when it fails, it adds the
-- finalizer's cause to the original one instead of replacing it, and elects
-- the defects (4.1.5's `combineFinalizerCause`).
onSuccess.FinalizerResult = function(frame)
  ---@cast frame -nil
  return frame.exit
end

onFailure.FinalizerResult = function(frame, cause)
  ---@cast frame -nil
  local exit = frame.exit
  if exit._op == core.OP_FAILURE then
    return exitFailCause(Cause.electDefects(Cause.combine(exit.cause, cause)))
  end
  return exitFailCause(cause)
end

---@param f fun(exit: leffect.Exit): leffect.Effect?
---@param exit leffect.Exit
---@param fiber leffect.FiberState
local function runFinalizer(f, exit, fiber)
  -- Pushed first, so a throw in `f` meets it too: the restarted loop's Die is
  -- then added to `exit` instead of replacing it.
  push(fiber, { _op = "FinalizerResult", exit = exit })
  local finalizer = f(exit)
  if finalizer == nil then
    local top = fiber.top
    fiber.stack[top] = nil
    fiber.top = top - 1
    return exit
  end
  return finalizer
end

evaluate.OnExit = pushSelf
onPop.OnExit = makeUninterruptible

onSuccess.OnExit = function(frame, value, fiber)
  ---@cast frame leffect.Instruction
  return runFinalizer(frame.f, exitSucceed(value), fiber)
end

onFailure.OnExit = function(frame, cause, fiber)
  ---@cast frame leffect.Instruction
  return runFinalizer(frame.f, exitFailCause(cause), fiber)
end

--- Pushes an exit frame for the effect that the current `withFiber` step
--- returns (specifications/33-primitives.md §33.2, 4.1.5's `onExitUnsafe`).
--- `f(exit)` runs uninterruptibly however that effect ends, and returns an
--- effect or nil. Pushed in the step that registers a waiter, so no interrupt
--- can land in between.
---@param fiber leffect.FiberState
---@param f fun(exit: leffect.Exit): leffect.Effect?
function runtime.onExitUnsafe(fiber, f)
  push(fiber, { _op = core.OP_ON_EXIT, f = f })
end

-- Async (specifications/06-async.md §6) -------------------------------------

evaluate.Async = function(op, fiber)
  ---@type leffect.Suspension
  local suspension = { resumed = false, completed = false, registering = true }
  local function resume(effect)
    if suspension.resumed then
      return
    end
    suspension.resumed = true
    suspension.completed = true
    if suspension.registering then
      suspension.value = effect
      return
    end
    fiber.scheduler:schedule(function()
      fiber:evaluate(effect)
    end)
  end
  local ok, cancel = xpcall(op.register, captureDefect, resume)
  suspension.registering = false
  if not ok then
    suspension.resumed = true
    return exitFailCause(defectCause(cancel))
  end
  -- Test `completed`, not `value`: a synchronous resume(nil) must reach the
  -- loop's "Not a valid effect" check instead of suspending forever.
  if suspension.completed then
    return suspension.value
  end
  if type(cancel) == "function" then
    cancel = core.sync(cancel)
  elseif cancel ~= nil and getmetatable(cancel) ~= EffectMT then
    suspension.resumed = true
    return exitFailCause(
      Cause.die(
        "Effect.async: a canceler must be a function, an effect or nil, got " .. describe(cancel)
      )
    )
  end
  fiber.suspension = suspension
  if cancel ~= nil then
    push(fiber, { _op = "AsyncCancel", cancel = cancel, suspension = suspension })
  end
  return YIELD
end

onPop.AsyncCancel = makeUninterruptible

-- Runs the canceler only if the operation never completed: wakeups are
-- scheduled, so an interrupt can arrive after `resume` but before the wakeup
-- runs, and then there is nothing left to cancel. A canceler is a finalizer,
-- so its own failure is added to the cause.
onFailure.AsyncCancel = function(frame, cause, fiber)
  ---@cast frame -nil
  if frame.suspension.completed or not Cause.hasInterrupts(cause) then
    return exitFailCause(cause)
  end
  push(fiber, { _op = "FinalizerResult", exit = exitFailCause(cause) })
  return frame.cancel
end

-- Context (specifications/18-context.md §18) --------------------------------

-- A SetContext frame puts the previous context back when it is popped. It has
-- no handlers, so it is transparent on both paths, and onPop runs even for a
-- skipped frame: the context comes back on every exit path.
onPop.SetContext = function(frame, fiber)
  fiber.context = frame.context
  return nil
end

--- Runs `effect` with the context `f(context)`, then puts the fiber's context
--- back however `effect` ends (specifications/26-services.md §26.4, 4.1.5's
--- `updateContext`). The SetContext frame is pushed in the step that changes
--- the context, so no interrupt can land between the two. If `f` returns the
--- current context, nothing is pushed.
---@param effect leffect.Effect
---@param f fun(context: leffect.Context): leffect.Context
---@return leffect.Effect
function runtime.updateContext(effect, f)
  return core.withFiber(function(fiber)
    local previous = fiber.context
    local context = f(previous)
    if context == previous then
      return effect
    end
    push(fiber, { _op = "SetContext", context = previous })
    fiber.context = context
    return effect
  end)
end

-- Gen (specifications/09-gen.md §9) -----------------------------------------

local coroutineCreate, coroutineResume, coroutineRunning, coroutineStatus, coroutineYield =
  coroutine.create, coroutine.resume, coroutine.running, coroutine.status, coroutine.yield

--- Marks what a gen coroutine yields through `run`.
local MARK = setmetatable({}, { __name = "leffect.GenMark" })

--- The coroutines the run loop created for gen bodies. The keys are weak, so
--- an abandoned coroutine is collected.
local genCoroutines = setmetatable({}, { __mode = "k" })

--- Runs `effect` from an `Effect.gen` body and returns its success value. If
--- the effect fails, or the fiber is interrupted, it never returns: the
--- coroutine is abandoned. Raises an error outside a gen body, including in a
--- coroutine of the user's own.
---@param effect leffect.Effect
---@return any
function runtime.run(effect)
  local co = coroutineRunning()
  if co == nil or not genCoroutines[co] then
    error("Leffect.run() called outside Effect.gen", 2)
  end
  return coroutineYield(MARK, effect)
end

local run = runtime.run

-- Resumes the body with the value of the effect it ran. A Gen frame has no
-- onFailure: when a run() fails, the frame is popped and dropped, and the
-- coroutine is abandoned.
onSuccess.Gen = function(frame, value, fiber)
  ---@cast frame -nil
  local co = frame.co
  local ok, a, b = coroutineResume(co, value)
  if not ok then
    -- traceback(co, ...) reads the dead coroutine's stack on 5.4 and LuaJIT.
    local trace
    if type(a) == "string" then
      trace = traceback(co, a)
    else
      trace = traceback(co, ""):sub(2)
    end
    return exitFailCause(Cause.die(a, trace))
  end
  if coroutineStatus(co) == "dead" then
    return exitSucceed(a)
  end
  if a ~= MARK then
    return exitFailCause(
      Cause.die(
        "Effect.gen: coroutine yielded without run(); "
          .. "don't call coroutine.yield directly inside gen"
      )
    )
  end
  push(fiber, frame)
  return b
end

-- Each run gets a fresh coroutine, so one gen effect can run many times, on
-- many fibers. The first resume passes `run` to the body.
evaluate.Gen = function(op, fiber)
  local co = coroutineCreate(op.body)
  genCoroutines[co] = true
  return onSuccess.Gen({ _op = "Gen", co = co }, run, fiber)
end

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
