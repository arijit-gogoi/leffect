# M4 specs, implementation order and decisions

Part IV (M4) of the [Leffect specifications](README.md).

## 39. Specs for M4

Write these before the code. They go in new files:
- `spec/ref_spec.lua`;
- `deferred_spec.lua`;
- `latch_spec.lua`;
- `semaphore_spec.lua`;
- `queue_spec.lua`;
- `pubsub_spec.lua`;
- below the cut line, `synchronizedref_spec.lua`.

The `Cause.Done` specs extend `spec/cause_spec.lua`.

No earlier spec changes. The layer specs must still pass once the MemoMap uses
the public Deferred.

**Shared** (§33)
- Every module function whose first argument is the primitive is also a
  method, the `Unsafe` ones included.
- These raise:
  - a module function given something other than its primitive;
  - a constructor given a bad capacity, a bad number of permits, or an
    unknown strategy.
- **`Unsafe` functions never run fiber code** (invariant 23). Each of these is
  called from plain Lua, between two flushes of the test scheduler:
  `Deferred.doneUnsafe`, `Latch.openUnsafe`, `Queue.offerUnsafe` and
  `PubSub.publishUnsafe`. The fiber each one wakes doesn't run until the next
  flush.
- **A woken waiter that is interrupted before it runs passes its turn on**
  (invariant 24). In each case, two fibers wait. One step wakes the first, and
  interrupts it with `interruptUnsafe`:
  - Semaphore: the step releases a permit, and the second waiter gets it.
  - Queue: the step offers a message, and the second taker gets it.
  - PubSub: the step publishes a message, and the second fiber taking from
    the same subscription gets it.

**Ref** (§34)
- `make` then `get`, and every function in §34's table, with its result.
- **`modify`:**
  - it sets the second value that `f` returns, and succeeds with the first;
  - `return b, nil` sets nil;
  - if `f` returns one value, the effect dies with "Ref.modify: f must return
    the result and the new value", and the Ref keeps its value.
- A Ref holds nil.
- A hundred fibers, each running `update` once, concurrently, leave a hundred.
- If `f` throws, the Ref keeps its value, and the effect dies with the error.
- Building an update calls nothing. Running it twice calls `f` twice.
- `makeUnsafe` and `getUnsafe` work. `run(ref)` dies with "Not a valid
  effect".

**Deferred** (§35.1)
- `await` waits until the Deferred is completed. Then it succeeds with the
  value, fails with the error, or dies with the defect. The value may be nil.
- Three awaiters all resume, in the order they started waiting.
- An await after completion doesn't suspend.
- **Completing twice:** the second call succeeds with false, and awaiters see
  the first completion.
- **`completeWith` and `complete`:**
  - with `completeWith(d, eff)`, each awaiter runs `eff`, so an `eff` that
    counts its runs counts one per awaiter;
  - `complete(d, eff)` runs `eff` once;
  - on a completed Deferred, `complete` doesn't run `eff`.
- **`interrupt(d)`:** awaiters fail with an interrupt cause that holds the
  completing fiber's id, and `catchAll` doesn't catch it. `interruptWith` uses
  the given id.
- **An interrupted awaiter is removed.** The others still resume, and
  nothing resumes it.
- `into` completes `d` with a success and with a failure. When `eff` is
  interrupted, it completes `d` with the interrupt.
- The `*Sync` variants compute their value when they run, not when they are
  built.
- `isDone`, `isDoneUnsafe` and `isDeferred` work.

**Latch** (§35.2)
- `await` waits until `open`. `open` wakes every waiter, and later awaits
  continue at once, until `close`.
- `open` and `close` succeed with whether they changed the latch.
- `release` wakes the current waiters, and leaves the latch closed. So a later
  await waits.
- `whenOpen` runs its effect after the latch opens.
- An interrupted waiter is removed.
- `isOpen` works, and `make(true)` starts open.

**Semaphore** (§36)
- With one permit, three fibers running `withPermit(sem, Effect.sleep(10))`
  finish at 10, 20 and 30 ms, in order. With two permits, two run at a time.
- `withPermits` gives the permits back after its effect succeeds, fails, dies,
  or is interrupted.
- `take` succeeds with `n`, and `release` with the number of free permits.
  `takeIfAvailable` succeeds with true or false, and never waits.
- **Overtaking:**
  - one fiber takes both of two permits;
  - a request for 2 waits, then a request for 1 waits;
  - when 1 permit comes back, the request for 1 proceeds, and the request for
    2 still waits;
  - once both permits are free again, the request for 2 proceeds.
- **No barging:** a permit comes back, and wakes a waiter. In the same tick,
  another fiber calls `take(1)`. It waits behind the woken waiter.
- An interrupted waiter is removed, and the permits go to the next waiter. An
  interrupted wait takes nothing.
- `takeScoped` holds its permits until the scope closes.
- `releaseAll` frees every taken permit. The `withPermits` calls still
  running give their permits back afterwards, so more than `permits` end up
  free.
- `resize` upwards wakes waiters. `resize` below the taken count makes new
  requests wait until enough permits come back.
- With 0 permits, `take(1)` waits until `release(1)`.

**Queue** (§37)
- `offer` then `take` keeps FIFO order. `take` on an empty queue waits for an
  offer.
- Takers are served in the order they started waiting.
- An interrupted waiting taker is removed, and the next message goes to the
  next taker.
- A nil message comes out as nil. `takeAll`'s list has `n`.
- **Bounded, suspending:**
  - an offer to a full queue waits, and a take lets the first waiting offer
    in;
  - waiting offers get in, in order;
  - `offerAll` adds what fits, waits for the rest, and succeeds with an empty
    list;
  - an interrupted waiting offer is removed, and its message never arrives.
- **Dropping:** an offer to a full queue succeeds with false, and the queue
  keeps its messages. `offerAll` succeeds with the messages that didn't fit.
- **Sliding:** an offer to a full queue drops the oldest message, and succeeds
  with true. `offerAll` keeps the newest messages.
- **Unbounded:** an offer never waits.
- `takeAll` takes every buffered message, waiting for one. `peek` waits for a
  message, and doesn't remove it.
- `takeUnsafe` returns a success Exit, nil when the queue is empty, and the
  failure once the queue is Done.
- `clear` removes and returns the buffered messages, and lets waiting offers
  in.
- `size` and `isFull` work.
- **`finish`:**
  - later offers succeed with false;
  - takers take the buffered messages, then fail with `Cause.Done()`, which
    `catchTag(eff, "Done", f)` catches;
  - offers that were waiting still get in: on a full `bounded(1)` with one
    offer waiting, two takes after `finish` get both messages, and then the
    queue is Done;
  - with nothing buffered, the queue is Done at once, and waiting takers fail
    with Done;
  - `await` succeeds once the queue is drained;
  - a second `finish` succeeds with false.
- **`fail`:** takers drain the queue, then fail with the error. `await` fails
  with it, and so does `clear` once the queue is Done. `failCause` keeps its
  cause. `interrupt` ends the queue with an interrupt that holds the fiber's
  id.
- **`shutdown`:**
  - the buffer is dropped;
  - waiting takers and awaiters end with an interrupt;
  - waiting offers succeed with false, and a waiting `offerAll` succeeds with
    the messages it didn't add;
  - later offers succeed with false, and `size` is 0;
  - a second call succeeds with false;
  - on a Closing queue, waiting takers fail with the queue's error, not with
    an interrupt.

Below the cut line:
- **`takeN` and `takeBetween`:**
  - they wait for the minimum, and take at most the maximum;
  - on `bounded(2)`, `takeBetween(3, 5)` takes 2;
  - while the queue is Closing, they take fewer;
  - a count of 0 gives an empty list at once;
  - fractions round down, and NaN counts as 0.
- `collect` succeeds with every message once the queue finishes, and fails
  when the queue fails.
- `into`: a success finishes the queue, and a failure fails it with the
  effect's cause.
- **Capacity 0:**
  - an offer waits until a taker takes its message;
  - a waiting taker lets an offer through at once;
  - a sliding queue of capacity 0 drops a message when no taker waits.

**PubSub** (§38)
- Two subscribers each get every message, in order.
- A message published before a subscription isn't received. With no
  subscribers, a publish succeeds, and the hub holds nothing.
- `take` waits. `takeAll` takes what is waiting, at least one message.
  `takeUpTo` never waits. `remaining` counts what is waiting.
- **Bounded:** a publish waits while the slowest subscriber has `capacity`
  messages it hasn't taken. It proceeds once that subscriber takes one.
  Waiting publishes are accepted in order.
- **Dropping:** a publish to a full hub succeeds with false, and no subscriber
  gets the message.
- **Sliding:** a publish to a full hub drops the oldest held message for the
  subscribers that haven't taken it, and succeeds with true.
- **Unbounded:** the hub is never full.
- **Closing a subscription's scope:**
  - lets a waiting publisher in, since the hub stops holding messages for the
    subscription;
  - ends its waiting takes with an interrupt from the closing fiber;
  - makes later takes interrupt.
- Two fibers taking from one subscription share its messages, each message to
  one of them.
- `subscribe` without a scope dies with `Effect.scope`'s message.
- **`finish(hub, final)`:**
  - later publishes, and waiting ones, succeed with false;
  - subscribers get their held messages, then `final` on every take;
  - a later subscriber gets `final`;
  - `takeUpTo` doesn't return `final`;
  - a second `finish` succeeds with false.
- **`shutdown`:**
  - waiting takes and waiting publishes end with an interrupt;
  - later publishes succeed with false, and later takes interrupt;
  - `awaitShutdown` continues, and `isShutdown` is true;
  - `size` is 0;
  - a second `shutdown` does nothing.

Below the cut line:
- `takeBetween`.
- **Replay** (§38.4):
  - a later subscriber gets the last `k` messages first, even ones published
    while there were no subscribers;
  - replayed messages don't count against capacity;
  - when a sliding hub drops a live message, it joins the end of a
    subscription's replay.

**SynchronizedRef** (§34.1, below the cut line)
- Two `updateEffect` calls whose effects each sleep 10 ms run one after the
  other. The second sees the first's value, and both end by 20 ms.
- A failing or interrupted update leaves the value, and the next update runs.
- `get` doesn't wait for a running update.
- `modifyEffect` sets the pair's second value, and succeeds with its first. An
  effect that succeeds with something other than a table dies.

**Done** (§37.1)
- `Cause.Done()` returns one shared table with `_tag = "Done"`.
- `Cause.Done(v)` holds `v`.
- `Cause.isDone` is true for both, and false for a plain `{ _tag = "Done" }`.

## 40. Implementation order for M4

These make M4 done:

1. **The shared pieces** (§33):
   - `leffect.waitlist`;
   - a runtime helper that pushes an OnExit frame for the current `withFiber`
     step (4.1.5's `onExitUnsafe`);
   - `Cause.Done` and `Cause.isDone` (§37.1).
2. **Ref** (§34).
3. **Deferred** (§35.1). Then the MemoMap moves onto it.
4. **Latch** (§35.2).
5. **Semaphore** (§36).
6. **Queue** (§37), for capacities of 1 and more:
   - the states and the three strategies;
   - `offer`, `offerAll`, `take`, `takeAll`, `peek`, `takeUnsafe` and
     `clear`;
   - the ending functions, `await`, `size` and `isFull`.
7. **PubSub** (§38), without replay:
   - the strategies and `subscribe`;
   - `take`, `takeAll`, `takeUpTo` and `remaining`;
   - `finish` and `shutdown`.

Below the cut line, built last:

8. SynchronizedRef (§34.1).
9. Queue's `takeN`, `takeBetween`, `collect` and `into`, then capacity 0.
10. PubSub's `takeBetween`, then replay (§38.4).

**Modules.**
- **New public modules:** `leffect.ref`, `leffect.deferred`, `leffect.latch`,
  `leffect.semaphore`, `leffect.queue` and `leffect.pubsub`, then
  `leffect.synchronizedref` below the cut line. `init.lua` exports them as
  `Ref`, `Deferred`, `Latch`, `Semaphore`, `Queue`, `PubSub` and
  `SynchronizedRef`.
- **A new internal module:** `leffect.waitlist`.
- **Changed modules:**
  - `leffect.cause` gets `Done` and `isDone`;
  - `leffect.runtime` gets the OnExit helper;
  - `leffect.layer` uses `leffect.deferred`.
- **The rockspec:** `build.modules` gets the new modules. There is no new
  dependency.

**Once M4 is built:**
- label §11's invariants and §14's rows "(M4)" instead of "(M4 design)";
- update §27.4's note on the Deferred;
- update CLAUDE.md's Layout and the README's status line.

## 41. M4 decisions taken on the user's behalf (2026-11-26)

The user asked for this design on 2026-11-26. These choices were made here,
and await the user's approval with the design.

49. **M4's scope** (§33):
    - CLAUDE.md's five primitives;
    - Latch, because PubSub's shutdown uses one;
    - `Cause.Done`, because a queue's end needs it;
    - SynchronizedRef, below the cut line.

    The rest of v4's concurrency modules are left out (§15). There are no
    `Effect.*` aliases, because 4.1.5 has none.
50. **Primitives are tables with methods,** not effects, as in v4. Every
    function whose first argument is the primitive is also a method, as for
    layers (decision 39, §33.5).
51. **Waiters keep their place, and a wake hands nothing over** (§33.2). This
    is v4's Semaphore model. Leffect uses it for every wait that consumes
    something, because its resume is scheduled.
52. **A waiter that leaves passes its turn on,** through an OnExit frame that
    the registering step pushes (§33.2, invariant 24).
53. **Wakes are direct, and no primitive captures a scheduler** (§33.4).
    v4's deferred wake tasks are left out, and the scheduler stays on the
    fiber (decision 41).
54. **Waiting offers and publishes are accepted when room frees,** as in v4.
    An offerer interrupted in the wake tick leaves its message in the queue,
    but loses its `true` (§14).
55. **PubSub subscribers take their own messages** when they wake (§38.2).
    v4's handoff through a Deferred could lose a message under scheduled
    resumes.
56. **`end` is renamed `finish`,** because `end` is a Lua keyword. This gives
    `Queue.finish`, `PubSub.finish` and `finishUnsafe` (§33.5). The other
    candidate was `close`, the name Go and Kotlin use for channels. It was
    passed over because `Latch.close` and `Scope.close` mean something else.
57. **Values and messages may be nil.** Lists of messages have a field `n`,
    as M2's result lists do (§33.5).
58. **Functions that take or return an Option wait for an Option type,** as
    M3's accessors do (decision 36). `Queue.takeUnsafe` returns an Exit or
    nil (§33.5).
59. **`Ref.modify`'s `f` returns two values,** and returning fewer is a defect
    (§34). `SynchronizedRef.modifyEffect`'s effect succeeds with a pair.
60. **Argument checks** (§33.5):
    - arguments of the wrong kind raise;
    - capacities and numbers of permits must be non-negative integers, and a
      PubSub's capacity must be positive;
    - take counts are normalized, as in v4.
61. **One PubSub buffer** replaces v4's four (§38.5).
62. **The MemoMap uses the public Deferred,** as v4's does (§35.1).
63. **The cut line** (§40). These come last:
    - SynchronizedRef;
    - the Queue functions `takeN`, `takeBetween`, `collect` and `into`;
    - queues of capacity 0;
    - PubSub's `takeBetween` and replay.
