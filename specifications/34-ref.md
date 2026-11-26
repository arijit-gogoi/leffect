# Ref and SynchronizedRef

Part IV (M4) of the [Leffect specifications](README.md).

## 34. Ref

A Ref holds one value that fibers share (`Ref.ts` at 4.1.5).

```lua
local counter = Ref.makeUnsafe(0)
local program = Effect.forEach(items, function()
  return counter:update(function(n) return n + 1 end)
end, { concurrency = 4 })
```

| Function | Semantics |
|---|---|
| `Ref.make(value)` | Effect: succeeds with a new Ref that holds `value`. |
| `Ref.makeUnsafe(value)` | A new Ref, outside an effect. |
| `Ref.get(ref)` | Succeeds with the value. |
| `Ref.set(ref, value)` | Sets the value. |
| `Ref.getAndSet(ref, value)` | Sets the value, and succeeds with the old one. |
| `Ref.setAndGet(ref, value)` | Sets the value, and succeeds with it. |
| `Ref.update(ref, f)` | Sets the value to `f(value)`. |
| `Ref.getAndUpdate(ref, f)` | Sets the value to `f(value)`, and succeeds with the old value. |
| `Ref.updateAndGet(ref, f)` | Sets the value to `f(value)`, and succeeds with the new value. |
| `Ref.modify(ref, f)` | `f(value)` returns a result and a new value. Sets the new value, and succeeds with the result. |
| `Ref.getUnsafe(ref)` | The value, outside an effect. |

- **Atomic updates.** Each function is one `sync` step (§33.1). So `f` sees the
  latest value, and an update never loses a concurrent one.
- **`modify`'s `f` returns two values:** the result, then the new value. In v4,
  `f` returns a tuple `[b, a]`.
  - If `f` returns fewer than two values, the effect dies with "Ref.modify: f
    must return the result and the new value", and the Ref keeps its value.
    Otherwise a forgotten second value would quietly set the Ref to nil.
  - The count comes from `select("#", ...)`, so `return b, nil` does set nil.
- **A Ref may hold nil** (§33.5).
- **A Ref is not an effect.** In 4.1.5, `Ref` doesn't extend `Effect`.
  `run(ref)` dies with "Not a valid effect".
- **Option variants wait.** v4's `getAndUpdateSome`, `updateSome`,
  `updateSomeAndGet` and `modifySome` take a function that returns an Option.
  They wait for an Option type (§15).

### 34.1 SynchronizedRef

This is below the cut line (§40).

A SynchronizedRef is a Ref plus a Semaphore with one permit
(`SynchronizedRef.ts` at 4.1.5). Its updates may run effects, and they run
one at a time.

| Function | Semantics |
|---|---|
| `SynchronizedRef.make(value)`, `makeUnsafe(value)` | As for Ref. |
| `SynchronizedRef.get(ref)`, `getUnsafe(ref)` | The value. They don't wait for an update that is running. |
| `set`, `getAndSet`, `setAndGet`, `update`, `getAndUpdate`, `updateAndGet`, `modify` | As for Ref, but each one takes the permit first. |
| `updateEffect(ref, f)`, `getAndUpdateEffect(ref, f)`, `updateAndGetEffect(ref, f)` | `f(value)` returns an effect. Runs it while holding the permit, and sets the value it succeeds with. |
| `modifyEffect(ref, f)` | `f(value)` returns an effect that succeeds with a pair `{ result, newValue }`. Sets `newValue`, and succeeds with `result`. |

- **Failure.** If the effect fails or is interrupted, the value doesn't change.
  The permit is given back either way, through `withPermit` (§36).
- **`modifyEffect`'s pair.** An effect succeeds with one value, so v4's tuple
  becomes a list of two elements. If the effect succeeds with something other
  than a table, the update dies.
- **Option variants wait.** The `*Some` variants wait for an Option type, as
  Ref's do.
