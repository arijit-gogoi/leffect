# Children and structured concurrency

Part I (the runtime, M1) of the [Leffect specifications](README.md).

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
