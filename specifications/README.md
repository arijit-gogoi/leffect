# Leffect specifications

The design of Leffect's runtime, one file per topic. Until 2026-11-25 this was
a single file, `FIBER-DESIGN.md`. Older commits and notes cite it by section
number, and the numbers have not changed.

Status: settled for Milestone M1 on 2026-11-25, and re-pinned the same day.
The M2 design (Part II, §18–§25) was drafted and approved on 2026-11-25,
and M2 was built the same day, the items below the cut line included.

**Reference:** Effect 4.1.5, which is the `effect@4.1.5` tag of
`Effect-TS/effect` (commit `e3aca1f`). The files are
`packages/effect/src/internal/effect.ts` and `internal/core.ts`, notably
`FiberImpl`, `exitFailCause`, `callbackOptions`, `setInterruptible`,
`OnExitImpl`, `forkUnsafe`, `raceAll`, `raceFirst` and `runSyncExitWith`.

**History:** M1 was first designed against `effect-smol` @ `3a1128c`
(4.0.0-beta.98), then adapted to Lua.
- §16 lists what the review of that draft changed.
- §17 lists what the re-pin to 4.1.5 changed.

Both list the decisions taken on the user's behalf.

## Sections

Section numbers are global and stable, and cross-references use them (§5.3,
§19). Each file is named after the first section it holds, so §N is in the file
with the largest prefix not above N.

### Part I: the runtime (M1)

| File | Sections |
|---|---|
| [00-overview.md](00-overview.md) | §0 Summary, §1 Goals and non-goals |
| [02-data-model.md](02-data-model.md) | §2 Cause, Exit, and the primitive ops |
| [03-run-loop.md](03-run-loop.md) | §3 The frame protocol, §4 The fiber, §5 The run loop and the skip rule |
| [06-async.md](06-async.md) | §6 Async and cancelers |
| [07-interruption.md](07-interruption.md) | §7 Interruption, masks and finalizers |
| [08-structured-concurrency.md](08-structured-concurrency.md) | §8 Children, `race`/`timeout`, running effects |
| [09-gen.md](09-gen.md) | §9 `gen` on coroutines (built in M2) |
| [10-scheduler.md](10-scheduler.md) | §10 The scheduler interface and the test scheduler |
| [11-invariants.md](11-invariants.md) | §11 Invariants |
| [12-m1-plan.md](12-m1-plan.md) | §12 Specs for M1, §13 Implementation order within M1 |
| [14-deviations.md](14-deviations.md) | §14 Deviations from Effect v4, §15 Open questions |
| [16-history.md](16-history.md) | §16 What the review changed, §17 What the re-pin to 4.1.5 changed |

### Part II: M2

Part II designs M2 on top of Part I's frames and fibers. It follows 4.1.5. §14
lists the deviations, and §25 the decisions taken on the user's behalf.

| File | Sections |
|---|---|
| [18-context.md](18-context.md) | §18 Fiber context |
| [19-scope.md](19-scope.md) | §19 Scope |
| [20-resources.md](20-resources.md) | §20 `acquireRelease`, `acquireUseRelease`, `forkIn`, `forkScoped` |
| [21-typed-errors.md](21-typed-errors.md) | §21 Typed error recovery and `Effect.exit` |
| [22-foreach.md](22-foreach.md) | §22 `forEach` and `all` |
| [23-m2-plan.md](23-m2-plan.md) | §23 Specs for M2, §24 Implementation order, §25 Decisions |
