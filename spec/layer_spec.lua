-- Layers (specifications/27-layers.md §27): building services, sharing builds
-- through the MemoMap, and Effect.provide.

local leffect = require("leffect")
local Cause = leffect.Cause
local Context = leffect.Context
local Effect = leffect.Effect
local Layer = leffect.Layer
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

local K = Context.Service("test/K")
local KA = Context.Service("test/A")
local KB = Context.Service("test/B")
local KC = Context.Service("test/C")

-- An effect that succeeds with the service under `key`, or nil if there is
-- none.
local function probe(key)
  return Effect.contextWith(function(context)
    return Effect.succeed(Context.getOrElse(context, key, function()
      return nil
    end))
  end)
end

-- Appends `entry` to `log` when run.
local function logged(log, entry)
  return Effect.sync(function()
    log[#log + 1] = entry
  end)
end

-- A layer for `key` that acquires the resource `{ name = name }` and logs
-- "acquire <name>", then "release <name>" when it is released. Acquiring
-- takes `options.acquireMs`, and releasing `options.releaseMs`. With
-- `options.needs`, the resource records that service as `dep`.
local function resource(key, name, log, options)
  options = options or {}
  local acquire = Effect.suspend(function()
    if options.needs then
      return options.needs
    end
    return Effect.void
  end):map(function(dep)
    log[#log + 1] = "acquire " .. name
    return { name = name, dep = dep }
  end)
  if options.acquireMs then
    local now = acquire
    acquire = Effect.sleep(options.acquireMs):flatMap(function()
      return now
    end)
  end
  return Layer.effect(
    key,
    Effect.acquireRelease(acquire, function()
      local release = logged(log, "release " .. name)
      if options.releaseMs then
        return Effect.sleep(options.releaseMs):flatMap(function()
          return release
        end)
      end
      return release
    end)
  )
end

-- How many times `entry` appears in `log`.
local function count(log, entry)
  local n = 0
  for i = 1, #log do
    if log[i] == entry then
      n = n + 1
    end
  end
  return n
end

-- The position of `entry` in `log`, or nil.
local function indexOf(log, entry)
  for i = 1, #log do
    if log[i] == entry then
      return i
    end
  end
  return nil
end

describe("Effect.provide", function()
  it("provides a layer's services to the effect, and only to it", function()
    local program = Effect.provide(K, Layer.succeed(K, "v"))
    assert.are.equal("v", Effect.runSync(program))
    local after = program:flatMap(function()
      return probe(K)
    end)
    assert.is_nil(Effect.runSync(after))
  end)

  it("merges a list of layers, provides a Context, and dies on anything else", function()
    local both =
      Effect.provide(Effect.all({ KA, KB }), { Layer.succeed(KA, 1), Layer.succeed(KB, 2) })
    assert.are.same({ 1, 2, n = 2 }, Effect.runSync(both))
    assert.are.equal(3, Effect.runSync(Effect.provide(KA, Context.make(KA, 3))))
    assert.is_nil(Effect.runSync(Effect.provide(probe(KA), {})))
    local expected = "Effect.provide: expected a Layer, a list of layers or a Context"
    local bad = { { 1, 2 }, { a = Layer.succeed(KA, 1) }, "layer", KA, Effect.void }
    for _, source in ipairs(bad) do
      ---@diagnostic disable-next-line: param-type-mismatch
      local cause = h.causeOf(Effect.runSyncExit(Effect.provide(Effect.void, source)))
      assert.are.same({ "Die" }, h.tags(cause))
      assert.are.equal(expected, cause.reasons[1].defect)
    end
  end)

  it("is a method", function()
    assert.are.equal("v", Effect.runSync(K:provide(Layer.succeed(K, "v"))))
  end)
end)

describe("Layer constructors", function()
  it("succeed, succeedContext and empty build what they were given", function()
    assert.are.equal(1, Effect.runSync(Effect.provide(KA, Layer.succeed(KA, 1))))
    local context = Context.add(Context.make(KA, 1), KB, 2)
    local both = Effect.provide(Effect.all({ KA, KB }), Layer.succeedContext(context))
    assert.are.same({ 1, 2, n = 2 }, Effect.runSync(both))
    assert.is_nil(Effect.runSync(Effect.provide(probe(KA), Layer.empty)))
    assert.has_error(function()
      Layer.succeed(KA, nil)
    end, "Context.add: a service can't be nil")
  end)

  it("sync calls its thunk once per build", function()
    local calls = 0
    local L = Layer.sync(K, function()
      calls = calls + 1
      return calls
    end)
    assert.are.equal(1, Effect.runSync(Effect.provide(K, Layer.mergeAll(L, L))))
    assert.are.equal(1, calls)
    assert.are.equal(2, Effect.runSync(Effect.provide(K, L)))
    assert.are.equal(2, calls)
  end)

  it("syncContext, effectContext and effectDiscard build contexts and run effects", function()
    local fromSync = Layer.syncContext(function()
      return Context.make(KA, "sync")
    end)
    assert.are.equal("sync", Effect.runSync(Effect.provide(KA, fromSync)))
    local fromEffect = Layer.effectContext(Effect.succeed(Context.make(KA, "effect")))
    assert.are.equal("effect", Effect.runSync(Effect.provide(KA, fromEffect)))
    local log = {}
    local discard = Layer.effectDiscard(logged(log, "ran"))
    assert.is_nil(Effect.runSync(Effect.provide(probe(KA), discard)))
    assert.are.same({ "ran" }, log)
  end)

  it("dies when a build gives nil or something other than a Context", function()
    local nilService = Layer.sync(K, function()
      return nil
    end)
    local cause = h.causeOf(Effect.runSyncExit(Effect.provide(Effect.void, nilService)))
    assert.are.equal("Context.add: a service can't be nil", cause.reasons[1].defect)
    local notContext = Layer.effectContext(Effect.succeed("nope"))
    cause = h.causeOf(Effect.runSyncExit(Effect.provide(Effect.void, notContext)))
    assert.is_truthy(cause.reasons[1].defect:find("expected a Context", 1, true))
  end)

  it("suspend builds the layer its thunk returns", function()
    local calls = 0
    local L = Layer.suspend(function()
      calls = calls + 1
      return Layer.succeed(K, "suspended")
    end)
    assert.are.equal(0, calls)
    assert.are.equal("suspended", Effect.runSync(Effect.provide(K, L)))
    assert.are.equal(1, calls)
  end)

  it("raises when given something other than a key or a layer", function()
    assert.has_error(function()
      ---@diagnostic disable-next-line: param-type-mismatch
      Layer.succeed("test/K", 1)
    end)
    assert.has_error(function()
      ---@diagnostic disable-next-line: param-type-mismatch
      Layer.mergeAll(Layer.empty, KA)
    end)
    assert.has_error(function()
      ---@diagnostic disable-next-line: param-type-mismatch
      Layer.provide(Layer.empty, Context.empty())
    end)
  end)
end)

describe("Layer.effect", function()
  it("acquires before the effect runs, and releases after it, with its exit", function()
    local log = {}
    local L = Layer.effect(
      K,
      Effect.acquireRelease(logged(log, "acquire"):as("r"), function(_, exit)
        return logged(log, "release " .. exit._tag)
      end)
    )
    Effect.runSync(Effect.provide(
      K:flatMap(function(r)
        return logged(log, "use " .. r)
      end),
      L
    ))
    assert.are.same({ "acquire", "use r", "release Success" }, log)

    local exits = {}
    local failing = Layer.effect(
      K,
      Effect.acquireRelease(Effect.succeed("r"), function(_, exit)
        exits[#exits + 1] = exit
        return nil
      end)
    )
    Effect.runSyncExit(Effect.provide(Effect.fail("x"), failing))
    assert.are.equal("x", h.causeOf(exits[1]).reasons[1].error)
  end)

  it("releases after an interrupt of the effect", function()
    local scheduler = TestScheduler.new()
    local log = {}
    local fiber = h.started(scheduler, Effect.provide(Effect.never, resource(K, "r", log)))
    assert.are.same({ "acquire r" }, log)
    fiber:interruptUnsafe()
    scheduler:runAll()
    h.assertInterrupted(fiber:poll())
    assert.are.same({ "acquire r", "release r" }, log)
  end)
end)

describe("a failing build", function()
  it(
    "fails the provide with its error, never runs the effect, and releases earlier layers",
    function()
      local log = {}
      local bad = Layer.effect(KB, Effect.fail("bad"))
      local ran = false
      local program = Effect.provide(
        Effect.sync(function()
          ran = true
        end),
        bad:provide(resource(KA, "first", log))
      )
      local cause = h.causeOf(Effect.runSyncExit(program))
      assert.are.same({ "Fail" }, h.tags(cause))
      assert.are.equal("bad", cause.reasons[1].error)
      assert.is_false(ran)
      assert.are.same({ "acquire first", "release first" }, log)
    end
  )

  it("releases what it acquired before the failure comes out", function()
    local log = {}
    local failing = Layer.effect(KB, Effect.fail("bad")):provide(resource(KA, "first", log))
    local recovered = failing:catchAll(function()
      return Layer.effect(KB, logged(log, "fallback"):as("b"))
    end)
    Effect.runSync(Effect.provide(logged(log, "effect"), recovered))
    assert.are.same({ "acquire first", "release first", "fallback", "effect" }, log)
  end)

  it("releases what was built when the build is interrupted, and never runs the effect", function()
    local scheduler = TestScheduler.new()
    local log = {}
    local stuck = Layer.effect(KB, Effect.never)
    local ran = false
    local program = Effect.provide(
      Effect.sync(function()
        ran = true
      end),
      stuck:provide(resource(KA, "first", log))
    )
    local fiber = h.started(scheduler, program)
    assert.are.same({ "acquire first" }, log)
    fiber:interruptUnsafe()
    scheduler:runAll()
    h.assertInterrupted(fiber:poll())
    assert.are.same({ "acquire first", "release first" }, log)
    assert.is_false(ran)
  end)
end)

describe("sharing", function()
  it("builds a layer used twice in a graph once, and releases it after its users", function()
    local log = {}
    local LC = resource(KC, "C", log)
    local LA = resource(KA, "A", log, { needs = KC })
    local LB = resource(KB, "B", log, { needs = KC })
    local program =
      Effect.provide(Effect.all({ KA, KB }), Layer.mergeAll(LA:provide(LC), LB:provide(LC)))
    local scheduler = TestScheduler.new()
    local both = h.valueOf(scheduler:run(program))
    assert.are.equal(both[1].dep, both[2].dep)
    assert.are.equal(1, count(log, "acquire C"))
    assert.are.equal(1, count(log, "release C"))
    assert.is_true(indexOf(log, "release C") > indexOf(log, "release A"))
    assert.is_true(indexOf(log, "release C") > indexOf(log, "release B"))
  end)

  it("makes requests that arrive during a shared build wait for it", function()
    local log = {}
    local LC = resource(KC, "C", log, { acquireMs = 100 })
    local LA = resource(KA, "A", log, { needs = KC })
    local LB = resource(KB, "B", log, { needs = KC })
    local program =
      Effect.provide(Effect.all({ KA, KB }), Layer.mergeAll(LA:provide(LC), LB:provide(LC)))
    local scheduler = TestScheduler.new()
    local both = h.valueOf(scheduler:run(program))
    assert.are.equal(1, count(log, "acquire C"))
    assert.are.equal(both[1].dep, both[2].dep)
    assert.are.equal(100, scheduler:now())
  end)

  it("fails every user waiting for a shared build that fails, after one attempt", function()
    local attempts = 0
    local LC = Layer.effect(
      KC,
      Effect.sleep(100):flatMap(function()
        attempts = attempts + 1
        return Effect.fail("no C")
      end)
    )
    local memoMap = Layer.makeMemoMapUnsafe()
    local function use()
      return Effect.scopedWith(function(scope)
        return Layer.buildWithMemoMap(LC, memoMap, scope)
      end)
    end
    local program = use():fork():flatMap(function(first)
      return use():fork():flatMap(function(second)
        return Effect.all({ first:await(), second:await() })
      end)
    end)
    local scheduler = TestScheduler.new()
    local exits = h.valueOf(scheduler:run(program))
    assert.are.equal(1, attempts)
    assert.are.equal("no C", h.causeOf(exits[1]).reasons[1].error)
    assert.are.equal("no C", h.causeOf(exits[2]).reasons[1].error)
    -- The failed entry left with its last user: a later request builds again.
    h.causeOf(scheduler:run(use()))
    assert.are.equal(2, attempts)
  end)

  it("builds again for a request that comes after the last user released it", function()
    local log = {}
    local LC = resource(KC, "C", log)
    local memoMap = Layer.makeMemoMapUnsafe()
    local function use()
      return Effect.scopedWith(function(scope)
        return Layer.buildWithMemoMap(LC, memoMap, scope)
      end)
    end
    Effect.runSync(use():flatMap(function()
      return use()
    end))
    assert.are.same({ "acquire C", "release C", "acquire C", "release C" }, log)
  end)

  it("builds a fresh layer again, even in the same graph", function()
    local log = {}
    local LC = resource(KC, "C", log)
    local LA = resource(KA, "A", log, { needs = KC })
    local LB = resource(KB, "B", log, { needs = KC })
    local graph = Layer.mergeAll(LA:provide(LC), LB:provide(Layer.fresh(LC)))
    local both = Effect.runSync(Effect.provide(Effect.all({ KA, KB }), graph))
    assert.are.equal(2, count(log, "acquire C"))
    assert.are_not.equal(both[1].dep, both[2].dep)
  end)

  it("builds separate copies for sibling provides", function()
    local log = {}
    local LC = resource(KC, "C", log)
    Effect.runSync(Effect.all({ Effect.provide(KC, LC), Effect.provide(KC, LC) }))
    assert.are.equal(2, count(log, "acquire C"))
  end)

  it("reuses the outer build in a nested provide, unless fresh is set", function()
    local log = {}
    local LC = resource(KC, "C", log)
    local nested = Effect.provide(Effect.provide(KC, LC), LC)
    Effect.runSync(nested)
    assert.are.equal(1, count(log, "acquire C"))
    local fresh = Effect.provide(Effect.provide(KC, LC, { fresh = true }), LC)
    Effect.runSync(fresh)
    assert.are.equal(3, count(log, "acquire C"))
  end)
end)

describe("Layer.mergeAll", function()
  it("builds its members at the same time, and releases them at the same time", function()
    local log = {}
    local scheduler = TestScheduler.new()
    local started
    local graph = Layer.mergeAll(
      resource(KA, "A", log, { acquireMs = 100, releaseMs = 50 }),
      resource(KB, "B", log, { acquireMs = 100, releaseMs = 50 })
    )
    local program = Effect.provide(
      Effect.sync(function()
        started = scheduler:now()
      end),
      graph
    )
    h.valueOf(scheduler:run(program))
    assert.are.equal(100, started)
    assert.are.equal(150, scheduler:now())
    assert.are.equal(1, count(log, "release A"))
    assert.are.equal(1, count(log, "release B"))
  end)

  it("interrupts the other members when one fails, and releases them first", function()
    local log = {}
    local slow = Layer.effect(
      KA,
      Effect.acquireRelease(logged(log, "acquire A"):as("a"), function()
        return logged(log, "release A")
      end):flatMap(function(a)
        return Effect.sleep(100):as(a)
      end)
    )
    local failing = Layer.effect(
      KB,
      Effect.sleep(10):flatMap(function()
        return Effect.fail("no B")
      end)
    )
    local program = Effect.provide(Effect.void, Layer.mergeAll(slow, failing)):onExit(function()
      return logged(log, "provide ended")
    end)
    local scheduler = TestScheduler.new()
    local cause = h.causeOf(scheduler:run(program))
    assert.is_true(Cause.hasFails(cause))
    assert.are.equal("no B", select(2, Cause.findError(cause)))
    assert.are.same({ "acquire A", "release A", "provide ended" }, log)
    assert.are.equal(10, scheduler:now())
  end)

  it("lets the later layer win where two have a key", function()
    local graph = Layer.mergeAll(Layer.succeed(K, 1), Layer.succeed(K, 2))
    assert.are.equal(2, Effect.runSync(Effect.provide(K, graph)))
    assert.are.equal(
      3,
      Effect.runSync(Effect.provide(K, Layer.merge(Layer.succeed(K, 1), Layer.succeed(K, 3))))
    )
    local listed = Layer.merge(Layer.succeed(KA, 1), { Layer.succeed(KB, 2), Layer.succeed(KA, 4) })
    assert.are.same({ 4, 2, n = 2 }, Effect.runSync(Effect.provide(Effect.all({ KA, KB }), listed)))
  end)
end)

describe("Layer.provide", function()
  it("builds self with that's services, gives only self's, and releases self first", function()
    local log = {}
    local LThat = resource(KB, "that", log)
    local LSelf = resource(KA, "self", log, { needs = KB })
    local program = Effect.all({ KA, probe(KB) })
    local result = Effect.runSync(Effect.provide(program, LSelf:provide(LThat)))
    assert.are.equal("that", result[1].dep.name)
    assert.is_nil(result[2])
    assert.are.same({ "acquire that", "acquire self", "release self", "release that" }, log)
  end)

  it("merges a list given as that", function()
    local LSelf = Layer.effect(
      K,
      Effect.all({ KA, KB }):map(function(list)
        return list[1] + list[2]
      end)
    )
    local graph = Layer.provide(LSelf, { Layer.succeed(KA, 1), Layer.succeed(KB, 2) })
    assert.are.equal(3, Effect.runSync(Effect.provide(K, graph)))
  end)

  it("gives both layers' services with provideMerge, self's winning", function()
    local that = Layer.mergeAll(Layer.succeed(K, "that"), Layer.succeed(KB, "b"))
    local graph = Layer.succeed(K, "self"):provideMerge(that)
    assert.are.same(
      { "self", "b", n = 2 },
      Effect.runSync(Effect.provide(Effect.all({ K, KB }), graph))
    )
  end)
end)

describe("a layer's build", function()
  it("sees the services of the fiber that provides it", function()
    local L = Layer.effect(
      K,
      KA:map(function(a)
        return "built with " .. a
      end)
    )
    local program = Effect.provideService(Effect.provide(K, L), KA, "outer")
    assert.are.equal("built with outer", Effect.runSync(program))
  end)
end)

describe("Layer combinators", function()
  it("flatMap builds the second layer from the first one's context", function()
    local L = Layer.succeed(KA, 5):flatMap(function(context)
      return Layer.succeed(K, Context.get(context, KA) * 2)
    end)
    assert.are.equal(10, Effect.runSync(Effect.provide(K, L)))
  end)

  it("orDie turns a build failure into a defect", function()
    local L = Layer.effect(K, Effect.fail("boom")):orDie()
    local cause = h.causeOf(Effect.runSyncExit(Effect.provide(Effect.void, L)))
    assert.are.same({ "Die" }, h.tags(cause))
    assert.are.equal("boom", cause.reasons[1].defect)
  end)

  it("catchAll builds the fallback layer, and catchCause gets the cause", function()
    local failing = Layer.effect(K, Effect.fail("boom"))
    local recovered = failing:catchAll(function(err)
      return Layer.succeed(K, "fallback after " .. err)
    end)
    assert.are.equal("fallback after boom", Effect.runSync(Effect.provide(K, recovered)))
    local withCause = failing:catchCause(function(cause)
      return Layer.succeed(K, h.tags(cause))
    end)
    assert.are.same({ "Fail" }, Effect.runSync(Effect.provide(K, withCause)))
  end)

  it("dies when a combinator's function returns something other than a layer", function()
    local L = Layer.succeed(KA, 1):flatMap(function()
      ---@diagnostic disable-next-line: return-type-mismatch
      return "nope"
    end)
    local cause = h.causeOf(Effect.runSyncExit(Effect.provide(Effect.void, L)))
    assert.is_truthy(cause.reasons[1].defect:find("expected a Layer", 1, true))
  end)
end)

describe("Layer.build", function()
  it("builds into the current scope, which releases the services when it closes", function()
    local log = {}
    local L = resource(K, "r", log)
    local program = Effect.scoped(Layer.build(L):flatMap(function(context)
      return logged(log, "built " .. Context.get(context, K).name)
    end))
    Effect.runSync(program)
    assert.are.same({ "acquire r", "built r", "release r" }, log)
  end)

  it("dies outside a scope, with Effect.scope's message", function()
    local cause = h.causeOf(Effect.runSyncExit(Layer.build(Layer.empty)))
    assert.are.equal(
      "Effect.scope: no Scope in context; wrap the effect in Effect.scoped",
      cause.reasons[1].defect
    )
  end)

  it("puts the MemoMap in the built context", function()
    local memoMap = Layer.makeMemoMapUnsafe()
    local program = Effect.scopedWith(function(scope)
      return Layer.buildWithMemoMap(Layer.empty, memoMap, scope)
    end)
    local context = Effect.runSync(program)
    assert.are.equal(memoMap, Context.get(context, Layer.CurrentMemoMap))
    assert.is_true(Effect.runSync(Layer.makeMemoMap) ~= memoMap)
  end)
end)

describe("Layer.launch", function()
  it("holds the layer until it is interrupted, then releases it", function()
    local scheduler = TestScheduler.new()
    local log = {}
    local fiber = h.started(scheduler, Layer.launch(resource(K, "server", log)))
    scheduler:advance(1000)
    assert.is_nil(fiber:poll())
    assert.are.same({ "acquire server" }, log)
    fiber:interruptUnsafe()
    scheduler:runAll()
    h.assertInterrupted(fiber:poll())
    assert.are.same({ "acquire server", "release server" }, log)
  end)
end)

describe("Layer.isLayer", function()
  it("tells layers from effects, contexts, keys and plain tables", function()
    assert.is_true(Layer.isLayer(Layer.empty))
    assert.is_true(Layer.isLayer(Layer.succeed(K, 1)))
    assert.is_false(Layer.isLayer(Effect.void))
    assert.is_false(Layer.isLayer(Context.empty()))
    assert.is_false(Layer.isLayer(K))
    assert.is_false(Layer.isLayer({ build = function() end }))
    assert.is_false(Context.isContext(Layer.empty))
    assert.is_false(Context.isKey(Layer.empty))
  end)

  it("has the combinators as methods", function()
    local L = Layer.succeed(KA, 1)
      :merge(Layer.succeed(KB, 2))
      :provideMerge(Layer.empty)
      :provide(Layer.empty)
      :fresh()
    assert.are.same({ 1, 2, n = 2 }, Effect.runSync(Effect.provide(Effect.all({ KA, KB }), L)))
  end)
end)
