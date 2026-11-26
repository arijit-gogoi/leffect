# Concurrency primitives: the shared rules

Part IV (M4) of the [Leffect specifications](README.md).

## 33. Concurrency primitives

M4 builds the concurrency primitives, which CLAUDE.md's Later list held until
this design. Each one follows its v4 module at 4.1.5:
- Ref (§34);
- Deferred and Latch (§35);
- Semaphore (§36);
- Queue (§37);
- PubSub (§38).

Latch is included because PubSub's shutdown uses one. Queue needs
`Cause.Done` (§37.1). SynchronizedRef comes below the cut line (§34.1). This
section holds the rules that all of them share.

None of them is an effect, as in v4. Each is a table with its own metatable.
Its functions return effects, except those whose names end in `Unsafe`. Those
act at once, and return what the effect would succeed with. 4.1.5's `Effect`
module re-exports none of the primitives, so Leffect adds no `Effect.*`
aliases.

M4 adds no op and no frame kind.

### 33.1 Atomic steps

- **Lua runs one fiber step at a time**, and a `sync` or `withFiber` step runs
  to completion.
- **A primitive's state is a plain table.** It changes only:
  - inside one such step;
  - or inside an `Unsafe` function.

  So each operation is atomic, as it is in v4, because JavaScript is
  single-threaded too.
- **A function passed to a primitive runs inside that step.** `Ref.update`'s
  `f` is an example. Such a function must not yield. It isn't a gen body, so
  calling `run` in it raises, and the effect dies (§9).
- **A Lua error thrown by such a function** leaves the state unchanged, and
  the effect dies with that error.

### 33.2 Waiting and waking

A fiber that has to wait suspends with `async`, which is v4's `callback`. v4
resumes a waiter inline: its `resume` runs the waiter's fiber at once, inside
the waker. So a v4 waker can wake one taker, watch it take a message, and only
then decide whether to wake the next.

Leffect's `resume` schedules the wakeup instead (invariant 1, the first row of
§14). Two things follow:
1. **A woken waiter hasn't acted yet** when the waker moves on. The waker has
   to count what each woken waiter will take, and wake only as many waiters as
   the state can serve.
2. **A woken waiter can be overtaken or interrupted** before its wakeup runs.
   An interrupt wins that race (§7.2). The resumed effect never runs, and the
   operation's canceler doesn't run either, because the operation has
   completed (invariant 6).

Hence the rule for every wait that consumes something: permits, queue
messages, and PubSub messages. It is the model of v4's Semaphore
(`takePermits`, Semaphore.ts 250):
- **A wake hands nothing over.** The waiter keeps its place in the line
  until it has what it waited for, or until it leaves.
- **A woken waiter checks again** when its wakeup runs. If it can proceed, it
  does. If it can't, because another fiber took the message first, say, it
  waits again in the same place.
- **The waker budgets.** A wake pass walks the line in arrival order. It
  wakes each waiter that the state can serve. It counts waiters it woke
  earlier, which haven't run yet, as already served.
- **A waiter that leaves passes its turn on.** The step that registers the
  waiter also pushes an OnExit frame. This is 4.1.5's `onExitUnsafe`
  (internal-effect.ts 4337), and it works the way `runtime.updateContext`
  pushes its SetContext frame. When the frame runs, and the waiter is still
  in line, it:
  - removes the waiter;
  - and runs the wake pass again.

  So a woken waiter that is interrupted before it runs hands its turn to the
  next one (invariant 24).

**Waits that consume nothing** are simply resumed: `Deferred.await`,
`Latch.await`, `Queue.await`, `Queue.peek` and `PubSub.awaitShutdown`. An
interrupted one removes itself with its canceler.

**Offers and publishes that wait for capacity** work differently. When room
frees, the waker moves the waiting message in, and resumes the offerer with
`true`, as v4 does (`releaseCapacity`, Queue.ts 2126). This keeps the waiting
offers in order: a new offer can't take the room first. If the offerer is
interrupted in the wake tick, its message stays accepted, and the offerer
ends with the interrupt (§14). No message is lost or duplicated. Only the
offer's `true` is lost.

### 33.3 Lines

Waiters wait in an ordered line.
- v4 keeps them in JavaScript `Set`s, which keep insertion order.
- A Lua table's `pairs` order is unspecified, and it differs between the two
  runtimes (§14).
- So Leffect uses an intrusive doubly linked list. Each waiter is a node, can
  leave in O(1), and every walk goes in arrival order.
- An internal module, `leffect.waitlist`, holds it.

### 33.4 Wakes are direct

- **v4 defers some wake passes to a scheduled task,** so that a waiter it
  resumes inline doesn't run inside the operation that woke it. Examples:
  - Semaphore's `releaseUnsafe`;
  - Latch's `open`;
  - Queue's `scheduleReleaseTaker`.

  Leffect's `resume` already schedules, so a wake pass runs in the step that
  changes the state.
- **So no primitive captures a scheduler.** A wake goes through the waiter's
  own `resume`, onto the waiter's own scheduler, which stays on the fiber
  (decision 41).
  - v4's `Queue.make` captures the creating fiber's dispatcher, for its
    deferred task.
  - Leffect's `Queue.make` is a plain `sync`.
- **The `Unsafe` functions are the bridge from callbacks.**
  `Deferred.doneUnsafe`, `Latch.openUnsafe`, `Queue.offerUnsafe`,
  `PubSub.publishUnsafe` and the rest change the state and schedule wakeups.
  They never run fiber code, so they may be called from anywhere, including a
  luv callback outside any fiber (invariant 23).

### 33.5 API conventions

- **Methods.** Every function whose first argument is the primitive is also a
  method, so `ref:update(f)` is `Ref.update(ref, f)`. Layers work the same way
  (decision 39). In v4, Semaphore and Latch have methods, and the other
  modules have only module functions.
  - The fields of a primitive are private, and none of them is named like a
    method.
  - v4's data-last forms aren't provided. v4's
    `semaphore.withPermits(n)(effect)` is `sem:withPermits(n, effect)`.
- **nil.** Any value may be nil, as values may be `undefined` in v4:
  - a value held in a Ref;
  - a Deferred's success;
  - a queue or PubSub message.

  Messages are stored by index, and never counted with `#`.
- **Lists.** A list of messages, such as the one `takeAll` returns or the one
  `offerAll` takes, has a field `n`, like M2's result lists (§14).
  - `offerAll` reads `n`, and falls back to `#` when there is none.
  - A list that a function returns always has `n`.
- **Options.** v4 functions that take or return an Option wait for an Option
  type (§15), like M3's accessors.
  - Where v4 also has a variant that returns an Exit or `undefined`, Leffect
    keeps that variant.
  - So `Queue.takeUnsafe` returns an Exit, or nil when nothing is ready.
- **Checks.** Constructors and functions raise when they get the wrong kind of
  argument, as in M3 (§14). That covers:
  - a value that isn't the primitive;
  - a function argument that isn't a function;
  - a capacity, or a number of permits, that isn't a non-negative integer.

  Take counts follow v4's normalization instead (`Count.normalize`): a
  fraction rounds down, and NaN or a count that isn't positive means 0.
- **Names.** Leffect uses v4's names, with one exception: `end` is a Lua
  keyword.
  - `Queue.end` and `PubSub.end` are called `finish`.
  - Their `Unsafe` variants are called `finishUnsafe`.
