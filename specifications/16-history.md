# History: the review and the re-pin

Part I (the runtime, M1) of the [Leffect specifications](README.md).

## 16. What the review changed (2026-11-25)

The first draft was checked against v4's source (`effect-smol` `main` @
`3a1128c`). Line numbers below are in `internal/effect.ts` at that commit.

**Bugs fixed**

1. `timeout` raced on `raceAll`, so an effect that failed before the deadline
   was ignored until the sleep won. It now uses `raceFirst`, like v4's
   `timeoutOrElse` (3617–3644), and fails with `TimeoutError`, like v4's
   `timeout` (3647–3667). `timeoutOption` waits for an Option type (§8.1).
2. `raceAll` waited inside `uninterruptibleMask` without `restore`, so the
   racing fiber couldn't be interrupted until a racer finished. It now has
   v4's shape: an interruptible wait whose canceler interrupts the racers
   (1423–1478).
3. A canceler could run after its operation completed: `resume` queued the
   wakeup, and an interrupt arrived before it ran. `s.completed` now guards
   the canceler (§6.2, §6.3).
4. A finalizer function that threw lost the original exit. `FinalizerResult`
   is now pushed before the function is called (§7.5).
5. `cur:evaluate(self)` on a non-effect raised a plain Lua error, which broke
   M0's "Not a valid effect" specs. Any table with an `evaluate` field would
   also have run. The loop now checks for an effect before dispatching, and
   dispatches through private tables (§2.3, §5.2).
6. `runSync`, `runSyncExit` and `runFork` weren't specified (§8.2).
7. A `pendingInterrupt` set during a step that then suspended the fiber, or
   during its last step, was never delivered (§5.1, §5.2).
8. A synchronous `resume(nil)` suspended the fiber forever (§6.2).
9. On LuaJIT, `debug.traceback(nil, level)` returns `nil`, so thrown tables
   would have had no trace (§5.2).
10. The op count reset when the loop restarted after a defect, so a fiber
    that kept failing could dodge the op budget. It now lives on the fiber.

**Brought in line with v4**

11. `Cause.combine` dedupes, as `causeCombine` does (243–259).
12. `onInterrupt` runs when the cause has any Interrupt reason, and gets the
    interruptor IDs (4089–4103).
13. §14 now lists the finalizer deviation: in v4 a failing finalizer replaces
    the cause (3924–3933).

**Decisions taken on the user's behalf**

14. The doc's name is `FIBER-DESIGN.md`; CLAUDE.md now points here. (Later
    the same day it was split into this folder.)
15. `gen` stays in M2, as CLAUDE.md's milestones say (§9).
16. `runSync` throws the raw error or defect, as v4 does; the traceback stays
    on the Exit (§8.2).
17. An unfinished `runSync` interrupts its fiber so that finalizers run, then
    returns `Die(AsyncFiberError)` (§8.2, §14).
18. Children are interrupted in fork order, and cancelers' failures combine
    like finalizers' (§5.1, §6.3).

---

## 17. What the re-pin to 4.1.5 changed (2026-11-25)

The user chose to re-pin the reference from `effect-smol` beta.98 to Effect
4.1.5. These changes between the two versions touch M1's semantics. Each one
comes with M1's observed output, from scripts run on Lua 5.4 and LuaJIT at
commit `30f4563`.

1. **Defect election** (§2.1, §7.5).
   - Example: `fail("e"):ensuring(die("d")):catchAll(h)`.
   - M1 runs `h` and ends with `Success(caught e)`, so the defect is lost
     without a trace.
   - 4.1.5 fails with `[Die(e), Die(d)]`, and `h` never runs.
2. **The skip rule records the interrupt** (§5.3). It appends only the
   missing Interrupt reasons (`causeAddInterrupts`), and touches nothing else.
   - Example: a fiber interrupted inside
     `uninterruptible(sleep(10):flatMap(→ fail("x")))`.
   - M1 ends with `[Fail(x)]`, so the interrupt is lost.
   - 4.1.5 ends with `[Fail(x), Interrupt]`.
3. **The skip rule drops Fails when it skips a recovery handler** (§5.3).
   - Change 2's example under a `catchAll`: M1 ends with `[Fail(x)]`, 4.1.5
     with `[Interrupt]`.
   - `never:ensuring(fail("cleanup")):catchAll(h)`, interrupted: M1 ends with
     `[Interrupt, Fail(cleanup)]`, 4.1.5 with `[Interrupt]`.
   - Without the `catchAll`, both give `[Interrupt, Fail(cleanup)]`.
4. **`combine` dedupes the whole concatenation** (§2.1). M1 compared only
   `b`'s reasons against `a`'s.
5. **`raceAll`'s all-failed cause elects defects** (§8.1).
6. **Finalizer and canceler failures.** 4.1.5 now combines them with the
   original cause, as M1 already did. §14 drops that row.

These are unchanged between beta.98 and 4.1.5, so M1 still matches them:
- interruptibility masks;
- `timeout` and `timeoutOrElse`;
- `onInterrupt`;
- the async resume and cancel protocol;
- `runSyncExit`;
- children shutdown;
- the op budget.

**Specs for the re-pin.** These amend `spec/cause_spec.lua`,
`effect_spec.lua`, `finalizer_spec.lua`, `interrupt_spec.lua` and
`race_spec.lua`.
- `electDefects`:
  - Fail and Die together become all Dies, in place.
  - A cause with only Fails, only Dies, or only interrupts comes back
    unchanged.
- `findRecoverableError`:
  - With no Die, it returns the first error.
  - With a Die, it returns `false` and the elected cause.
  - With neither a Fail nor a Die, it returns `false` and the cause.
- When both causes are non-empty, `combine` also drops repeats within `a`.
- `addInterrupts` appends only the Interrupt reasons whose `fiberId` is
  missing. It keeps every other reason as it is, duplicates included.
- `fail(e):ensuring(die(d)):catchAll(h)`: `h` doesn't run, and the exit is
  `[Die(e), Die(d)]`.
- A finalizer that fails after a failure keeps both Fails. One that dies after
  a failure elects the Fail.
- `raceAll` with one racer that fails and one that dies fails with two Dies.
- Interrupted inside `uninterruptible(...)`, which then fails: the exit has
  the failure and the Interrupt.
- The same under a `catchAll`: the handler doesn't run, and the exit is the
  Interrupt alone.
- `never:ensuring(fail("cleanup")):catchAll(h)`, interrupted:
  - the exit is the Interrupt alone;
  - without the `catchAll`, it is `[Interrupt, Fail(cleanup)]`.
- A finalizer that dies during an interrupt keeps its Die, even when a
  `catchAll` is skipped.

**Decisions taken on the user's behalf**

19. **Dropping Fails (change 3) follows 4.1.5.** A finalizer's Fail during an
    interrupt is lost if a recovery handler is skipped later. Dies are always
    kept. The user confirmed this on 2026-11-25, over keeping the Fails as a
    deviation. CLAUDE.md's rule that "finalizer errors are added to the
    Cause" now names this exception.
20. **The pin is the release tag** (`e3aca1f`), not `main` (`296c209` on
    2026-11-24). `main` changes `forkUnsafe` and `catchReasons` after the
    release, and neither affects Leffect.
