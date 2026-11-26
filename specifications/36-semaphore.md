# Semaphore

Part IV (M4) of the [Leffect specifications](README.md).

## 36. Semaphore

A Semaphore holds a number of permits. Fibers take permits, wait while too few
are free, and give them back (`Semaphore.ts` at 4.1.5).

```lua
local sem = Semaphore.makeUnsafe(2)
local guarded = sem:withPermits(1, Effect.sleep(10))
```

| Function | Semantics |
|---|---|
| `Semaphore.make(permits)`, `makeUnsafe(permits)` | A semaphore with `permits` permits, all free. |
| `Semaphore.withPermits(sem, n, effect)` | Waits for `n` permits, takes them, runs `effect`, and gives them back however `effect` ends. |
| `Semaphore.withPermit(sem, effect)` | `withPermits` with one permit. |
| `Semaphore.take(sem, n)` | Waits for `n` permits, and takes them. Succeeds with `n`. |
| `Semaphore.takeScoped(sem, n)` | Takes `n` permits until the current scope closes. |
| `Semaphore.takeIfAvailable(sem, n)` | Takes `n` permits if they are free, without waiting. Succeeds with whether it took them. |
| `Semaphore.release(sem, n)` | Gives `n` permits back. Succeeds with the number of free permits. |
| `Semaphore.releaseAll(sem)` | Gives back every taken permit. Succeeds with the number of free permits. |
| `Semaphore.resize(sem, permits)` | Changes the number of permits. Taken permits stay taken. |

The state is two numbers, like v4's `SemaphoreImpl` (Semaphore.ts 291), plus
the line of waiters (§33.3):

```lua
---@class leffect.Semaphore
---@field permits integer
---@field taken integer -- free = permits - taken, which can be negative
```

- **Who is served.** This is v4's `firstAvailableWaiter` (Semaphore.ts 243):
  - The waiters are scanned in arrival order. The first one whose request fits
    in the free permits is served.
  - A larger, earlier request keeps its place, but a smaller, later one can
    overtake it.
  - A new request takes its permits at once only if they fit and no waiter
    fits. So a new request doesn't overtake a woken waiter that hasn't run
    yet.
- **Waking** (§33.2). Three things run the wake pass: `release`, `resize`, and
  a waiter leaving.
  - The pass walks the waiters in order. The free permits are its budget, and
    it wakes each waiter that fits.
  - Woken waiters count against the budget, since they keep their place until
    they take (Semaphore.ts 328).
  - A woken waiter takes its permits when it runs, if it is still the first
    waiter that fits. Otherwise it waits again, in its place.
- **Interrupts.** Waiting is interruptible, unless the caller is
  uninterruptible.
  - `withPermits` and `takeScoped` take the permits and register their release
    in one uninterruptible step (`uninterruptibleMask`). So permits that were
    taken always come back (invariant 25).
  - An interrupted wait takes nothing.
- **`takeIfAvailable` ignores the waiters,** as in v4. It can take permits that
  a waiter is waiting for.
- **`release` and `releaseAll` don't check what was taken.** v4's gotcha holds
  here too: after `releaseAll`, effects that are still inside `withPermits`
  give their permits back when they end. So more than `permits` can end up
  free.
- **`resize` below the taken count** leaves the free count negative. New
  requests wait until enough permits come back.
- **Checks.** `permits` and `n` must be non-negative integers, or the
  functions raise (§33.5). v4 doesn't check.
- **`withPermitsIfAvailable` waits.** In v4 it returns an Option, so it waits
  for an Option type (§15).
- **One optimization is left out.** v4 keeps a lower bound on the waiters'
  requests, so that a scan can stop early (`waiterPermitsLowerBound`). Leffect
  leaves it out until a benchmark asks for it.
