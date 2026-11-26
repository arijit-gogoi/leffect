# Scope

Part II (M2) of the [Leffect specifications](README.md).

## 19. Scope

A Scope collects finalizers and runs them when it closes. This follows v4's
`Scope` module. The public module is `leffect.scope`, exported as `Scope`.

### 19.1 Data

```lua
---@class Scope
---@field strategy "sequential"|"parallel"
---@field parent Scope?   -- set for a scope made by Scope.fork
---@field state "open"|"closed"
---@field exit Exit?      -- the exit it was closed with
-- and an ordered set of finalizers fn(exit) -> Effect?, each under a key
```

- **Keys** are tables: a fresh `{}` for `addFinalizer`, the child scope for
  `Scope.fork`, and the fiber for `forkIn`. A key lets the owner remove its
  finalizer early.
- **Adding** appends.
- **Removing** is O(1) and leaves a hole, which closing skips. Compact the list
  when holes outnumber entries. Removing from a closed scope does nothing:
  a `forkIn` fiber that its scope's close interrupts removes itself from a
  scope that is already closed.

### 19.2 API

| Function | Semantics |
|---|---|
| `Scope.make(strategy?)` | Effect: a new open scope. `strategy` defaults to `"sequential"`. |
| `Scope.makeUnsafe(strategy?)` | The same, outside an effect. |
| `Scope.addFinalizerExit(scope, f)` | Effect: add `f(exit)`. On a closed scope, run `f(scope.exit)` at once instead. |
| `Scope.addFinalizer(scope, eff)` | `addFinalizerExit` with a finalizer that ignores the exit. |
| `Scope.close(scope, exit)` | Effect: close `scope` with `exit`, uninterruptibly (§19.3). A closed scope stays as it is. |
| `Scope.closeUnsafe(scope, exit)` | Close `scope` outside an effect, and return the effect that runs its finalizers, or nil (§19.3). Public in v4 too. |
| `Scope.fork(scope, strategy?)` | Effect: a child scope that closes when `scope` closes. Forking a closed scope gives a closed child with the same exit. |
| `Scope.forkUnsafe(scope, strategy?)` | The same, outside an effect. Public in v4 too. |
| `Scope.addFinalizerUnsafe(scope, key, f)`, `Scope.removeFinalizerUnsafe(scope, key)` | Add or remove a keyed finalizer, outside an effect (§19.1). Internal in v4; public here because `leffect.effect` needs them for `forkIn`. |
| `Scope.Scope` | The key of the current scope, `"leffect/Scope"` (§26.4). M2 had the string `Scope.contextKey` instead; M3 replaced it. |
| `Scope.provide(eff, scope)` | Runs `eff` with `scope` as the current scope, without closing it. |
| `Scope.use(eff, scope)` | `provide`, then close `scope` with `eff`'s exit. Below the cut line (§24). |
| `Effect.scope` | Effect: the current scope. Without one, it dies with "Effect.scope: no Scope in context; wrap the effect in Effect.scoped". |
| `Effect.scoped(eff)` | Runs `eff` with a fresh current scope, then closes it with `eff`'s exit (§19.4). Also a method. |
| `Effect.scopedWith(f)` | Runs `f(scope)` with a fresh scope passed as an argument, not put in the context, then closes it. Below the cut line. |
| `Effect.addFinalizer(f)` | Adds `f(exit)` to the current scope (§20.3). |

### 19.3 Closing

```lua
function Scope.close(scope, exit)
  return withFiber(function(fiber)
    enterUninterruptible(fiber) -- pushes Restore(true) if interruptible
    return closeUnsafe(scope, exit) or Exit.void
  end)
end

-- Returns the effect that runs the finalizers, or nil if there are none.
local function closeUnsafe(scope, exit)
  if scope.state == "closed" then return nil end
  scope.state, scope.exit = "closed", exit
  if scope.parent then removeFinalizer(scope.parent, scope) end
  local finalizers = newestFirst(scope)
  if #finalizers == 0 then return nil end
  if scope.strategy == "sequential" then
    return runInTurn(finalizers, exit)
  end
  return runTogether(finalizers, exit) -- "parallel"
end
```

- **Order.** Finalizers run newest first, and each gets the close exit.
- **Isolation.** Each finalizer runs as `Effect.exit(suspend(→ f(exit) or
  void))`. A failure or a throw doesn't stop the next one, and a throw becomes
  a Die with a traceback (§5.2).
- **Result.** The close fails with every finalizer's reasons, in run order and
  duplicates included, or else succeeds. This is v4's `exitAsVoidAll`.
- **Stack.** `runInTurn` is a `flatMap` chain, like §22.2's, so a scope with
  many finalizers doesn't grow the stack.
- **`runTogether`** (below the cut line):
  - It forks each finalizer on the closing fiber, as a daemon that inherits
    the closing fiber's interruptibility, so the forks are uninterruptible.
  - It awaits them all, and combines their exits in fork order.
  - It skips the finalizer whose key is the closing fiber. That is the fiber's
    own `forkIn` finalizer, which would wait for the closing fiber and
    deadlock. v4 skips it too.

### 19.4 `scoped`

```lua
function Effect.scoped(eff)
  return withFiber(function(fiber)
    local prev = fiber.context
    local scope = Scope.makeUnsafe()
    push(fiber, { _op = "OnExit", f = function(exit) return closeUnsafe(scope, exit) end })
    push(fiber, { _op = "SetContext", context = prev })
    fiber.context = Context.add(prev, "leffect/Scope", scope)
    return eff
  end)
end
```

- Both frames are pushed directly, for the reason §18 gives.
- Unwinding pops `SetContext` first, so the finalizers run in the outer
  context. v4's `scoped` likewise restores the context, then closes.
- The `OnExit` frame runs the close uninterruptibly, and adds its failure to
  the exit (§7.5).
- `Scope.provide(eff, scope)` is §18's `provideService` with the Scope key.
- `scopedWith(f)` is `suspend(→ onExit(f(scope), → closeUnsafe(scope, exit)))`
  on a fresh scope. It leaves the context alone, so its frame can be an
  ordinary effect: if an interrupt lands first, the scope is still empty.
- `Scope.use(eff, scope)` is
  `onExit(Scope.provide(eff, scope), → closeUnsafe(scope, exit))`.
