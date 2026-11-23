# Leffect

An Effect-TS (v4)-style effect system for Lua: lazy effects, a fiber runtime,
typed errors, structured concurrency, interruption, resource safety, and
services/layers. Effect TS's behavior is the reference: when in doubt, match it.

## Decisions (settled)

- **Targets:** LuaJIT 2.1 and Lua 5.4, both tested in CI. Write in the common
  subset: Lua 5.1 syntax plus yieldable `pcall`. No `//`, no bitwise operators,
  no `<close>`, no integer-only APIs. Plain Lua 5.1 is unsupported (it can't
  yield across `pcall`).
- **Hosts:** the runtime is host-agnostic behind a scheduler interface:
  `scheduler:schedule(fn)` (next tick), `scheduler:after(ms, fn)` returning a
  cancel function, and `scheduler:now()`. Build adapters in this order: test
  scheduler (pure Lua, virtual clock) → luv → OpenResty → LÖVE/Defold tick.
- **Async primitive:** `Effect.async(function(resume) ... return canceler end)`.
  Every async operation returns a canceler. `resume` is one-shot: ignore every
  call after the first.
- **Interruption:**
  - It's cooperative and checked between instructions and at async suspension.
  - `fiber:interrupt()` waits for the target's finalizers to finish;
    `interruptFork` doesn't wait.
  - Interruption is a Cause, not a failure: `catchAll` must not catch it.
  - Finalizers always run uninterruptibly, and their errors are added to the
    Cause.
  - The runtime never throws into user code. On interrupt, abandon the
    suspended coroutine. On 5.4 call `coroutine.close` when available.
- **Errors:** expected failures are tagged tables (`{ _tag = "NotFound", ... }`).
  Defects are caught with `xpcall(..., debug.traceback)`. Exit is
  Success | Failure(Cause). Cause = Fail | Die | Interrupt | Sequential | Parallel.
- **API style:** methods via a shared metatable (`eff:map(f)`, `eff:flatMap(f)`)
  plus module functions (`Effect.succeed`, `Effect.all`).
- **Types:** plain Lua with LuaLS `---@` annotations from day one. Teal, Luau
  and Nebra definition files may come later.

## Layout

```
src/leffect/
  init.lua          -- public entry
  effect.lua        -- constructors + combinators (instruction tables)
  exit.lua
  cause.lua
  runtime.lua       -- fiber run loop
  fiber.lua
  scheduler/test.lua
spec/               -- busted specs
```

## Tooling

- Tests: `busted` · Format: `stylua` · Lint: `luacheck` (or `selene`)
- Package: LuaRocks rockspec
- CI: GitHub Actions matrix (LuaJIT 2.1, Lua 5.4) via `leafo/gh-actions-lua` and
  `leafo/gh-actions-luarocks`

## Runtime rules

- Effects are data: tables with an `_op` field. Nothing runs until a runtime
  runs it.
- The run loop is a `while` loop over an explicit continuation stack. It must
  never recurse, so a million chained `flatMap`s must not overflow.
- Before implementing any feature, write busted specs describing Effect TS's
  behavior in its edge cases (for example, interrupt during acquire, or failure
  inside a finalizer). Then make them pass.

## Milestones

- **M0, effects as data:** `succeed`, `fail`, `die`, `sync`, `map`, `flatMap`,
  `catchAll`, Exit, Cause, `runSync`.
  Done when: 1e6 flatMaps don't overflow, `fail` short-circuits, a throw inside
  `sync` becomes a defect with a traceback.
- **M1, fibers:** test scheduler, `async` with cancelers, fibers,
  `fork`/`join`, `interrupt`, finalizer stack, `ensuring`,
  `uninterruptibleMask`, `sleep`, `race`, `timeout`.
  Done when: the virtual clock drives `sleep`, a timeout interrupts the loser,
  finalizers run on interrupt, a late callback is ignored.
- **M2, ergonomics:** `gen` on coroutines, `catchTag`, `Scope`,
  `acquireRelease`, `all`/`race`/`forEach` with concurrency limits.
- **M3, real world:** luv adapter, `runCallback`, Context/Tag/Layer, FiberRef.
- **Later:** concurrency primitives (Ref, Deferred, Queue, Semaphore, PubSub),
  Schedule, Clock/Random services, logging/tracing, Equal/Hash, then Stream,
  Schema, STM, platform modules.

## Reference

Effect v4's fiber runtime source (effect-smol repo) for the run loop's
structure.
