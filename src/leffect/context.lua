--- Internal: a fiber's context, the services it runs with
--- (specifications/18-context.md §18).
---
--- A context is an immutable table of services keyed by strings. Adding a
--- service copies the table, and nothing ever mutates one. A fork starts with
--- its parent's context. Until M3 brings Context, Tag and Layer, the only
--- service is the current Scope, under `"leffect/Scope"`.

local core = require("leffect.core")
local runtime = require("leffect.runtime")

local pairs = pairs

local push = runtime.push

local Context = {}

--- The context with no services, which root fibers start with.
---@type table<string, any>
Context.empty = {}

--- A copy of `context` with `value` under `key`.
---@param context table<string, any>
---@param key string
---@param value any
---@return table<string, any>
function Context.add(context, key, value)
  local copy = {}
  for k, v in pairs(context) do
    copy[k] = v
  end
  copy[key] = value
  return copy
end

--- The service under `key`, or nil.
---@param context table<string, any>
---@param key string
---@return any
function Context.get(context, key)
  return context[key]
end

--- Runs `effect` with `value` under `key` in the fiber's context, then puts
--- the previous context back however `effect` ends. The SetContext frame is
--- pushed in the same step that changes the context, so no interrupt can land
--- between the two.
---@param key string
---@param value any
---@param effect leffect.Effect
---@return leffect.Effect
function Context.provide(key, value, effect)
  return core.withFiber(function(fiber)
    local previous = fiber.context
    push(fiber, { _op = "SetContext", context = previous })
    fiber.context = Context.add(previous, key, value)
    return effect
  end)
end

return Context
