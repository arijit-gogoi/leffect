-- The fiber context (specifications/18-context.md §18): an immutable map of
-- services, inherited at fork. M3 made it public (26-services.md §26); these
-- specs restate M2's on the public API.

local leffect = require("leffect")
local Context = leffect.Context
local Effect = leffect.Effect
local Scope = leffect.Scope
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

local K = Context.Service("test/K")

-- An effect that succeeds with the service under `key`, or nil if there is
-- none.
local function service(key)
  return Effect.contextWith(function(context)
    return Effect.succeed(Context.getOrElse(context, key, function()
      return nil
    end))
  end)
end

describe("Context", function()
  it("adds a service to a copy, leaving the original unchanged", function()
    local A, B = Context.Service("test/a"), Context.Service("test/b")
    local one = Context.add(Context.empty(), A, 1)
    local two = Context.add(one, B, 2)
    assert.are.equal(1, Context.get(one, A))
    assert.has_error(function()
      Context.get(one, B)
    end, "Service not found: test/b")
    assert.are.equal(1, Context.get(two, A))
    assert.are.equal(2, Context.get(two, B))
    assert.has_error(function()
      Context.get(Context.empty(), A)
    end, "Service not found: test/a")
    assert.is_nil(next(Context.empty().map))
  end)

  it("is empty on a root fiber", function()
    assert.are.equal(Context.empty(), Effect.runSync(Effect.context()))
  end)

  it("is inherited by every fork, daemon or not", function()
    local scheduler = TestScheduler.new()
    local function seenByFork(fork)
      return Effect.provideService(
        fork(service(K)):flatMap(function(fiber)
          return fiber:join()
        end),
        K,
        "v"
      )
    end
    assert.are.equal("v", h.valueOf(scheduler:run(seenByFork(Effect.fork))))
    assert.are.equal("v", h.valueOf(scheduler:run(seenByFork(Effect.forkDaemon))))
  end)

  describe("provideService", function()
    it("sets a service for the effect only", function()
      local inside = Effect.runSync(Effect.provideService(service(K), K, "v"))
      assert.are.equal("v", inside)
      local after = Effect.runSync(Effect.provideService(Effect.void, K, "v"):flatMap(function()
        return service(K)
      end))
      assert.is_nil(after)
    end)

    it("puts the previous context back after a failure", function()
      local program = Effect.provideService(
        Effect.provideService(Effect.fail("e"), K, "inner"),
        K,
        "outer"
      )
        :catchAll(function()
          return Effect.void
        end)
        :flatMap(function()
          return service(K)
        end)
      assert.is_nil(Effect.runSync(program))
      local nested = Effect.provideService(
        Effect.provideService(Effect.fail("e"), K, "inner"):catchAll(function()
          return service(K)
        end),
        K,
        "outer"
      )
      assert.are.equal("outer", Effect.runSync(nested))
    end)

    it("puts the previous context back on interrupt, before outer finalizers run", function()
      local scheduler = TestScheduler.new()
      local seen
      local program = Effect.provideService(
        Effect.provideService(Effect.never, K, "inner"):ensuring(service(K):map(function(v)
          seen = v
        end)),
        K,
        "outer"
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

    -- M2's spec used Effect.addFinalizer, whose finalizers now run in the
    -- context where they were added (26-services.md §26.5).
    it("runs a raw Scope finalizer in the outer context", function()
      local program = Effect.scoped(Effect.scope:flatMap(function(outer)
        local seenScope, seenK = nil, "unset"
        local addRaw = Effect.scope:flatMap(function(inner)
          return Scope.addFinalizerExit(inner, function()
            return Effect.all({ Effect.scope, service(K) }):map(function(list)
              seenScope, seenK = list[1], list[2]
            end)
          end)
        end)
        return Effect.scoped(Effect.provideService(addRaw, K, "inner")):map(function()
          return seenScope == outer and seenK == nil
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
