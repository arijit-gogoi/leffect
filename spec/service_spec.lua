-- Services (specifications/26-services.md §26): Context values, keys,
-- references, and the Effect functions that read and provide them.

local leffect = require("leffect")
local Context = leffect.Context
local Effect = leffect.Effect
local Scope = leffect.Scope
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

local A = Context.Service("test/A")
local B = Context.Service("test/B")

local NIL_SERVICE = "Context.add: a service can't be nil"

-- An effect that succeeds with the service under `key`, or nil if there is
-- none.
local function probe(key)
  return Effect.contextWith(function(context)
    return Effect.succeed(Context.getOrElse(context, key, function()
      return nil
    end))
  end)
end

-- The raw fields of a table, for checking that nothing changed them.
local function fields(t)
  local copy = {}
  for k, v in next, t do
    copy[k] = v
  end
  return copy
end

describe("Context", function()
  it("gets the service that make put in", function()
    assert.are.equal(1, Context.get(Context.make(A, 1), A))
  end)

  it("adds to a copy, leaving the original unchanged", function()
    local one = Context.make(A, 1)
    local two = Context.add(one, B, 2)
    assert.are.equal(1, Context.get(two, A))
    assert.are.equal(2, Context.get(two, B))
    assert.are.equal(
      "none",
      Context.getOrElse(one, B, function()
        return "none"
      end)
    )
    local three = Context.add(two, A, 3)
    assert.are.equal(3, Context.get(three, A))
    assert.are.equal(1, Context.get(two, A))
  end)

  it("merges two contexts, the second winning where both have a key", function()
    local merged = Context.merge(Context.make(A, "a"), Context.add(Context.make(A, "x"), B, "b"))
    assert.are.equal("x", Context.get(merged, A))
    assert.are.equal("b", Context.get(merged, B))
    local one = Context.make(A, 1)
    assert.are.equal(one, Context.merge(one, Context.empty()))
    assert.are.equal(one, Context.merge(Context.empty(), one))
  end)

  it("merges many contexts, later ones winning", function()
    local C = Context.Service("test/C")
    local merged = Context.mergeAll(
      Context.make(A, 1),
      Context.add(Context.make(A, 2), B, 2),
      Context.make(C, 3),
      Context.make(B, 4)
    )
    assert.are.equal(2, Context.get(merged, A))
    assert.are.equal(4, Context.get(merged, B))
    assert.are.equal(3, Context.get(merged, C))
    assert.are.equal(Context.empty(), Context.mergeAll())
  end)

  it("raises on get of a missing Service, where getOrElse calls orElse", function()
    assert.has_error(function()
      Context.get(Context.make(B, 1), A)
    end, "Service not found: test/A")
    local calls = 0
    local value = Context.getOrElse(Context.make(B, 1), A, function()
      calls = calls + 1
      return "else"
    end)
    assert.are.equal("else", value)
    assert.are.equal(1, calls)
  end)

  describe("with a Reference", function()
    it("gives its default when missing, computed once across contexts and fibers", function()
      local calls = 0
      local Ref = Context.Reference("test/once", {
        defaultValue = function()
          calls = calls + 1
          return { "default" }
        end,
      })
      local a = Context.get(Context.empty(), Ref)
      local b = Context.get(Context.make(A, 1), Ref)
      local c = Effect.runSync(Ref)
      local scheduler = TestScheduler.new()
      local d = h.valueOf(scheduler:run(Ref:fork():flatMap(function(fiber)
        return fiber:join()
      end)))
      assert.are.same({ "default" }, a)
      assert.are.equal(a, b)
      assert.are.equal(a, c)
      assert.are.equal(a, d)
      assert.are.equal(1, calls)
    end)

    it("prefers a provided value to its default", function()
      local Ref = Context.Reference("test/level", {
        defaultValue = function()
          return "info"
        end,
      })
      assert.are.equal("debug", Context.get(Context.make(Ref, "debug"), Ref))
      assert.are.equal("debug", Effect.runSync(Effect.provideService(Ref, Ref, "debug")))
      assert.are.equal("info", Effect.runSync(Ref))
    end)

    it("may have a nil default, computed only once too", function()
      local calls = 0
      local Ref = Context.Reference("test/nil", {
        defaultValue = function()
          calls = calls + 1
          return nil
        end,
      })
      assert.is_nil(Context.get(Context.empty(), Ref))
      assert.is_nil(Effect.runSync(Ref))
      local orElseCalled = false
      assert.is_nil(Context.getOrElse(Context.empty(), Ref, function()
        orElseCalled = true
        return "else"
      end))
      assert.is_false(orElseCalled)
      assert.are.equal(1, calls)
    end)

    it("is never changed by a lookup", function()
      local Ref = Context.Reference("test/unchanged", {
        defaultValue = function()
          return 0
        end,
      })
      local before = fields(Ref)
      Context.get(Context.empty(), Ref)
      Effect.runSync(Ref)
      Context.getOrElse(Context.empty(), Ref, function()
        return nil
      end)
      assert.are.same(before, fields(Ref))
    end)

    it("dies with the error of a throwing default, and calls it again next time", function()
      local calls = 0
      local Ref = Context.Reference("test/throws", {
        defaultValue = function()
          calls = calls + 1
          if calls == 1 then
            error("no default yet")
          end
          return "ok"
        end,
      })
      local cause = h.causeOf(Effect.runSyncExit(Ref))
      assert.are.same({ "Die" }, h.tags(cause))
      assert.is_truthy(cause.reasons[1].defect:find("no default yet", 1, true))
      assert.is_string(cause.reasons[1].trace)
      assert.are.equal("ok", Effect.runSync(Ref))
      assert.are.equal("ok", Context.get(Context.empty(), Ref))
      assert.are.equal(2, calls)
    end)
  end)

  it("raises on a nil service in make and add, and provideService dies", function()
    assert.has_error(function()
      Context.make(A, nil)
    end, NIL_SERVICE)
    assert.has_error(function()
      Context.add(Context.empty(), A, nil)
    end, NIL_SERVICE)
    local cause = h.causeOf(Effect.runSyncExit(Effect.provideService(Effect.void, A, nil)))
    assert.are.same({ "Die" }, h.tags(cause))
    assert.are.equal(NIL_SERVICE, cause.reasons[1].defect)
  end)

  it("raises on a key that isn't a key", function()
    assert.has_error(function()
      ---@diagnostic disable-next-line: param-type-mismatch
      Context.make("test/A", 1)
    end, "Context.make: expected a key, got test/A")
    assert.has_error(function()
      ---@diagnostic disable-next-line: param-type-mismatch
      Context.get(Context.empty(), Effect.void)
    end)
    assert.has_error(function()
      ---@diagnostic disable-next-line: missing-fields
      Effect.provideService(Effect.void, { key = "test/A" }, 1)
    end)
    assert.has_error(function()
      ---@diagnostic disable-next-line: param-type-mismatch
      Context.Service(42)
    end, "Context.Service: the key must be a string, got 42")
    assert.has_error(function()
      ---@diagnostic disable-next-line: missing-fields
      Context.Reference("test/R", {})
    end, "Context.Reference: options.defaultValue must be a function, got nil")
  end)

  it("shares one service between two keys with the same string", function()
    local One, Two = Context.Service("test/same"), Context.Service("test/same")
    assert.are.equal("v", Context.get(Context.make(One, "v"), Two))
    assert.are.equal("v", Effect.runSync(Effect.provideService(Two, One, "v")))
  end)

  it("tells contexts, keys and references from effects and plain tables", function()
    local Ref = Context.Reference("test/ref", {
      defaultValue = function()
        return 0
      end,
    })
    local context = Context.make(A, 1)
    assert.is_true(Context.isContext(context))
    assert.is_true(Context.isContext(Context.empty()))
    assert.is_false(Context.isContext({ map = {} }))
    assert.is_false(Context.isContext(Effect.void))
    assert.is_false(Context.isContext(A))

    assert.is_true(Context.isKey(A))
    assert.is_true(Context.isKey(Ref))
    assert.is_false(Context.isKey(Effect.void))
    assert.is_false(Context.isKey(Effect.withFiber(function()
      return Effect.void
    end)))
    assert.is_false(Context.isKey("test/A"))
    assert.is_false(Context.isKey({ key = "test/A" }))
    assert.is_false(Context.isKey(context))

    assert.is_true(Context.isReference(Ref))
    assert.is_false(Context.isReference(A))
    assert.is_false(Context.isReference(Effect.void))
    assert.is_false(Context.isReference({ key = "test/ref", defaultValue = function() end }))
  end)
end)

describe("a key", function()
  it("is an effect that succeeds with its service", function()
    local viaGen = Effect.gen(function(run)
      return run(A) + 1
    end)
    assert.are.equal(2, Effect.runSync(Effect.provideService(viaGen, A, 1)))
    local viaFlatMap = A:flatMap(function(a)
      return Effect.succeed(a * 10)
    end)
    assert.are.equal(10, Effect.runSync(Effect.provideService(viaFlatMap, A, 1)))
    assert.are.equal(A, Effect.service(A))
  end)

  it("dies with Service not found when the service is missing; catchAll can't catch it", function()
    local caught = false
    local exit = Effect.runSyncExit(A:catchAll(function()
      caught = true
      return Effect.void
    end))
    local cause = h.causeOf(exit)
    assert.are.same({ "Die" }, h.tags(cause))
    assert.are.equal("Service not found: test/A", cause.reasons[1].defect)
    assert.is_false(caught)
  end)

  it("has use and useSync, which call f with the service", function()
    local used = A:use(function(a)
      return Effect.succeed(a + 1)
    end)
    assert.are.equal(2, Effect.runSync(Effect.provideService(used, A, 1)))
    local usedSync = A:useSync(function(a)
      return a + 2
    end)
    assert.are.equal(3, Effect.runSync(Effect.provideService(usedSync, A, 1)))
    local missing = h.causeOf(Effect.runSyncExit(usedSync))
    assert.are.equal("Service not found: test/A", missing.reasons[1].defect)
  end)
end)

describe("Effect.provideService", function()
  it("covers only its region, after success, failure or interrupt", function()
    local afterSuccess = Effect.provideService(Effect.void, A, "inner"):flatMap(function()
      return probe(A)
    end)
    assert.is_nil(Effect.runSync(afterSuccess))

    local afterFailure = Effect.provideService(
      Effect.provideService(Effect.fail("e"), A, "inner"):catchAll(function()
        return probe(A)
      end),
      A,
      "outer"
    )
    assert.are.equal("outer", Effect.runSync(afterFailure))

    local scheduler = TestScheduler.new()
    local seen
    local afterInterrupt = Effect.provideService(
      Effect.provideService(Effect.never, A, "inner"):ensuring(probe(A):map(function(v)
        seen = v
      end)),
      A,
      "outer"
    )
    local fiber = h.started(scheduler, afterInterrupt)
    fiber:interruptUnsafe()
    scheduler:runAll()
    h.assertInterrupted(fiber:poll())
    assert.are.equal("outer", seen)
  end)

  it("lets the innermost of nested regions win", function()
    local program = Effect.provideService(Effect.provideService(A, A, "inner"), A, "outer")
    assert.are.equal("inner", Effect.runSync(program))
  end)

  it("is seen by a fork inside the region, which keeps it after the region ends", function()
    local scheduler = TestScheduler.new()
    local log = {}
    local child = Effect.sleep(10):flatMap(function()
      return A
    end)
    local program = Effect.provideService(child:fork(), A, "v"):flatMap(function(fiber)
      return probe(A):flatMap(function(outside)
        log[#log + 1] = outside or "none"
        return fiber:join()
      end)
    end)
    assert.are.equal("v", h.valueOf(scheduler:run(program)))
    assert.are.same({ "none" }, log)
  end)
end)

describe("Effect.provideServiceEffect", function()
  it("runs acquire once, before self", function()
    local log, record = h.recorder()
    local self = A:flatMap(function(a)
      return record("self " .. a)
    end)
    Effect.runSync(Effect.provideServiceEffect(self, A, record("acquire"):as("v")))
    assert.are.same({ "acquire", "self v" }, log)
  end)

  it("never runs self when acquire fails", function()
    local ran = false
    local self = Effect.sync(function()
      ran = true
    end)
    local exit = Effect.runSyncExit(Effect.provideServiceEffect(self, A, Effect.fail("no")))
    assert.are.equal("no", h.causeOf(exit).reasons[1].error)
    assert.is_false(ran)
  end)
end)

describe("Effect.updateService", function()
  it("passes the current value to f", function()
    local program = Effect.updateService(A, A, function(a)
      return a + 1
    end)
    assert.are.equal(2, Effect.runSync(Effect.provideService(program, A, 1)))
  end)

  it("passes a missing Reference's default to f", function()
    local Ref = Context.Reference("test/update", {
      defaultValue = function()
        return "default"
      end,
    })
    local program = Effect.updateService(Ref, Ref, function(v)
      return v .. "!"
    end)
    assert.are.equal("default!", Effect.runSync(program))
  end)

  it("dies for a missing Service, without calling f", function()
    local called = false
    local program = Effect.updateService(Effect.void, A, function(a)
      called = true
      return a
    end)
    local cause = h.causeOf(Effect.runSyncExit(program))
    assert.are.equal("Service not found: test/A", cause.reasons[1].defect)
    assert.is_false(called)
  end)
end)

describe("Effect.provideContext", function()
  it("merges the context over the fiber's, the given one winning", function()
    local program = Effect.provideContext(Effect.all({ A, B }), Context.make(B, "given"))
    local both = Effect.provideService(Effect.provideService(program, A, "a"), B, "b")
    assert.are.same({ "a", "given", n = 2 }, Effect.runSync(both))
  end)

  it("returns an Exit as it is", function()
    local exit = Effect.succeed(1)
    assert.are.equal(exit, Effect.provideContext(exit, Context.make(A, 1)))
  end)
end)

describe("Effect.context", function()
  it("gives the fiber's context, with the services provided around it", function()
    local context = Effect.runSync(Effect.provideService(Effect.context(), A, 1))
    assert.is_true(Context.isContext(context))
    assert.are.equal(1, Context.get(context, A))
  end)

  it("passes the context to contextWith", function()
    local program = Effect.contextWith(function(context)
      return Effect.succeed(Context.get(context, A))
    end)
    assert.are.equal(2, Effect.runSync(Effect.provideService(program, A, 2)))
  end)
end)

describe("Effect.updateContext", function()
  it("runs the effect with the context f returns", function()
    local program = Effect.updateContext(A, function(context)
      return Context.add(context, A, "updated")
    end)
    assert.are.equal("updated", Effect.runSync(program))
  end)

  it("dies when f returns something other than a Context", function()
    local program = Effect.updateContext(Effect.void, function()
      return { map = {} }
    end)
    local cause = h.causeOf(Effect.runSyncExit(program))
    assert.are.same({ "Die" }, h.tags(cause))
    assert.is_truthy(cause.reasons[1].defect:find("f must return a Context", 1, true))
  end)
end)

it("has provideService and the other service functions as methods", function()
  assert.are.equal(1, Effect.runSync(A:provideService(A, 1)))
  assert.are.equal(1, Effect.runSync(A:provideServiceEffect(A, Effect.succeed(1))))
  local updated = A:updateService(A, function(a)
    return a + 1
  end)
  assert.are.equal(2, Effect.runSync(updated:provideService(A, 1)))
  assert.are.equal(1, Effect.runSync(A:provideContext(Context.make(A, 1))))
  local viaUpdate = A:updateContext(function(context)
    return Context.add(context, A, 1)
  end)
  assert.are.equal(1, Effect.runSync(viaUpdate))
end)

describe("the release context", function()
  it("gives an acquireRelease release the services provided around it", function()
    local seen = {}
    local acquired = Effect.acquireRelease(Effect.succeed("resource"), function(resource)
      return Effect.all({ probe(A), probe(B) }):map(function(list)
        seen.resource, seen.a, seen.b = resource, list[1], list[2]
      end)
    end)
    -- The scope closes after the provideService regions have ended, where A
    -- is "closing" and B is missing.
    local program = Effect.provideService(
      Effect.scoped(Effect.provideService(Effect.provideService(acquired, B, "b"), A, "acquired")),
      A,
      "closing"
    )
    Effect.runSync(program)
    assert.are.same({ resource = "resource", a = "acquired", b = "b" }, seen)
  end)

  it("gives an Effect.addFinalizer finalizer its services, and its own scope", function()
    local seen, inner = {}, nil
    local add = Effect.scope:flatMap(function(scope)
      inner = scope
      return Effect.addFinalizer(function()
        return Effect.all({ probe(A), Effect.scope }):map(function(list)
          seen.a, seen.scope = list[1], list[2]
        end)
      end)
    end)
    local outer
    local program = Effect.scoped(Effect.scope:flatMap(function(scope)
      outer = scope
      return Effect.scoped(Effect.provideService(add, A, "added"))
    end))
    Effect.runSync(program)
    assert.are.equal("added", seen.a)
    assert.is_not_nil(inner)
    assert.are.equal(inner, seen.scope)
    assert.are_not.equal(outer, seen.scope)
  end)

  it("lets the captured services win over the closing fiber's", function()
    local seen
    local add = Effect.addFinalizer(function()
      return probe(A):map(function(v)
        seen = v
      end)
    end)
    -- scopedWith closes the scope inside the outer region, where A is
    -- "closing".
    local program = Effect.provideService(
      Effect.scopedWith(function(scope)
        return Scope.provide(Effect.provideService(add, A, "captured"), scope)
      end),
      A,
      "closing"
    )
    Effect.runSync(program)
    assert.are.equal("captured", seen)
  end)
end)

describe("Scope.Scope", function()
  it("is the key of the current scope", function()
    local same = Effect.scoped(Effect.all({ Scope.Scope, Effect.scope })):map(function(list)
      return list[1] ~= nil and list[1] == list[2]
    end)
    assert.is_true(Effect.runSync(same))
  end)

  it("dies with Service not found outside a scope, where Effect.scope gives a hint", function()
    local missing = h.causeOf(Effect.runSyncExit(Scope.Scope))
    assert.are.equal("Service not found: leffect/Scope", missing.reasons[1].defect)
    local hinted = h.causeOf(Effect.runSyncExit(Effect.scope))
    assert.are.equal(
      "Effect.scope: no Scope in context; wrap the effect in Effect.scoped",
      hinted.reasons[1].defect
    )
  end)
end)
