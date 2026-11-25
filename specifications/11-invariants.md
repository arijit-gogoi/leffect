# Invariants

Part I (the runtime, M1) of the [Leffect specifications](README.md).

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
19. **A release runs in the context of its acquire** (M3 design):
    `acquireRelease` and `Effect.addFinalizer` capture the context, and the
    raw Scope functions don't (§26.5).
20. **A shared layer is built once per MemoMap, and released once** (M3
    design), after the last scope that uses it closes (§27.4).
21. **A failed layer build releases what it acquired** (M3 design) before the
    failure comes out (§27.1, §27.5).
22. **The luv scheduler never runs a task in the batch that queued it** (M3
    design), so I/O and timers get a turn between batches (§29.2).
