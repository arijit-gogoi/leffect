rockspec_format = "3.0"
package = "leffect"
version = "scm-1"

source = {
  url = "git+https://github.com/arijit-gogoi/leffect.git",
  branch = "main",
}

description = {
  summary = "An Effect TS-style effect system for Lua",
  detailed = [[
Lazy effects as data, typed errors (Exit and Cause) and a stack-safe run loop,
modelled on Effect TS. Fibers with structured concurrency and cooperative
interruption, finalizers, Scope and acquireRelease, generators on coroutines,
and bounded concurrency with forEach and all. Services and layers are
planned. Targets LuaJIT 2.1 and Lua 5.4.
]],
  homepage = "https://github.com/arijit-gogoi/leffect",
  -- No license chosen yet. Add `license = "..."` here, then restore the
  -- `luarocks lint` step in .github/workflows/ci.yml.
  labels = { "effect", "functional", "concurrency" },
}

-- LuaJIT reports itself as 5.1. Plain Lua 5.1 is not supported: it cannot
-- yield across pcall.
dependencies = {
  "lua >= 5.1",
}

test_dependencies = {
  "busted",
}

test = {
  type = "busted",
}

build = {
  type = "builtin",
  modules = {
    ["leffect"] = "src/leffect/init.lua",
    ["leffect.cause"] = "src/leffect/cause.lua",
    ["leffect.context"] = "src/leffect/context.lua",
    ["leffect.core"] = "src/leffect/core.lua",
    ["leffect.effect"] = "src/leffect/effect.lua",
    ["leffect.exit"] = "src/leffect/exit.lua",
    ["leffect.fiber"] = "src/leffect/fiber.lua",
    ["leffect.layer"] = "src/leffect/layer.lua",
    ["leffect.runtime"] = "src/leffect/runtime.lua",
    ["leffect.scheduler.test"] = "src/leffect/scheduler/test.lua",
    ["leffect.scope"] = "src/leffect/scope.lua",
  },
}
