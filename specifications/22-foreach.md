# `forEach` and `all`

Part II (M2) of the [Leffect specifications](README.md).

## 22. `forEach` and `all`

### 22.1 API

```lua
Effect.forEach(list, f, options) -- f(item, index) returns an effect
Effect.all(effects, options)     -- a list or a record of effects
-- options: { concurrency = n or "unbounded", discard = boolean }
```

- `concurrency`:
  - nil or 1 runs one item at a time, which is v4's default;
  - a number runs at most that many at once, and anything below 1 counts
    as 1;
  - `"unbounded"` runs them all at once;
  - anything else is a defect.

  4.1.5 has no `"inherit"`.
- The result is a list with a field `n`, like `table.pack`, so nil results
  are counted. With `discard = true`, the result is nil.
- `f` gets the item and its index, counting from 1. It is called only when
  that item's turn comes.
- The input list's length is `list.n` if that is a number, else `#list`.

### 22.2 Running

**One at a time** uses a `flatMap` chain:

```lua
local function inTurn(items, n, f, out)
  local function step(i)
    if i > n then return Exit.succeed(out) end
    return f(items[i], i):flatMap(function(value)
      if out then out[i] = value end
      return step(i + 1)
    end)
  end
  return step(1)
end
-- wrapped in suspend, so each run gets a fresh `out`
```

Each step returns the next effect from a continuation, so neither the frame
stack nor the Lua stack grows; M0's stack-safety argument covers it. The first
failure ends the chain, and later items never start.

**Concurrently**, the parent suspends in one `async`, as `raceAll` does
(§8.1):

- **Launching.** Fork workers until `concurrency` are running.
  - They are daemons, forked with `uninterruptible = "inherit"` (4.1.5), so
    inside an uninterruptible region they are uninterruptible too.
  - A worker's exit launches the next item.
  - One launch function serves both the first batch, inside `register`, and
    the refills, from worker observers. It calls `f` under `xpcall` both
    times. A refill runs outside the loop, and a throw in `register` would
    otherwise turn into a Die with no canceler.
  - A throw from `f` ends the run like a worker failure. Nothing more is
    launched, the workers already running are interrupted and awaited, and
    then the run fails with the Die. Workers are daemons, so nothing else
    would stop them. v4's `failDefect` does the same.
- **Results.** A success stores its value at its own index, so the results
  keep input order whatever order the workers finish in.
- **Failure** (4.1.5's `iterateConcurrent`):
  - The first failure stops new launches. It interrupts the running workers
    on behalf of the parent, in fork order.
  - The run resumes only once every worker has exited.
  - A later worker's failure adds its non-interrupt reasons to the cause, with
    defects elected.
- **End.** When no worker is running and no item is left, the run resumes
  with the failure, or with the results.
- **The canceler** handles an interrupt of the parent:
  - it stops launching;
  - it interrupts every running worker and waits for them;
  - then it fails with any failure already recorded, which §6.3's
    `FinalizerResult` adds to the interrupt.
- **Ticks.** Workers start on the next tick (§14), so even an item that
  finishes at once takes a tick.

### 22.3 `all`

`all` is `forEach` over the effects, with `f` the identity. A Lua table can be
both a list and a record, so its keys decide which it is:

1. If `type(t.n) == "number"`, it is a list of `t.n` effects.
2. If every key is an integer from 1 to the number of keys, it is a list. So
   `{}` is an empty list, and gives `{ n = 0 }`.
3. Otherwise it is a record, and the result has the same keys.
   - It runs in sorted key order: numbers ascending, then strings ascending.
     `pairs` order isn't specified, and differs between the runtimes, so
     sorting makes runs the same on both.
   - A key of any other type is a defect.

`discard`, `concurrency` and failures work as in `forEach`.
