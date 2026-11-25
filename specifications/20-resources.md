# Resources

Part II (M2) of the [Leffect specifications](README.md).

## 20. Resources

### 20.1 `acquireRelease`

```lua
function Effect.acquireRelease(acquire, release, options)
  return uninterruptibleMask(function(restore)
    return Effect.scope:flatMap(function(scope)
      local run = acquire
      if options and options.interruptible then run = restore(acquire) end
      return run:flatMap(function(a)
        return Scope.addFinalizerExit(scope, function(exit)
          return release(a, exit)
        end):as(a)
      end)
    end)
  end)
end
```

- The scope is looked up before acquire runs. Without one, nothing is
  acquired.
- **Interrupt during acquire** (CLAUDE.md's example):
  - acquire runs uninterruptibly, and the release is added before the mask
    ends.
  - The interrupt is delivered when the mask ends.
  - The scope then closes, and the release runs.
- `{ interruptible = true }` runs acquire under `restore`. An interrupt can
  then stop it, and there is nothing to release.
- If acquire fails, no release is added.
- The release gets the resource and the scope's close exit. It runs
  uninterruptibly (§19.3), and its failure is added to the cause through the
  `OnExit` of `scoped` (§7.5).
- v4 also runs the release with the context captured at acquire. In M2 the
  context holds only the Scope, so that waits for M3 (§15). The M3 design
  adds it (§26.5).

### 20.2 `acquireUseRelease`

```lua
function Effect.acquireUseRelease(acquire, use, release)
  return uninterruptibleMask(function(restore)
    return acquire:flatMap(function(a)
      return Effect.suspend(function() return restore(use(a)) end)
        :onExit(function(exit) return release(a, exit) end)
    end)
  end)
end
```

This needs no Scope:
- acquire runs uninterruptibly;
- `use` runs as interruptibly as the caller;
- the release always runs, and its failure is added to the cause.

### 20.3 `addFinalizer`, `forkIn` and `forkScoped`

- `Effect.addFinalizer(f)` is
  `Effect.scope:flatMap(→ Scope.addFinalizerExit(scope, f))`.
- `Effect.forkIn(eff, scope)` forks `eff` as a daemon, tied to `scope`.
  - Closing the scope interrupts the fiber and waits for it.
  - A fiber that finishes first removes its finalizer.
  - On a closed scope, the fiber is interrupted before it starts, so it runs
    none of `eff` (§7.2).

  ```lua
  function Effect.forkIn(eff, scope)
    return withFiber(function(parent)
      local fiber = Fiber.forkUnsafe(parent, eff, true) -- a daemon
      if scope.state == "closed" then
        fiber:interruptUnsafe(parent.id)
      else
        addFinalizerUnsafe(scope, fiber, function()
          return withFiber(function(current)
            if current == fiber then return Exit.void end -- closing itself
            return fiber:interrupt()
          end)
        end)
        fiber:addObserver(function() removeFinalizer(scope, fiber) end)
      end
      return Exit.succeed(fiber)
    end)
  end
  ```

- `Effect.forkScoped(eff)` is `Effect.scope:flatMap(→ forkIn(eff, scope))`.
- Both are also methods. Unlike v4's, they take no options (§14).
- For a closed scope, v4 creates the fiber unstarted and interrupts it at
  once. Leffect starts every fork on the next tick, and an interrupt requested
  before then is delivered at the fiber's first step.
