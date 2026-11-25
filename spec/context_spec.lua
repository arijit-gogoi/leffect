-- The fiber context (FIBER-DESIGN.md §18): an immutable table of services,
-- inherited at fork. Until M3 it holds only the current Scope.

local leffect = require("leffect")
local Context = require("leffect.context")
local Effect = leffect.Effect
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

-- An effect that succeeds with the service under `key` in the current context.
local function service(key)
  return Effect.withFiber(function(fiber)
    return Effect.succeed(Context.get(fiber.context, key))
  end)
end

describe("Context", function()
  it("adds a service to a copy, leaving the original unchanged", function()
    local one = Context.add(Context.empty, "a", 1)
    local two = Context.add(one, "b", 2)
    assert.are.equal(1, Context.get(one, "a"))
    assert.is_nil(Context.get(one, "b"))
    assert.are.equal(1, Context.get(two, "a"))
    assert.are.equal(2, Context.get(two, "b"))
    assert.is_nil(Context.get(Context.empty, "a"))
    assert.is_nil(next(Context.empty))
  end)

  it("is empty on a root fiber", function()
    local context = Effect.runSync(Effect.withFiber(function(fiber)
      return Effect.succeed(fiber.context)
    end))
    assert.are.equal(Context.empty, context)
  end)

  it("is inherited by every fork, daemon or not", function()
    local scheduler = TestScheduler.new()
    local function seenByFork(fork)
      return Context.provide(
        "k",
        "v",
        fork(service("k")):flatMap(function(fiber)
          return fiber:join()
        end)
      )
    end
    assert.are.equal("v", h.valueOf(scheduler:run(seenByFork(Effect.fork))))
    assert.are.equal("v", h.valueOf(scheduler:run(seenByFork(Effect.forkDaemon))))
  end)

  describe("provide", function()
    it("sets a service for the effect only", function()
      local inside = Effect.runSync(Context.provide("k", "v", service("k")))
      assert.are.equal("v", inside)
      local after = Effect.runSync(Context.provide("k", "v", Effect.void):flatMap(function()
        return service("k")
      end))
      assert.is_nil(after)
    end)

    it("puts the previous context back after a failure", function()
      local program = Context.provide("k", "outer", Context.provide("k", "inner", Effect.fail("e")))
        :catchAll(function()
          return Effect.void
        end)
        :flatMap(function()
          return service("k")
        end)
      assert.is_nil(Effect.runSync(program))
      local nested = Context.provide(
        "k",
        "outer",
        Context.provide("k", "inner", Effect.fail("e")):catchAll(function()
          return service("k")
        end)
      )
      assert.are.equal("outer", Effect.runSync(nested))
    end)

    it("puts the previous context back on interrupt, before outer finalizers run", function()
      local scheduler = TestScheduler.new()
      local seen
      local program = Context.provide(
        "k",
        "outer",
        Context.provide("k", "inner", Effect.never):ensuring(service("k"):map(function(v)
          seen = v
        end))
      )
      local fiber = h.started(scheduler, program)
      fiber:interruptUnsafe()
      scheduler:runAll()
      h.assertInterrupted(fiber:poll())
      assert.are.equal("outer", seen)
    end)
  end)

  describe("with Effect.scoped", function()
    local scheduler
    before_each(function()
      scheduler = TestScheduler.new()
    end)

    it("gives every fork the same scope, daemon or not", function()
      local function seenByFork(fork)
        return Effect.scoped(Effect.scope:flatMap(function(scope)
          return fork(Effect.scope)
            :flatMap(function(fiber)
              return fiber:join()
            end)
            :map(function(seen)
              return seen == scope
            end)
        end))
      end
      assert.is_true(h.valueOf(scheduler:run(seenByFork(Effect.fork))))
      assert.is_true(h.valueOf(scheduler:run(seenByFork(Effect.forkDaemon))))
    end)

    it("restores the outer scope after a nested scoped succeeds or fails", function()
      local program = Effect.scoped(Effect.scope:flatMap(function(outer)
        return Effect.scoped(Effect.scope)
          :flatMap(function(inner)
            assert(inner ~= outer)
            return Effect.scoped(Effect.fail("e"))
          end)
          :catchAll(function()
            return Effect.scope
          end)
          :map(function(after)
            return after == outer
          end)
      end))
      assert.is_true(Effect.runSync(program))
    end)

    it("restores the outer scope after a nested scoped is interrupted", function()
      local outer, seen
      local program = Effect.scoped(Effect.scope:flatMap(function(scope)
        outer = scope
        return Effect.scoped(Effect.never):ensuring(Effect.scope:map(function(current)
          seen = current
        end))
      end))
      local fiber = h.started(scheduler, program)
      fiber:interruptUnsafe()
      scheduler:runAll()
      h.assertInterrupted(fiber:poll())
      assert.is_not_nil(outer)
      assert.are.equal(outer, seen)
    end)

    it("runs a scope's finalizers in the outer context", function()
      local program = Effect.scoped(Effect.scope:flatMap(function(outer)
        local seen
        return Effect.scoped(Effect.addFinalizer(function()
          return Effect.scope:map(function(current)
            seen = current
          end)
        end)):map(function()
          return seen == outer
        end)
      end))
      assert.is_true(Effect.runSync(program))
    end)

    it("closes an inner scope interrupted as soon as it can be, in the outer context", function()
      local log, record = h.recorder()
      local outer, seen
      local program = Effect.scoped(Effect.scope:flatMap(function(scope)
        outer = scope
        return Effect.uninterruptibleMask(function(restore)
          return Effect.sleep(10):flatMap(function()
            return Effect.scoped(Effect.addFinalizer(function()
              return record("inner closed")
            end):flatMap(function()
              return restore(Effect.sync(function()
                log[#log + 1] = "body ran"
              end))
            end))
          end)
        end):ensuring(Effect.scope:map(function(current)
          seen = current
        end))
      end))
      local fiber = h.started(scheduler, program)
      fiber:interruptUnsafe()
      scheduler:runAll()
      h.assertInterrupted(fiber:poll())
      assert.are.same({ "inner closed" }, log)
      assert.are.equal(outer, seen)
    end)
  end)
end)
