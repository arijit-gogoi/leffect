# Deferred and Latch

Part IV (M4) of the [Leffect specifications](README.md).

## 35. Deferred and Latch

Both are signals. Fibers wait for them, and nothing is consumed when a fiber
gets through, so a wake needs no budget (§33.2).

### 35.1 Deferred

Any fiber can complete a Deferred, but only once. Any number of fibers can wait
for it (`Deferred.ts` at 4.1.5).

```lua
local ready = Deferred.makeUnsafe()
local worker = Effect.gen(function(run)
  local config = run(ready:await())
  return config.name
end)
-- elsewhere: run(ready:succeed({ name = "x" }))
```

| Function | Semantics |
|---|---|
| `Deferred.make()`, `Deferred.makeUnsafe()` | A new Deferred, not yet completed. |
| `Deferred.await(d)` | Waits until `d` is completed, then runs its effect. So it succeeds with the value, or fails with the cause. |
| `Deferred.completeWith(d, effect)` | Completes `d` with `effect`. Succeeds with true, or with false if `d` was already completed. |
| `Deferred.done(d, exit)` | `completeWith` with an Exit. |
| `Deferred.succeed(d, value)`, `fail(d, error)`, `failCause(d, cause)`, `die(d, defect)` | `done` with the matching Exit. |
| `Deferred.interrupt(d)`, `interruptWith(d, fiberId)` | `done` with an interrupt cause, from the current fiber or from `fiberId`. |
| `Deferred.sync(d, f)`, `failSync(d, f)`, `failCauseSync(d, f)`, `dieSync(d, f)` | The same, with the value, the error, the cause or the defect computed by `f` when the effect runs. |
| `Deferred.complete(d, effect)` | Runs `effect` once, and completes `d` with its exit. If `d` is already completed, `effect` doesn't run. |
| `Deferred.into(effect, d)` | Runs `effect`, and completes `d` with its exit, even if `effect` is interrupted. Succeeds with whether this call completed `d`. |
| `Deferred.isDone(d)`, `Deferred.isDoneUnsafe(d)` | Whether `d` is completed. |
| `Deferred.doneUnsafe(d, effect)` | Completes `d` at once, and returns whether it did. This is the bridge from callbacks (§33.4). |
| `Deferred.isDeferred(x)` | Type check. |

- **`completeWith` stores the effect, not its result.** Each awaiter runs the
  effect in its own fiber, as in v4. `complete` runs it once, through `into`,
  and every awaiter gets the same exit.
- **Awaiters resume in the order they started waiting.** The list is cleared
  before the first resume, as in v4 (`doneUnsafe`, Deferred.ts 881).
- **An interrupted awaiter removes itself,** through its canceler.
- **`into` runs `effect` interruptibly,** and completes `d` uninterruptibly
  (`uninterruptibleMask`, Deferred.ts 934). If `effect` is interrupted, `d`
  completes with the interrupt cause.
- **`poll` waits.** v4's `Deferred.poll` returns an Option, so it waits for an
  Option type (§15).
- **The MemoMap uses this Deferred.** It replaces the MemoMap's internal one
  (§27.4). v4's MemoMap uses `Deferred.makeUnsafe`, `doneUnsafe` and `await`
  (Layer.ts 247–464).

### 35.2 Latch

A Latch is a gate. Fibers wait at it until it opens (`Latch.ts` and
internal-effect.ts 5943 at 4.1.5).

| Function | Semantics |
|---|---|
| `Latch.make(open?)`, `Latch.makeUnsafe(open?)` | A new latch. It is closed unless `open` is true. |
| `Latch.await(latch)` | Waits until the latch opens. Continues at once if it is open. |
| `Latch.open(latch)`, `Latch.openUnsafe(latch)` | Opens the latch, and wakes every waiter. Succeeds with true, or with false if it was already open. |
| `Latch.release(latch)` | Wakes the current waiters, and leaves the latch closed. Succeeds with false if the latch was open, and with true otherwise. |
| `Latch.close(latch)`, `Latch.closeUnsafe(latch)` | Closes the latch, so later awaits wait. Succeeds with true, or with false if it was already closed. |
| `Latch.whenOpen(latch, effect)` | Waits until the latch opens, then runs `effect`. |
| `Latch.isOpen(latch)` | Whether the latch is open. A plain function, not an effect, as in v4. |

- Waiters resume in the order they started waiting. An interrupted waiter
  removes itself.
- v4's `open` defers its wakes to a scheduled task, and its `openUnsafe` wakes
  at once. Here both wake at once (§33.4).
