# Interruption

Part I (the runtime, M1) of the [Leffect specifications](README.md).

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
