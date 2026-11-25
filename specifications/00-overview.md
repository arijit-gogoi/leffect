# Overview

Part I (the runtime, M1) of the [Leffect specifications](README.md).

## 0. Summary

- **Effects are data, and exits are effects.** `Success` and `Failure` are both
  the result of a computation and instructions the run loop can evaluate.
- **One stack of frames per fiber.** Every combinator that waits for a result
  (`flatMap`, `catchCause`, `onExit`, an async canceler, an interruptibility
  restore, and a generator in M2) pushes itself as a frame. A frame can handle
  success, failure, or both, and can react to being popped (`onPop`).
- **Interruption is a failure with a special rule.** An interrupt is delivered
  by failing the fiber with an `Interrupt` cause. While the fiber is
  interruptible and has been interrupted, recovery handlers are skipped during
  unwinding, and the cause that unwinds records the interrupt. Finalizer
  frames switch the fiber to uninterruptible when popped, so they always run.
- **A cause with a defect is not recoverable** (4.1.5). When a cause holds both
  Fail and Die reasons, combining elects the Fails to Dies, and `catchAll`
  only recovers causes without a Die (§2.1).
- **Interruptibility is a flag plus restore frames.** `uninterruptible(e)` sets
  the flag and pushes a frame that restores it. Restoring to interruptible while
  an interrupt is pending delivers it right there.
- **Async is a one-shot suspension with an optional canceler.** The canceler is
  pushed as a frame, so interruption cancels the operation by ordinary
  unwinding. A canceler never runs once its operation has completed.
- **No nested run loops.** Every wakeup (async resume, interrupt of a suspended
  fiber, fork start, yield) goes through `scheduler:schedule`. Only one run
  loop is ever on the Lua stack. This is the main deviation from v4, which
  resumes synchronously for speed. See §14.
- **Structured concurrency.** A fiber publishes its exit only after
  interrupting and awaiting all its children.
- **`gen` on stackful coroutines, in M2.** `run(eff)` yields a marked effect to
  the run loop. On failure or interrupt the coroutine is abandoned, never
  thrown into (§9).
- **M2 adds a minimal fiber context, Scope and bounded concurrency.**
  - The context holds the current Scope until M3 brings Context and Layer
    (§18).
  - A Scope runs its finalizers in reverse order (§19).
  - `acquireRelease` registers the release before an interrupt can land (§20).
  - `forEach` and `all` run under a concurrency limit and keep input order
    (§22).

---

## 1. Goals and non-goals

**Goals for M1:** fibers, a test scheduler with a virtual clock, `async` with
cancelers, `sleep`, `fork`/`forkDaemon`/`join`/`await`, `interrupt`/
`interruptFork`, `uninterruptible`/`interruptible`/`uninterruptibleMask`,
`onExit`/`ensuring`/`onInterrupt`, `race`/`raceFirst`/`timeout`, fair
yielding, and the entry points `runFork`, `runSync` and `runSyncExit`.

**Non-goals for M1:** `gen` (M2, as CLAUDE.md's milestones say; designed in
§9), Scope (M2), Context/Layer/FiberRef (M3), an Option type (so no
`timeoutOption` yet), tracing and stack annotations, scheduler priorities,
real-host adapters other than test (luv comes in M3).

**Goals for M2:**
- `gen`;
- `catchIf`, `catchTag`, `catchTags` and `Effect.exit`;
- a minimal fiber context;
- Scope, with `scoped`, `addFinalizer`, `forkIn` and `forkScoped`;
- `acquireRelease` and `acquireUseRelease`;
- `forEach` and `all` with concurrency limits;
- the re-pin's changes to M1 semantics (§17).

`race` was done in M1. v4's `raceAll` has no concurrency option, so the limits
in CLAUDE.md's M2 line apply to `forEach` and `all`.

**Non-goals for M2:**
- Context, Tag, Layer and FiberRef (M3);
- a Result type, so `all` has no `mode: "result"`;
- `Effect.fn`;
- v4's `catchReason` and `catchReasons`;
- the `match` family;
- structural equality.
