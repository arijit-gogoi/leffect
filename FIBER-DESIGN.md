
# Leffect: fiber and interruption design

Status: settled for Milestone M1 on 2026-11-25, and re-pinned the same day.
The M2 design (Part II, §18–§25) was drafted and approved on 2026-11-25,
and M2 was built the same day, the items below the cut line included.

**Reference:** Effect 4.1.5, which is the `effect@4.1.5` tag of
`Effect-TS/effect` (commit `e3aca1f`). The files are
`packages/effect/src/internal/effect.ts` and `internal/core.ts`, notably
`FiberImpl`, `exitFailCause`, `callbackOptions`, `setInterruptible`,
`OnExitImpl`, `forkUnsafe`, `raceAll`, `raceFirst` and `runSyncExitWith`.

**History:** M1 was first designed against `effect-smol` @ `3a1128c`
(4.0.0-beta.98), then adapted to Lua.
- §16 lists what the review of that draft changed.
- §17 lists what the re-pin to 4.1.5 changed.

Both list the decisions taken on the user's behalf.

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
  unwinding, and the cause that unwinds records the interrupt. Finalizer
  frames switch the fiber to uninterruptible when popped, so they always run.
- **A cause with a defect is not recoverable** (4.1.5). When a cause holds both
  Fail and Die reasons, combining elects the Fails to Dies, and `catchAll`
  only recovers causes without a Die (§2.1).
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
  thrown into (§9).
- **M2 adds a minimal fiber context, Scope and bounded concurrency.**
  - The context holds the current Scope until M3 brings Context and Layer
    (§18).
  - A Scope runs its finalizers in reverse order (§19).
  - `acquireRelease` registers the release before an interrupt can land (§20).
  - `forEach` and `all` run under a concurrency limit and keep input order
    (§22).

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

**Goals for M2:**
- `gen`;
- `catchIf`, `catchTag`, `catchTags` and `Effect.exit`;
- a minimal fiber context;
- Scope, with `scoped`, `addFinalizer`, `forkIn` and `forkScoped`;
- `acquireRelease` and `acquireUseRelease`;
- `forEach` and `all` with concurrency limits;
- the re-pin's changes to M1 semantics (§17).

`race` was done in M1. v4's `raceAll` has no concurrency option, so the limits
in CLAUDE.md's M2 line apply to `forEach` and `all`.

**Non-goals for M2:**
- Context, Tag, Layer and FiberRef (M3);
- a Result type, so `all` has no `mode: "result"`;
- `Effect.fn`;
- v4's `catchReason` and `catchReasons`;
- the `match` family;
- structural equality.

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
- `Cause.empty` has no reasons.
- `Cause.combine(a, b)`:
  - If either cause is empty, the other comes back unchanged.
  - Otherwise the result is `a`'s reasons followed by `b`'s, keeping only the
    first of each set of equal reasons. Two reasons are equal when they are
    the same table, or have the same `_tag` and raw-equal (`==`) payloads.
  - This is 4.1.5's `causeCombine`, which dedupes the concatenation under
    `Equal`. M1 compared `b`'s reasons only against `a`'s.
- `Cause.fromReasons(list)` keeps every reason, duplicates included, like v4's
  `causeFromReasons` (used by `raceAll`).
- `Cause.electDefects(c)` is 4.1.5's `causeElectDefects`:
  - If `c` has both Fail and Die reasons, each Fail becomes a Die in place.
    The new Die's `defect` is the error, and it has no `trace`.
  - Otherwise `c` comes back unchanged.
  - It applies when a finalizer's or a canceler's cause is combined into a
    failure (§7.5), to `raceAll`'s all-failed cause (§8.1), and in M2 to
    `forEach` (§22).
- `Cause.findRecoverableError(c)` is 4.1.5's `findRecoverableError`. A cause
  with a defect is not recoverable.
  - It returns `true, error` for the first Fail, when `c` has no Die.
  - Otherwise it returns `false, rethrow`, where `rethrow` is
    `electDefects(c)` if `c` has a Die, else `c`.
  - `catchAll` uses it, and so do M2's typed catches (§21).
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
`AsyncCancel`, `FinalizerResult`, and in M2 `Gen` and `SetContext`) are plain
tables with a private `_op`; they are never evaluated as effects. Ops with per-run state
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
  if cancel then push(fiber, { _op = "AsyncCancel", cancel = cancel, suspension = s }) end
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
  if frame.suspension.completed or not Cause.hasInterrupts(cause) then
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
  local cause = Cause.interrupt(byId) -- 4.1.5 adds it with causeAddInterrupts
  self.interruptCause = self.interruptCause
    and Cause.addInterrupts(self.interruptCause, cause) or cause
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
- A failing finalizer adds its cause and never replaces the original.
  - `FinalizerResult` fails with `electDefects(combine(original, c2))`.
  - If the body succeeded and the finalizer failed, the result is the
    finalizer's cause, unchanged.
  - 4.1.5 does the same (`combineFinalizerCause`); beta.98 replaced the cause.
  - With §5.3, a Fail added during an interrupt is dropped later if a recovery
    handler is skipped.

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
-- uninterruptible: true, false (the default) or, from M2, "inherit"
function forkUnsafe(parent, eff, daemon, uninterruptible)
  local interruptible
  if uninterruptible == "inherit" then
    interruptible = parent.interruptible
  else
    interruptible = not uninterruptible
  end
  local child = Fiber.new(parent.scheduler, interruptible)
  child.context = parent.context -- M2: children see the parent's services (§18)
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
  `forkUnsafe`, whose `uninterruptible` option defaults to false. In M2,
  `"inherit"` copies the parent's state; `forEach` workers use it (§22).
- `Effect.fork(eff)` attaches the child to the current fiber and starts it on
  the next tick.
- `forkDaemon` doesn't attach it.
- `forkIn` and `forkScoped` tie it to a Scope instead (M2, §20.3).
- `fiber:await()` is `async(function(resume) ... end)`: if the fiber is
  already done, resume immediately. Otherwise `addObserver(resume ∘ succeed)`
  and return the observer-removal function as the canceler, so interrupting an
  awaiter unregisters it.
- `fiber:join()` is the same with `addObserver(resume)`. The child's exit is
  an effect, so a child's failure fails the joiner, and a child's interrupt
  cause too. This is catchable by the joiner, because the joiner itself wasn't
  interrupted.
- `Fiber.awaitAll(fibers)` waits for every fiber and succeeds with their
  exits, in order, as v4's does. It is public from M2, which uses it for the
  parallel scope strategy (§19.3). `Fiber.interruptAll` succeeds with nil.
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
      --     resume(failCause(Cause.electDefects(Cause.fromReasons(reasons))))
      return suspend(function() return interruptAll(stillRunning()) end) -- canceler
    end)
  end)
end
```

- The wait is interruptible. If the racing fiber is interrupted, the canceler
  interrupts every racer still running, and waits for them.
- Losers are interrupted and awaited, uninterruptibly, before the race
  returns.
- When every racer fails, the cause keeps all their reasons in order,
  duplicates included, with defects elected (4.1.5). So a racer that fails and
  a racer that dies give two Dies.
- 4.1.5 restructured `raceAll`. Losers are interrupted as soon as the race is
  won, and an exit frame on the racing fiber awaits them. What you can observe
  is the same as M1: the losers are awaited before the race returns. So M1's
  structure stays.
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

`Leffect.run` is `require("leffect").run`: the same function the body gets as
`run`. `Effect.gen(body)` builds `{ _op = "Gen", body = body }`, and `core`
gets `OP_GEN`.

### 9.2 Mechanics

```lua
local MARK = {} -- unique sentinel
local genCoroutines = setmetatable({}, { __mode = "k" })

local function run(eff) -- exported as Leffect.run
  if not genCoroutines[coroutine.running()] then
    error("Leffect.run() called outside Effect.gen", 2)
  end
  return coroutine.yield(MARK, eff)
end

evaluate.Gen = function(op, fiber)
  local co = coroutine.create(op.body) -- a fresh coroutine on every run
  genCoroutines[co] = true
  local frame = { _op = "Gen", co = co }
  return onSuccess.Gen(frame, run, fiber) -- the first resume passes `run`
end

onSuccess.Gen = function(frame, value, fiber)
  local co = frame.co
  local ok, a, b = coroutine.resume(co, value)
  if not ok then
    -- traceback(co, msg) reads the dead coroutine's stack on 5.4 and LuaJIT
    -- (checked on both). Give it a string, as captureDefect does (§5.2).
    local trace
    if type(a) == "string" then
      trace = debug.traceback(co, a)
    else
      trace = debug.traceback(co, ""):sub(2) -- drop the leading newline
    end
    return Exit.die(a, trace) -- the defect stays the raw error
  end
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
- **Errors in the gen body** become a `Die` holding the raw error, with a
  traceback taken from the dead coroutine.
  - `debug.traceback(co, msg)` after an error includes the body's line on 5.4
    and on LuaJIT. Both were checked on 2026-11-25.
  - A string message comes back prefixed to the trace; `""` gives a leading
    newline.
- **Each run starts a fresh coroutine**, so one gen effect can run many times,
  concurrently (invariant 13).
- **The body's first return value is the result.** Returning an effect returns
  it as a plain value, without running it, as v4 does.
- **`run(x)` with a non-effect** dies with "Not a valid effect", like any
  other instruction (§5.2). The Gen frame is already pushed, so the Die
  unwinds through it and the coroutine is abandoned.

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
   never run, and the cause that unwinds carries the fiber's interrupts.
   Finalizers and cancelers always run, and always uninterruptibly.
5. **Finalizer and canceler failures add to the cause** and never replace it,
   even when a finalizer function throws. Defects are elected when the result
   holds both Fail and Die reasons. A Fail added during an interrupt is
   dropped if a recovery handler is skipped later (§5.3, decision 19).
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
14. **A cause with a Die is never recovered** by `catchAll`, nor by M2's typed
    catches (4.1.5).
15. **Context changes are undone on every exit path** (M2). `SetContext`
    frames restore the context in `onPop`, which runs even for skipped frames
    (§18).
16. **A Scope runs each finalizer once** (M2): newest first, uninterruptibly,
    and a failing finalizer doesn't stop the rest (§19).
17. **`acquireRelease` registers the release exactly when acquire succeeds**
    (M2), before any interrupt can be delivered (§20).
18. **`forEach` keeps input order** (M2). It never runs more than
    `concurrency` items at once, and it returns only after every worker it
    started has exited (§22).

---

## 12. Specs for M1

Write these before the code, in `spec/scheduler_spec.lua`,
`spec/fiber_spec.lua`, `spec/async_spec.lua`, `spec/interrupt_spec.lua`,
`spec/finalizer_spec.lua` and `spec/race_spec.lua`. M0's specs move to the
flat Cause and the `trace` field, and keep passing. The re-pin to 4.1.5 changes
some outcomes; §17 lists the specs it adds and amends.

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

**For M2**: the `gen` specs moved to §23.

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
| Invalid effect | The loop returns `Die` at once, skipping the remaining frames | The Die unwinds through the frames | Finalizers still run (an M0 decision). |
| Op dispatch | Symbol-keyed functions on each primitive | Private tables keyed by `_op`, and one shared metatable | Lua has no symbols; this keeps the protocol out of the user method namespace. |
| Children shutdown | An `interruptChildren` middleware wraps the exit | Same idea, run explicitly uninterruptibly, in fork order | Spelled out so an interrupt during shutdown can't strand children. |
| `runFork` start | Evaluates the fiber immediately | Starts it on the next tick | The wakeup rule, and deterministic tests. |
| Unfinished `runSync` | Returns `Die(AsyncFiberError)` and leaves the fiber running | Interrupts the fiber and flushes again first, then returns the same Die | A private sync scheduler never runs again, so the fiber's finalizers would never run. |
| `gen` (M2) | `yield*` inside a generator | `run(eff)` inside a coroutine; helpers call `Leffect.run` | Lua has no generators (§9). |
| `catchAll` name (M2) | Renamed `catch` | Keeps M0's `catchAll` | CLAUDE.md's M0 API. |
| Context (M2) | A `Context` of services, with Tags and Layers | A string-keyed table that holds only the Scope until M3 | M3 owns Context, Tag and Layer (§18). |
| Release context (M2) | `release` runs with the context captured at acquire | It runs with the closing fiber's context | The context holds only the Scope in M2; revisit in M3 (§15). |
| Finalizer callbacks (M2) | `release` and `addFinalizer`'s function return an Effect | They may also return nil | Matches `onExit` (§7.5). |
| `forkIn` options (M2) | `startImmediately`, `uninterruptible` | None | Forks start on the next tick (first row); M1's `fork` takes no options either. |
| Indexes (M2) | `f(a, i)` with `i` from 0 | `i` from 1 | Lua convention. |
| Result lists (M2) | Arrays | Lists with a field `n`, like `table.pack` | Results can be nil, and `#` can't count past a hole. |
| `all` input (M2) | An iterable or a record, told apart by type; a record runs in insertion order | Told apart by keys; a record runs in sorted key order (§22.3) | A Lua table is both. `pairs` order is unspecified, and differs between runtimes. |
| `all` options (M2) | `mode`, `"default"` or `"result"` | No `mode` | No Result type yet (§15). |
| Concurrent `forEach` items that are Exits (M2) | Handled inline: a success costs no fork and no tick, and a failure stops the run before `f` is called on any later item | Every item gets a worker. With `concurrency = 3` and `f(1)` returning `Effect.fail(x)`, `f(2)` and `f(3)` are still called; their workers are interrupted before they start | One launch path, as §22.2 describes. The inline path is an optimization to add later (§15). |

Everything else follows 4.1.5:
- frames and `onPop`/`contAll`;
- the skip rule, including how it handles interrupts and Fails;
- restore frames and async cancel frames;
- abandoning generators;
- the flat Cause, its `combine` and defect election;
- finalizer and canceler failures combined into the cause (beta.98 replaced
  the cause; that was a deviation until the re-pin, §17);
- `onInterrupt`'s condition;
- `race` and `timeout`;
- the 2048-op budget;
- in M2: Scope's states and close order, `scoped`, `acquireRelease`,
  `acquireUseRelease`, `forkIn`, the typed catches, and how `forEach` handles
  failures.

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
- **Release context (M3):** run `release` with the context captured at
  acquire, as v4 does, once the context holds more than the Scope.
- **A Result type:** it would give `all` its `mode: "result"`, plus
  `Effect.result`.
- **A loop op for `forEach`:** v4 uses a `While` primitive. The `flatMap`
  chain of §22.2 is stack-safe, but allocates a frame and a closure per item.
  Add the op only if a benchmark asks for it.
- **Inline Exits in concurrent `forEach`:** v4 handles an item whose effect is
  already an Exit without forking it (§14). Adding that would save a fork and
  a tick per such item, and stop calling `f` after a failing one.
- **Structural equality:** `combine` dedupes with `==`. Structural dedupe
  waits for Equal/Hash ("Later" in CLAUDE.md).

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

---

## 17. What the re-pin to 4.1.5 changed (2026-11-25)

The user chose to re-pin the reference from `effect-smol` beta.98 to Effect
4.1.5. These changes between the two versions touch M1's semantics. Each one
comes with M1's observed output, from scripts run on Lua 5.4 and LuaJIT at
commit `30f4563`.

1. **Defect election** (§2.1, §7.5).
   - Example: `fail("e"):ensuring(die("d")):catchAll(h)`.
   - M1 runs `h` and ends with `Success(caught e)`, so the defect is lost
     without a trace.
   - 4.1.5 fails with `[Die(e), Die(d)]`, and `h` never runs.
2. **The skip rule records the interrupt** (§5.3). It appends only the
   missing Interrupt reasons (`causeAddInterrupts`), and touches nothing else.
   - Example: a fiber interrupted inside
     `uninterruptible(sleep(10):flatMap(→ fail("x")))`.
   - M1 ends with `[Fail(x)]`, so the interrupt is lost.
   - 4.1.5 ends with `[Fail(x), Interrupt]`.
3. **The skip rule drops Fails when it skips a recovery handler** (§5.3).
   - Change 2's example under a `catchAll`: M1 ends with `[Fail(x)]`, 4.1.5
     with `[Interrupt]`.
   - `never:ensuring(fail("cleanup")):catchAll(h)`, interrupted: M1 ends with
     `[Interrupt, Fail(cleanup)]`, 4.1.5 with `[Interrupt]`.
   - Without the `catchAll`, both give `[Interrupt, Fail(cleanup)]`.
4. **`combine` dedupes the whole concatenation** (§2.1). M1 compared only
   `b`'s reasons against `a`'s.
5. **`raceAll`'s all-failed cause elects defects** (§8.1).
6. **Finalizer and canceler failures.** 4.1.5 now combines them with the
   original cause, as M1 already did. §14 drops that row.

These are unchanged between beta.98 and 4.1.5, so M1 still matches them:
- interruptibility masks;
- `timeout` and `timeoutOrElse`;
- `onInterrupt`;
- the async resume and cancel protocol;
- `runSyncExit`;
- children shutdown;
- the op budget.

**Specs for the re-pin.** These amend `spec/cause_spec.lua`,
`effect_spec.lua`, `finalizer_spec.lua`, `interrupt_spec.lua` and
`race_spec.lua`.
- `electDefects`:
  - Fail and Die together become all Dies, in place.
  - A cause with only Fails, only Dies, or only interrupts comes back
    unchanged.
- `findRecoverableError`:
  - With no Die, it returns the first error.
  - With a Die, it returns `false` and the elected cause.
  - With neither a Fail nor a Die, it returns `false` and the cause.
- When both causes are non-empty, `combine` also drops repeats within `a`.
- `addInterrupts` appends only the Interrupt reasons whose `fiberId` is
  missing. It keeps every other reason as it is, duplicates included.
- `fail(e):ensuring(die(d)):catchAll(h)`: `h` doesn't run, and the exit is
  `[Die(e), Die(d)]`.
- A finalizer that fails after a failure keeps both Fails. One that dies after
  a failure elects the Fail.
- `raceAll` with one racer that fails and one that dies fails with two Dies.
- Interrupted inside `uninterruptible(...)`, which then fails: the exit has
  the failure and the Interrupt.
- The same under a `catchAll`: the handler doesn't run, and the exit is the
  Interrupt alone.
- `never:ensuring(fail("cleanup")):catchAll(h)`, interrupted:
  - the exit is the Interrupt alone;
  - without the `catchAll`, it is `[Interrupt, Fail(cleanup)]`.
- A finalizer that dies during an interrupt keeps its Die, even when a
  `catchAll` is skipped.

**Decisions taken on the user's behalf**

19. **Dropping Fails (change 3) follows 4.1.5.** A finalizer's Fail during an
    interrupt is lost if a recovery handler is skipped later. Dies are always
    kept. The user confirmed this on 2026-11-25, over keeping the Fails as a
    deviation. CLAUDE.md's rule that "finalizer errors are added to the
    Cause" now names this exception.
20. **The pin is the release tag** (`e3aca1f`), not `main` (`296c209` on
    2026-11-24). `main` changes `forkUnsafe` and `catchReasons` after the
    release, and neither affects Leffect.

---

# Part II: M2

Part II designs M2 on top of Part I's frames and fibers. It follows 4.1.5. §14
lists the deviations, and §25 the decisions taken on the user's behalf.

## 18. Fiber context

v4 keeps a fiber's services in `fiber.context`. A fork starts with its
parent's context, and `scoped` puts its Scope there. Context, Tag and Layer
are M3. M2 needs only the current Scope, so it adds the field and the frame
that restores it, but no public Context API.

- **The table.** `fiber.context` is an immutable table of services keyed by
  strings, like v4's service keys. M2 uses one key, `"leffect/Scope"`.
  - Adding a service copies the table; nothing mutates a context.
  - The internal module `leffect.context` has `empty`,
    `add(ctx, key, value)`, `get(ctx, key)`, and
    `provide(key, value, eff)`, which is `provideService` below.
- **Inheritance.** Root fibers start with `empty`. `forkUnsafe` hands the
  child the parent's table (§8), so every fork, daemon or not, sees the
  parent's Scope.
- **The `SetContext` frame**, `{ _op = "SetContext", context = prev }`, puts
  `prev` back in its `onPop`.
  - It has no handlers, so it is transparent on both paths.
  - `onPop` runs for every popped frame, skipped or not, so the context comes
    back on every exit path (invariant 15).

Push the frame and change the context in the same `withFiber` step:

```lua
local function provideService(key, value, eff)
  return withFiber(function(fiber)
    local prev = fiber.context
    push(fiber, { _op = "SetContext", context = prev })
    fiber.context = Context.add(prev, key, value)
    return eff
  end)
end
```

Building the restore as an effect instead, as in `onExit(eff, restore)`, opens
a gap:
- It leaves a loop step between `withFiber` and the frame's push.
- A pending interrupt replaces the current effect at that step (§5.2 (a)).
- The frame is then never pushed, and the changed context leaks into the outer
  continuation.

v4 closes the same gap with `onExitUnsafe`, which pushes onto the stack
directly.

## 19. Scope

A Scope collects finalizers and runs them when it closes. This follows v4's
`Scope` module. The public module is `leffect.scope`, exported as `Scope`.

### 19.1 Data

```lua
---@class Scope
---@field strategy "sequential"|"parallel"
---@field parent Scope?   -- set for a scope made by Scope.fork
---@field state "open"|"closed"
---@field exit Exit?      -- the exit it was closed with
-- and an ordered set of finalizers fn(exit) -> Effect?, each under a key
```

- **Keys** are tables: a fresh `{}` for `addFinalizer`, the child scope for
  `Scope.fork`, and the fiber for `forkIn`. A key lets the owner remove its
  finalizer early.
- **Adding** appends.
- **Removing** is O(1) and leaves a hole, which closing skips. Compact the list
  when holes outnumber entries. Removing from a closed scope does nothing:
  a `forkIn` fiber that its scope's close interrupts removes itself from a
  scope that is already closed.

### 19.2 API

| Function | Semantics |
|---|---|
| `Scope.make(strategy?)` | Effect: a new open scope. `strategy` defaults to `"sequential"`. |
| `Scope.makeUnsafe(strategy?)` | The same, outside an effect. |
| `Scope.addFinalizerExit(scope, f)` | Effect: add `f(exit)`. On a closed scope, run `f(scope.exit)` at once instead. |
| `Scope.addFinalizer(scope, eff)` | `addFinalizerExit` with a finalizer that ignores the exit. |
| `Scope.close(scope, exit)` | Effect: close `scope` with `exit`, uninterruptibly (§19.3). A closed scope stays as it is. |
| `Scope.closeUnsafe(scope, exit)` | Close `scope` outside an effect, and return the effect that runs its finalizers, or nil (§19.3). Public in v4 too. |
| `Scope.fork(scope, strategy?)` | Effect: a child scope that closes when `scope` closes. Forking a closed scope gives a closed child with the same exit. |
| `Scope.forkUnsafe(scope, strategy?)` | The same, outside an effect. Public in v4 too. |
| `Scope.addFinalizerUnsafe(scope, key, f)`, `Scope.removeFinalizerUnsafe(scope, key)` | Add or remove a keyed finalizer, outside an effect (§19.1). Internal in v4; public here because `leffect.effect` needs them for `forkIn`. |
| `Scope.contextKey` | `"leffect/Scope"`, the context key of the current scope, until M3's Tags. |
| `Scope.provide(eff, scope)` | Runs `eff` with `scope` as the current scope, without closing it. |
| `Scope.use(eff, scope)` | `provide`, then close `scope` with `eff`'s exit. Below the cut line (§24). |
| `Effect.scope` | Effect: the current scope. Without one, it dies with "Effect.scope: no Scope in context; wrap the effect in Effect.scoped". |
| `Effect.scoped(eff)` | Runs `eff` with a fresh current scope, then closes it with `eff`'s exit (§19.4). Also a method. |
| `Effect.scopedWith(f)` | Runs `f(scope)` with a fresh scope passed as an argument, not put in the context, then closes it. Below the cut line. |
| `Effect.addFinalizer(f)` | Adds `f(exit)` to the current scope (§20.3). |

### 19.3 Closing

```lua
function Scope.close(scope, exit)
  return withFiber(function(fiber)
    enterUninterruptible(fiber) -- pushes Restore(true) if interruptible
    return closeUnsafe(scope, exit) or Exit.void
  end)
end

-- Returns the effect that runs the finalizers, or nil if there are none.
local function closeUnsafe(scope, exit)
  if scope.state == "closed" then return nil end
  scope.state, scope.exit = "closed", exit
  if scope.parent then removeFinalizer(scope.parent, scope) end
  local finalizers = newestFirst(scope)
  if #finalizers == 0 then return nil end
  if scope.strategy == "sequential" then
    return runInTurn(finalizers, exit)
  end
  return runTogether(finalizers, exit) -- "parallel"
end
```

- **Order.** Finalizers run newest first, and each gets the close exit.
- **Isolation.** Each finalizer runs as `Effect.exit(suspend(→ f(exit) or
  void))`. A failure or a throw doesn't stop the next one, and a throw becomes
  a Die with a traceback (§5.2).
- **Result.** The close fails with every finalizer's reasons, in run order and
  duplicates included, or else succeeds. This is v4's `exitAsVoidAll`.
- **Stack.** `runInTurn` is a `flatMap` chain, like §22.2's, so a scope with
  many finalizers doesn't grow the stack.
- **`runTogether`** (below the cut line):
  - It forks each finalizer on the closing fiber, as a daemon that inherits
    the closing fiber's interruptibility, so the forks are uninterruptible.
  - It awaits them all, and combines their exits in fork order.
  - It skips the finalizer whose key is the closing fiber. That is the fiber's
    own `forkIn` finalizer, which would wait for the closing fiber and
    deadlock. v4 skips it too.

### 19.4 `scoped`

```lua
function Effect.scoped(eff)
  return withFiber(function(fiber)
    local prev = fiber.context
    local scope = Scope.makeUnsafe()
    push(fiber, { _op = "OnExit", f = function(exit) return closeUnsafe(scope, exit) end })
    push(fiber, { _op = "SetContext", context = prev })
    fiber.context = Context.add(prev, "leffect/Scope", scope)
    return eff
  end)
end
```

- Both frames are pushed directly, for the reason §18 gives.
- Unwinding pops `SetContext` first, so the finalizers run in the outer
  context. v4's `scoped` likewise restores the context, then closes.
- The `OnExit` frame runs the close uninterruptibly, and adds its failure to
  the exit (§7.5).
- `Scope.provide(eff, scope)` is §18's `provideService` with the Scope key.
- `scopedWith(f)` is `suspend(→ onExit(f(scope), → closeUnsafe(scope, exit)))`
  on a fresh scope. It leaves the context alone, so its frame can be an
  ordinary effect: if an interrupt lands first, the scope is still empty.
- `Scope.use(eff, scope)` is
  `onExit(Scope.provide(eff, scope), → closeUnsafe(scope, exit))`.

## 20. Resources

### 20.1 `acquireRelease`

```lua
function Effect.acquireRelease(acquire, release, options)
  return uninterruptibleMask(function(restore)
    return Effect.scope:flatMap(function(scope)
      local run = acquire
      if options and options.interruptible then run = restore(acquire) end
      return run:flatMap(function(a)
        return Scope.addFinalizerExit(scope, function(exit)
          return release(a, exit)
        end):as(a)
      end)
    end)
  end)
end
```

- The scope is looked up before acquire runs. Without one, nothing is
  acquired.
- **Interrupt during acquire** (CLAUDE.md's example):
  - acquire runs uninterruptibly, and the release is added before the mask
    ends.
  - The interrupt is delivered when the mask ends.
  - The scope then closes, and the release runs.
- `{ interruptible = true }` runs acquire under `restore`. An interrupt can
  then stop it, and there is nothing to release.
- If acquire fails, no release is added.
- The release gets the resource and the scope's close exit. It runs
  uninterruptibly (§19.3), and its failure is added to the cause through the
  `OnExit` of `scoped` (§7.5).
- v4 also runs the release with the context captured at acquire. In M2 the
  context holds only the Scope, so that waits for M3 (§15).

### 20.2 `acquireUseRelease`

```lua
function Effect.acquireUseRelease(acquire, use, release)
  return uninterruptibleMask(function(restore)
    return acquire:flatMap(function(a)
      return Effect.suspend(function() return restore(use(a)) end)
        :onExit(function(exit) return release(a, exit) end)
    end)
  end)
end
```

This needs no Scope:
- acquire runs uninterruptibly;
- `use` runs as interruptibly as the caller;
- the release always runs, and its failure is added to the cause.

### 20.3 `addFinalizer`, `forkIn` and `forkScoped`

- `Effect.addFinalizer(f)` is
  `Effect.scope:flatMap(→ Scope.addFinalizerExit(scope, f))`.
- `Effect.forkIn(eff, scope)` forks `eff` as a daemon, tied to `scope`.
  - Closing the scope interrupts the fiber and waits for it.
  - A fiber that finishes first removes its finalizer.
  - On a closed scope, the fiber is interrupted before it starts, so it runs
    none of `eff` (§7.2).

  ```lua
  function Effect.forkIn(eff, scope)
    return withFiber(function(parent)
      local fiber = Fiber.forkUnsafe(parent, eff, true) -- a daemon
      if scope.state == "closed" then
        fiber:interruptUnsafe(parent.id)
      else
        addFinalizerUnsafe(scope, fiber, function()
          return withFiber(function(current)
            if current == fiber then return Exit.void end -- closing itself
            return fiber:interrupt()
          end)
        end)
        fiber:addObserver(function() removeFinalizer(scope, fiber) end)
      end
      return Exit.succeed(fiber)
    end)
  end
  ```

- `Effect.forkScoped(eff)` is `Effect.scope:flatMap(→ forkIn(eff, scope))`.
- Both are also methods. Unlike v4's, they take no options (§14).
- For a closed scope, v4 creates the fiber unstarted and interrupts it at
  once. Leffect starts every fork on the next tick, and an interrupt requested
  before then is delivered at the fiber's first step.

## 21. Typed error recovery and `Effect.exit`

Expected failures are tagged tables (CLAUDE.md). These functions recover them
by tag or by predicate. All of them go through `Cause.findRecoverableError`
(§2.1), so they never recover a cause that holds a Die, and they never see
interrupts.

```lua
function Effect.catchIf(self, predicate, f, orElse)
  return catchCause(self, function(cause)
    local found, value = Cause.findRecoverableError(cause)
    if not found then return Exit.failCause(value) end -- the cause to rethrow
    if predicate(value) then return f(value) end
    if orElse then return orElse(value) end
    return Exit.failCause(cause)
  end)
end
```

| Function | Recovers |
|---|---|
| `catchAll(self, f)` | Any recoverable error: `catchIf` with a predicate that is always true. v4 calls it `catch`. |
| `catchIf(self, predicate, f, orElse?)` | Errors for which `predicate(err)` is true. Other errors go to `orElse(err)` if it is given, and otherwise keep failing. |
| `catchTag(self, tag, f, orElse?)` | Errors whose `_tag` is `tag`, or is in `tag` when `tag` is a list. |
| `catchTags(self, cases, orElse?)` | Errors whose `_tag` has a handler in `cases`, as in `{ NotFound = function(e) ... end }`. |

- The tag test is `type(e) == "table" and e._tag == tag`.
  - It reads `_tag` with normal indexing, so errors built from metatable
    classes match.
  - Strings, numbers, booleans and nil never match, and the test never raises.
- `catchTags` looks up `cases[e._tag]` only when `e._tag` is a string. A tag
  with no case falls to `orElse`, or keeps failing.
- `eff:catchIf`, `eff:catchTag` and `eff:catchTags` are methods too.

`Effect.exit(self)` succeeds with `self`'s exit. It is
`catchCause(map(self, Exit.succeed), → succeed(Exit.failCause(cause)))`.
- It is a recovery handler, so it doesn't run while its own fiber is
  interrupted and interruptible.
- It is also a method, `eff:exit()`.
- Scope uses it (§19.3), so it lives in `core`, which `leffect.scope` can
  require without a cycle.

## 22. `forEach` and `all`

### 22.1 API

```lua
Effect.forEach(list, f, options) -- f(item, index) returns an effect
Effect.all(effects, options)     -- a list or a record of effects
-- options: { concurrency = n or "unbounded", discard = boolean }
```

- `concurrency`:
  - nil or 1 runs one item at a time, which is v4's default;
  - a number runs at most that many at once, and anything below 1 counts
    as 1;
  - `"unbounded"` runs them all at once;
  - anything else is a defect.

  4.1.5 has no `"inherit"`.
- The result is a list with a field `n`, like `table.pack`, so nil results
  are counted. With `discard = true`, the result is nil.
- `f` gets the item and its index, counting from 1. It is called only when
  that item's turn comes.
- The input list's length is `list.n` if that is a number, else `#list`.

### 22.2 Running

**One at a time** uses a `flatMap` chain:

```lua
local function inTurn(items, n, f, out)
  local function step(i)
    if i > n then return Exit.succeed(out) end
    return f(items[i], i):flatMap(function(value)
      if out then out[i] = value end
      return step(i + 1)
    end)
  end
  return step(1)
end
-- wrapped in suspend, so each run gets a fresh `out`
```

Each step returns the next effect from a continuation, so neither the frame
stack nor the Lua stack grows; M0's stack-safety argument covers it. The first
failure ends the chain, and later items never start.

**Concurrently**, the parent suspends in one `async`, as `raceAll` does
(§8.1):

- **Launching.** Fork workers until `concurrency` are running.
  - They are daemons, forked with `uninterruptible = "inherit"` (4.1.5), so
    inside an uninterruptible region they are uninterruptible too.
  - A worker's exit launches the next item.
  - One launch function serves both the first batch, inside `register`, and
    the refills, from worker observers. It calls `f` under `xpcall` both
    times. A refill runs outside the loop, and a throw in `register` would
    otherwise turn into a Die with no canceler.
  - A throw from `f` ends the run like a worker failure. Nothing more is
    launched, the workers already running are interrupted and awaited, and
    then the run fails with the Die. Workers are daemons, so nothing else
    would stop them. v4's `failDefect` does the same.
- **Results.** A success stores its value at its own index, so the results
  keep input order whatever order the workers finish in.
- **Failure** (4.1.5's `iterateConcurrent`):
  - The first failure stops new launches. It interrupts the running workers
    on behalf of the parent, in fork order.
  - The run resumes only once every worker has exited.
  - A later worker's failure adds its non-interrupt reasons to the cause, with
    defects elected.
- **End.** When no worker is running and no item is left, the run resumes
  with the failure, or with the results.
- **The canceler** handles an interrupt of the parent:
  - it stops launching;
  - it interrupts every running worker and waits for them;
  - then it fails with any failure already recorded, which §6.3's
    `FinalizerResult` adds to the interrupt.
- **Ticks.** Workers start on the next tick (§14), so even an item that
  finishes at once takes a tick.

### 22.3 `all`

`all` is `forEach` over the effects, with `f` the identity. A Lua table can be
both a list and a record, so its keys decide which it is:

1. If `type(t.n) == "number"`, it is a list of `t.n` effects.
2. If every key is an integer from 1 to the number of keys, it is a list. So
   `{}` is an empty list, and gives `{ n = 0 }`.
3. Otherwise it is a record, and the result has the same keys.
   - It runs in sorted key order: numbers ascending, then strings ascending.
     `pairs` order isn't specified, and differs between the runtimes, so
     sorting makes runs the same on both.
   - A key of any other type is a defect.

`discard`, `concurrency` and failures work as in `forEach`.

## 23. Specs for M2

Write these before the code. First, §17's specs for the re-pin. The rest go in
new files: `spec/gen_spec.lua`, `catch_spec.lua`, `context_spec.lua`,
`scope_spec.lua`, `resource_spec.lua` and `foreach_spec.lua`.

**gen** (moved here from §12)
- Values flow through `run()`; the body's first return value is the result.
- A failing `run()` never returns: code after it doesn't execute, and a
  `pcall` around it doesn't catch it.
- A Lua error in the body becomes a `Die` holding the raw error, with a
  traceback that contains the body's line number on both runtimes. A thrown
  table stays the defect.
- A raw `coroutine.yield` inside gen becomes a defect.
- `Leffect.run` raises a clear error when called outside gen, and when called
  from a user coroutine inside the body.
- `run(x)` with a non-effect dies with "Not a valid effect".
- A helper function called by the body can call `Leffect.run`.
- An interrupt during `run(sleep(...))` abandons the coroutine, and runs the
  `ensuring` added outside.
- Running one gen effect twice runs the body twice, from the start.
- Nested gens work.
- A gen body may return an effect, which comes back as a plain value.
- A gen body that calls `run()` 1e5 times in a loop doesn't overflow.

**Typed catches and `exit`**
- `catchTag`:
  - it recovers a matching `_tag`, and passes the error to the handler;
  - a list of tags works;
  - other errors keep failing, or go to `orElse`.
- Errors that aren't tables (a string, a number, nil) never match, and never
  raise.
- An error whose `_tag` comes from a metatable class matches.
- `catchTags` dispatches on `_tag`. A tag with no case keeps failing, or goes
  to `orElse`.
- `catchIf` follows its predicate.
- None of them recover a defect, an interrupt, or a cause that holds a Die.
- `Effect.exit` succeeds with the exit, for a success, a failure and a
  defect.

**Context**
- A fiber forked inside `scoped` sees the same scope, daemon or not.
- After a nested `scoped` ends, by success, failure or interrupt,
  `Effect.scope` sees the outer scope again.
- A scope's finalizers run in the outer context: inside one, `Effect.scope`
  is the outer scope.
- When the body of a nested `scoped` is interrupted at its first step, the
  inner scope still closes, and a finalizer outside it sees the outer scope.

**Scope**
- Finalizers run newest first, each with the close exit.
- Closing twice runs them once.
- Adding to a closed scope runs the finalizer at once, with the close exit.
- A failing or throwing finalizer doesn't stop the others. The close fails
  with all their reasons, in run order.
- Closing is uninterruptible: interrupting the closing fiber doesn't cut a
  sleeping finalizer short.
- A forked scope:
  - it closes with its parent, at its own position;
  - closed first, it detaches, and the parent doesn't close it again;
  - forking a closed scope gives a closed scope.
- `Effect.scope` outside `scoped` dies with §19.2's message.
- `Scope.provide` doesn't close the scope.
- A scope with 1e5 finalizers closes without overflowing.
- Below the cut line:
  - `"parallel"` runs finalizers at the same time (two 100 ms finalizers end
    at 100 ms), and combines their exits;
  - `scopedWith` passes the scope, and closes it;
  - `Scope.use` closes the scope with the effect's exit.

**Resources**
- `acquireRelease`:
  - the release runs when the scope closes, with the resource and the exit;
  - a failed acquire releases nothing;
  - an interrupt during acquire lets acquire finish, then the release runs,
    and the exit is the interrupt;
  - with `interruptible = true`, an interrupt stops acquire, and nothing is
    released;
  - resources are released in reverse order of acquisition;
  - a failing release is added to the cause.
- `acquireUseRelease`:
  - the release runs after `use` succeeds, fails or is interrupted;
  - `use` is interruptible, and acquire isn't.
- `addFinalizer` gets the exit.
- `forkScoped`: closing the scope interrupts the fiber, and waits for it. A
  fiber that ended earlier leaves no finalizer behind.
- `forkIn` on a closed scope gives an interrupted fiber that ran none of its
  code.

**forEach and all**
- One at a time by default:
  - `f` runs in order, only when the item's turn comes;
  - the results keep order, and carry `n`.
- The first failure stops the run: later items never start.
- 1e5 items, one at a time, don't overflow.
- Shape of the result:
  - nil results count in `n`;
  - `discard` returns nil;
  - an empty list gives `{ n = 0 }`;
  - `f` gets indexes that count from 1;
  - `list.n` sets the length.
- `concurrency = 2` never runs more than two at once. The results keep input
  order when items finish out of order. `"unbounded"` starts them all at once.
- A failure:
  - interrupts the running workers, and waits for their finalizers before
    failing;
  - a second worker's non-interrupt failure is added, with defects elected.
- Interrupting the parent interrupts every worker, and waits for them.
- Inside `uninterruptible`, a failing worker doesn't cut the others short.
- `f` throws on item 2 of the first batch, with `concurrency` of 2 or more.
  Item 1's worker is interrupted before it starts, since forks start on the
  next tick, so it runs none of its code. `forEach` fails with the Die once
  that worker has exited, instead of leaving it running.
- `f` throws during a later refill. The running workers are interrupted, and
  their finalizers run before `forEach` fails with the Die.
- An invalid `concurrency` is a defect.
- `all`:
  - a list gives the values, with `n`;
  - a record gives the same keys, and runs in sorted key order;
  - `t.n` marks a list;
  - `discard` and `concurrency` work.

## 24. Implementation order for M2

These make M2 done:

1. **The re-pin** (§17):
   - `Cause.electDefects`, `findRecoverableError` and the new `combine`;
   - defect election in `FinalizerResult` and `raceAll`;
   - the skip rule's handling of interrupts and Fails (§5.3);
   - `catchAll` on `findRecoverableError`;
   - updates to the M1 specs these change.
2. `Effect.exit`, `catchIf`, `catchTag` and `catchTags`.
3. `gen` (§9).
4. The context: `leffect.context`, `fiber.context`, inheritance in
   `forkUnsafe`, and the `SetContext` frame.
5. Scope, sequential only:
   - `Scope.make`, `makeUnsafe`, `addFinalizer`, `addFinalizerExit`, `close`,
     `fork` and `provide`;
   - `Effect.scope`, `scoped` and `addFinalizer`.
6. `acquireRelease`, `acquireUseRelease`, `forkIn` and `forkScoped`.
7. `forkUnsafe`'s `"inherit"`, then `forEach` (one at a time, then
   concurrently), then `all`.

Below the cut line, built last:

8. The `"parallel"` finalizer strategy.
9. `Effect.scopedWith` and `Scope.use`.

**Modules.**
- `leffect.context` is new and internal.
- `leffect.scope` is new and public, exported from `init.lua` as `Scope`.
- `core` gets `OP_GEN` and `exit`.
- `runtime` gets the `Gen` op and the `SetContext` frame.
- `leffect.effect` gets the rest.
- `init.lua` also exports `run` (§9).
- Every new module goes into the rockspec's `build.modules`.

## 25. M2 decisions taken on the user's behalf (2026-11-25)

The user picked option (a), a minimal fiber context for the Scope, and asked
for this design. These were decided here, and the user approved them with the
design on 2026-11-25.

21. **The context** is an immutable table keyed by strings, and internal until
    M3. Only `"leffect/Scope"` exists (§18).
22. **Context and scope frames are pushed directly** inside `withFiber`, never
    built as effects (§18, §19.4).
23. **`Leffect.run`** is `require("leffect").run`, the same function the gen
    body gets (§9).
24. **Lists from `forEach` and `all` carry `n`.** Indexes count from 1, and
    `all` sorts a record's keys (§22).
25. **`catchAll` keeps its name.** `catchIf`, `catchTag` and `catchTags` take
    an optional `orElse`, as in v4 (§21).
26. **Finalizer callbacks may return nil**, as `onExit`'s can (§14).
27. **`forkIn` and `forkScoped` take no options**, and their forks start on the
    next tick (§20.3).
28. **Running the release in the acquire-time context waits for M3** (§15).
29. **The cut line** (§24): the parallel strategy, `scopedWith` and
    `Scope.use` come last.
30. **`Effect.exit` is public**, and Scope uses it too (§21).
