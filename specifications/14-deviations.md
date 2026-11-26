# Deviations and open questions

Part I (the runtime, M1) of the [Leffect specifications](README.md).

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
| Finalizer callbacks (M2) | `release` and `addFinalizer`'s function return an Effect | They may also return nil | Matches `onExit` (§7.5). |
| `forkIn` options (M2) | `startImmediately`, `uninterruptible` | None | Forks start on the next tick (first row); M1's `fork` takes no options either. |
| Indexes (M2) | `f(a, i)` with `i` from 0 | `i` from 1 | Lua convention. |
| Result lists (M2) | Arrays | Lists with a field `n`, like `table.pack` | Results can be nil, and `#` can't count past a hole. |
| `all` input (M2) | An iterable or a record, told apart by type; a record runs in insertion order | Told apart by keys; a record runs in sorted key order (§22.3) | A Lua table is both. `pairs` order is unspecified, and differs between runtimes. |
| `all` options (M2) | `mode`, `"default"` or `"result"` | No `mode` | No Result type yet (§15). |
| Concurrent `forEach` items that are Exits (M2) | Handled inline: a success costs no fork and no tick, and a failure stops the run before `f` is called on any later item | Every item gets a worker. With `concurrency = 3` and `f(1)` returning `Effect.fail(x)`, `f(2)` and `f(3)` are still called; their workers are interrupted before they start | One launch path, as §22.2 describes. The inline path is an optimization to add later (§15). |
| Scheduler and op budget (M3) | References in the fiber's context (`Scheduler.Scheduler`, `MaxOpsBeforeYield`), which `provideService` can change | The scheduler stays on the fiber, and the op budget on the scheduler, as in M1 | A program runs on one host loop. A fiber that switched schedulers could wake on a loop that isn't running (§28.1). |
| Default scheduler (M3) | Without a `scheduler` option, `runFork` uses a `MixedScheduler` on `setImmediate` | `scheduler` is required | Lua has no built-in event loop to fall back on (§28.1). |
| `RunOptions.signal` (M3) | An AbortSignal interrupts the fiber | No such option | Lua has no AbortSignal. `runCallback`'s interruptor does the job (§28.1). |
| Option accessors (M3) | `Effect.serviceOption`, `serviceOptional`, `Context.getOption` | Not provided | No Option type yet (§15). `Context.getOrElse` and `Effect.contextWith` cover the need. |
| nil services (M3) | A service may be `undefined` | Providing nil raises, or dies inside an effect | A Lua table can't hold nil, and nil must keep meaning "absent" (§26.1). |
| `Context.Service`'s class form (M3) | `Context.Service<Self, Shape>()(id, { make })` | Only `Context.Service(id)` | The class form is TypeScript syntax (§26.2). |
| `Effect.scope` without a scope (M3) | `Effect.scope` is the Scope key, so it dies with "Service not found: effect/Scope" | `Effect.scope` keeps M2's message; `Scope.Scope` gives the generic one | M2's message names the fix (§26.4). |
| `provide`'s `local` option (M3) | `{ local: true }` | `{ fresh = true }` | `local` is a Lua keyword (§27.5). |
| `Layer.catch` (M3) | `Layer.catch` | `Layer.catchAll` | Matches `Effect.catchAll` (decision 25, §27.3). |
| Argument checks (M3) | TypeScript's types reject a non-key, a non-layer or a non-Context | Constructors and combinators raise; builds and `Effect.provide` die | Lua has no static types (§26.1, §27.1, §27.5). |
| `Effect.updateContext`'s result (M3) | Not checked | The effect dies when `f` returns something other than a Context | A non-Context would break every later lookup in the region (§26.4). |
| `updateServiceScoped` order (M3) | Changes the context, then looks up the scope, so a missing scope fails after the change | Looks up the key and the scope first, and changes nothing if either is missing | A failed call shouldn't leave the context changed (§26.4). |
| `end` (M4 design) | `Queue.end`, `PubSub.end` and `endUnsafe` | `finish` and `finishUnsafe` | `end` is a Lua keyword (§33.5, decision 56). |
| Waiters (M4 design) | Some wake passes run in a scheduled task. A woken Queue taker leaves the line, and takes inline | A wake pass runs in the step that changes the state. A woken waiter keeps its place until it takes, and takes when its wakeup runs | Leffect's resume is scheduled (first row), so a woken waiter can be overtaken or interrupted before it runs (§33.2). |
| Accepted offers (M4 design) | A waiting offer or publish whose message gets in resumes inline | It resumes on the next tick. If it is interrupted meanwhile, its message stays in, and the offer ends with the interrupt | Follows from the first row. No message is lost or duplicated (§33.2). |
| PubSub takers (M4 design) | A waiting subscriber gets its message through a Deferred | It takes the message when its wakeup runs | With a scheduled resume, an interrupt in the wake tick would lose a message that was handed over (§38.2). |
| PubSub buffers (M4 design) | Four buffers, one of which indexes with `&`. `make` accepts a custom buffer and strategy | One linked list. Buffers and strategies stay internal | The common subset has no bitwise operators, and one list behaves the same (§38.5). |
| Option functions (M4 design) | `Queue.poll`, `Deferred.poll`, Ref's `*Some` functions, `withPermitsIfAvailable`, `PubSub.remainingUnsafe` | Not provided. `Queue.takeUnsafe` returns an Exit or nil | No Option type yet (§15, §33.5). |
| `Ref.modify` (M4 design) | `f` returns a tuple `[b, a]` | `f` returns two values, and fewer than two is a defect | Lua has multiple return values. The check keeps a forgotten second value from setting the Ref to nil (§34). |
| `SynchronizedRef.modifyEffect` (M4 design) | The effect succeeds with a tuple | The effect succeeds with a pair `{ result, newValue }` | An effect succeeds with one value (§34.1). |
| Data-last forms (M4 design) | `semaphore.withPermits(n)(effect)` | `sem:withPermits(n, effect)` | Leffect has no `pipe`, and its functions take the effect directly (§33.5). |
| Queue views (M4 design) | `asEnqueue`, `asDequeue`, `isEnqueue`, `isDequeue`, `flush`, `flushUnsafe` | Not provided | The first four concern TypeScript types. `flush` forces a deferred wake task, which Leffect doesn't have (§37.5). |
| Counts (M4 design) | Semaphore permits and Queue capacities aren't checked | They must be non-negative integers, or the call raises | Lua has no static types (§33.5). |

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
  failures;
- in M3: context lookups and References, the functions that provide
  services, the release context, layers and their MemoMap, and
  `runCallback`;
- in M4 (design): the primitives' operations, results, states and service
  orders.

---

## 15. Open questions

- **Unhandled failures in daemon fibers:** log them, or stay silent? Logging
  is Later in CLAUDE.md, not M3 (decision 47). Until then, the exit stays on
  the fiber.
- **Ending on an interrupt cause:** should `runFork`'s top-level observer
  report a process exit whose cause is interrupts-only differently from other
  failures? Effect treats it as non-error in some runners.
- **Immediate start:** v4's `startImmediately` for forks, and its immediate
  `runFork`, save a tick. They are safe under invariant 1 only when no loop is
  running. Skip them until a benchmark asks for them.
- **Fiber-aware tracebacks:** M1 gives Lua tracebacks for defects only.
  Annotating causes with the fork site or span is tracing work, which is Later
  in CLAUDE.md, not M3 (decision 47).
- **Coroutine cleanup (M2):** whether to `coroutine.close` abandoned gen
  coroutines on 5.4. It isn't needed for correctness (no `<close>` variables in
  the common subset). Leave it out unless memory profiling says otherwise.
- **A Result type:** it would give `all` its `mode: "result"`, plus
  `Effect.result`.
- **An Option type:** these wait for it:
  - `timeoutOption`, `Effect.serviceOption`, `serviceOptional` and
    `Context.getOption`;
  - from M4: `Queue.poll`, `Deferred.poll`, Ref's `*Some` functions,
    `Semaphore.withPermitsIfAvailable` and `PubSub.remainingUnsafe`.
- **Context overlays (M3):** v4 adds a service by linking an overlay instead
  of copying the map, and flattens the chain after enough reads. Leffect
  copies (§26.1). Switch only if a benchmark asks for it.
- **ManagedRuntime (M3):** build a layer once, then run many effects against
  it. The runners of §28.3 are the pieces; v4's `ManagedRuntime` packages
  them.
- **A main runner for luv (M3):** v4's platform `runMain` interrupts the
  program on SIGINT, sets the exit code, and reports failures. With luv that
  needs signal handles, so it belongs with the platform modules (Later).
- **A Neovim scheduler (M3):** a scheduler on `vim.schedule`, so that effects
  may call `vim.api` (§29.6).
- **A loop op for `forEach`:** v4 uses a `While` primitive. The `flatMap`
  chain of §22.2 is stack-safe, but allocates a frame and a closure per item.
  Add the op only if a benchmark asks for it.
- **Inline Exits in concurrent `forEach`:** v4 handles an item whose effect is
  already an Exit without forking it (§14). Adding that would save a fork and
  a tick per such item, and stop calling `f` after a failing one.
- **Structural equality:** `combine` dedupes with `==`. Structural dedupe
  waits for Equal/Hash ("Later" in CLAUDE.md).
- **More concurrency modules (M4):** these v4 modules aren't in CLAUDE.md's
  list, and M4 leaves them out:
  - PartitionedSemaphore;
  - FiberHandle, FiberMap and FiberSet;
  - Pool, RcRef, RcMap, ScopedRef, Cache and LayerMap.

  SubscriptionRef waits for Stream, and the Tx modules wait for STM.
- **Custom PubSub buffers and strategies (M4):** v4's `PubSub.make` accepts
  both. Leffect keeps them internal until someone needs one (§38.5).
- **The cost of a wake pass (M4):** each pass walks its line from the start.
  v4's Semaphore keeps a lower bound on the requests, so that a scan can stop
  early. Add that, or an index, if a benchmark asks for it.
