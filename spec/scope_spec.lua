-- Scope (FIBER-DESIGN.md §19): collects finalizers and runs them, newest
-- first and uninterruptibly, when it closes.

local leffect = require("leffect")
local Cause = leffect.Cause
local Effect = leffect.Effect
local Exit = leffect.Exit
local Scope = leffect.Scope
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

-- A finalizer that records `name` and the exit it gets in `log`.
local function finalizer(log, name)
  return function(exit)
    return Effect.sync(function()
      log[#log + 1] = { name = name, exit = exit }
    end)
  end
end

local function names(log)
  local out = {}
  for i, entry in ipairs(log) do
    out[i] = entry.name
  end
  return out
end

-- Adds each finalizer to `scope`, in order.
local function addAll(scope, finalizers)
  local effect = Effect.void
  for _, f in ipairs(finalizers) do
    effect = effect:flatMap(function()
      return Scope.addFinalizerExit(scope, f)
    end)
  end
  Effect.runSync(effect)
end

describe("Scope", function()
  local log
  before_each(function()
    log = {}
  end)

  it("runs its finalizers newest first, each with the close exit", function()
    local scope = Scope.makeUnsafe()
    addAll(scope, { finalizer(log, "a"), finalizer(log, "b"), finalizer(log, "c") })
    local closeExit = Exit.succeed("done")
    h.valueOf(Effect.runSyncExit(Scope.close(scope, closeExit)))
    assert.are.same({ "c", "b", "a" }, names(log))
    for _, entry in ipairs(log) do
      assert.are.equal(closeExit, entry.exit)
    end
  end)

  it("make builds a new open scope each time it runs", function()
    local make = Scope.make()
    local a, b = Effect.runSync(make), Effect.runSync(make)
    assert.are_not.equal(a, b)
    assert.are.equal("open", a.state)
    assert.are.equal("sequential", a.strategy)
  end)

  it("runs the finalizers once when it is closed twice", function()
    local scope = Scope.makeUnsafe()
    addAll(scope, { finalizer(log, "a") })
    Effect.runSync(Scope.close(scope, Exit.void))
    Effect.runSync(Scope.close(scope, Exit.fail("later")))
    assert.are.same({ "a" }, names(log))
    assert.are.equal(Exit.void, scope.exit)
  end)

  it("runs a finalizer added after it closed at once, with the close exit", function()
    local scope = Scope.makeUnsafe()
    local closeExit = Exit.fail("closed")
    Effect.runSync(Scope.close(scope, closeExit))
    Effect.runSync(Scope.addFinalizerExit(scope, finalizer(log, "late")))
    assert.are.same({ "late" }, names(log))
    assert.are.equal(closeExit, log[1].exit)
  end)

  it("addFinalizer adds an effect that ignores the exit", function()
    local scope = Scope.makeUnsafe()
    local ran = false
    Effect.runSync(Scope.addFinalizer(
      scope,
      Effect.sync(function()
        ran = true
      end)
    ))
    Effect.runSync(Scope.close(scope, Exit.void))
    assert.is_true(ran)
  end)

  it("accepts finalizers that return nothing", function()
    local scope = Scope.makeUnsafe()
    local seen
    addAll(scope, {
      function(exit)
        seen = exit
      end,
    })
    h.valueOf(Effect.runSyncExit(Scope.close(scope, Exit.void)))
    assert.are.equal(Exit.void, seen)
  end)

  it("keeps running finalizers after one fails, and fails with all their reasons", function()
    local scope = Scope.makeUnsafe()
    addAll(scope, {
      finalizer(log, "first added"),
      function()
        return Effect.fail("x")
      end,
      function()
        error("boom")
      end,
      finalizer(log, "last added"),
    })
    local cause = h.causeOf(Effect.runSyncExit(Scope.close(scope, Exit.void)))
    assert.are.same({ "last added", "first added" }, names(log))
    assert.are.same({ "Die", "Fail" }, h.tags(cause))
    assert.matches("boom", cause.reasons[1].defect, 1, true)
    assert.matches("stack traceback:", cause.reasons[1].trace, 1, true)
    assert.are.same({ "x" }, (Cause.failures(cause)))
  end)

  it("closes uninterruptibly: an interrupt doesn't cut a sleeping finalizer short", function()
    local scheduler = TestScheduler.new()
    local scope = Scope.makeUnsafe()
    addAll(scope, {
      function()
        return Effect.sleep(100):flatMap(function()
          return finalizer(log, "slept")()
        end)
      end,
    })
    local fiber = h.started(scheduler, Scope.close(scope, Exit.void))
    fiber:interruptUnsafe()
    scheduler:advance(99)
    assert.are.same({}, names(log))
    assert.is_nil(fiber:poll())
    scheduler:advance(1)
    assert.are.same({ "slept" }, names(log))
    h.assertInterrupted(fiber:poll())
  end)

  it("closes a scope with 1e5 finalizers without overflowing", function()
    local scope = Scope.makeUnsafe()
    local count = 0
    local function f()
      count = count + 1
    end
    local effect = Effect.void
    for _ = 1, 100000 do
      effect = effect:flatMap(function()
        return Scope.addFinalizerExit(scope, f)
      end)
    end
    Effect.runSync(effect)
    h.valueOf(Effect.runSyncExit(Scope.close(scope, Exit.void)))
    assert.are.equal(100000, count)
  end)

  describe("fork", function()
    it("gives a scope that closes with its parent, at its own position", function()
      local parent = Scope.makeUnsafe()
      addAll(parent, { finalizer(log, "a") })
      local child = Effect.runSync(Scope.fork(parent))
      addAll(child, { finalizer(log, "child") })
      addAll(parent, { finalizer(log, "c") })
      local closeExit = Exit.fail("e")
      Effect.runSync(Scope.close(parent, closeExit):exit())
      assert.are.same({ "c", "child", "a" }, names(log))
      assert.are.equal(closeExit, child.exit)
    end)

    it("gives a scope that detaches when it closes first", function()
      local parent = Scope.makeUnsafe()
      addAll(parent, { finalizer(log, "a") })
      local child = Effect.runSync(Scope.fork(parent))
      addAll(child, { finalizer(log, "child") })
      Effect.runSync(Scope.close(child, Exit.void))
      Effect.runSync(Scope.close(parent, Exit.void))
      assert.are.same({ "child", "a" }, names(log))
    end)

    it("of a closed scope gives a closed scope with the same exit", function()
      local parent = Scope.makeUnsafe()
      local closeExit = Exit.fail("closed")
      Effect.runSync(Scope.close(parent, closeExit))
      local child = Effect.runSync(Scope.fork(parent, "sequential"))
      assert.are.equal("closed", child.state)
      Effect.runSync(Scope.addFinalizerExit(child, finalizer(log, "late")))
      assert.are.equal(closeExit, log[1].exit)
    end)
  end)

  describe("with the parallel strategy", function()
    it("runs the finalizers at the same time", function()
      local scheduler = TestScheduler.new()
      local scope = Scope.makeUnsafe("parallel")
      local function slow(name)
        return function()
          return Effect.sleep(100):flatMap(function()
            return finalizer(log, name)()
          end)
        end
      end
      addAll(scope, { slow("a"), slow("b") })
      h.valueOf(scheduler:run(Scope.close(scope, Exit.void)))
      assert.are.equal(100, scheduler:now())
      assert.are.same({ "b", "a" }, names(log))
    end)

    it("fails with every finalizer's reasons, newest finalizer first", function()
      local scheduler = TestScheduler.new()
      local scope = Scope.makeUnsafe("parallel")
      local function failsAfter(ms, err)
        return function()
          return Effect.sleep(ms):flatMap(function()
            return Effect.fail(err)
          end)
        end
      end
      addAll(scope, { failsAfter(50, "first added"), failsAfter(100, "last added") })
      local exit = scheduler:run(Scope.close(scope, Exit.void))
      assert.are.same({ "last added", "first added" }, (Cause.failures(h.causeOf(exit))))
      assert.are.equal(100, scheduler:now())
    end)

    it("lets a fiber forked into the scope close it without waiting for itself", function()
      local scheduler = TestScheduler.new()
      local scope = Effect.runSync(Scope.make("parallel"))
      local program = Effect.forkIn(Scope.close(scope, Exit.void), scope):flatMap(function(fiber)
        return fiber:join()
      end)
      h.valueOf(scheduler:run(program))
      assert.are.equal("closed", scope.state)
    end)

    it("can be the strategy of a forked scope", function()
      local scheduler = TestScheduler.new()
      local parent = Scope.makeUnsafe()
      local child = Effect.runSync(Scope.fork(parent, "parallel"))
      assert.are.equal("parallel", child.strategy)
      addAll(child, {
        function()
          return Effect.sleep(10)
        end,
        function()
          return Effect.sleep(10)
        end,
      })
      h.valueOf(scheduler:run(Scope.close(parent, Exit.void)))
      assert.are.equal(10, scheduler:now())
    end)
  end)

  describe("use", function()
    it("provides the scope, then closes it with the effect's exit", function()
      local scope = Scope.makeUnsafe()
      local exit =
        Effect.runSyncExit(Scope.use(
          Effect.addFinalizer(finalizer(log, "a")):flatMap(function()
            return Effect.scope
          end),
          scope
        ))
      assert.are.equal(scope, h.valueOf(exit))
      assert.are.same({ "a" }, names(log))
      assert.are.equal(scope, h.valueOf(log[1].exit))
      assert.are.equal("closed", scope.state)
    end)
  end)

  it("makeUnsafe rejects an unknown strategy", function()
    assert.has_error(function()
      Scope.makeUnsafe("random")
    end)
  end)
end)

describe("Effect.scope", function()
  it("dies outside Effect.scoped", function()
    local reason = h.causeOf(Effect.runSyncExit(Effect.scope)).reasons[1]
    assert.are.equal("Die", reason._tag)
    assert.are.equal(
      "Effect.scope: no Scope in context; wrap the effect in Effect.scoped",
      reason.defect
    )
  end)

  it("is the scope given to Scope.provide, which doesn't close it", function()
    local log = {}
    local scope = Scope.makeUnsafe()
    local seen =
      Effect.runSync(Scope.provide(
        Effect.addFinalizer(finalizer(log, "a")):flatMap(function()
          return Effect.scope
        end),
        scope
      ))
    assert.are.equal(scope, seen)
    assert.are.same({}, names(log))
    assert.are.equal("open", scope.state)
    Effect.runSync(Scope.close(scope, Exit.void))
    assert.are.same({ "a" }, names(log))
  end)
end)

describe("Effect.scoped", function()
  local log
  before_each(function()
    log = {}
  end)

  it("closes the scope with the effect's exit once the effect ends", function()
    local value =
      Effect.runSync(Effect.scoped(Effect.addFinalizer(finalizer(log, "a")):flatMap(function()
        return Effect.sync(function()
          log[#log + 1] = { name = "body" }
          return "result"
        end)
      end)))
    assert.are.equal("result", value)
    assert.are.same({ "body", "a" }, names(log))
    assert.are.equal("result", h.valueOf(log[2].exit))
  end)

  it("closes the scope with a failure, and keeps the failure", function()
    local exit = Effect.runSyncExit(Effect.addFinalizer(finalizer(log, "a"))
      :flatMap(function()
        return Effect.fail("e")
      end)
      :scoped())
    assert.are.same({ "e" }, (Cause.failures(h.causeOf(exit))))
    assert.are.same({ "e" }, (Cause.failures(h.causeOf(log[1].exit))))
  end)

  it("adds a failing finalizer's cause to the exit", function()
    local exit = Effect.runSyncExit(Effect.scoped(Effect.addFinalizer(function()
      return Effect.fail("cleanup")
    end):flatMap(function()
      return Effect.fail("body")
    end)))
    assert.are.same({ "body", "cleanup" }, (Cause.failures(h.causeOf(exit))))
  end)

  it("closes the scope when the fiber is interrupted", function()
    local scheduler = TestScheduler.new()
    local fiber = h.started(
      scheduler,
      Effect.scoped(Effect.addFinalizer(finalizer(log, "a")):flatMap(function()
        return Effect.never
      end))
    )
    fiber:interruptUnsafe()
    scheduler:runAll()
    h.assertInterrupted(fiber:poll())
    assert.are.same({ "a" }, names(log))
    assert.is_true(Cause.hasInterrupts(h.causeOf(log[1].exit)))
  end)

  it("gives each run a fresh scope", function()
    local program = Effect.scoped(Effect.scope)
    assert.are_not.equal(Effect.runSync(program), Effect.runSync(program))
  end)
end)

describe("Effect.scopedWith", function()
  it("passes a fresh scope, and closes it with the effect's exit", function()
    local log = {}
    local given
    local exit = Effect.runSyncExit(Effect.scopedWith(function(scope)
      given = scope
      return Scope.addFinalizerExit(scope, finalizer(log, "a")):flatMap(function()
        return Effect.fail("e")
      end)
    end))
    assert.are.same({ "e" }, (Cause.failures(h.causeOf(exit))))
    assert.are.same({ "a" }, names(log))
    assert.are.same({ "e" }, (Cause.failures(h.causeOf(log[1].exit))))
    assert.are.equal("closed", given.state)
  end)

  it("leaves the context alone", function()
    local exit = Effect.runSyncExit(Effect.scopedWith(function()
      return Effect.scope
    end))
    assert.are.same({ "Die" }, h.tags(h.causeOf(exit)))
  end)
end)

describe("Effect.addFinalizer", function()
  it("adds a finalizer that gets the exit to the current scope", function()
    local seen
    local exit = Effect.runSyncExit(Effect.scoped(Effect.addFinalizer(function(exit)
      seen = exit
    end):flatMap(function()
      return Effect.fail("e")
    end)))
    assert.are.same({ "e" }, (Cause.failures(h.causeOf(seen))))
    assert.are.same({ "e" }, (Cause.failures(h.causeOf(exit))))
  end)

  it("dies outside Effect.scoped", function()
    local exit = Effect.runSyncExit(Effect.addFinalizer(function() end))
    assert.are.same({ "Die" }, h.tags(h.causeOf(exit)))
  end)
end)
