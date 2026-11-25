# Frames, fibers and the run loop

Part I (the runtime, M1) of the [Leffect specifications](README.md).

## 3. The frame protocol

```lua
-- Private dispatch tables, keyed by a frame's `_op`:
onSuccess[op](frame, value, fiber) --> Effect
onFailure[op](frame, cause, fiber) --> Effect
onPop[op](frame, fiber)            --> override handler, or nil
```

- `onPop` runs for every popped frame, on both the success and failure paths,
  before its handler is considered. It may push frames (a `Restore`). It can
  also return an override handler, which is used instead of the frame's own
  handler. This corresponds to v4's `contAll`.

### 3.1 Popping a continuation

```lua
-- handlers is the onSuccess or the onFailure table
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
      if override then return override, nil end
      top = fiber.top -- pop may have pushed a Restore
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
```

### 3.2 Frame kinds for M1

| Frame                    | onSuccess        | onFailure                     | onPop                                      |
|--------------------------|------------------|-------------------------------|--------------------------------------------|
| `Map`                    | `succeed(f(value))` | —                          | —                                          |
| `OnSuccess` (flatMap)    | `f(value)`       | —                             | —                                          |
| `OnFailure` (catchCause) | —                | `f(cause)`                    | —                                          |
| `OnExit` (finalizer)     | run `f(exit)`, then exit | run `f(exit)`, then combined exit | make uninterruptible, push `Restore(true)` |
| `Restore(b)`             | —                | —                             | set `interruptible = b`; if `b` and interrupted, override to fail with the interrupt |
| `AsyncCancel`            | —                | if interrupted and the operation never completed, run the canceler, then re-fail | make uninterruptible, push `Restore(true)` |
| `FinalizerResult`        | return original exit | fail with `electDefects(combine(original, c2))` (or `c2` if original succeeded) | — |
| `Gen` (M2)               | resume coroutine | —                             | —                                          |
| `SetContext` (M2)        | —                | —                             | set `fiber.context` back to `frame.context` (§18) |

`OnExit` and `AsyncCancel` only switch to uninterruptible (and push a restore)
if the fiber is currently interruptible. Otherwise they leave the state alone.
`Restore(true)` and `Restore(false)` are shared singletons.

---

## 4. The fiber

```lua
---@class Fiber
---@field id integer
---@field status "pending"|"running"|"suspended"|"done"
---@field stack Frame[]
---@field top integer                -- stack height
---@field interruptible boolean
---@field interruptCause Cause?      -- set once interrupted, accumulates interruptors
---@field pendingInterrupt boolean   -- deliver at the next loop step
---@field suspension Suspension?     -- the live async wait, if any
---@field exit Exit?
---@field observers fun(exit: Exit)[]
---@field children table<Fiber, true>?
---@field scheduler Scheduler
---@field opCount integer            -- steps since the fiber last yielded
---@field context table              -- M2: immutable services, inherited at fork (§18)
```

Fiber IDs are monotonically increasing integers, shared by every runtime in
the process.

---

## 5. The run loop

### 5.1 Entry point

```lua
function Fiber:evaluate(eff)
  if self.exit then return end
  self.suspension = nil
  self.status = "running"
  self.opCount = 0
  local exit = runLoop(self, eff)
  if exit == YIELD then
    self.status = "suspended"
    -- An interrupt requested during the step that suspended (by user code in
    -- `register`, say) has no loop step left to deliver it. Wake the fiber.
    local s = self.suspension
    if self.pendingInterrupt and self.interruptible and s and not s.resumed then
      self.pendingInterrupt = false
      s.resumed = true
      wakeWithInterrupt(self) -- schedules evaluate(Failure(interruptCause))
    end
    return
  end
  -- Structured concurrency: children exit before the parent publishes its exit.
  if self.children and next(self.children) then
    self.interruptible = false -- shutting down children can't itself be interrupted
    -- exits are effects, so returning `exit` makes it the final instruction
    return self:evaluate(interruptAll(sortedById(self.children), self.id)
      :flatMap(function() return exit end))
  end
  self:complete(exit)
end

function Fiber:complete(exit)
  self.exit = exit
  self.status = "done"
  local obs = self.observers
  self.observers = {}
  for i = 1, #obs do obs[i](exit) end
end
```

`interruptAll(...)` awaits all children, so it suspends. When it
resumes, `evaluate` runs again with `exit` as the final effect. By then the
children are gone, because each child's observer removes it from the set, and
the parent completes. Children are interrupted in fork order (by ID), so specs
that log their finalizers are deterministic.

### 5.2 The loop

```lua
local function runLoop(fiber, cur)
  local ok, res = xpcall(loop, captureDefect, fiber, cur)
  if ok then return res end
  -- A Lua error escaped user code (a map function, a sync thunk, a finalizer
  -- function...). Restart the loop with a defect. The frame being processed
  -- was already popped, so unwinding continues correctly. This is a proper
  -- tail call, and the op count lives on the fiber, so a fiber that keeps
  -- failing can't dodge the op budget.
  return runLoop(fiber, Exit.failCause(defectCause(res)))
end

local function loop(fiber, cur)
  local maxOps = fiber.scheduler.maxOpsBeforeYield or 2048 -- v4's default
  while true do
    -- (a) deliver an interrupt requested while we were running or queued
    if fiber.pendingInterrupt then
      fiber.pendingInterrupt = false
      if fiber.interruptible then cur = Exit.failCause(fiber.interruptCause) end
    end
    -- (b) fairness: give other fibers a turn
    local ops = fiber.opCount + 1
    fiber.opCount = ops
    if ops > maxOps then
      return yieldWith(fiber, cur) -- schedules evaluate(cur), returns YIELD
    end
    -- (c) M0's contract: a non-effect is a defect, and it unwinds
    if getmetatable(cur) ~= EffectMT then
      cur = Exit.die("Not a valid effect: " .. describe(cur))
    end
    -- (d) step
    cur = evaluate[cur._op](cur, fiber)
    if cur == YIELD then return YIELD end
    if cur == DONE then
      if not (fiber.pendingInterrupt and fiber.interruptible) then
        return fiber.finalExit
      end
      cur = fiber.finalExit -- interrupted during the last step: (a) takes over
    end
  end
end
```

`Success`, `Failure` and `Sync` call `nextHandler`. When the stack is empty,
they store the exit in `fiber.finalExit` and return `DONE`.

v4's `runLoop` has the same shape: a `try`/`catch` around the whole loop that
restarts it with `exitDie(error)`. For an invalid effect, though, v4 returns
the `Die` at once and skips the remaining frames. Leffect unwinds it through
the frames like any other failure (an M0 decision), so finalizers still run.

`captureDefect` must handle non-string errors. Lua errors can be any value,
and `debug.traceback(x)` returns non-strings unchanged. LuaJIT even returns
`nil` for `debug.traceback(nil, level)`, so pass `""` instead:

```lua
local Captured = {} -- marks the handler's result
local function captureDefect(e)
  local trace
  if type(e) == "string" then
    trace = debug.traceback(e, 2)
  else
    trace = debug.traceback("", 2):sub(2) -- drop the leading newline
  end
  return setmetatable({ defect = e, trace = trace }, Captured)
end
```

`defectCause(res)` builds `Cause.die(res.defect, res.trace)`, or
`Cause.die(res)` if the handler itself failed. The defect is the thrown value,
unchanged, and the traceback goes in `trace`.

### 5.3 Failure evaluation and the skip rule

This is the core of interruption semantics:

```lua
evaluate.Failure = function(op, fiber)
  local cause = op.cause
  local h, frame = nextHandler(fiber, onFailure)
  local interrupted = fiber.interruptCause
  -- While interruptible and interrupted, recovery handlers don't run.
  -- Finalizer frames escape this because their onPop already made the fiber
  -- uninterruptible by the time we get here.
  if interrupted and fiber.interruptible then
    local skipped = false
    while h and fiber.interruptible do
      skipped = skipped or frame ~= nil -- an override has no frame: not counted
      h, frame = nextHandler(fiber, onFailure)
    end
    if skipped then cause = withoutFails(cause) end -- drop the Fail reasons
    cause = addInterrupts(cause, interrupted)        -- record the interrupt
  end
  if not h then
    fiber.finalExit = cause == op.cause and op or Exit.failCause(cause)
    return DONE
  end
  return h(frame, cause, fiber)
end
```

This is 4.1.5's rule (`internal/core.ts`, `exitFailCause`). The skip itself is
M1's, and the two changes to the cause are new with the re-pin (§17):

- **The interrupt is recorded.** The fiber's interrupt reasons are added to the
  cause that unwinds. Take a fiber interrupted inside an uninterruptible region
  that then fails: it now ends with the failure and the Interrupt, not with the
  failure alone.

  `addInterrupts(cause, interrupted)` appends each Interrupt reason whose
  `fiberId` the cause doesn't have yet, and leaves every other reason alone.
  This is 4.1.5's `causeAddInterrupts`. `Cause.combine` would not do here: it
  would also merge repeated Fail and Die reasons.
- **Typed failures are dropped when a recovery handler is skipped.** A skipped
  `catchCause`-family frame would have handled the Fail reasons, so they leave
  the cause and the interrupt stands alone. Defects stay.

  Example: a finalizer that fails with `Fail` during an interrupt keeps its
  reason only if no recovery handler is skipped later. The user confirmed
  this (§17, decision 19), and CLAUDE.md names it as the exception to
  "finalizer errors are added to the Cause".

An override from `Restore(true)` comes without a frame. It is skipped like any
handler, but it doesn't count as a recovery handler; v4's restore
continuations likewise carry no `identifier`.

Finalizer frames are popped while the fiber is uninterruptible, so they are
never skipped and never counted. In practice, the skipped frames that count are
`OnFailure` frames.
