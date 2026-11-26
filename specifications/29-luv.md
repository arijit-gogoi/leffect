# The luv scheduler

Part III (M3) of the [Leffect specifications](README.md).

## 29. The luv scheduler

luv binds libuv, the event loop under Node, to Lua. The module
`leffect.scheduler.luv` runs fibers on it. It implements the interface of
§10.1, and replaces the sketch in §10.3. The luv sources cited below are on
`luvit/luv` at commit `e97e752`.

### 29.1 Construction

```lua
local LuvScheduler = require("leffect.scheduler.luv")
local scheduler = LuvScheduler.new({
  uv = vim.uv,              -- optional: a luv module; defaults to require("luv")
  maxOpsBeforeYield = 2048, -- optional
})
```

- luv is an optional dependency. The module requires it inside `new`, not
  when the module loads, and the rockspec doesn't depend on it.
- `options.uv` takes any luv module: Neovim's `vim.uv`, or a fake one in specs
  (§29.7).
- Each scheduler owns one idle handle, created the first time it is needed.

### 29.2 Tasks: one batch per loop iteration

```lua
function scheduler:schedule(task)
  -- append task to the FIFO queue, then:
  if not self.idleActive then
    self.idle:start(self.onIdle)
    self.idleActive = true
  end
end

-- self.onIdle, the idle callback
local function drain(self)
  local last = self.tail -- the batch: the tasks queued before this point
  while self.head <= last do
    local task = self.queue[self.head]
    self.queue[self.head] = nil
    self.head = self.head + 1 -- the task leaves the queue before it runs
    task()
  end
  if self.head > self.tail then -- nothing was queued meanwhile
    self.idle:stop()
    self.idleActive = false
  end
end
```

- While an idle handle is active, libuv polls for I/O with a zero timeout
  instead of blocking, and calls the idle callback once per iteration. The
  handle is active only while tasks are queued. So a Leffect with no work
  neither spins the loop nor keeps it alive.
- **Batches.** The callback runs the tasks that were queued when it started.
  Tasks queued meanwhile, by forks, resumes and op-budget yields, wait for the
  next iteration. Between the two, libuv polls for I/O and fires the timers
  that are due. A busy fiber yields every 2048 ops, so it lets I/O in. v4's
  `MixedScheduler` works the same way: each `setImmediate` runs the tasks
  queued so far (Scheduler.ts 217–270).
- §10.3 drained the queue until it was empty, tasks queued during the drain
  included. That starves I/O while any fiber is busy, so M3 drops it
  (decision 43).
- Tasks run in FIFO order, as on the test scheduler. Only their interleaving
  with I/O and timers differs.

### 29.3 Timers and time

```lua
function scheduler:after(ms, task)
  local timer = uv.new_timer()
  timer:start(toDelay(ms), 0, function()
    timer:close()
    task()
  end)
  return function() -- cancel; calling it again does nothing
    if not timer:is_closing() then timer:close() end
  end
end
```

- luv's `timer_start` takes integers (`luaL_checkinteger`, `src/timer.c`
  line 49), so `sleep(1.5)` would raise on Lua 5.4. `toDelay` rounds `ms` up,
  so a timer never fires early. It clamps the result to at least 0 and at most
  2^53, and treats NaN as 0.
- Closing a timer stops it. A timer that fired has closed itself, so
  cancelling it afterwards does nothing.
- Timers due in the same iteration all fire before the fibers they wake run.
  The test scheduler flushes after each timer instead (§10.2). Both orders are
  valid. A spec that depends on one of them must use the test scheduler.
- A pending timer keeps the loop alive, as a pending `setTimeout` keeps Node
  alive.
- `now()` is `uv.now()`: milliseconds since an arbitrary start, cached at the
  start of each iteration. It measures durations; it isn't wall-clock time.

### 29.4 Errors in tasks

- The runtime lets no error of its own escape a task (§5.2). An error that
  does escape comes from a bug, or from user code that the runtime calls
  outside a fiber, such as a `runCallback` `onExit` (§28.2).
- The scheduler doesn't catch it. The error reaches luv's callback handler,
  `luv_cfpcall` (`src/luv.c` lines 725–779). By default, that prints
  "Uncaught Error:" with a traceback, and exits the process. Node treats an
  uncaught exception the same way.
- A task leaves the queue before it runs, and the idle handle stays active
  while tasks remain. In a host whose handler survives errors, such as Neovim,
  the next iteration runs the rest of the queue.

### 29.5 Running the loop

`scheduler:fork(eff)` is `Effect.runFork(eff, { scheduler = self })`, as on
the test scheduler.

`scheduler:run(eff)` returns `exit, fiber`:

```lua
function scheduler:run(effect)
  if uv.loop_mode() then
    error("LuvScheduler:run: the luv loop is already running;"
      .. " use fork or Effect.runCallback inside it", 2)
  end
  local fiber = self:fork(effect)
  local remove = fiber:addObserver(function() uv.stop() end)
  local ok, err = pcall(uv.run, "default")
  remove() -- however the loop returned
  if not ok then error(err, 0) end
  return fiber.exit, fiber
end
```

- It runs the loop until the fiber ends, and stops it after that iteration.
  Daemon fibers and other handles stay as they are, and the next `uv.run`
  carries on with them.
- The loop can run out of handles before the fiber ends: the fiber then waits
  for something that no handle will complete, such as `Effect.never`. `run`
  returns nil and the fiber, as the test scheduler's `run` does for a fiber
  that didn't finish.
- `uv.run` isn't reentrant. Called from inside the loop, luv returns
  `nil, "loop already running"` (`src/loop.c` lines 32–46). `run` raises the
  clearer error above instead.
- `run` removes its observer before it returns, or raises if `uv.run`
  raised. A fiber that ends during a later `uv.run` therefore doesn't stop
  someone else's loop. `uv.stop()` is called only from inside the running
  loop: libuv keeps the flag otherwise, and the next `uv.run` would return at
  once.
- In Neovim, Neovim runs the loop itself, and `uv.loop_mode()` can't see that.
  Use `fork` or `runCallback` there, never `run`.

### 29.6 Neovim

- Pass `vim.uv` as `options.uv`.
- Neovim runs luv callbacks as fast events, where most of `vim.api` is off
  limits. An effect that calls the API must go through `vim.schedule`. A
  scheduler built on `vim.schedule` belongs in a Neovim module, which is Later
  (§15). §10.3 made the same point.

### 29.7 Testing

- `spec/luv_scheduler_spec.lua` drives the scheduler with a fake `uv`. The
  fake records when the idle handle starts and stops, keeps a list of timers,
  and runs loop iterations when the spec asks. It runs everywhere, and covers
  §29.2 to §29.5.
- `spec/luv_live_spec.lua` uses real luv: a sleep, a timeout and a
  `runCallback` on a live loop. When luv can't be loaded, it is pending,
  unless the environment variable `LEFFECT_REQUIRE_LUV` is set; then it fails.
- CI installs luv on both legs (`luarocks install luv`) and sets
  `LEFFECT_REQUIRE_LUV=1`, so the live specs can't go silently dead.
- Locally, Alpine's `lua5.4-luv` package covers the Lua 5.4 leg. Before
  relying on `lua5.1-luv` for the LuaJIT leg, check that LuaJIT can load it.
