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
modelled on Effect TS (v4). Fibers with structured concurrency and cooperative
interruption, finalizers, Scope and acquireRelease, generators on coroutines,
and bounded concurrency with forEach and all. Services with Context keys and
references, layers with shared builds, runCallback, and a scheduler on luv
(an optional dependency). Concurrency primitives: Ref, SynchronizedRef,
Deferred, Latch, Semaphore, Queue and PubSub. Targets LuaJIT 2.1 and Lua 5.4.
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
    ["leffect.deferred"] = "src/leffect/deferred.lua",
    ["leffect.effect"] = "src/leffect/effect.lua",
    ["leffect.exit"] = "src/leffect/exit.lua",
    ["leffect.fiber"] = "src/leffect/fiber.lua",
    ["leffect.latch"] = "src/leffect/latch.lua",
    ["leffect.layer"] = "src/leffect/layer.lua",
    ["leffect.pubsub"] = "src/leffect/pubsub.lua",
    ["leffect.queue"] = "src/leffect/queue.lua",
    ["leffect.ref"] = "src/leffect/ref.lua",
    ["leffect.runtime"] = "src/leffect/runtime.lua",
    ["leffect.scheduler.luv"] = "src/leffect/scheduler/luv.lua",
    ["leffect.scheduler.test"] = "src/leffect/scheduler/test.lua",
    ["leffect.scope"] = "src/leffect/scope.lua",
    ["leffect.semaphore"] = "src/leffect/semaphore.lua",
    ["leffect.synchronizedref"] = "src/leffect/synchronizedref.lua",
    ["leffect.waitlist"] = "src/leffect/waitlist.lua",
  },
}
