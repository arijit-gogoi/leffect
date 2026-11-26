# Layers

Part III (M3) of the [Leffect specifications](README.md).

## 27. Layers

A layer builds services. Building it can need other services, can fail, and
can acquire resources that live as long as the layer is in use. This follows
v4's `Layer` module (`Layer.ts` and `internal/layer.ts` at 4.1.5). The public
module is `leffect.layer`, exported as `Layer`.

### 27.1 Data

```lua
---@class leffect.Layer
---@field build fun(memoMap: leffect.Layer.MemoMap, scope: leffect.Scope): leffect.Effect
```

- `build` returns an effect that succeeds with a Context of the layer's
  services. The resources it acquires belong to `scope`.
- Layers share one metatable. `Layer.isLayer` is a metatable check, and layers
  have methods, as effects do: `DatabaseLive:provide(ConfigLive)`.
- Most built-in layers are made by one of two wrappers (Layer.ts 315–416):
  - **`Layer.fromBuild(build)`** forks a child of `scope` for the layer. It
    closes the child if the build fails, so a failing layer releases what it
    acquired.
  - **`Layer.fromBuildMemo(build)`** is `fromBuild` through the MemoMap
    (§27.4): one build per layer per MemoMap.

  Both are public, as in v4, for layers that the constructors below can't
  express. `succeed`, `succeedContext`, `orDie`, `catchAll`, `catchCause` and
  `fresh` set `build` directly, as v4's do (`fromBuildUnsafe`): they add no
  scope of their own.
- **Checks.** TypeScript's types catch these mistakes in v4; Leffect checks
  at run time.
  - A constructor or combinator given something other than a key or a layer
    raises at once.
  - A build dies if its service is nil, or if what should be a Context or a
    layer isn't one. This covers the thunk of `sync` and `syncContext`, the
    effect of `effect` and `effectContext`, and the functions given to
    `suspend`, `flatMap`, `catchAll` and `catchCause`.

### 27.2 Constructors

| Function | Shared | Semantics |
|---|---|---|
| `Layer.succeed(key, service)` | no | One service. |
| `Layer.succeedContext(ctx)` | no | Every service in `ctx`. |
| `Layer.empty` | no | No services. |
| `Layer.sync(key, thunk)` | yes | The service `thunk()` returns, called once per build. |
| `Layer.syncContext(thunk)` | yes | The same, where `thunk` returns a Context. |
| `Layer.effect(key, eff)` | yes | The value `eff` succeeds with. `eff` runs with the layer's scope as its current scope. An `acquireRelease` inside `eff` therefore ties the resource to the layer. |
| `Layer.effectContext(eff)` | yes | The same, where `eff` succeeds with a Context. |
| `Layer.effectDiscard(eff)` | yes | Runs `eff` for its effects, and provides nothing. |
| `Layer.suspend(thunk)` | yes | Builds the layer that `thunk()` returns. |
| `Layer.unwrap(eff)` | yes | Builds the layer that `eff` succeeds with. Below the cut line. |

"Shared" means memoized (§27.4). `succeed` and `succeedContext` skip the
MemoMap, as in v4, since there is nothing to build. As in v4, the effect of
`Layer.effect` may use the current Scope (Layer.ts 1039–1134), so no separate
constructor is needed for layers that acquire resources.

### 27.3 Composition

| Function | Semantics |
|---|---|
| `Layer.mergeAll(...)` | Builds every layer at the same time, and merges their services. Where two have a key, the later layer wins. Shared. |
| `Layer.merge(self, that)` | `mergeAll(self, that)`. `that` may be a list. |
| `Layer.provide(self, that)` | Builds `that` first, then `self` with `that`'s services. A list in `that` is merged. Only `self`'s services come out. Shared. |
| `Layer.provideMerge(self, that)` | The same, but both layers' services come out. Where both have a key, `self` wins. |
| `Layer.flatMap(self, f)` | Builds `self`, then the layer `f(context)`. |
| `Layer.orDie(self)` | A build failure becomes a defect. |
| `Layer.catchAll(self, f)` | When the build fails, builds `f(err)` instead. v4 calls it `Layer.catch`; the name follows `Effect.catchAll` (decision 25). |
| `Layer.catchCause(self, f)` | The same, with the cause. |
| `Layer.fresh(self)` | Builds `self` with a new MemoMap, so it shares nothing with the rest of the graph. |
| `Layer.tap`, `tapError`, `tapCause`, `catchTag` | Below the cut line. |

**mergeAll** (Layer.ts 1209–1224):

```lua
local function mergeAllEffect(layers, count, memoMap, scope)
  local parent = Scope.forkUnsafe(scope, "parallel")
  return Effect.forEach(layers, function(layer)
    return layer.build(memoMap, Scope.forkUnsafe(parent, "sequential"))
  end, { concurrency = count }):map(function(contexts)
    local merged = Context.empty()
    for i = 1, contexts.n do
      merged = Context.merge(merged, contexts[i])
    end
    return merged
  end)
end
```

- The builds run at the same time, so two layers that take 100 ms each build
  in 100 ms.
- A failing build stops the others, as in `forEach` (§22.2). They are
  interrupted, and their finalizers finish before the failure comes out.
- The parallel scope releases the members at the same time.

**provide** (`provideWith`, Layer.ts 1361–1380) builds `that`, then runs
`self.build(memoMap, scope)` under `provideContext(thatContext)`. Both builds
use the same scope, and `self` forks its child second, so `self` is released
before `that`.

### 27.4 Sharing: the MemoMap

A layer that appears twice in one graph is built once. Layers are told apart
by identity, so to share a layer, share the value. `Layer.fresh` opts out.

```lua
---@class leffect.Layer.MemoMap
---@field parent leffect.Layer.MemoMap?
---@field entries table<leffect.Layer, Entry>

---@class Entry
---@field observers integer   -- how many scopes use this build
---@field deferred Deferred   -- the build's exit, once there is one
---@field scope leffect.Scope -- owns the build's resources
---@field finalizer fun(exit: leffect.Exit): leffect.Effect
```

This follows v4's `MemoMapImpl` (Layer.ts 253–275 and 418–469).
- **`getOrElseMemoize(layer, scope, build)`:**
  - If this map or a parent has an entry for `layer`, add `scope` as an
    observer, and wait for the entry's exit.
  - Otherwise, create the entry, add `scope` as an observer, publish the
    entry, and build in the entry's own scope. An `onExit` completes the
    entry's Deferred with the build's exit, even when the first requester is
    interrupted.
  - A closed `scope` can't own a shared entry. Then the layer is built in
    `scope`, and not shared.
- **Observing.** Adding an observer increments `observers` and adds the
  entry's finalizer to the observer's scope. Both happen in one synchronous
  step, so an interrupt can't strand an observer.
- **The finalizer** decrements `observers`. The last one removes the entry,
  and closes the entry's scope with its exit. A shared layer is thus released
  once, after its last user.
- **A failed build is shared only while it runs.** Requests that arrive
  during the build wait for it, and get the same failure without building
  again.
  - Each user's observer finalizer is on the layer scope that `fromBuild`
    forked for it. `fromBuild` closes that scope when the build fails.
  - So the last failing user removes the entry. A request that comes later
    builds the layer again.
- **The current MemoMap** is a service, `Layer.CurrentMemoMap`, under
  `"leffect/Layer/CurrentMemoMap"`. `buildWithMemoMap` provides it to the
  build, and adds it to the built context (Layer.ts 662–681).
  - `build` and `buildWithScope` fork the current MemoMap if the context has
    one. Otherwise they make a new one (`CurrentMemoMap.forkOrCreate`,
    Layer.ts 600–605).
  - So a `provide` inside an effect that got its services from another
    `provide` reuses the layers the outer one built. Sibling `provide` calls
    build their own copies. v4 documents this behavior for `Effect.provide`.
- **The Deferred is internal.** It holds an exit and a list of waiters. It is
  awaited with `async`, and completed once, the way `fiber:await` works with
  observers. A public Deferred is Later (CLAUDE.md).

### 27.5 Building and providing

| Function | Semantics |
|---|---|
| `Layer.build(layer)` | Effect: builds the layer into the current scope, and succeeds with the Context. Without a scope, it dies with `Effect.scope`'s message (§19.2). |
| `Layer.buildWithScope(layer, scope)` | Builds into `scope`. |
| `Layer.buildWithMemoMap(layer, memoMap, scope)` | Builds into `scope`, with `memoMap`. |
| `Layer.makeMemoMap`, `Layer.makeMemoMapUnsafe()` | A new MemoMap: an effect, and a function. |
| `Layer.launch(layer)` | Builds the layer, then never ends. When interrupted, it releases the layer. For a layer that is the whole program, such as a server. |
| `Effect.provide(eff, source, options?)` | See below. |

`Effect.provide` (internal/layer.ts 8–24):

```lua
function Effect.provide(self, source, options)
  if Context.isContext(source) then
    return Effect.provideContext(self, source)
  end
  local layer = source
  if not Layer.isLayer(source) then
    local count = layerCount(source) -- nil unless it is a list of layers
    if count == nil then
      return Effect.die("Effect.provide: expected a Layer, a list of layers or a Context")
    end
    layer = Layer.mergeAll(unpack(source, 1, count))
  end
  return Effect.scopedWith(function(scope)
    local built
    if options and options.fresh then
      built = Layer.buildWithMemoMap(layer, Layer.makeMemoMapUnsafe(), scope)
    else
      built = Layer.buildWithScope(layer, scope)
    end
    return built:flatMap(function(context)
      return Effect.provideContext(self, context)
    end)
  end)
end
```

- The layer builds into a new scope. That scope closes with the exit of
  `self` after `self` ends, by success, failure or interrupt.
- If the build fails, the provide fails with the build's error, and `self`
  never runs. The scope closes, which releases what was built.
- The build runs on the calling fiber, in the caller's context, so a layer may
  use services the caller already has. `mergeAll`'s members run on forks of
  it.
- v4's option is `local`, which is a Lua keyword: `options.local` can't be
  written. Leffect calls it `fresh`, after `Layer.fresh`, which does the same
  for one layer (§14).
- An empty list provides nothing. A table that is neither a Layer, a Context
  nor a list of layers makes the effect die with "Effect.provide: expected a
  Layer, a list of layers or a Context". A list is a table without a
  metatable whose keys are 1 to n, each holding a layer.
- `leffect.layer` requires `leffect.effect`. To break the cycle,
  `Effect.provide` requires `leffect.layer` when it is first called.
