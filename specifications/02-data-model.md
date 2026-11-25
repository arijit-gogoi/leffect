# Data model

Part I (the runtime, M1) of the [Leffect specifications](README.md).

## 2. Data model

### 2.1 Cause

This follows v4, which replaced Effect 2/3's Sequential/Parallel tree with a
flat list.

```lua
---@alias Reason
---| { _tag: "Fail", error: any }
---| { _tag: "Die", defect: any, trace: string? }
---| { _tag: "Interrupt", fiberId: integer? }

---@class Cause
---@field reasons Reason[]
```

- A Die's `defect` is the thrown value, unchanged. `trace` is the traceback
  captured where the runtime caught it, if it did.
- `Cause.empty` has no reasons.
- `Cause.combine(a, b)`:
  - If either cause is empty, the other comes back unchanged.
  - Otherwise the result is `a`'s reasons followed by `b`'s, keeping only the
    first of each set of equal reasons. Two reasons are equal when they are
    the same table, or have the same `_tag` and raw-equal (`==`) payloads.
  - This is 4.1.5's `causeCombine`, which dedupes the concatenation under
    `Equal`. M1 compared `b`'s reasons only against `a`'s.
- `Cause.fromReasons(list)` keeps every reason, duplicates included, like v4's
  `causeFromReasons` (used by `raceAll`).
- `Cause.electDefects(c)` is 4.1.5's `causeElectDefects`:
  - If `c` has both Fail and Die reasons, each Fail becomes a Die in place.
    The new Die's `defect` is the error, and it has no `trace`.
  - Otherwise `c` comes back unchanged.
  - It applies when a finalizer's or a canceler's cause is combined into a
    failure (§7.5), to `raceAll`'s all-failed cause (§8.1), and in M2 to
    `forEach` (§22).
- `Cause.findRecoverableError(c)` is 4.1.5's `findRecoverableError`. A cause
  with a defect is not recoverable.
  - It returns `true, error` for the first Fail, when `c` has no Die.
  - Otherwise it returns `false, rethrow`, where `rethrow` is
    `electDefects(c)` if `c` has a Die, else `c`.
  - `catchAll` uses it, and so do M2's typed catches (§21).
- Queries: `failures` and `defects` (each returns `list, count`, because a
  value can be nil), `interruptors` (the distinct fiber IDs), `findError`,
  `findDefect`, `hasFails`, `hasDies`, `hasInterrupts`, `hasInterruptsOnly`
  and `isEmpty`.
- `squash` picks the one value to report: the first error, else the first
  defect, else "All fibers interrupted without error", else "Empty cause"
  (v4's `causeSquash`).
- The runtime's own error values live in `Cause`, as in v4. They are tagged
  tables with a `message` and a `__tostring`: `Cause.TimeoutError()` and
  `Cause.AsyncFiberError(fiber)`.

### 2.2 Exit, also an effect

```lua
{ _op = "Success", _tag = "Success", value = v }
{ _op = "Failure", _tag = "Failure", cause = c }
```

`Exit.succeed`, `Exit.failCause`, `Exit.fail(e)`, `Exit.die(d, trace)`,
`Exit.interrupt(id)`, `Exit.void`. Because exits are effects, a frame handler
can return an exit directly, and a finished fiber's exit can be yielded back
into another loop.

### 2.3 Primitive ops for M1

Everything else derives from these. M0's op names and fields (`Map`,
`OnSuccess`, `OnFailure`, `first`) stay.

| `_op`        | Fields            | Evaluate                                      |
|--------------|-------------------|-----------------------------------------------|
| `Success`    | `value`           | pop next `onSuccess` handler                  |
| `Failure`    | `cause`           | pop next `onFailure` handler (with skip rule) |
| `Sync`       | `thunk`           | pop next `onSuccess` handler with `thunk()`   |
| `Suspend`    | `thunk`           | `thunk()` (lazy effect)                       |
| `Map`        | `first`, `f`      | push self as frame, continue with `first`     |
| `OnSuccess`  | `first`, `f`      | push self as frame (this is `flatMap`)        |
| `OnFailure`  | `first`, `f`      | push self as frame (this is `catchCause`)     |
| `OnExit`     | `first`, `f`      | push self as frame (finalizer)                |
| `WithFiber`  | `f`               | `f(fiber)`                                    |
| `Async`      | `register`        | see §6                                        |
| `Yield`      | —                 | reschedule, return `YIELD`                    |
| `Gen` (M2)   | `body`            | create coroutine and frame, see §9            |

All effects keep M0's single shared metatable, so `isEffect` and `isExit` stay
metatable checks, and the user methods (`eff:map(f)`) keep working. The run
loop finds each op's behavior in private tables keyed by `_op`:
`evaluate[op]`, `onSuccess[op]`, `onFailure[op]` and `onPop[op]`. v4 hangs the
same functions off symbol keys on each primitive. Lua has no symbols, and
plain method names would share the `__index` namespace with the user methods.

Ops that push themselves as frames carry their own handlers, which avoids
allocating a separate frame (v4 does the same). Internal frames (`Restore`,
`AsyncCancel`, `FinalizerResult`, and in M2 `Gen` and `SetContext`) are plain
tables with a private `_op`; they are never evaluated as effects. Ops with per-run state
(`Async`, `Gen`) push a fresh frame table on each evaluation, because an
effect value can run many times, concurrently. The loop never mutates an
effect table.
