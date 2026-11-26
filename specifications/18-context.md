# Fiber context

Part II (M2) of the [Leffect specifications](README.md).

## 18. Fiber context

v4 keeps a fiber's services in `fiber.context`. A fork starts with its
parent's context, and `scoped` puts its Scope there. The public Context and
Layer are M3. M2 needs only the current Scope, so it adds the field and the
frame that restores it, but no public Context API. M3 made the context
public, with key objects instead of strings (§26).

- **The table.** `fiber.context` is an immutable table of services keyed by
  strings, like v4's service keys. M2 uses one key, `"leffect/Scope"`.
  - Adding a service copies the table; nothing mutates a context.
  - M2's internal module `leffect.context` had `empty`,
    `add(ctx, key, value)`, `get(ctx, key)`, and
    `provide(key, value, eff)`, which is `provideService` below. M3 replaced
    it with the public Context of §26.1, keyed by key objects.
- **Inheritance.** Root fibers start with `empty`. `forkUnsafe` hands the
  child the parent's table (§8), so every fork, daemon or not, sees the
  parent's Scope.
- **The `SetContext` frame**, `{ _op = "SetContext", context = prev }`, puts
  `prev` back in its `onPop`.
  - It has no handlers, so it is transparent on both paths.
  - `onPop` runs for every popped frame, skipped or not, so the context comes
    back on every exit path (invariant 15).

Push the frame and change the context in the same `withFiber` step:

```lua
local function provideService(key, value, eff)
  return withFiber(function(fiber)
    local prev = fiber.context
    push(fiber, { _op = "SetContext", context = prev })
    fiber.context = Context.add(prev, key, value)
    return eff
  end)
end
```

Building the restore as an effect instead, as in `onExit(eff, restore)`, opens
a gap:
- It leaves a loop step between `withFiber` and the frame's push.
- A pending interrupt replaces the current effect at that step (§5.2 (a)).
- The frame is then never pushed, and the changed context leaks into the outer
  continuation.

v4 closes the same gap with `onExitUnsafe`, which pushes onto the stack
directly.
