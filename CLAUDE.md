
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
  Every async operation returns a canceler (a function, an Effect, or nil).
  `resume` is one-shot: ignore every call after the first. Wakeups always go
  through `scheduler:schedule`, so run loops never nest.
- **Interruption:**
  - It's cooperative and checked between instructions and at async suspension.
  - `fiber:interrupt()` waits for the target's finalizers to finish;
    `interruptFork` doesn't wait.
  - Interruption is a Cause, not a failure: `catchAll` must not catch it.
  - Finalizers always run uninterruptibly, and their errors are added to the
    Cause. One exception, as in Effect 4.1.5: when an interrupt skips a
    recovery handler, the Fail reasons are dropped, and only the Die and
    Interrupt reasons stay (`specifications/03-run-loop.md` §5.3).
  - The runtime never throws into user code. On failure or interrupt, abandon
    the suspended gen coroutine.
- **Errors:** expected failures are tagged tables (`{ _tag = "NotFound", ... }`).
  Defects are caught with `xpcall` plus a traceback. Exit is
  Success | Failure(Cause), and exits are themselves effects. Cause is a flat
  list of reasons (Fail | Die | Interrupt), as in Effect v4.
- **API style:** methods via a shared metatable (`eff:map(f)`, `eff:flatMap(f)`)
  plus module functions (`Effect.succeed`, `Effect.all`).
- **Types:** plain Lua with LuaLS `---@` annotations from day one. Teal, Luau
  and Nebra definition files may come later.

## Layout

```
src/leffect/
  init.lua          -- public entry: Cause, Context, Effect, Exit, Fiber, Scope, run
  core.lua          -- effect representation: shared metatable, op names, primitives
  effect.lua        -- public API: constructors, combinators, runners
  exit.lua
  cause.lua
  runtime.lua       -- fiber run loop, frames, gen
  fiber.lua
  context.lua       -- Context: services, Service and Reference keys
  scope.lua         -- Scope
  scheduler/test.lua
spec/               -- busted specs
specifications/     -- the runtime design, one file per topic
```

## Tooling

- Tests: `busted` · Format: `stylua` · Lint: `luacheck` (or `selene`)
- Package: LuaRocks rockspec
- CI: GitHub Actions matrix (LuaJIT 2.1, Lua 5.4) via `leafo/gh-actions-lua` and
  `leafo/gh-actions-luarocks`

## Runtime rules

- Effects are data: tables with an `_op` field. Nothing runs until a runtime
  runs it.
- The run loop is a `while` loop over an explicit stack of frames (the frame
  protocol in `specifications/03-run-loop.md` §3). Use it from M0 on. The loop
  must never recurse, so a million chained `flatMap`s must not overflow.
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
- **M3, real world:** luv adapter, `runCallback`, Context (`Context.Service`,
  `Context.Reference`), Layer.
- **Later:** concurrency primitives (Ref, Deferred, Queue, Semaphore, PubSub),
  Schedule, Clock/Random services, logging/tracing, Equal/Hash, then Stream,
  Schema, STM, platform modules.

## Reference

- `specifications/`: the runtime design, one file per topic. Its `README.md`
  holds the status, the reference and the section map.
  - Part I (files `00`–`16`) covers frames, the run loop, async, interruption
    delivery, structured concurrency, gen, the scheduler, the invariants and
    the M1 spec list.
  - Part II (files `18`–`23`) covers M2: the fiber context, Scope, resources,
    typed catches, `forEach`/`all`, and the M2 spec list.
  - Part III (files `26`–`30`) covers M3: services (Context, keys,
    references), layers, `runCallback`, the luv scheduler, and the M3 spec
    list. The user approved it on 2026-11-26.

  Follow it. Propose changes to the specifications before deviating in code.
- Effect v4's source, pinned to Effect 4.1.5: the `effect@4.1.5` tag of
  `Effect-TS/effect` (commit `e3aca1f`). Read
  `packages/effect/src/internal/effect.ts` and `internal/core.ts` for the run
  loop's structure and for the behavior to match. M1 was first written against
  `Effect-TS/effect-smol` @ `3a1128c` (4.0.0-beta.98), which is now frozen.
