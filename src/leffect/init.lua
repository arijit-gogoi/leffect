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
--- ```

return {
  Cause = require("leffect.cause"),
  Effect = require("leffect.effect"),
  Exit = require("leffect.exit"),
}
