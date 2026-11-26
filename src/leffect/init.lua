--- Leffect: an Effect TS-style effect system for Lua.
---
--- ```lua
--- local leffect = require("leffect")
--- local Effect = leffect.Effect
---
--- local answer = Effect.succeed(20)
---   :map(function(n) return n + 1 end)
---   :flatMap(function(n) return Effect.succeed(n * 2) end)
--- print(Effect.runSync(answer)) --> 42
---
--- local program = Effect.gen(function(run)
---   local n = run(answer)
---   return n + 1
--- end)
--- print(Effect.runSync(program)) --> 43
--- ```
---
--- Fibers run on a scheduler; `leffect.scheduler.test` is a virtual-clock
--- scheduler for tests.

return {
  Cause = require("leffect.cause"),
  Context = require("leffect.context"),
  Deferred = require("leffect.deferred"),
  Effect = require("leffect.effect"),
  Exit = require("leffect.exit"),
  Fiber = require("leffect.fiber"),
  Layer = require("leffect.layer"),
  Ref = require("leffect.ref"),
  Scope = require("leffect.scope"),
  --- Runs an effect from an `Effect.gen` body; the same function the body
  --- gets as its argument.
  run = require("leffect.runtime").run,
}
