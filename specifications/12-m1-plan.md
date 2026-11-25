# M1 specs and implementation order

Part I (the runtime, M1) of the [Leffect specifications](README.md).

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
