-- Resources (FIBER-DESIGN.md §20): acquireRelease ties a release to the
-- current scope, acquireUseRelease brackets a use, and forkIn/forkScoped tie
-- a fiber to a scope.

local leffect = require("leffect")
local Cause = leffect.Cause
local Effect = leffect.Effect
local Exit = leffect.Exit
local Scope = leffect.Scope
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

describe("acquireRelease", function()
  local scheduler, log, record
  before_each(function()
    scheduler = TestScheduler.new()
    log, record = h.recorder()
  end)

  -- A release that records the resource, and keeps the exit it gets.
  local exits
  before_each(function()
    exits = {}
  end)
  local function release(resource, exit)
    exits[#exits + 1] = exit
    return record("released " .. resource)
  end

  it("releases the resource when the scope closes, with the close exit", function()
    local program =
      Effect.scoped(Effect.acquireRelease(Effect.succeed("r"), release):flatMap(function(resource)
        return record("using " .. resource):as("result")
      end))
    assert.are.equal("result", Effect.runSync(program))
    assert.are.same({ "using r", "released r" }, log)
    assert.are.equal("result", h.valueOf(exits[1]))
  end)

  it("releases nothing when acquire fails", function()
    local exit =
      Effect.runSyncExit(Effect.scoped(Effect.acquireRelease(Effect.fail("no"), release)))
    assert.are.same({ "no" }, (Cause.failures(h.causeOf(exit))))
    assert.are.same({}, log)
  end)

  it("acquires nothing without a scope", function()
    local acquired = false
    local exit = Effect.runSyncExit(Effect.acquireRelease(
      Effect.sync(function()
        acquired = true
      end),
      release
    ))
    assert.are.same({ "Die" }, h.tags(h.causeOf(exit)))
    assert.is_false(acquired)
  end)

  it("lets an interrupted acquire finish, then releases, and ends interrupted", function()
    local acquire = Effect.sleep(100):flatMap(function()
      return record("acquired"):as("r")
    end)
    local fiber = h.started(
      scheduler,
      Effect.scoped(Effect.acquireRelease(acquire, release):flatMap(function()
        return record("used")
      end))
    )
    fiber:interruptUnsafe()
    scheduler:advance(99)
    assert.are.same({}, log)
    scheduler:advance(1)
    assert.are.same({ "acquired", "released r" }, log)
    h.assertInterrupted(fiber:poll())
    assert.is_true(Cause.hasInterrupts(h.causeOf(exits[1])))
  end)

  it("with interruptible = true, lets an interrupt stop acquire, and releases nothing", function()
    local acquire = Effect.sleep(100):flatMap(function()
      return record("acquired"):as("r")
    end)
    local fiber = h.started(
      scheduler,
      Effect.scoped(Effect.acquireRelease(acquire, release, { interruptible = true }))
    )
    fiber:interruptUnsafe()
    scheduler:runAll()
    h.assertInterrupted(fiber:poll())
    assert.are.same({}, log)
    assert.are.equal(0, scheduler:now())
  end)

  it("releases resources in reverse order of acquisition", function()
    local function acquire(name)
      return Effect.acquireRelease(Effect.succeed(name), release)
    end
    Effect.runSync(Effect.scoped(acquire("a")
      :flatMap(function()
        return acquire("b")
      end)
      :flatMap(function()
        return acquire("c")
      end)))
    assert.are.same({ "released c", "released b", "released a" }, log)
  end)

  it("adds a failing release's cause to the exit", function()
    local exit =
      Effect.runSyncExit(Effect.scoped(Effect.acquireRelease(Effect.succeed("r"), function()
        return Effect.fail("release failed")
      end):flatMap(function()
        return Effect.fail("use failed")
      end)))
    assert.are.same({ "use failed", "release failed" }, (Cause.failures(h.causeOf(exit))))
  end)

  it("accepts a release that returns nothing", function()
    local released
    Effect.runSync(Effect.scoped(Effect.acquireRelease(Effect.succeed("r"), function(resource)
      released = resource
    end)))
    assert.are.equal("r", released)
  end)
end)

describe("acquireUseRelease", function()
  local scheduler, log, record
  before_each(function()
    scheduler = TestScheduler.new()
    log, record = h.recorder()
  end)

  local exits
  before_each(function()
    exits = {}
  end)
  local function release(resource, exit)
    exits[#exits + 1] = exit
    return record("released " .. resource)
  end

  it("releases after use succeeds, and keeps use's value", function()
    local value = Effect.runSync(Effect.acquireUseRelease(Effect.succeed("r"), function(resource)
      return record("using " .. resource):as("result")
    end, release))
    assert.are.equal("result", value)
    assert.are.same({ "using r", "released r" }, log)
    assert.are.equal("result", h.valueOf(exits[1]))
  end)

  it("releases after use fails, and keeps the failure", function()
    local exit = Effect.runSyncExit(Effect.acquireUseRelease(Effect.succeed("r"), function()
      return Effect.fail("use failed")
    end, release))
    assert.are.same({ "use failed" }, (Cause.failures(h.causeOf(exit))))
    assert.are.same({ "released r" }, log)
    assert.are.same({ "use failed" }, (Cause.failures(h.causeOf(exits[1]))))
  end)

  it("releases after use is interrupted: use is interruptible", function()
    local fiber = h.started(
      scheduler,
      Effect.acquireUseRelease(Effect.succeed("r"), function()
        return Effect.sleep(100):flatMap(function()
          return record("used")
        end)
      end, release)
    )
    scheduler:advance(10)
    fiber:interruptUnsafe()
    scheduler:runAll()
    h.assertInterrupted(fiber:poll())
    assert.are.same({ "released r" }, log)
    assert.are.equal(10, scheduler:now())
  end)

  it("doesn't let an interrupt stop acquire", function()
    local fiber = h.started(
      scheduler,
      Effect.acquireUseRelease(
        Effect.sleep(100):flatMap(function()
          return record("acquired"):as("r")
        end),
        function()
          return record("used")
        end,
        release
      )
    )
    fiber:interruptUnsafe()
    scheduler:runAll()
    h.assertInterrupted(fiber:poll())
    assert.are.same({ "acquired", "released r" }, log)
    assert.are.equal(100, scheduler:now())
  end)

  it("adds a failing release's cause to the exit", function()
    local exit = Effect.runSyncExit(Effect.acquireUseRelease(Effect.succeed("r"), function()
      return Effect.fail("use failed")
    end, function()
      return Effect.fail("release failed")
    end))
    assert.are.same({ "use failed", "release failed" }, (Cause.failures(h.causeOf(exit))))
  end)
end)

describe("forkIn and forkScoped", function()
  local scheduler, log, record
  before_each(function()
    scheduler = TestScheduler.new()
    log, record = h.recorder()
  end)

  it("forkScoped: closing the scope interrupts the fiber and waits for it", function()
    local forked
    local program = Effect.scoped(Effect.never
      :ensuring(Effect.sleep(50):flatMap(function()
        return record("fiber cleaned up")
      end))
      :forkScoped()
      :flatMap(function(fiber)
        forked = fiber
        return Effect.sleep(10)
      end)):flatMap(function()
      return record("scope closed")
    end)
    h.valueOf(scheduler:run(program))
    assert.are.same({ "fiber cleaned up", "scope closed" }, log)
    assert.are.equal(60, scheduler:now())
    h.assertInterrupted(forked:poll())
  end)

  it("forkScoped: a fiber that ended earlier leaves no finalizer behind", function()
    local program = Effect.scoped(Effect.scope:flatMap(function(scope)
      return Effect.forkScoped(Effect.succeed(1))
        :flatMap(function(fiber)
          return fiber:join()
        end)
        :map(function()
          return scope.live
        end)
    end))
    assert.are.equal(0, h.valueOf(scheduler:run(program)))
  end)

  it("forkScoped dies outside Effect.scoped", function()
    local exit = scheduler:run(Effect.forkScoped(Effect.void))
    assert.are.same({ "Die" }, h.tags(h.causeOf(exit)))
  end)

  it("forkIn ties the fiber to the scope, not to the fiber that forked it", function()
    local scope = Scope.makeUnsafe()
    local forked
    local parent = scheduler:fork(Effect.forkIn(Effect.never, scope):map(function(fiber)
      forked = fiber
    end))
    scheduler:runAll()
    h.valueOf(parent:poll())
    assert.is_nil(forked:poll())
    scheduler:run(Scope.close(scope, Exit.void))
    h.assertInterrupted(forked:poll())
  end)

  it("forkIn on a closed scope gives an interrupted fiber that ran none of its code", function()
    local scope = Scope.makeUnsafe()
    Effect.runSync(Scope.close(scope, Exit.void))
    local ran = false
    local effect = Effect.sync(function()
      ran = true
    end)
    local exit = scheduler:run(effect:forkIn(scope):flatMap(function(fiber)
      return fiber:await()
    end))
    h.assertInterrupted(h.valueOf(exit))
    assert.is_false(ran)
  end)

  it("lets a forked fiber close its own scope without waiting for itself", function()
    local scope = Scope.makeUnsafe()
    local exit =
      scheduler:run(Effect.forkIn(Scope.close(scope, Exit.void), scope):flatMap(function(fiber)
        return fiber:join()
      end))
    h.valueOf(exit)
    assert.are.equal("closed", scope.state)
  end)
end)
