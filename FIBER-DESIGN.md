
# Leffect: fiber and interruption design

Status: settled for Milestone M1 on 2026-11-25. It is based on Effect v4's
runtime (`effect-smol` `main` @ `3a1128c`: `packages/effect/src/internal/effect.ts`
and `internal/core.ts`, notably `FiberImpl`, `exitFailCause`, `callbackOptions`,
`setInterruptible`, `onExitPrimitive`, `forkUnsafe`, `raceAll`, `raceFirst` and
`runSyncExitWith`) and adapted to Lua. §16 lists what the review of the first
draft changed, including the decisions taken on the user's behalf.

---

## 0. Summary

- **Effects are data, and exits are effects.** `Success` and `Failure` are both
  the result of a computation and instructions the run loop can evaluate.
- **One stack of frames per fiber.** Every combinator that waits for a result
  (`flatMap`, `catchCause`, `onExit`, an async canceler, an interruptibility
  restore, and a generator in M2) pushes itself as a frame. A frame can handle
  success, failure, or both, and can react to being popped (`onPop`).
- **Interruption is a failure with a special rule.** An interrupt is delivered
  by failing the fiber with an `Interrupt` cause. While the fiber is
  interruptible and has been interrupted, recovery handlers are skipped during
  unwinding. Finalizer frames switch the fiber to uninterruptible when popped,
  so they always run.
- **Interruptibility is a flag plus restore frames.** `uninterruptible(e)` sets
  the flag and pushes a frame that restores it. Restoring to interruptible while
  an interrupt is pending delivers it right there.
- **Async is a one-shot suspension with an optional canceler.** The canceler is
  pushed as a frame, so interruption cancels the operation by ordinary
  unwinding. A canceler never runs once its operation has completed.
- **No nested run loops.** Every wakeup (async resume, interrupt of a suspended
  fiber, fork start, yield) goes through `scheduler:schedule`. Only one run
  loop is ever on the Lua stack. This is the main deviation from v4, which
  resumes synchronously for speed. See §14.
- **Structured concurrency.** A fiber publishes its exit only after
  interrupting and awaiting all its children.
- **`gen` on stackful coroutines, in M2.** `run(eff)` yields a marked effect to
  the run loop. On failure or interrupt the coroutine is abandoned, never
  thrown into. §9 designs it now, so that M1's frames can host it.

---

## 1. Goals and non-goals

**Goals for M1:** fibers, a test scheduler with a virtual clock, `async` with
cancelers, `sleep`, `fork`/`forkDaemon`/`join`/`await`, `interrupt`/
`interruptFork`, `uninterruptible`/`interruptible`/`uninterruptibleMask`,
`onExit`/`ensuring`/`onInterrupt`, `race`/`raceFirst`/`timeout`, fair
yielding, and the entry points `runFork`, `runSync` and `runSyncExit`.

**Non-goals for M1:** `gen` (M2, as CLAUDE.md's milestones say; designed in
§9), Scope (M2), Context/Layer/FiberRef (M3), an Option type (so no
`timeoutOption` yet), tracing and stack annotations, scheduler priorities,
real-host adapters other than test (luv comes in M3).

---

## 2. Data model

### 2.1 Cause

This follows v4, which replaced Effect 2/3's Sequential/Parallel tree with a
flat list.

```lua
---@alias Reason
---| { _tag: "Fail", error: any }
---| { _tag: "Die", defect: any, trace: string? }
---| { _tag: "Interrupt", fiberId: integer? }

---@class Cause
---@field reasons Reason[]
```

- A Die's `defect` is the thrown value, unchanged. `trace` is the traceback
  captured where the runtime caught it, if it did.
- `Cause.empty` has no reasons. `Cause.combine(a, b)` appends the reasons of
  `b` that `a` doesn't already have: the same table, or the same `_tag` with a
  raw-equal (`==`) payload. An empty cause is the identity. This is v4's
  `causeCombine`, which merges with `Arr.union` under structural equality.
- `Cause.fromReasons(list)` keeps every reason, duplicates included, like v4's
  `causeFromReasons` (used by `raceAll`).
- Queries: `failures` and `defects` (each returns `list, count`, because a
  value can be nil), `interruptors` (the distinct fiber IDs), `findError`,
  `findDefect`, `hasFails`, `hasDies`, `hasInterrupts`, `hasInterruptsOnly`
  and `isEmpty`.
- `squash` picks the one value to report: the first error, else the first
  defect, else "All fibers interrupted without error", else "Empty cause"
  (v4's `causeSquash`).
- The runtime's own error values live in `Cause`, as in v4. They are tagged
  tables with a `message` and a `__tostring`: `Cause.TimeoutError()` and
  `Cause.AsyncFiberError(fiber)`.

### 2.2 Exit, also an effect

```lua
{ _op = "Success", _tag = "Success", value = v }
{ _op = "Failure", _tag = "Failure", cause = c }
```

`Exit.succeed`, `Exit.failCause`, `Exit.fail(e)`, `Exit.die(d, trace)`,
`Exit.interrupt(id)`, `Exit.void`. Because exits are effects, a frame handler
can return an exit directly, and a finished fiber's exit can be yielded back
into another loop.

### 2.3 Primitive ops for M1

Everything else derives from these. M0's op names and fields (`Map`,
`OnSuccess`, `OnFailure`, `first`) stay.

| `_op`        | Fields            | Evaluate                                      |
|--------------|-------------------|-----------------------------------------------|
| `Success`    | `value`           | pop next `onSuccess` handler                  |
| `Failure`    | `cause`           | pop next `onFailure` handler (with skip rule) |
| `Sync`       | `thunk`           | pop next `onSuccess` handler with `thunk()`   |
| `Suspend`    | `thunk`           | `thunk()` (lazy effect)                       |
| `Map`        | `first`, `f`      | push self as frame, continue with `first`     |
| `OnSuccess`  | `first`, `f`      | push self as frame (this is `flatMap`)        |
| `OnFailure`  | `first`, `f`      | push self as frame (this is `catchCause`)     |
| `OnExit`     | `first`, `f`      | push self as frame (finalizer)                |
| `WithFiber`  | `f`               | `f(fiber)`                                    |
| `Async`      | `register`        | see §6                                        |
| `Yield`      | —                 | reschedule, return `YIELD`                    |
| `Gen` (M2)   | `body`            | create coroutine and frame, see §9            |

All effects keep M0's single shared metatable, so `isEffect` and `isExit` stay
metatable checks, and the user methods (`eff:map(f)`) keep working. The run
loop finds each op's behavior in private tables keyed by `_op`:
`evaluate[op]`, `onSuccess[op]`, `onFailure[op]` and `onPop[op]`. v4 hangs the
same functions off symbol keys on each primitive. Lua has no symbols, and
plain method names would share the `__index` namespace with the user methods.

Ops that push themselves as frames carry their own handlers, which avoids
allocating a separate frame (v4 does the same). Internal frames (`Restore`,
`AsyncCancel`, `FinalizerResult`, and `Gen` in M2) are plain tables with a
private `_op`; they are never evaluated as effects. Ops with per-run state
(`Async`, `Gen`) push a fresh frame table on each evaluation, because an
effect value can run many times, concurrently. The loop never mutates an
effect table.

---

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
| `FinalizerResult`        | return original exit | fail with `combine(original, c2)` (or `c2` if original succeeded) | — |
| `Gen` (M2)               | resume coroutine | —                             | —                                          |

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
  local h, frame = nextHandler(fiber, onFailure)
  -- While interruptible and interrupted, recovery handlers don't run.
  -- Finalizer frames escape this because their onPop already made the fiber
  -- uninterruptible by the time we get here.
  while h and fiber.interruptible and fiber.interruptCause do
    h, frame = nextHandler(fiber, onFailure)
  end
  if not h then
    fiber.finalExit = op
    return DONE
  end
  return h(frame, op.cause, fiber)
end
```

This also correctly skips an override from `Restore(true)`. The override fails
with the interrupt cause, which only re-enters this same path. It is v4's rule
(`internal/core.ts`, `exitFailCause`): v4 skips the handlers, but doesn't
strip failures from the cause.

---

## 6. Async

### 6.1 API

```lua
Effect.async(function(resume)
  local handle = startSomething(function(err, value)
    if err then resume(Effect.fail(err)) else resume(Effect.succeed(value)) end
  end)
  return function() handle:cancel() end -- canceler: a function, an Effect, or nil
end)
```

- `resume` takes an effect, so it can succeed, fail or die.
- The canceler is optional. A function is wrapped as `Effect.sync(fn)`.
  Anything else that isn't an Effect or nil is a defect.

### 6.2 Evaluate

```lua
evaluate.Async = function(op, fiber)
  -- resumed: no further wakeup may happen (the operation or an interrupt won).
  -- completed: the operation itself called resume.
  local s = { resumed = false, completed = false, registering = true }
  local function resume(eff)
    if s.resumed then return end -- one-shot: late or duplicate calls are ignored
    s.resumed = true
    s.completed = true
    if s.registering then s.value = eff; return end -- resumed synchronously
    fiber.scheduler:schedule(function() fiber:evaluate(eff) end)
  end
  local ok, cancel = xpcall(op.register, captureDefect, resume)
  s.registering = false
  if not ok then
    s.resumed = true
    return Exit.failCause(defectCause(cancel))
  end
  -- Test `completed`, not `value`: a synchronous `resume(nil)` must reach the
  -- loop's "Not a valid effect" check instead of suspending forever.
  if s.completed then return s.value end -- no suspension, no cancel frame
  if type(cancel) == "function" then cancel = Effect.sync(cancel) end
  if cancel ~= nil and not isEffect(cancel) then
    s.resumed = true
    return Exit.die("Effect.async: a canceler must be a function, an Effect or nil")
  end
  fiber.suspension = s
  if cancel then push(fiber, { _op = "AsyncCancel", cancel = cancel, s = s }) end
  return YIELD
end
```

### 6.3 Cancel frame

```lua
onPop.AsyncCancel = makeUninterruptibleIfInterruptible -- pushes Restore(true)
onFailure.AsyncCancel = function(frame, cause, fiber)
  -- Run the canceler only if the operation never completed. Wakeups are
  -- scheduled, so an interrupt can arrive after `resume` but before the
  -- wakeup runs. The operation is done by then; there is nothing to cancel.
  if frame.s.completed or not Cause.hasInterrupts(cause) then
    return Exit.failCause(cause)
  end
  -- A canceler is a finalizer: its own failure is added to the cause.
  push(fiber, { _op = "FinalizerResult", exit = Exit.failCause(cause) })
  return frame.cancel
end
-- No onSuccess: on success the frame is popped and dropped, so a completed
-- operation is never cancelled.
```

### 6.4 `sleep` with the scheduler

```lua
function Effect.sleep(ms)
  return Effect.withFiber(function(fiber)
    return Effect.async(function(resume)
      return fiber.scheduler:after(ms, function() resume(Effect.void) end)
    end)
  end)
end
```

`scheduler:after` already returns a cancel function, which becomes the
canceler. In M3 this moves behind a `Clock` service.

---

## 7. Interruption

### 7.1 Requesting

```lua
function Fiber:interruptUnsafe(byId)
  if self.exit then return end
  self.interruptCause = Cause.combine(self.interruptCause or Cause.empty,
                                      Cause.interrupt(byId))
  if not self.interruptible then return end -- delivered later by Restore(true)
  local s = self.suspension
  if self.status == "suspended" and s and not s.resumed then
    s.resumed = true -- win the race against the operation's own resume
    self.scheduler:schedule(function()
      self:evaluate(Exit.failCause(self.interruptCause))
    end)
  else
    -- running (self-interrupt), pending (not started yet), or a wakeup is
    -- already queued: the loop delivers it at its next step
    self.pendingInterrupt = true
  end
end
```

### 7.2 Where an interrupt gets delivered

Delivery only ever happens while the fiber is interruptible:

1. **Suspended:** woken with `Failure(interruptCause)`. The `AsyncCancel`
   frame on top of the stack runs the canceler.
2. **Running, pending, or already woken:** at the next loop step, through
   `pendingInterrupt`. If the request came during the fiber's last step, or
   during a step that then suspended the fiber, §5.2 and §5.1 still deliver
   it.
3. **When an uninterruptible region ends:** `Restore(true).onPop` sees
   `interruptCause` and overrides the continuation with a failure.
4. **On entering `interruptible(e)`:** if already interrupted, fail
   immediately instead of running `e`.

A fiber that is interrupted before it starts runs no user code: its first loop
step delivers the interrupt.

### 7.3 Public operations

| Operation                 | Semantics |
|---------------------------|-----------|
| `fiber:interrupt()`       | `interruptUnsafe(currentFiber.id)`, then await the target's exit, including its finalizers. Returns void. |
| `fiber:interruptFork()`   | Same request, without waiting. |
| `Effect.interrupt`        | Self-interrupt: `failCause(Interrupt(self.id))`. This matches v4: it doesn't set `interruptCause`, so it unwinds like a failure. `catchAll` (Fail-only) won't match it, since there's no Fail reason, but `catchCause` can catch it. |
| `Fiber.interruptAll(fibers)` | Request all, as the current fiber, then await all. |

### 7.4 Interruptibility regions

```lua
function Effect.uninterruptible(eff)
  return Effect.withFiber(function(f)
    if not f.interruptible then return eff end
    f.interruptible = false
    f:push(Restore(true))
    return eff
  end)
end

function Effect.interruptible(eff)
  return Effect.withFiber(function(f)
    if f.interruptible then return eff end
    f.interruptible = true
    f:push(Restore(false))
    if f.interruptCause then return Exit.failCause(f.interruptCause) end
    return eff
  end)
end

function Effect.uninterruptibleMask(body)
  return Effect.withFiber(function(f)
    if not f.interruptible then return body(identity) end -- nested: restore is a no-op
    f.interruptible = false
    f:push(Restore(true))
    return body(Effect.interruptible)
  end)
end
```

`restore` inside a nested mask is the identity function. This is what makes
`uninterruptibleMask` compose: `restore` returns to the state the mask was
entered in, never further.

### 7.5 Finalizers

```lua
-- eff:onExit(f), where f(exit) returns an Effect or nil
onPop.OnExit = makeUninterruptibleIfInterruptible
onSuccess.OnExit = function(frame, value, fiber)
  return runFinalizer(frame.f, Exit.succeed(value), fiber)
end
onFailure.OnExit = function(frame, cause, fiber)
  return runFinalizer(frame.f, Exit.failCause(cause), fiber)
end

local function runFinalizer(f, exit, fiber)
  -- Push FinalizerResult first: if `f` itself throws, the restarted loop's Die
  -- still meets it, and is added to `exit` instead of replacing it.
  push(fiber, { _op = "FinalizerResult", exit = exit })
  local fin = f(exit)
  if fin == nil then
    pop(fiber) -- nothing to run: drop the FinalizerResult again
    return exit
  end
  return fin
end
```

- `ensuring(fin)` is `onExit(function() return fin end)`.
- `onInterrupt(f)` is an `onExit` that runs `f(interruptors)` when the exit's
  cause has any Interrupt reason. `interruptors` is the list of distinct
  interruptor IDs. v4 does the same, through `causeFilterInterruptors`.
- A failing finalizer adds its cause and never replaces the original. If the
  body succeeded and the finalizer failed, the result is a failure with the
  finalizer's cause. This deviates from v4 (§14), where a finalizer's failure
  replaces the cause; CLAUDE.md requires adding it.

### 7.6 Worked trace: timeout interrupts a sleeping fiber with cleanup

```
child stack: [OnExit(log "closed"), AsyncCancel(cancelTimer)]   status: suspended
parent: child:interrupt()
  → child.interruptCause = [Interrupt(parent)]
  → suspension live → s.resumed = true, schedule(evaluate(Failure(...)))
  → parent awaits child (suspends)
tick: child:evaluate(Failure)
  pop AsyncCancel: onPop → uninterruptible, push Restore(true)
    onFailure: never completed, has interrupts → push FinalizerResult, cancelTimer()
  FinalizerResult → Failure(original)
  pop Restore(true): interruptible = true; its override is skipped (skip rule)
  pop OnExit: onPop → uninterruptible, push Restore(true)
    onFailure → push FinalizerResult, log "closed"
  FinalizerResult → Failure(original)
  pop Restore(true): interruptible = true; its override is skipped
  stack empty → DONE → children? none → complete(exit) → observers
tick: parent resumes from await → interrupt() returns
Meanwhile: the timer callback can never fire (cancelled). If it had already
been queued, its resume would be ignored because s.resumed is true.
```

---

## 8. Children and structured concurrency

```lua
function forkUnsafe(parent, eff, daemon, uninterruptible)
  local child = Fiber.new(parent.scheduler, not uninterruptible)
  parent.scheduler:schedule(function() child:evaluate(eff) end)
  if not daemon then
    parent.children = parent.children or {}
    parent.children[child] = true
    child:addObserver(function() parent.children[child] = nil end)
  end
  return child
end
```

- Children start interruptible whatever the parent's state, as with v4's
  `forkUnsafe`, whose `uninterruptible` option defaults to false.
- `Effect.fork(eff)` attaches the child to the current fiber and starts it on
  the next tick.
- `forkDaemon` doesn't attach it.
- `forkScoped` attaches it to a Scope (M2).
- `fiber:await()` is `async(function(resume) ... end)`: if the fiber is
  already done, resume immediately. Otherwise `addObserver(resume ∘ succeed)`
  and return the observer-removal function as the canceler, so interrupting an
  awaiter unregisters it.
- `fiber:join()` is the same with `addObserver(resume)`. The child's exit is
  an effect, so a child's failure fails the joiner, and a child's interrupt
  cause too. This is catchable by the joiner, because the joiner itself wasn't
  interrupted.
- **Parent exit means children are interrupted first** (§5.1). Shutdown runs
  uninterruptibly, so an interrupt arriving mid-shutdown can't strand
  children that are still cleaning up.

### 8.1 race and timeout

`raceAll(effs)`: the first success wins, and the race fails only if every
racer fails. `raceFirst`: the first exit wins, success or failure. Both follow
v4 (`raceAll`, `raceAllFirst`):

```lua
local function raceWith(effects, firstExitWins)
  return withFiber(function(parent)
    return async(function(resume)
      -- fork every racer as a daemon: the race manages them itself
      -- observe each racer:
      --   a winner (a success, or any exit when firstExitWins):
      --     resume(uninterruptible(interruptAll(stillRunning)):flatMap(→ exit))
      --   otherwise: collect its reasons; once every racer is done,
      --     resume(failCause(Cause.fromReasons(reasons)))
      return suspend(function() return interruptAll(stillRunning()) end) -- canceler
    end)
  end)
end
```

- The wait is interruptible. If the racing fiber is interrupted, the canceler
  interrupts every racer still running, and waits for them.
- Losers are interrupted and awaited, uninterruptibly, before the race
  returns.
- `race(a, b)` is `raceAll({a, b})`. `raceFirst(a, b)` races `{a, b}` with
  `firstExitWins`.
- `timeoutOrElse(eff, ms, orElse)` is `raceFirst(eff, sleep(ms):flatMap(orElse))`.
  `timeout(eff, ms)` is `timeoutOrElse` with an `orElse` that fails with
  `Cause.TimeoutError()`. `raceFirst` matters here. Under `raceAll`, an effect
  that fails before the deadline would be ignored, and the race would wait out
  the sleep.
- `timeoutOption` waits for an Option type: `nil` can't tell a timeout from a
  successful `nil`.

Because the losers are awaited, a timeout returns only after the timed-out
work has finished its cleanup. This matches Effect.

### 8.2 Running effects

- `Effect.runFork(eff, { scheduler = s })` creates a root fiber on `s`, starts
  it on the next tick, and returns it. v4 evaluates the fiber immediately.
  Scheduling the start keeps invariant 1, even when user code calls `runFork`
  from inside a running fiber.
- `Effect.runSyncExit(eff)` returns an Exit argument unchanged, as v4 does.
  Otherwise it runs `eff` on a fresh root fiber with a private synchronous
  scheduler:
  - `schedule` queues tasks, and the runner flushes them, including tasks
    queued while flushing. That covers op-budget yields, forks and resumes.
  - `after` never fires, so any timer makes the effect asynchronous.
  - If the fiber hasn't finished after the flush, the effect was asynchronous.
    v4 returns `Die(AsyncFiberError)` and leaves the fiber alone, since its JS
    timers still fire later. A private scheduler never runs again, so Leffect
    first interrupts the fiber and flushes once more, letting its finalizers
    run. Then it returns `Die(Cause.AsyncFiberError(fiber))`.
- `Effect.runSync(eff)` returns the success value, or throws
  `error(Cause.squash(cause), 0)`: the raw error or defect, as v4 does. The
  traceback stays on the Exit's Die reason (`trace`), so use `runSyncExit` to
  see it.
- Each call gets its own fiber and scheduler, so user code may call `runSync`
  inside a `sync` thunk. Invariant 1 is about the loops the runtime starts.

---

## 9. `gen` on coroutines (M2)

`gen` is built in M2, as CLAUDE.md's milestones say. It is designed here
because it plugs into M1's frames: it only needs steps 2–5 of §13.

### 9.1 API

```lua
local program = Effect.gen(function(run)
  local user = run(getUser(id))
  local posts = run(getPosts(user)) -- helpers may call Leffect.run(eff) too
  return #posts
end)
```

### 9.2 Mechanics

```lua
local MARK = {} -- unique sentinel
local genCoroutines = setmetatable({}, { __mode = "k" })

function Leffect.run(eff)
  if not genCoroutines[coroutine.running()] then
    error("Leffect.run() called outside Effect.gen", 2)
  end
  return coroutine.yield(MARK, eff)
end

evaluate.Gen = function(op, fiber)
  local co = coroutine.create(op.body)
  genCoroutines[co] = true
  local frame = { _op = "Gen", co = co }
  return onSuccess.Gen(frame, Leffect.run, fiber) -- first resume passes `run`
end

onSuccess.Gen = function(frame, value, fiber)
  local co = frame.co
  local ok, a, b = coroutine.resume(co, value)
  if not ok then return Exit.die(a, debug.traceback(co, tostring(a))) end
  if coroutine.status(co) == "dead" then return Exit.succeed(a) end -- returned
  if a ~= MARK then
    return Exit.die("Effect.gen: coroutine yielded without run(); "
      .. "don't call coroutine.yield directly inside gen")
  end
  push(fiber, frame)
  return b -- the effect to run; its result comes back through onSuccess
end
-- No onFailure: a failed or interrupted run() never returns. The frame is
-- skipped and the coroutine abandoned, then garbage collected.
```

### 9.3 Rules

- **`run()` never throws.** If the effect fails or the fiber is interrupted,
  `run()` simply never returns. A user's `pcall` around `run()` only catches
  Lua errors from their own code, never effect failures or interrupts. This is
  the "runtime never throws into user code" rule, and it matches v4, which
  never calls `.return()` on the generator.
- **Cleanup inside gen uses effects** (`ensuring`, `acquireRelease`), never
  `pcall` "finally" patterns, because an abandoned coroutine runs nothing
  further.
- **The loop runs outside gen coroutines.** The coroutine only yields effects
  out. Runtime work therefore never nests inside a resume, which keeps clear
  of Lua's C-stack limit on nested `coroutine.resume` (about 200 levels).
- **`run()` can't cross C boundaries.** Calling `run()` from inside a callback
  invoked by a C function (`table.sort` comparator, `string.gsub` replacer)
  raises "attempt to yield across a C-call boundary", which becomes a defect.
  Document it.
- **`run()` doesn't work inside the user's own coroutines.** The
  `genCoroutines` registry check catches this with a clear error.
- **Errors in the gen body** become `Die`, with a traceback taken from the
  dead coroutine (`debug.traceback(co, msg)` works after an error on 5.4 and
  LuaJIT).

---

## 10. Scheduler

### 10.1 Interface

```lua
---@class Scheduler
---@field schedule fun(self, task: fun())                 -- next tick, FIFO
---@field after fun(self, ms: number, task: fun()): fun() -- returns cancel
---@field now fun(self): number                           -- milliseconds
---@field maxOpsBeforeYield integer?                      -- default 2048
```

Leave priorities out for now (v4 has them). Add them if fairness problems show
up.

### 10.2 Test scheduler

Build this first. `require("leffect.scheduler.test").new(options)`, where
`options` may set `maxOpsBeforeYield` and `maxTasks`.

- A FIFO task queue, and a timer list ordered by `(dueTime, insertionSeq)`. A
  timer's cancel function removes it, and calling it again does nothing.
- `flush()` runs queued tasks until the queue is empty, including tasks
  queued while flushing. It never advances time. It errors after `maxTasks`
  tasks (default 1e6), to catch livelock in tests.
- `advance(ms)` steps through due timers in order: set `now` to each timer's
  due time, fire it, flush, then repeat. It ends with `now = start + ms`.
- `runAll()` alternates flushing and jumping to the next timer until there
  are no tasks and no timers.
- `pendingTasks()` and `pendingTimers()` count what is left, for specs such
  as "the timer was cancelled".
- Test helpers:

  ```lua
  local exit, fiber = scheduler:run(eff) -- fork, runAll, return the exit (nil if unfinished)
  ```

  Plus `scheduler:fork(eff)`, which is `Effect.runFork(eff, { scheduler =
  scheduler })`, for tests that interleave `advance` calls and assertions.

### 10.3 luv adapter (M3, sketched so the interface is validated)

- `schedule`: push onto a queue. If no drain is pending, start a
  `uv.new_idle()` (or a 0 ms timer) that drains the whole queue, including
  tasks added during the drain, then stops itself.
- `after`: `uv.new_timer():start(ms, 0, cb)`. Cancel is `stop()` and
  `close()`, made idempotent.
- `now`: `uv.now()`, which is cached loop time. Call `uv.update_time()` if
  precision matters.
- Neovim: same adapter through `vim.uv`. Effects that call the Neovim API
  must wrap the call in `vim.schedule`, so that belongs in Neovim-specific
  helpers, not the core.

---

## 11. Invariants

Each of these becomes at least one spec.

1. **One loop at a time.** The runtime never starts a run loop while another
   is on the Lua stack. All wakeups go through `scheduler:schedule`. (User
   code that calls `runSync` inside a running effect gets a separate fiber on
   its own scheduler; that is allowed.)
2. **Resume is one-shot** per suspension. Interrupt and resume race through
   the same `s.resumed` flag.
3. **Delivery only while interruptible**, at the points in §7.2.
4. **The skip rule:** while interruptible and interrupted, recovery handlers
   never run. Finalizers and cancelers always run, and always uninterruptibly.
5. **Finalizer and canceler failures add to the cause** and never replace it,
   even when a finalizer function throws.
6. **A canceler runs only if its operation never completed.**
7. **Children first:** a fiber's exit is published only after all its
   non-daemon children have exited.
8. **No throwing into user code.** Lua errors from user code become `Die`
   with a traceback. Effect failures and interrupts never surface as Lua
   errors in user code.
9. **Gen coroutines are never resumed after failure or interrupt** (M2).
10. **`interrupt()` waits:** it returns only after the target has exited,
    including its finalizers.
11. **Observers run exactly once**, with the final exit.
12. **Fairness:** no fiber runs more than `maxOpsBeforeYield` steps without
    yielding.
13. **Effects are values:** the loop never mutates an effect table.

---

## 12. Specs for M1

Write these before the code, in `spec/scheduler_spec.lua`,
`spec/fiber_spec.lua`, `spec/async_spec.lua`, `spec/interrupt_spec.lua`,
`spec/finalizer_spec.lua` and `spec/race_spec.lua`. M0's specs move to the
flat Cause and the `trace` field, and keep passing.

**Test scheduler**
- `flush` runs tasks in FIFO order, including tasks queued while flushing,
  and never advances time.
- Timers fire in `(due, insertion)` order. `advance` sets `now` to each due
  time, and ends at start + ms.
- A cancelled timer never fires and no longer counts as pending.
- `runAll` runs every task and timer. `flush` errors on livelock.

**Basics**
- `runFork` starts the fiber on the next tick, and needs a scheduler.
- `fork` + `join` returns the child's value; a failing child fails the
  joiner.
- `await` returns the exit without failing.
- Observers run exactly once, with the final exit. `addObserver` on a done
  fiber runs at once.
- Two forked fibers interleave under the op budget (each records a trace;
  assert they alternate).
- `runSync` runs forks and joins. On an effect that never completes, it
  returns `Die(AsyncFiberError)` after running the fiber's finalizers.
- `runSync` throws the raw defect; the traceback stays on the Exit.

**Async**
- Synchronous resume during register doesn't suspend, and its canceler never
  runs.
- A duplicate `resume` is ignored.
- `register` throwing becomes a defect, and a later `resume` is ignored.
- A synchronous `resume(nil)` dies with "Not a valid effect: nil" instead of
  hanging.
- A canceler that isn't a function, an Effect or nil is a defect.
- `sleep(100)` completes at virtual time 100, not before.
- `yieldNow` lets another fiber run.

**Interruption**
- Interrupting a sleeping fiber cancels its timer: the timer list is empty
  afterwards.
- A late resume after the interrupt is ignored.
- If the operation resumed before the interrupt's wakeup ran, its canceler
  doesn't run.
- Interrupting before start: the body never runs.
- Self-interrupt (`Effect.interrupt`) runs finalizers and the exit has an
  Interrupt reason. `catchAll` doesn't catch it; `catchCause` does.
- `catchAll` / `catchCause` don't run on an external interrupt while
  interruptible.
- `uninterruptible`: an interrupt during the region is deferred, and
  delivered when the region ends.
- An effect inside an uninterruptible region still completes, then the fiber
  is interrupted.
- `uninterruptibleMask`: `restore(e)` is interruptible; the code around it
  isn't.
- Nested masks: the inner `restore` doesn't make the outer region
  interruptible.
- `interruptible(e)` entered when already interrupted fails immediately.
- An interrupt requested during the fiber's last step, or inside `register`,
  is still delivered.
- `interrupt()` returns only after the target's finalizers finish (check
  ordering with a log). `interruptFork()` returns at once.
- Interrupting an already-done fiber is a no-op and returns at once.
- Two interruptors: the cause contains both fiber IDs.
- Interrupting a fiber that's awaiting another fiber removes its observer:
  the other fiber's observer list shrinks.

**Finalizers**
- `ensuring` runs after success, failure and defects, and keeps the result.
- Finalizers run in reverse order on interrupt.
- A finalizer that fails after a success fails with the finalizer's cause.
  After a failure, the exit has both causes, the original first.
- A finalizer that fails during an interrupt gives an exit with both
  Interrupt and the finalizer's reason.
- A finalizer function that throws keeps the original cause, next to the
  defect.
- A failing canceler adds its cause to the interrupt.
- A finalizer that sleeps isn't cut short by a second interrupt.
- `onInterrupt` runs only if the cause has an Interrupt, and receives the
  interruptor IDs.

**Structured concurrency**
- A parent finishing interrupts its running children, and its exit arrives
  after theirs.
- Daemon children survive the parent.
- Interrupting a parent interrupts its grandchildren.

**race and timeout**
- The winner's value is returned, and the loser's finalizer has run by the
  time `race` returns.
- `race`: an early failure doesn't win. Both fail: the cause contains both.
- `raceFirst`: the first exit wins, even a failure.
- Interrupting a fiber blocked in `race` interrupts both racers.
- `timeout` on a slow effect fails with `TimeoutError` at the deadline, with
  the slow effect's cleanup done.
- `timeout` on a fast effect returns its value and cancels the timer.
- `timeout` on an effect that fails before the deadline fails at once, with
  its own error.
- `timeoutOrElse` runs the fallback at the deadline.

**Stack safety**
- M0's 1e6-op specs keep passing through `runSync`, which now runs them on a
  fiber that yields every 2048 ops.

**For M2 (`gen`)**
- Values flow through `run()`; the return value is the result.
- A failing `run()` never returns: code after it doesn't execute, and a
  `pcall` around it doesn't catch it.
- A Lua error in the body becomes `Die` with a traceback containing the body's
  line number.
- A raw `coroutine.yield` inside gen becomes a defect.
- `Leffect.run` called outside gen raises a clear error.
- An interrupt during `run(sleep(...))` abandons the coroutine and runs the
  `ensuring` added outside.
- A gen body that calls `run()` 1e5 times in a loop doesn't overflow.

---

## 13. Implementation order within M1

1. Cause as a flat list of reasons (Die with `trace`), plus Exit as effects.
   Update M0's specs.
2. The frame protocol: move M0's loop onto dispatch tables and frames (§2.3,
   §3, §5.2). It runs on a fiber with §8.2's synchronous scheduler, so
   `runSync` keeps working.
3. Test scheduler (§10.2), with its own unit specs.
4. Fiber object: `evaluate`, `complete`, observers, `runFork`, `await`,
   `join`.
5. `Async` with suspension and the one-shot resume; `sleep`, `yieldNow`,
   `never`.
6. `interruptUnsafe`, `pendingInterrupt`, the skip rule, `AsyncCancel`.
7. `Restore`, `uninterruptible`, `interruptible`, `uninterruptibleMask`.
8. `OnExit`, `FinalizerResult`, `ensuring`, `onInterrupt`.
9. `fork`/`forkDaemon`, children shutdown, `interrupt`, `interruptFork`,
   `interruptAll`.
10. `raceAll`, `race`, `raceFirst`, `timeoutOrElse`, `timeout`.
11. Op-budget yielding and the fairness spec.

`gen` comes in M2. It only needs steps 2–5.

---

## 14. Deviations from Effect v4, and why

| Topic | v4 | Leffect | Reason |
|-------|----|---------|--------|
| Wakeups | `resume` and interrupt call `fiber.evaluate` synchronously; a loop counter detects takeover by a re-entrant loop | Always `scheduler:schedule` | Simpler re-entrancy, deterministic tests, no C-stack growth through nested coroutine resumes. Costs about one tick of latency per async resume, and an interrupt that arrives in that tick wins. Revisit with a benchmark; a safe optimization is to evaluate immediately when no loop is on the stack. |
| Running-fiber interrupt | Restarts the loop through `evaluate` | `pendingInterrupt`, checked at each loop step | Follows from the row above. One boolean check per step. |
| Resume racing an interrupt | Can't happen: resume is synchronous | `s.completed` keeps the canceler from running on an operation that already completed | Follows from the first row. |
| Canceler type | `Effect` (or an `AbortSignal`) | Function, Effect, or nil | Lua has no AbortSignal; plain functions are the common case. |
| Finalizer and canceler failures | `onExitPrimitive` and `asyncFinalizer` flatMap the finalizer, so its failure replaces the cause | Added to the cause through `FinalizerResult`, even when a finalizer function throws | CLAUDE.md: finalizer errors are added to the Cause. |
| Invalid effect | The loop returns `Die` at once, skipping the remaining frames | The Die unwinds through the frames | Finalizers still run (an M0 decision). |
| Op dispatch | Symbol-keyed functions on each primitive | Private tables keyed by `_op`, and one shared metatable | Lua has no symbols; this keeps the protocol out of the user method namespace. |
| Children shutdown | An `interruptChildren` middleware wraps the exit | Same idea, run explicitly uninterruptibly, in fork order | Spelled out so an interrupt during shutdown can't strand children. |
| `runFork` start | Evaluates the fiber immediately | Starts it on the next tick | The wakeup rule, and deterministic tests. |
| Unfinished `runSync` | Returns `Die(AsyncFiberError)` and leaves the fiber running | Interrupts the fiber and flushes again first, then returns the same Die | A private sync scheduler never runs again, so the fiber's finalizers would never run. |

Everything else follows v4: frames, `onPop`/`contAll`, the skip rule, restore
frames, async cancel frames, abandoning generators, the flat Cause and its
`combine`, `onInterrupt`'s condition, `race` and `timeout`, and the 2048-op
budget.

---

## 15. Open questions

- **Unhandled failures in daemon fibers:** log them, or stay silent? Logging
  waits for the M3 logger; until then, the exit stays on the fiber.
- **Ending on an interrupt cause:** should `runFork`'s top-level observer
  report a process exit whose cause is interrupts-only differently from other
  failures? Effect treats it as non-error in some runners.
- **Immediate start:** v4's `startImmediately` for forks, and its immediate
  `runFork`, save a tick. They are safe under invariant 1 only when no loop is
  running. Skip them until a benchmark asks for them.
- **Fiber-aware tracebacks:** M1 gives Lua tracebacks for defects only.
  Annotating causes with the fork site or span is M3 work.
- **Coroutine cleanup (M2):** whether to `coroutine.close` abandoned gen
  coroutines on 5.4. It isn't needed for correctness (no `<close>` variables in
  the common subset). Leave it out unless memory profiling says otherwise.

---

## 16. What the review changed (2026-11-25)

The first draft was checked against v4's source (`effect-smol` `main` @
`3a1128c`). Line numbers below are in `internal/effect.ts` at that commit.

**Bugs fixed**

1. `timeout` raced on `raceAll`, so an effect that failed before the deadline
   was ignored until the sleep won. It now uses `raceFirst`, like v4's
   `timeoutOrElse` (3617–3644), and fails with `TimeoutError`, like v4's
   `timeout` (3647–3667). `timeoutOption` waits for an Option type (§8.1).
2. `raceAll` waited inside `uninterruptibleMask` without `restore`, so the
   racing fiber couldn't be interrupted until a racer finished. It now has
   v4's shape: an interruptible wait whose canceler interrupts the racers
   (1423–1478).
3. A canceler could run after its operation completed: `resume` queued the
   wakeup, and an interrupt arrived before it ran. `s.completed` now guards
   the canceler (§6.2, §6.3).
4. A finalizer function that threw lost the original exit. `FinalizerResult`
   is now pushed before the function is called (§7.5).
5. `cur:evaluate(self)` on a non-effect raised a plain Lua error, which broke
   M0's "Not a valid effect" specs. Any table with an `evaluate` field would
   also have run. The loop now checks for an effect before dispatching, and
   dispatches through private tables (§2.3, §5.2).
6. `runSync`, `runSyncExit` and `runFork` weren't specified (§8.2).
7. A `pendingInterrupt` set during a step that then suspended the fiber, or
   during its last step, was never delivered (§5.1, §5.2).
8. A synchronous `resume(nil)` suspended the fiber forever (§6.2).
9. On LuaJIT, `debug.traceback(nil, level)` returns `nil`, so thrown tables
   would have had no trace (§5.2).
10. The op count reset when the loop restarted after a defect, so a fiber
    that kept failing could dodge the op budget. It now lives on the fiber.

**Brought in line with v4**

11. `Cause.combine` dedupes, as `causeCombine` does (243–259).
12. `onInterrupt` runs when the cause has any Interrupt reason, and gets the
    interruptor IDs (4089–4103).
13. §14 now lists the finalizer deviation: in v4 a failing finalizer replaces
    the cause (3924–3933).

**Decisions taken on the user's behalf**

14. The doc's name is `FIBER-DESIGN.md`; CLAUDE.md now points here.
15. `gen` stays in M2, as CLAUDE.md's milestones say (§9).
16. `runSync` throws the raw error or defect, as v4 does; the traceback stays
    on the Exit (§8.2).
17. An unfinished `runSync` interrupts its fiber so that finalizers run, then
    returns `Die(AsyncFiberError)` (§8.2, §14).
18. Children are interrupted in fork order, and cancelers' failures combine
    like finalizers' (§5.1, §6.3).
