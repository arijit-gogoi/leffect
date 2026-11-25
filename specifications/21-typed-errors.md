# Typed error recovery and `Effect.exit`

Part II (M2) of the [Leffect specifications](README.md).

## 21. Typed error recovery and `Effect.exit`

Expected failures are tagged tables (CLAUDE.md). These functions recover them
by tag or by predicate. All of them go through `Cause.findRecoverableError`
(§2.1), so they never recover a cause that holds a Die, and they never see
interrupts.

```lua
function Effect.catchIf(self, predicate, f, orElse)
  return catchCause(self, function(cause)
    local found, value = Cause.findRecoverableError(cause)
    if not found then return Exit.failCause(value) end -- the cause to rethrow
    if predicate(value) then return f(value) end
    if orElse then return orElse(value) end
    return Exit.failCause(cause)
  end)
end
```

| Function | Recovers |
|---|---|
| `catchAll(self, f)` | Any recoverable error: `catchIf` with a predicate that is always true. v4 calls it `catch`. |
| `catchIf(self, predicate, f, orElse?)` | Errors for which `predicate(err)` is true. Other errors go to `orElse(err)` if it is given, and otherwise keep failing. |
| `catchTag(self, tag, f, orElse?)` | Errors whose `_tag` is `tag`, or is in `tag` when `tag` is a list. |
| `catchTags(self, cases, orElse?)` | Errors whose `_tag` has a handler in `cases`, as in `{ NotFound = function(e) ... end }`. |

- The tag test is `type(e) == "table" and e._tag == tag`.
  - It reads `_tag` with normal indexing, so errors built from metatable
    classes match.
  - Strings, numbers, booleans and nil never match, and the test never raises.
- `catchTags` looks up `cases[e._tag]` only when `e._tag` is a string. A tag
  with no case falls to `orElse`, or keeps failing.
- `eff:catchIf`, `eff:catchTag` and `eff:catchTags` are methods too.

`Effect.exit(self)` succeeds with `self`'s exit. It is
`catchCause(map(self, Exit.succeed), → succeed(Exit.failCause(cause)))`.
- It is a recovery handler, so it doesn't run while its own fiber is
  interrupted and interruptible.
- It is also a method, `eff:exit()`.
- Scope uses it (§19.3), so it lives in `core`, which `leffect.scope` can
  require without a cycle.
