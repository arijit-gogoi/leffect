# Running effects: options, `runCallback`, and a context

Part III (M3) of the [Leffect specifications](README.md).

## 28. Running effects

### 28.1 Run options

M1's `Effect.runFork(eff, { scheduler = s })` (§8.2) gains v4's other run
options in M3 (`RunOptions`, Effect.ts 9539):

| Option | Semantics |
|---|---|
| `scheduler` | Required. The core has no host loop to fall back on (decision 41). |
| `uninterruptible` | The root fiber starts uninterruptible. Defaults to false. |
| `onFiberStart(fiber)` | Called once with the new fiber, before `runFork` returns. |

- v4's `signal` is an AbortSignal, which Lua doesn't have. The interruptor
  that `runCallback` returns does the same job.
- **Where the scheduler lives.** In v4, the scheduler is a Reference in the
  fiber's context (`Scheduler.Scheduler`, Scheduler.ts 82), and so is the op
  budget (`MaxOpsBeforeYield`, Scheduler.ts 294). `runFork`'s `scheduler`
  option just adds it to the root context.
  - Leffect keeps both where M1 put them (§4, §10.1): the scheduler on the
    fiber, and the op budget on the scheduler. Children inherit the scheduler
    when they fork.
  - A program runs on one host loop. If a fiber could switch schedulers
    halfway, as `provideService(Scheduler, s)` allows in v4, its wakeups
    could land on a loop that isn't running (§14).

### 28.2 `runCallback`

```lua
local interrupt = Effect.runCallback(eff, {
  scheduler = scheduler,
  onExit = function(exit) ... end, -- optional
})
interrupt()        -- interrupts on behalf of no fiber
interrupt(fiberId) -- interrupts on behalf of fiberId
```

This is v4's `runCallbackWith` (internal-effect.ts 5845–5863): `runFork`,
then `fiber:addObserver(onExit)`, then return
`function(id) fiber:interruptUnsafe(id) end`. It takes the run options of
§28.1 too.

- `onExit` gets the exit once, in the task where the fiber ends.
- The interruptor doesn't wait. Calling it after the fiber has ended does
  nothing.
- If the interruptor is called before the fiber starts, which is on the next
  tick (§8.2), the fiber stops at its first step, and none of `eff`'s code
  runs. v4 starts the fiber at once, so there `eff` runs up to its first
  suspension before `runCallback` returns.
- `onExit` must not throw. If it does, the error leaves the task that ended
  the fiber, and reaches the host like any error in a scheduler task. The test
  scheduler's `flush` raises it. luv's default handler prints it and exits the
  process (§29.4).

### 28.3 Running with a context

`Effect.runForkWith(context)`, `runCallbackWith(context)`,
`runSyncWith(context)` and `runSyncExitWith(context)` each return a runner.
Its root fibers start with `context` instead of `Context.empty()`
(internal-effect.ts 5788–5813 and 5845–5935).

They can run many effects against one set of built services. Build the
services once with `Layer.buildWithScope`, into a scope that the caller closes
at the end. v4's `ManagedRuntime` packages exactly that, and is Later (§15).

These runners are below the cut line.
