-- PubSub (specifications/38-pubsub.md §38): a hub that broadcasts each
-- message to every subscriber.

local leffect = require("leffect")
local Cause = leffect.Cause
local Effect = leffect.Effect
local Exit = leffect.Exit
local PubSub = leffect.PubSub
local Scope = leffect.Scope
local TestScheduler = require("leffect.scheduler.test")
local h = require("spec.helpers")

local run = Effect.runSync

local function list(...)
  return { n = select("#", ...), ... }
end

describe("PubSub", function()
  local scheduler
  before_each(function()
    scheduler = TestScheduler.new()
  end)

  local function started(effect)
    return h.started(scheduler, effect)
  end

  -- A subscription to `hub` in a fresh scope, which the caller closes.
  local function subscribe(hub)
    local scope = Scope.makeUnsafe()
    local sub = run(Scope.provide(hub:subscribe(), scope))
    return sub, scope
  end

  it("gives every message to two subscribers, in order", function()
    local hub = run(PubSub.unbounded())
    local a, b = subscribe(hub), subscribe(hub)
    run(hub:publishAll(list(1, 2, 3)))
    assert.are.same(list(1, 2, 3), run(a:takeAll()))
    assert.are.same({ 1, 2, 3 }, { run(b:take()), run(b:take()), run(b:take()) })
  end)

  it("doesn't deliver a message published before a subscription", function()
    local hub = run(PubSub.bounded(4))
    assert.is_true(run(hub:publish("early")))
    assert.are.equal(0, run(hub:size()))
    local sub = subscribe(hub)
    assert.are.equal(0, run(sub:remaining()))
    run(hub:publish("late"))
    assert.are.equal("late", run(sub:take()))
  end)

  it("take waits; takeAll takes at least one; takeUpTo never waits; remaining counts", function()
    local hub = run(PubSub.unbounded())
    local sub = subscribe(hub)
    local taker = started(sub:take())
    assert.is_nil(taker.exit)
    assert.are.same({ n = 0 }, run(sub:takeUpTo(5)))
    hub:publishUnsafe("a")
    scheduler:flush()
    assert.are.equal("a", h.valueOf(taker.exit))
    local all = started(sub:takeAll())
    assert.is_nil(all.exit)
    run(hub:publishAll(list("b", "c", "d")))
    scheduler:flush()
    assert.are.same(list("b", "c", "d"), h.valueOf(all.exit))
    run(hub:publishAll(list(1, 2, 3)))
    assert.are.equal(3, run(sub:remaining()))
    assert.are.same(list(1, 2), run(sub:takeUpTo(2)))
    assert.are.equal(1, run(sub:remaining()))
  end)

  it("passes nil messages through", function()
    local hub = run(PubSub.unbounded())
    local sub = subscribe(hub)
    run(hub:publish(nil))
    run(hub:publish(2))
    local all = run(sub:takeAll())
    assert.are.equal(2, all.n)
    assert.is_nil(all[1])
    assert.are.equal(2, all[2])
  end)

  describe("bounded", function()
    it(
      "a publish waits while the slowest subscriber is full, and waiting ones go in order",
      function()
        local hub = run(PubSub.bounded(1))
        local fast, slow = subscribe(hub), subscribe(hub)
        run(hub:publish(1))
        assert.are.equal(1, run(fast:take()))
        local p2 = started(hub:publish(2))
        local p3 = started(hub:publish(3))
        assert.is_nil(p2.exit)
        assert.is_true(run(hub:isFull()))
        assert.are.equal(1, run(slow:take()))
        scheduler:flush()
        assert.is_true(h.valueOf(p2.exit))
        assert.is_nil(p3.exit)
        assert.are.equal(2, run(fast:take()))
        assert.are.equal(2, run(slow:take()))
        scheduler:flush()
        assert.is_true(h.valueOf(p3.exit))
        assert.are.equal(3, run(slow:take()))
      end
    )

    it("an interrupted publish withdraws what wasn't accepted", function()
      local hub = run(PubSub.bounded(2))
      local sub = subscribe(hub)
      local p = started(hub:publishAll(list(1, 2, 3, 4)))
      assert.are.equal(1, run(sub:take()))
      p:interruptUnsafe()
      scheduler:flush()
      h.assertInterrupted(p.exit)
      assert.are.same(list(2, 3), run(sub:takeAll()))
      assert.are.equal(0, run(sub:remaining()))
    end)

    it("keeps an accepted publish accepted when its sender is interrupted (decision 54)", function()
      local hub = run(PubSub.bounded(1))
      local sub = subscribe(hub)
      run(hub:publish(1))
      local p = started(hub:publish(2))
      -- One step: the subscriber takes, which accepts the waiting message,
      -- then the publisher is interrupted before its wakeup runs.
      assert.are.equal(1, run(sub:take()))
      p:interruptUnsafe()
      scheduler:flush()
      h.assertInterrupted(p.exit)
      assert.are.same(list(2), run(sub:takeUpTo(10)))
      assert.are.same({ n = 0 }, run(sub:takeUpTo(10)))
    end)
  end)

  it("dropping: a publish to a full hub succeeds with false, and nobody gets it", function()
    local hub = run(PubSub.dropping(1))
    local sub = subscribe(hub)
    assert.is_true(run(hub:publish(1)))
    assert.is_false(run(hub:publish(2)))
    assert.is_false(run(hub:publishAll(list(3))))
    assert.are.same(list(1), run(sub:takeUpTo(10)))
  end)

  it("sliding: a publish to a full hub drops the oldest held message", function()
    local hub = run(PubSub.sliding(2))
    local a, b = subscribe(hub), subscribe(hub)
    run(hub:publishAll(list(1, 2)))
    assert.are.equal(1, run(a:take()))
    assert.is_true(run(hub:publish(3)))
    assert.are.same(list(2, 3), run(a:takeAll()))
    assert.are.same(list(2, 3), run(b:takeAll()))
  end)

  it("unbounded: never full", function()
    local hub = run(PubSub.unbounded())
    subscribe(hub)
    for i = 1, 1000 do
      assert.is_true(run(hub:publish(i)))
    end
    assert.are.equal(1000, hub:sizeUnsafe())
    assert.is_false(run(hub:isFull()))
    assert.are.equal(math.huge, hub:capacity())
  end)

  describe("closing a subscription's scope", function()
    it("lets a waiting publisher in", function()
      local hub = run(PubSub.bounded(1))
      local _, slowScope = subscribe(hub)
      local fast = subscribe(hub)
      run(hub:publish(1))
      run(fast:take())
      local p = started(hub:publish(2))
      assert.is_nil(p.exit)
      run(Scope.close(slowScope, Exit.void))
      scheduler:flush()
      assert.is_true(h.valueOf(p.exit))
      assert.are.equal(2, run(fast:take()))
    end)

    it(
      "ends waiting takes with an interrupt from the closing fiber, and later takes interrupt",
      function()
        local hub = run(PubSub.unbounded())
        local sub, scope = subscribe(hub)
        local taker = started(sub:take())
        local closer = scheduler:fork(Scope.close(scope, Exit.void))
        scheduler:flush()
        local cause = h.causeOf(taker.exit)
        assert.is_true(Cause.hasInterruptsOnly(cause))
        assert.are.same({ closer.id }, Cause.interruptors(cause))
        h.assertInterrupted(Effect.runSyncExit(sub:take()))
        h.assertInterrupted(Effect.runSyncExit(sub:remaining()))
        h.assertInterrupted(Effect.runSyncExit(sub:takeUpTo(1)))
      end
    )
  end)

  it("lets two fibers share one subscription, each message to one of them", function()
    local hub = run(PubSub.unbounded())
    local sub = subscribe(hub)
    local a, b = started(sub:take()), started(sub:take())
    run(hub:publishAll(list(1, 2)))
    scheduler:flush()
    assert.are.same({ 1, 2 }, { h.valueOf(a.exit), h.valueOf(b.exit) })
  end)

  it("doesn't let a new take overtake a fiber waiting on the same subscription", function()
    local hub = run(PubSub.unbounded())
    local sub = subscribe(hub)
    local waiting = started(sub:take())
    -- In one step, a publish wakes `waiting`, then the same fiber takes.
    local late = scheduler:fork(hub:publish("m"):flatMap(function()
      return sub:take()
    end))
    scheduler:flush()
    assert.are.equal("m", h.valueOf(waiting.exit))
    assert.is_nil(late.exit)
  end)

  it("passes the turn of a woken taker interrupted before it runs (invariant 24)", function()
    local hub = run(PubSub.unbounded())
    local sub = subscribe(hub)
    local a, b = started(sub:take()), started(sub:take())
    -- One step: the publish wakes a, then a is interrupted before it runs.
    assert.is_true(hub:publishUnsafe("m"))
    a:interruptUnsafe()
    scheduler:flush()
    h.assertInterrupted(a.exit)
    assert.are.equal("m", h.valueOf(b.exit))
  end)

  it("publishUnsafe never runs fiber code: the taker waits for the next flush", function()
    local hub = run(PubSub.unbounded())
    local sub = subscribe(hub)
    local log, record = h.recorder()
    started(sub:take():flatMap(record))
    hub:publishUnsafe("m")
    assert.are.same({}, log)
    scheduler:flush()
    assert.are.same({ "m" }, log)
  end)

  it("subscribe without a scope dies with Effect.scope's message", function()
    local hub = run(PubSub.unbounded())
    local expected = h.causeOf(Effect.runSyncExit(Effect.scope)).reasons[1].defect
    local cause = h.causeOf(Effect.runSyncExit(hub:subscribe()))
    assert.are.equal(expected, cause.reasons[1].defect)
  end)

  it("subscribe in Effect.scoped lasts until the scope closes", function()
    local hub = run(PubSub.bounded(16))
    local got = run(Effect.scoped(Effect.gen(function(go)
      local sub = go(hub:subscribe())
      go(hub:publish("hello"))
      return go(sub:take())
    end)))
    assert.are.equal("hello", got)
    assert.are.equal(0, hub.subscriberCount)
  end)

  describe("finish", function()
    it("later publishes and waiting ones succeed with false", function()
      local hub = run(PubSub.bounded(1))
      subscribe(hub)
      run(hub:publish(1))
      local p = started(hub:publish(2))
      assert.is_true(run(hub:finish("end")))
      scheduler:flush()
      assert.is_false(h.valueOf(p.exit))
      assert.is_false(run(hub:publish(3)))
      assert.is_false(hub:publishUnsafe(3))
    end)

    it("subscribers get their held messages, then the final one on every take", function()
      local hub = run(PubSub.unbounded())
      local sub = subscribe(hub)
      local waiting = subscribe(hub)
      local taker = started(waiting:take())
      run(hub:publish(1))
      scheduler:flush()
      assert.are.equal(1, h.valueOf(taker.exit))
      local second = started(waiting:take())
      hub:finishUnsafe("end")
      scheduler:flush()
      assert.are.equal("end", h.valueOf(second.exit))
      assert.are.equal(1, run(sub:take()))
      assert.are.equal("end", run(sub:take()))
      assert.are.equal("end", run(sub:take()))
      assert.are.same(list("end"), run(sub:takeAll()))
    end)

    it("a later subscriber gets the final message; takeUpTo never returns it", function()
      local hub = run(PubSub.unbounded())
      run(hub:finish("end"))
      local sub = subscribe(hub)
      assert.are.same({ n = 0 }, run(sub:takeUpTo(5)))
      assert.are.equal("end", run(sub:take()))
    end)

    it("a second finish succeeds with false", function()
      local hub = run(PubSub.unbounded())
      assert.is_true(run(hub:finish(1)))
      assert.is_false(run(hub:finish(2)))
      assert.is_false(hub:finishUnsafe(3))
    end)
  end)

  describe("shutdown", function()
    it("interrupts waiting takes and publishes", function()
      local hub = run(PubSub.bounded(1))
      local sub = subscribe(hub)
      local other = subscribe(hub)
      run(hub:publish(1))
      run(sub:take())
      local taker = started(sub:take())
      local p = started(hub:publish(2))
      local shutter = scheduler:fork(hub:shutdown())
      scheduler:flush()
      h.valueOf(shutter.exit)
      assert.are.same({ shutter.id }, Cause.interruptors(h.causeOf(taker.exit)))
      h.assertInterrupted(p.exit)
      h.assertInterrupted(Effect.runSyncExit(other:take()))
    end)

    it("later publishes fail, later takes interrupt, awaitShutdown continues, size is 0", function()
      local hub = run(PubSub.unbounded())
      local sub = subscribe(hub)
      run(hub:publish(1))
      local awaiter = started(hub:awaitShutdown())
      assert.is_false(run(hub:isShutdown()))
      run(hub:shutdown())
      scheduler:flush()
      h.valueOf(awaiter.exit)
      assert.is_true(run(hub:isShutdown()))
      assert.is_true(hub:isShutdownUnsafe())
      assert.is_false(run(hub:publish(2)))
      assert.are.equal(0, run(hub:size()))
      assert.is_true(run(hub:isEmpty()))
      h.assertInterrupted(Effect.runSyncExit(sub:take()))
      local late = subscribe(hub)
      h.assertInterrupted(Effect.runSyncExit(late:take()))
      h.valueOf(Effect.runSyncExit(hub:awaitShutdown()))
    end)

    it("a second shutdown does nothing", function()
      local hub = run(PubSub.unbounded())
      run(hub:shutdown())
      h.valueOf(Effect.runSyncExit(hub:shutdown()))
    end)
  end)

  describe("takeBetween", function()
    it("waits for the minimum, and takes up to the maximum", function()
      local hub = run(PubSub.unbounded())
      local sub = subscribe(hub)
      local taker = started(sub:takeBetween(2, 3))
      hub:publishUnsafe(1)
      scheduler:flush()
      assert.is_nil(taker.exit)
      run(hub:publishAll(list(2, 3, 4)))
      scheduler:flush()
      assert.are.same(list(1, 2), h.valueOf(taker.exit))
      assert.are.same(list(3, 4), run(sub:takeBetween(1, 5)))
    end)
  end)

  describe("replay", function()
    it("gives a later subscriber the last k messages first, even unheard ones", function()
      local hub = run(PubSub.unbounded({ replay = 2 }))
      run(hub:publishAll(list(1, 2, 3)))
      local sub = subscribe(hub)
      assert.are.equal(2, run(sub:remaining()))
      run(hub:publish(4))
      assert.are.equal(2, run(sub:take()))
      assert.are.same(list(3, 4), run(sub:takeAll()))
      local later = subscribe(hub)
      assert.are.same(list(3), run(later:takeUpTo(1)))
      assert.are.same(list(4), run(later:takeUpTo(5)))
    end)

    it("doesn't count replayed messages against capacity", function()
      local hub = run(PubSub.bounded({ capacity = 1, replay = 3 }))
      run(hub:publishAll(list(1, 2, 3)))
      local sub = subscribe(hub)
      assert.is_true(run(hub:publish(4)))
      local waiting = started(hub:publish(5))
      assert.is_nil(waiting.exit)
      assert.are.same(
        { 1, 2, 3, 4 },
        { run(sub:take()), run(sub:take()), run(sub:take()), run(sub:take()) }
      )
      scheduler:flush()
      assert.is_true(h.valueOf(waiting.exit))
    end)

    it("adds a live message a sliding hub drops to the end of the replay", function()
      local hub = run(PubSub.sliding({ capacity = 1, replay = 2 }))
      run(hub:publishAll(list(1, 2)))
      local sub = subscribe(hub)
      run(hub:publish(3))
      run(hub:publish(4))
      assert.are.same(list(2, 3, 4), run(sub:takeAll()))
    end)

    it("raises on a bad replay size", function()
      assert.has_error(function()
        PubSub.unbounded({ replay = -1 })
      end)
      assert.has_error(function()
        PubSub.bounded({ capacity = 2, replay = 1.5 })
      end)
    end)
  end)

  it("has every function as a method", function()
    local hub = run(PubSub.unbounded())
    for _, name in ipairs({
      "publish",
      "publishAll",
      "publishUnsafe",
      "capacity",
      "size",
      "sizeUnsafe",
      "isFull",
      "isEmpty",
      "subscribe",
      "finish",
      "finishUnsafe",
      "shutdown",
      "isShutdown",
      "isShutdownUnsafe",
      "awaitShutdown",
    }) do
      assert.are.equal(PubSub[name], hub[name], name)
    end
    local sub = subscribe(hub)
    for _, name in ipairs({ "take", "takeAll", "takeUpTo", "takeBetween", "remaining" }) do
      assert.are.equal(PubSub[name], sub[name], name)
    end
    assert.is_true(PubSub.isPubSub(hub))
    assert.is_true(PubSub.isSubscription(sub))
    assert.is_false(PubSub.isPubSub(sub))
  end)

  it("raises on a non-PubSub or a bad capacity", function()
    ---@diagnostic disable-next-line: missing-fields
    local ok, err = pcall(PubSub.publish, {}, 1)
    assert.is_false(ok)
    ---@diagnostic disable-next-line: param-type-mismatch
    assert.matches("PubSub.publish: expected a PubSub", err)
    for _, bad in ipairs({ 0, -1, 1.5, 0 / 0, "2" }) do
      assert.has_error(function()
        PubSub.bounded(bad)
      end)
      assert.has_error(function()
        PubSub.sliding(bad)
      end)
    end
  end)
end)
