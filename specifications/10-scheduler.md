# Scheduler

Part I (the runtime, M1) of the [Leffect specifications](README.md).

## 10. Scheduler

### 10.1 Interface

```lua
---@class Scheduler
---@field schedule fun(self, task: fun())                 -- next tick, FIFO
---@field after fun(self, ms: number, task: fun()): fun() -- returns cancel
---@field now fun(self): number                           -- milliseconds
---@field maxOpsBeforeYield integer?                      -- default 2048
```

Leave priorities out for now (v4 has them). Add them if fairness problems show
up.

### 10.2 Test scheduler

Build this first. `require("leffect.scheduler.test").new(options)`, where
`options` may set `maxOpsBeforeYield` and `maxTasks`.

- A FIFO task queue, and a timer list ordered by `(dueTime, insertionSeq)`. A
  timer's cancel function removes it, and calling it again does nothing.
- `flush()` runs queued tasks until the queue is empty, including tasks
  queued while flushing. It never advances time. It errors after `maxTasks`
  tasks (default 1e6), to catch livelock in tests.
- `advance(ms)` steps through due timers in order: set `now` to each timer's
  due time, fire it, flush, then repeat. It ends with `now = start + ms`.
- `runAll()` alternates flushing and jumping to the next timer until there
  are no tasks and no timers.
- `pendingTasks()` and `pendingTimers()` count what is left, for specs such
  as "the timer was cancelled".
- Test helpers:

  ```lua
  local exit, fiber = scheduler:run(eff) -- fork, runAll, return the exit (nil if unfinished)
  ```

  Plus `scheduler:fork(eff)`, which is `Effect.runFork(eff, { scheduler =
  scheduler })`, for tests that interleave `advance` calls and assertions.

### 10.3 luv adapter (M3, sketched so the interface is validated)

Part III designs the adapter (§29). This sketch stays as the record of what M1
checked; where the two differ, §29 holds.

- `schedule`: push onto a queue. If no drain is pending, start a
  `uv.new_idle()` (or a 0 ms timer) that drains the whole queue, including
  tasks added during the drain, then stops itself. (§29.2 runs one batch per
  loop iteration instead, so that a busy fiber can't starve I/O.)
- `after`: `uv.new_timer():start(ms, 0, cb)`. Cancel is `stop()` and
  `close()`, made idempotent. (§29.3 also rounds `ms` up to an integer.)
- `now`: `uv.now()`, which is cached loop time. Call `uv.update_time()` if
  precision matters.
- Neovim: same adapter through `vim.uv`. Effects that call the Neovim API
  must wrap the call in `vim.schedule`, so that belongs in Neovim-specific
  helpers, not the core (§29.6).
