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
| Context (M2) | A `Context` of services, with Tags and Layers | A string-keyed table that holds only the Scope until M3 | M3 owns Context, Tag and Layer (§18). |
| Release context (M2) | `release` runs with the context captured at acquire | It runs with the closing fiber's context | The context holds only the Scope in M2; revisit in M3 (§15). |
| Finalizer callbacks (M2) | `release` and `addFinalizer`'s function return an Effect | They may also return nil | Matches `onExit` (§7.5). |
| `forkIn` options (M2) | `startImmediately`, `uninterruptible` | None | Forks start on the next tick (first row); M1's `fork` takes no options either. |
| Indexes (M2) | `f(a, i)` with `i` from 0 | `i` from 1 | Lua convention. |
| Result lists (M2) | Arrays | Lists with a field `n`, like `table.pack` | Results can be nil, and `#` can't count past a hole. |
| `all` input (M2) | An iterable or a record, told apart by type; a record runs in insertion order | Told apart by keys; a record runs in sorted key order (§22.3) | A Lua table is both. `pairs` order is unspecified, and differs between runtimes. |
| `all` options (M2) | `mode`, `"default"` or `"result"` | No `mode` | No Result type yet (§15). |
| Concurrent `forEach` items that are Exits (M2) | Handled inline: a success costs no fork and no tick, and a failure stops the run before `f` is called on any later item | Every item gets a worker. With `concurrency = 3` and `f(1)` returning `Effect.fail(x)`, `f(2)` and `f(3)` are still called; their workers are interrupted before they start | One launch path, as §22.2 describes. The inline path is an optimization to add later (§15). |

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
  failures.

---

## 15. Open questions

- **Unhandled failures in daemon fibers:** log them, or stay silent? Logging
  waits for the M3 logger; until then, the exit stays on the fiber.
- **Ending on an interrupt cause:** should `runFork`'s top-level observer
  report a process exit whose cause is interrupts-only differently from other
  failures? Effect treats it as non-error in some runners.
- **Immediate start:** v4's `startImmediately` for forks, and its immediate
  `runFork`, save a tick. They are safe under invariant 1 only when no loop is
  running. Skip them until a benchmark asks for them.
- **Fiber-aware tracebacks:** M1 gives Lua tracebacks for defects only.
  Annotating causes with the fork site or span is M3 work.
- **Coroutine cleanup (M2):** whether to `coroutine.close` abandoned gen
  coroutines on 5.4. It isn't needed for correctness (no `<close>` variables in
  the common subset). Leave it out unless memory profiling says otherwise.
- **Release context (M3):** run `release` with the context captured at
  acquire, as v4 does, once the context holds more than the Scope.
- **A Result type:** it would give `all` its `mode: "result"`, plus
  `Effect.result`.
- **A loop op for `forEach`:** v4 uses a `While` primitive. The `flatMap`
  chain of §22.2 is stack-safe, but allocates a frame and a closure per item.
  Add the op only if a benchmark asks for it.
- **Inline Exits in concurrent `forEach`:** v4 handles an item whose effect is
  already an Exit without forking it (§14). Adding that would save a fork and
  a tick per such item, and stop calling `f` after a failing one.
- **Structural equality:** `combine` dedupes with `==`. Structural dedupe
  waits for Equal/Hash ("Later" in CLAUDE.md).
