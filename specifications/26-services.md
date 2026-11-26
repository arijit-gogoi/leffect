# Services: Context, keys and references

Part III (M3) of the [Leffect specifications](README.md).

## 26. Services

M2 gave each fiber a context that holds only its Scope (§18). M3 makes the
context public, following v4's `Context` module (`Context.ts` at 4.1.5):
- **A service key** is a Service: `Context.Service("app/Database")`.
- **A fiber-local value** is a `Context.Reference`, a key with a default
  value. Its value changes only when a new one is provided for a region
  (§26.3).

Leffect tracks v4, so these are its only kinds of key (decisions 31 and 32).

### 26.1 Context values

```lua
---@class leffect.Context
---@field map table<string, any> -- service by key string; never changed once built
```

- As in M2, a context is an immutable table of services keyed by strings. M3
  wraps that table in an object with its own metatable. `Context.isContext`
  can then tell a context from a layer or a list (§27.5), which a bare table
  can't do.
- Adding a service copies the map. v4 shares structure through a chain of
  overlays, and flattens the chain after enough reads (`lookup`, Context.ts
  546). That is an optimization, left for later (§15).
- **A service can't be nil.** A Lua table can't hold nil, and nil has to keep
  meaning "absent". Every function that puts a service into a context raises
  "Context.add: a service can't be nil". Inside an effect, the effect dies with
  that message instead.
- Two keys with the same string name the same service, as in v4.

| Function | Semantics |
|---|---|
| `Context.empty()` | The context with no services, shared. Root fibers start with it. A function, as in v4. |
| `Context.make(key, service)` | A context with one service. |
| `Context.add(ctx, key, service)` | A copy of `ctx` with `service` under `key`. |
| `Context.get(ctx, key)` | The service. For a missing Reference, its default (§26.3). For a missing Service, it raises "Service not found: " followed by the key. |
| `Context.getOrElse(ctx, key, orElse)` | The service. For a missing Reference, its default. For a missing Service, `orElse()`. |
| `Context.merge(a, b)` | The services of `a` and `b`. Where both have a key, `b`'s service wins. |
| `Context.mergeAll(...)` | The same for any number of contexts. Later ones win. |
| `Context.isContext(x)`, `Context.isKey(x)`, `Context.isReference(x)` | Type checks. |

In v4, `Context.getOption` and `Effect.serviceOption` return an Option. They
wait for an Option type (§15), as `timeoutOption` does.

### 26.2 Keys

```lua
local Database = Context.Service("app/Database")
```

A key is an effect, as in v4: `Key` extends `Effect`, and its `evaluate`
reads the fiber's context (`ServiceProto`, Context.ts 277). Running the key
succeeds with the service:

```lua
local program = Effect.gen(function(run)
  local db = run(Database)
  return db.query("select 1")
end)
```

- **Representation.** A key is a `WithFiber` effect with extra fields. It uses
  the shared metatable and needs no new op.

  ```lua
  function Context.Service(name)
    local key
    key = setmetatable({
      _op = "WithFiber",
      f = function(fiber) return lookup(fiber.context, key) end,
      key = name,            -- the string, "app/Database"
      defaultValue = nil,    -- a function, for a Reference
      use = useService,
      useSync = useServiceSync,
      [KEY] = true,          -- private marker for Context.isKey
    }, EffectMT)
    return key
  end
  ```

  `lookup` returns an Exit: the service, the Reference's default, or the Die
  below.
- **A missing service is a defect.** The effect dies with "Service not found:
  app/Database". v4's `get` throws an Error with the same message (Context.ts
  1037–1110). The Die has no traceback, because the lookup runs inside the
  loop, far from the user's code. `catchAll` doesn't catch it.
- `Effect.service(key)` returns `key` itself, as in v4.
- `key:use(f)` is `withFiber(fiber -> f(get(fiber.context, key)))`.
  `key:useSync(f)` is the same, but wraps the result in `succeed`.
- `Context.Service` takes only the key string. v4 also has a class form,
  `Context.Service<Self, Shape>()(id, { make })`, which is TypeScript syntax
  (§14).

### 26.3 References

```lua
local LogLevel = Context.Reference("app/LogLevel", {
  defaultValue = function() return "info" end,
})
```

- A Reference is a key with a `defaultValue`. Looking it up in a context
  without it gives the default instead of failing.
- The default is computed the first time a lookup needs it. It is then cached,
  so every fiber and context shares it.
  - v4 caches it on the Reference itself (`getDefaultValue`, Context.ts 1091).
    Leffect can't: a Reference is an effect, and the loop never mutates an
    effect table (invariant 13).
  - So the cache is a private table with weak keys, keyed by Reference. It
    stores each value in a box, so a nil default is computed only once too.
- If `defaultValue` throws, nothing is cached. The lookup dies with the error
  and its traceback, and the next lookup calls `defaultValue` again.
- The default may be nil. A provided value may not (§26.1).
- Running the Reference reads it. `provideService` and `updateService`
  change it for a region, and `updateServiceScoped` for the rest of a scope
  (§26.4). Nothing else changes it.
- A fork starts with its parent's context (§18), and a join merges nothing
  back.

v4 also has built-in references: the log level, the tracer settings, the
scheduler and the op budget. The first two belong to modules that are Later in
CLAUDE.md. The scheduler and the op budget stay where M1 put them (§28.1).

### 26.4 Reading and providing services

Every function that provides services changes the fiber's context for one
region. When the region ends, by any path, the old context comes back. All of
them are built on `updateContext` (internal-effect.ts 2281). It works like
M2's `provideService` (§18): it pushes the `SetContext` frame and changes the
context in the same `withFiber` step.

```lua
function Effect.updateContext(self, f)
  return withFiber(function(fiber)
    local previous = fiber.context
    local next = f(previous)
    if next == previous then return self end
    push(fiber, { _op = "SetContext", context = previous })
    fiber.context = next
    return self
  end)
end
```

| Function | Semantics |
|---|---|
| `Effect.service(key)` | `key` itself. |
| `Effect.provideService(self, key, service)` | Runs `self` with `service` under `key`. |
| `Effect.provideServiceEffect(self, key, acquire)` | Runs `acquire`, then provides its value to `self`. If `acquire` fails, the effect fails and `self` never runs. |
| `Effect.updateService(self, key, f)` | Runs `self` with `f(current)` under `key`. For a missing Reference, `f` gets the default. For a missing Service, the effect dies. |
| `Effect.updateServiceScoped(key, f, options?)` | Sets `f(current)` for the rest of the current scope. When the scope closes, it puts the original back, unless something has changed the value since. `options.reset(original, updated, current)` replaces that rule. Below the cut line (internal-effect.ts 2335). |
| `Effect.context()` | Succeeds with the fiber's context. A function, as in v4. |
| `Effect.contextWith(f)` | `f(context)` is the next effect. |
| `Effect.provideContext(self, ctx)` | Runs `self` with `ctx` merged over the current context. An Exit comes back unchanged, as in v4. |
| `Effect.updateContext(self, f)` | Runs `self` with the context `f(context)`. Public in v4 too. |
| `Effect.provide(self, source, options?)` | Provides a Layer, a list of layers, or a Context (§27.5). |

- `provideService`, `provideServiceEffect`, `updateService`,
  `provideContext`, `updateContext` and `provide` are also methods.
- A fork inside the region starts with the region's context. It keeps that
  context after the region ends (§18).
- In v4, `updateContext` restores the context through `onExitUnsafe`, a frame
  pushed directly. The `SetContext` frame does the same job (§18).
- The `updateContext` above lives in `leffect.runtime`, next to the frames
  it pushes, so `leffect.scope` can use it without requiring
  `leffect.effect`. `Effect.updateContext` adds a check: if `f` returns
  something other than a Context, the effect dies. `Scope.provide(eff,
  scope)` is `provideService(eff, Scope.Scope, scope)`.
- `provideService` with a nil service returns an effect that dies (§26.1).
  `updateService` is the key run as an effect, then `provideService` of
  `f(current)`. So a missing Service dies before `f` is called.
- `updateServiceScoped` is the one exception to invariant 15. It changes the
  fiber's context without pushing a `SetContext` frame, so the change outlasts
  the call. The finalizer it adds to the scope puts the original back, as in
  v4.
- `Scope.Scope` is the key of the current scope, `"leffect/Scope"`, as in v4.
  It replaces M2's `Scope.contextKey` string. `Effect.scope` keeps M2's error
  message (§19.2). `run(Scope.Scope)` outside a scope dies with the generic
  "Service not found: leffect/Scope".

### 26.5 The release context

v4 runs a release in the context where its resource was acquired
(internal-effect.ts 4252–4280):
- `acquireRelease` captures the fiber's context when it starts.
- `Effect.addFinalizer` captures it when it adds the finalizer.
- Both run the finalizer under `provideContext(f(exit), captured)`. So the
  captured services win over those of the fiber that closes the scope.

M2 left this out, because its context held only the Scope (§14, §15). M3 adds
it:

```lua
function Effect.addFinalizer(f)
  return Effect.scope:flatMap(function(scope)
    return withFiber(function(fiber)
      local captured = fiber.context
      return Scope.addFinalizerExit(scope, function(exit)
        return Effect.provideContext(f(exit) or Exit.void, captured)
      end)
    end)
  end)
end
```

- A release can use a service that was provided around the acquire, even when
  the scope closes outside that region.
- The captured context includes the Scope. Inside a finalizer added by
  `Effect.addFinalizer` or `acquireRelease`, `Effect.scope` is therefore the
  scope the finalizer belongs to, which is now closed. It is not the outer
  scope.
  - This changes the outcome of one approved M2 spec: "inside one,
    `Effect.scope` is the outer scope" (§23, `spec/context_spec.lua` line
    153). No other M2 spec reads the context inside a finalizer or a
    release.
- The raw functions `Scope.addFinalizer` and `Scope.addFinalizerExit` capture
  nothing, in v4 as here. Their finalizers run in the context of the fiber
  that closes the scope. `scoped` has already restored the outer context by
  then (§18, §19.4).
  - The amended M2 spec uses them, so it still checks that order (§30).
