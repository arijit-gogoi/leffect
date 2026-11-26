# M3 specs, implementation order and decisions

Part III (M3) of the [Leffect specifications](README.md).

## 30. Specs for M3

Write these before the code. They go in new files: `spec/service_spec.lua`,
`layer_spec.lua`, `luv_scheduler_spec.lua` and `luv_live_spec.lua`. The
runner specs extend `spec/runtime_spec.lua`.

Two kinds of M2 spec change, all in `spec/context_spec.lua`:
- **One outcome flips:** the spec at line 153 (see "The release context").
- **Six specs are restated.** The `Context` block at the top of the file tests
  M2's internal API: string keys, `Context.empty` as a table, and
  `Context.provide`. M3 replaces that API (§26). The six specs keep their
  behaviors, restated with keys, `Context.empty()` and `provideService`:
  - adding copies;
  - a root fiber starts empty;
  - every fork inherits the context;
  - and `provide` sets a service for its effect only, and puts the previous
    context back after a failure and on interrupt.

  One detail changes: `Context.get` on a missing key returned nil in M2, and
  now raises (§26.1).

No spec uses `Scope.contextKey`, so removing it changes no spec.

**Context values**
- `make` then `get` gives the service. `add` leaves the original context
  unchanged.
- `merge(a, b)`: where both have a key, `b`'s service wins. In `mergeAll`,
  later contexts win.
- `get` on a missing Service raises "Service not found: " followed by the key.
  `getOrElse` calls `orElse` instead.
- A missing Reference gives its default. `defaultValue` is called once, across
  contexts and fibers. A provided value wins over the default. A default may
  be nil, and is computed only once too. The Reference table itself is never
  changed.
- If `defaultValue` throws, the lookup dies with the error, and the next
  lookup calls `defaultValue` again.
- A nil service raises in `make` and `add`, and makes `provideService` die.
- A key that isn't a key raises.
- Two keys with the same string share one service.
- `isContext`, `isKey` and `isReference` tell contexts, keys and references
  from effects, layers and plain tables.

**Keys and providing**
- `run(key)` in a gen body gives the service, and so does `key:flatMap(f)`.
  `Effect.service(key)` is `key`.
- A missing Service dies with "Service not found: " and the key, and
  `catchAll` doesn't catch it.
- `key:use(f)` and `key:useSync(f)` call `f` with the service.
- `provideService` covers only its region. After the region ends, by success,
  failure or interrupt, the outer service is back, or none. Nested regions:
  the innermost wins.
- A fork inside the region sees the service, and keeps it while it runs after
  the region ends.
- `provideServiceEffect` runs `acquire` once, before `self`. If `acquire`
  fails, `self` never runs.
- `updateService` passes the current value to `f`. For a missing Reference it
  passes the default. For a missing Service the effect dies.
- `provideContext` merges, and the given context wins. An Exit comes back
  unchanged.
- `Effect.context()` gives the fiber's context. Inside `provideService`, the
  context has the service. `contextWith` passes the context.
- `provideService`, `provideServiceEffect`, `updateService`,
  `provideContext`, `updateContext` and `provide` work as methods.
- `run(Scope.Scope)` inside `scoped` gives the scope. Outside a scope it dies
  with "Service not found: leffect/Scope". `Effect.scope` keeps its M2
  message.
- Below the cut line, `updateServiceScoped`:
  - it sets the value for the rest of the scope;
  - when the scope closes, it puts the original back, unless something has
    changed the value since;
  - `options.reset` replaces that rule.

**The release context** (§26.5)
- An `acquireRelease` release sees a service that was provided around the
  `acquireRelease`, even when the scope closes outside that region.
- The same holds for a finalizer added with `Effect.addFinalizer`. Inside it,
  `Effect.scope` is the scope it was added to.
- A finalizer added with `Scope.addFinalizerExit` runs in the context of the
  fiber that closes the scope. Inside it, `Effect.scope` is the outer scope.
  - This spec replaces the M2 spec "runs a scope's finalizers in the outer
    context" (`spec/context_spec.lua` line 153), which used
    `Effect.addFinalizer`.
  - It also narrows §23's Context bullet to the raw Scope functions.

**Layers**
- `Effect.provide(eff, Layer.succeed(K, v))`: `eff` sees `v`. Outside the
  provide, `K` is missing.
- `Layer.sync`'s thunk runs once per build.
- `Layer.effect` with an `acquireRelease` inside:
  - the resource is acquired before `eff` runs;
  - it is released after `eff` ends, by success, failure or interrupt;
  - the release gets `eff`'s exit.
- A failing build:
  - `eff` never runs, and the provide fails with the build's error;
  - what earlier layers acquired is released, before the failure comes out:
    a `catchAll` fallback is built after the release.
- One layer used twice in a graph is built once.
  `mergeAll(A:provide(C), B:provide(C))` acquires C once. It releases C once,
  after A and B are released.
- Requests that arrive while a shared build is running wait for it. When C
  takes 100 ms, the graph above still builds C once, and A and B get the same
  instance.
- A shared build that fails while two users wait for it fails both of them,
  after one attempt. A request that comes later builds again.
- A request that comes after the last user released a shared build builds it
  again.
- `Layer.fresh(C)` builds C again, even in the same graph.
- Sibling provides build their own copies: two `Effect.provide(x, C)` in a row
  acquire C twice.
- A nested provide reuses the outer build. Inside `Effect.provide(outer, C)`,
  `Effect.provide(inner, C)` doesn't acquire C again. With
  `{ fresh = true }`, it does.
- `mergeAll` builds its members at the same time: two 100 ms layers take
  100 ms. It also releases them at the same time.
- When one member of a `mergeAll` fails, the others are interrupted. Their
  releases run before the provide fails.
- Where two layers have a key, the later one wins in `mergeAll`.
  `provideMerge` gives the services of both layers, and `self`'s win.
  `provide` gives only `self`'s.
- `provide(self, that)`: `self`'s construction sees `that`'s services, and
  `self` is released before `that`.
- A layer's construction sees the services of the fiber that provides it.
- `flatMap` builds the second layer from the first layer's context.
- `orDie` turns a build failure into a Die. `catchAll` builds the fallback
  layer. `catchCause` gets the cause.
- An interrupt during a build releases what was built, and `eff` never runs.
- `Layer.build` inside `scoped` gives a Context with the services. They are
  released when the scope closes. Outside a scope, `Layer.build` dies with
  `Effect.scope`'s message.
- `Layer.launch` holds the layer until it is interrupted, then releases it.
- `Effect.provide` with a list merges the layers. With a Context, it provides
  the Context. With anything else, it dies.
- Layers have methods.
- Below the cut line: `Layer.unwrap`, `tap`, `tapError`, `tapCause` and
  `catchTag`.

**Running**
- `runCallback`'s `onExit` gets the exit of a success, a failure and a defect.
- The interruptor interrupts the fiber. Its finalizers run, and `onExit` gets
  an interrupt cause with the given fiber id, or with no id.
- Called before the fiber starts, the interruptor stops it before any of its
  code runs. Called after the fiber has ended, it does nothing.
- Without `onExit`, the effect still runs.
- With `uninterruptible = true`, the interruptor doesn't stop an effect that
  has no interruptible region. The fiber ends with the effect's own exit. (The
  runtime already works this way: an interrupt is delivered only while the
  fiber is interruptible, §7.2.)
- `onFiberStart` gets the fiber before `runFork` returns.
- `runFork` and `runCallback` raise when `scheduler` is missing.
- Below the cut line: the root fibers of `runForkWith(ctx)`,
  `runCallbackWith(ctx)`, `runSyncWith(ctx)` and `runSyncExitWith(ctx)` start
  with `ctx`.

**luv scheduler, with a fake `uv`**
- Tasks run in FIFO order at the next idle callback, not before.
- A task queued during a batch runs in the next iteration, not the same one.
- The idle handle:
  - starts on the first `schedule`;
  - stops when the queue is empty;
  - starts again on the next `schedule`;
  - is the only one the scheduler creates.
- A task that throws: the error leaves the idle callback, and the next
  iteration runs the rest of the queue.
- `after` passes integer delays to the timer: 1.5 becomes 2, and -5, NaN and
  `math.huge` become 0, 0 and 2^53.
- `after`'s cancel stops the timer. A second cancel, or a cancel after the
  timer fired, does nothing.
- `now` returns `uv.now()`.
- `run`:
  - it returns the exit, and stops the loop when the fiber ends;
  - it returns nil and the fiber when the loop runs out of work first;
  - it raises when the loop is already running;
  - it removes its observer before it returns.
- Requiring the module doesn't load luv, and `new` doesn't either when
  `options.uv` is given.

**luv scheduler, live** (pending without luv, §29.7)
- `Effect.sleep(20)` ends after at least 20 ms of `uv.now()`.
- `timeout` interrupts a slower effect. A callback that arrives after the
  timeout is ignored.
- `runCallback` followed by `uv.run()` delivers the exit.
- A busy fiber that yields lets a timer fire before the fiber ends.

## 31. Implementation order for M3

These make M3 done:

1. **Context values and keys** (§26.1 to §26.3):
   - rewrite `leffect.context`: the metatable, the map, `Service`,
     `Reference` and the table functions;
   - `Scope.Scope` replaces `Scope.contextKey`;
   - move M2's call sites to keys.
2. **The Effect service API** (§26.4): `updateContext`, moved into
   `leffect.context`, then `provideService`, `provideServiceEffect`,
   `updateService`, `context`, `contextWith`, `provideContext`, and the
   methods.
3. **The release context** (§26.5), with the amended M2 spec. (The six
   restated `Context` specs go with step 1.)
4. **Layers** (§27):
   - the data, `fromBuild`, `fromBuildMemo`, and the MemoMap with its
     Deferred;
   - the constructors;
   - `mergeAll`, `merge`, `provide`, `provideMerge`, `flatMap`, `orDie`,
     `catchAll`, `catchCause` and `fresh`;
   - `build`, `buildWithScope`, `buildWithMemoMap`, `launch`, then
     `Effect.provide`.
5. **Run options and `runCallback`** (§28.1 and §28.2).
6. **The luv scheduler** (§29): first with the fake-`uv` specs, then the live
   specs and the CI step.

Below the cut line, built last:

7. `Effect.updateServiceScoped`.
8. `runForkWith`, `runCallbackWith`, `runSyncWith` and `runSyncExitWith`
   (§28.3).
9. `Layer.unwrap`, `tap`, `tapError`, `tapCause` and `catchTag`.

**Modules.**
- `leffect.context` becomes public. `init.lua` exports it as `Context`.
- `leffect.layer` is new and public, exported as `Layer`.
- `leffect.scheduler.luv` is new.
- `leffect.effect` gets §26.4's functions, `provide`, the run options,
  `runCallback`, and the runners of §28.3.
- `leffect.scope` gets `Scope.Scope`, and loses `contextKey`.
- The rockspec's `build.modules` gets `leffect.layer` and
  `leffect.scheduler.luv`. luv doesn't become a dependency.
- CI's test job gets `luarocks install luv`, and `LEFFECT_REQUIRE_LUV=1` for
  the specs.

**Once M3 is built:**
- delete §14's rows "Context (M2)" and "Release context (M2)";
- narrow §23's Context bullet, and §18's and §19.2's notes about M3;
- update CLAUDE.md's Layout and the README's status line.

## 32. M3 decisions taken on the user's behalf (2026-11-26)

The user asked for this design on 2026-11-25. These were decided here, and
the user approved them with the design on 2026-11-26. On 31 and 32 the user
said: "We are tracking v4, not v3. So `Context.Reference` and
`Context.Service` as per v4 are what we want."

31. **Fiber-local values are `Context.Reference`s** (§26.3), as in v4. A
    Reference changes only for a region, and nothing merges on join.
    CLAUDE.md's M3 line uses v4's names.
32. **Service keys are `Context.Service`s** (§26.2), as in v4.
33. **Keys are effects** built on `WithFiber`. A missing service dies with
    "Service not found: " and the key (§26.2).
34. **A service can't be nil.** A Reference's default can be (§26.1,
    §26.3).
35. **Context values are immutable maps,** copied on every add, with a
    metatable and no methods (§26.1). Overlays wait for a benchmark (§15).
36. **Accessors that return an Option wait** for an Option type (§26.1).
37. **`Scope.Scope` replaces `Scope.contextKey`.** `Effect.scope` keeps
    M2's message (§26.4).
38. **The release context follows v4** (§26.5). This flips the outcome of
    one approved M2 spec, which moves to the raw Scope functions (§30). Six
    more M2 specs, which test M2's internal string-keyed API, are restated
    on the public API with the same behaviors.
39. **Layers have methods,** and v4's `Layer.catch` is `catchAll` (§27).
40. **Sharing follows v4's MemoMap,** nested reuse included. v4's `local`
    option is spelled `fresh`, and the Deferred stays internal (§27.4,
    §27.5).
41. **The scheduler stays on the fiber,** and `runFork` and `runCallback`
    require `options.scheduler` (§28.1).
42. **`runCallback` returns only the interruptor,** as in v4. The run
    options are `scheduler`, `uninterruptible` and `onFiberStart` (§28).
43. **The luv scheduler runs one batch per loop iteration,** as v4's
    MixedScheduler does. This replaces §10.3's drain until empty (§29.2).
44. **The luv scheduler doesn't catch task errors** (§29.4).
45. **`scheduler:run` stops the loop when its fiber ends,** and returns nil
    when the loop runs out of work first (§29.5).
46. **luv is optional and injectable.** Specs use a fake `uv`, and CI runs
    the live specs with luv installed (§29.7).
47. **Logging and fiber-aware tracebacks stay Later.** §15 had pinned them on
    M3, but CLAUDE.md lists logging and tracing under Later.
48. **The cut line** (§31): `updateServiceScoped`, the runners with a
    context, and the rarer layer combinators come last.
