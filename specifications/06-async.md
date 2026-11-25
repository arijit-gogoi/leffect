# Async

Part I (the runtime, M1) of the [Leffect specifications](README.md).

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
