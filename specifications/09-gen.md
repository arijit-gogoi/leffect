# `gen` on coroutines

Part I (the runtime, M1) of the [Leffect specifications](README.md).

## 9. `gen` on coroutines (M2)

`gen` is built in M2, as CLAUDE.md's milestones say. It is designed here
because it plugs into M1's frames: it only needs steps 2–5 of §13.

### 9.1 API

```lua
local program = Effect.gen(function(run)
  local user = run(getUser(id))
  local posts = run(getPosts(user)) -- helpers may call Leffect.run(eff) too
  return #posts
end)
```

`Leffect.run` is `require("leffect").run`: the same function the body gets as
`run`. `Effect.gen(body)` builds `{ _op = "Gen", body = body }`, and `core`
gets `OP_GEN`.

### 9.2 Mechanics

```lua
local MARK = {} -- unique sentinel
local genCoroutines = setmetatable({}, { __mode = "k" })

local function run(eff) -- exported as Leffect.run
  if not genCoroutines[coroutine.running()] then
    error("Leffect.run() called outside Effect.gen", 2)
  end
  return coroutine.yield(MARK, eff)
end

evaluate.Gen = function(op, fiber)
  local co = coroutine.create(op.body) -- a fresh coroutine on every run
  genCoroutines[co] = true
  local frame = { _op = "Gen", co = co }
  return onSuccess.Gen(frame, run, fiber) -- the first resume passes `run`
end

onSuccess.Gen = function(frame, value, fiber)
  local co = frame.co
  local ok, a, b = coroutine.resume(co, value)
  if not ok then
    -- traceback(co, msg) reads the dead coroutine's stack on 5.4 and LuaJIT
    -- (checked on both). Give it a string, as captureDefect does (§5.2).
    local trace
    if type(a) == "string" then
      trace = debug.traceback(co, a)
    else
      trace = debug.traceback(co, ""):sub(2) -- drop the leading newline
    end
    return Exit.die(a, trace) -- the defect stays the raw error
  end
  if coroutine.status(co) == "dead" then return Exit.succeed(a) end -- returned
  if a ~= MARK then
    return Exit.die("Effect.gen: coroutine yielded without run(); "
      .. "don't call coroutine.yield directly inside gen")
  end
  push(fiber, frame)
  return b -- the effect to run; its result comes back through onSuccess
end
-- No onFailure: a failed or interrupted run() never returns. The frame is
-- skipped and the coroutine abandoned, then garbage collected.
```

### 9.3 Rules

- **`run()` never throws.** If the effect fails or the fiber is interrupted,
  `run()` simply never returns. A user's `pcall` around `run()` only catches
  Lua errors from their own code, never effect failures or interrupts. This is
  the "runtime never throws into user code" rule, and it matches v4, which
  never calls `.return()` on the generator.
- **Cleanup inside gen uses effects** (`ensuring`, `acquireRelease`), never
  `pcall` "finally" patterns, because an abandoned coroutine runs nothing
  further.
- **The loop runs outside gen coroutines.** The coroutine only yields effects
  out. Runtime work therefore never nests inside a resume, which keeps clear
  of Lua's C-stack limit on nested `coroutine.resume` (about 200 levels).
- **`run()` can't cross C boundaries.** Calling `run()` from inside a callback
  invoked by a C function (`table.sort` comparator, `string.gsub` replacer)
  raises "attempt to yield across a C-call boundary", which becomes a defect.
  Document it.
- **`run()` doesn't work inside the user's own coroutines.** The
  `genCoroutines` registry check catches this with a clear error.
- **Errors in the gen body** become a `Die` holding the raw error, with a
  traceback taken from the dead coroutine.
  - `debug.traceback(co, msg)` after an error includes the body's line on 5.4
    and on LuaJIT. Both were checked on 2026-11-25.
  - A string message comes back prefixed to the trace; `""` gives a leading
    newline.
- **Each run starts a fresh coroutine**, so one gen effect can run many times,
  concurrently (invariant 13).
- **The body's first return value is the result.** Returning an effect returns
  it as a plain value, without running it, as v4 does.
- **`run(x)` with a non-effect** dies with "Not a valid effect", like any
  other instruction (§5.2). The Gen frame is already pushed, so the Die
  unwinds through it and the coroutine is abandoned.
