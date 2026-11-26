--- PubSub: a hub that broadcasts each message to every subscriber
--- (specifications/38-pubsub.md §38, 4.1.5's `PubSub` module).
---
--- ```lua
--- local program = Effect.scoped(Effect.gen(function(run)
---   local hub = run(PubSub.bounded(16))
---   local sub = run(hub:subscribe())
---   run(hub:publish("hello"))
---   return run(sub:take())
--- end))
--- ```
---
--- The hub holds a message until every subscriber that was subscribed when it
--- was published has taken it. Each subscription has its own line of waiting
--- takers, which keep their place until they take (specifications/
--- 33-primitives.md §33.2). Waiting publishes are accepted in order when room
--- frees.

local Cause = require("leffect.cause")
local Effect = require("leffect.effect")
local Latch = require("leffect.latch")
local Scope = require("leffect.scope")
local Waitlist = require("leffect.waitlist")
local core = require("leffect.core")
local runtime = require("leffect.runtime")

local error, floor, getmetatable, huge, max, min, setmetatable, type =
  error, math.floor, getmetatable, math.huge, math.max, math.min, setmetatable, type

local describe = runtime.describe
local exitSucceed, exitFailCause, exitVoid = core.exitSucceed, core.exitFailCause, core.exitVoid
local EXIT_TRUE, EXIT_FALSE = exitSucceed(true), exitSucceed(false)

---A hub of messages.
---@class leffect.PubSub
---@field maxSize number The capacity: a positive integer, or math.huge.
---@field policy "suspend"|"dropping"|"sliding"
---@field values table Held messages, by publish index.
---@field counts table<integer, integer> Subscribers still to take each held message.
---@field publisherIndex integer The index of the next message.
---@field subscribersIndex integer The index of the oldest held message.
---@field subscriberCount integer
---@field subscriptions leffect.Waitlist The live subscriptions, in order.
---@field publishers leffect.Waitlist Waiting publishes.
---@field hubScope leffect.Scope Every subscription's scope is a child of it.
---@field shutdownHook leffect.Latch
---@field down boolean Set by `shutdown`.
---@field ended boolean Set by `finish`.
---@field final any The message `finish` published.
---@field publish fun(self: leffect.PubSub, message: any): leffect.Effect
---@field publishAll fun(self: leffect.PubSub, messages: table): leffect.Effect
---@field publishUnsafe fun(self: leffect.PubSub, message: any): boolean
---@field capacity fun(self: leffect.PubSub): number
---@field size fun(self: leffect.PubSub): leffect.Effect
---@field sizeUnsafe fun(self: leffect.PubSub): integer
---@field isFull fun(self: leffect.PubSub): leffect.Effect
---@field isEmpty fun(self: leffect.PubSub): leffect.Effect
---@field subscribe fun(self: leffect.PubSub): leffect.Effect
---@field finish fun(self: leffect.PubSub, message: any): leffect.Effect
---@field finishUnsafe fun(self: leffect.PubSub, message: any): boolean
---@field shutdown fun(self: leffect.PubSub): leffect.Effect
---@field isShutdown fun(self: leffect.PubSub): leffect.Effect
---@field isShutdownUnsafe fun(self: leffect.PubSub): boolean
---@field awaitShutdown fun(self: leffect.PubSub): leffect.Effect

---A subscriber's view of a hub.
---@class leffect.PubSub.Subscription
---@field hub leffect.PubSub
---@field index integer The index of the next message for this subscription.
---@field unsubscribed boolean It no longer holds messages.
---@field closed boolean Its scope closed: takes interrupt.
---@field takers leffect.Waitlist
---@field take fun(self: leffect.PubSub.Subscription): leffect.Effect
---@field takeAll fun(self: leffect.PubSub.Subscription): leffect.Effect
---@field takeUpTo fun(self: leffect.PubSub.Subscription, max: number): leffect.Effect
---@field takeBetween fun(self: leffect.PubSub.Subscription, min: number, max: number): leffect.Effect
---@field remaining fun(self: leffect.PubSub.Subscription): leffect.Effect

---A waiting publish: what is left of its list.
---@class leffect.PubSub.Publisher
---@field list table
---@field offset integer
---@field total integer
---@field resume fun(effect: leffect.Effect)

local hubMethods = {}
local subMethods = {}

local PubSubMT = { __index = hubMethods, __name = "leffect.PubSub" }
local SubscriptionMT = { __index = subMethods, __name = "leffect.PubSub.Subscription" }

local PubSub = {}

---@param value any
---@param name string
local function checkHub(value, name)
  if getmetatable(value) ~= PubSubMT then
    error(name .. ": expected a PubSub, got " .. describe(value), 3)
  end
end

---@param value any
---@param name string
local function checkSubscription(value, name)
  if getmetatable(value) ~= SubscriptionMT then
    error(name .. ": expected a Subscription, got " .. describe(value), 3)
  end
end

---@param value any
---@param name string
local function checkList(value, name)
  if type(value) ~= "table" then
    error(name .. ": expected a list, got " .. describe(value), 3)
  end
end

--- v4's `Count.normalize`.
---@param n any
---@return number
local function normalize(n)
  if type(n) ~= "number" or n ~= n or n <= 0 then
    return 0
  end
  return floor(n)
end

-- The buffer (§38.5) ---------------------------------------------------------

---@param hub leffect.PubSub
---@return boolean
local function isFullUnsafe(hub)
  return hub.publisherIndex - hub.subscribersIndex >= hub.maxSize
end

--- Frees the held message at `index` once no subscriber needs it.
---@param hub leffect.PubSub
---@param index integer
local function release(hub, index)
  local left = hub.counts[index] - 1
  if left == 0 then
    hub.values[index], hub.counts[index] = nil, nil
    hub.subscribersIndex = hub.subscribersIndex + 1
  else
    hub.counts[index] = left
  end
end

--- Publishes one message if the hub isn't full. With no subscribers, the
--- message is accepted but not held.
---@param hub leffect.PubSub
---@param message any
---@return boolean
local function offer(hub, message)
  if isFullUnsafe(hub) then
    return false
  end
  if hub.subscriberCount ~= 0 then
    local index = hub.publisherIndex
    hub.values[index], hub.counts[index] = message, hub.subscriberCount
    hub.publisherIndex = index + 1
  end
  return true
end

--- Drops the oldest held message, for every subscriber that hasn't taken it.
---@param hub leffect.PubSub
local function slide(hub)
  local index = hub.subscribersIndex
  if index ~= hub.publisherIndex then
    hub.values[index], hub.counts[index] = nil, nil
    hub.subscribersIndex = index + 1
  end
end

---@param sub leffect.PubSub.Subscription
---@return integer
local function heldFor(sub)
  if sub.unsubscribed then
    return 0
  end
  local hub = sub.hub
  return hub.publisherIndex - max(sub.index, hub.subscribersIndex)
end

--- Takes the subscription's next held message. Returns false if there is
--- none, and true and the message otherwise.
---@param sub leffect.PubSub.Subscription
---@return boolean
---@return any
local function poll(sub)
  if sub.unsubscribed then
    return false
  end
  local hub = sub.hub
  local index = max(sub.index, hub.subscribersIndex)
  if index == hub.publisherIndex then
    sub.index = index
    return false
  end
  local message = hub.values[index]
  release(hub, index)
  sub.index = index + 1
  return true, message
end

--- Takes up to `n` of the subscription's held messages, as a list with `n`.
---@param sub leffect.PubSub.Subscription
---@param n number
---@return table
local function pollUpTo(sub, n)
  local list, k = { n = 0 }, 0
  while k < n do
    local ok, message = poll(sub)
    if not ok then
      break
    end
    k = k + 1
    list[k] = message
  end
  list.n = k
  return list
end

--- The subscription stops holding messages.
---@param sub leffect.PubSub.Subscription
local function unsubscribeUnsafe(sub)
  if sub.unsubscribed then
    return
  end
  sub.unsubscribed = true
  local hub = sub.hub
  hub.subscriberCount = hub.subscriberCount - 1
  local index = max(sub.index, hub.subscribersIndex)
  while index < hub.publisherIndex do
    release(hub, index)
    index = index + 1
  end
  sub.index = index
end

-- Waking --------------------------------------------------------------------

---@param node { resume: fun(effect: leffect.Effect)? }
---@param effect leffect.Effect
local function wakeNode(node, effect)
  local resume = node.resume
  if resume then
    node.resume = nil
    resume(effect)
  end
end

--- The wake pass for one subscription's takers: budgets its held messages
--- over the line, in order. After `finish`, every taker can proceed.
---@param sub leffect.PubSub.Subscription
local function wakeTakers(sub)
  local takers = sub.takers
  if takers.size == 0 then
    return
  end
  local node = takers.head
  if sub.hub.ended then
    while node do
      wakeNode(node, exitVoid)
      node = node._next
    end
    return
  end
  local left = heldFor(sub)
  while node and left > 0 do
    left = left - min(node.max, left)
    wakeNode(node, exitVoid)
    node = node._next
  end
end

---@param hub leffect.PubSub
local function wakeSubscribers(hub)
  local sub = hub.subscriptions.head
  while sub do
    local nextSub = sub._next
    wakeTakers(sub)
    sub = nextSub
  end
end

--- Accepts waiting publishes, in order, while the hub has room (v4's
--- `onPubSubEmptySpaceUnsafe`).
---@param hub leffect.PubSub
local function acceptPublishers(hub)
  if hub.down then
    return -- shutdown interrupts the waiting publishers instead
  end
  local publishers = hub.publishers
  local accepted = false
  while publishers.size > 0 and not isFullUnsafe(hub) do
    local entry = publishers.head --[[@as leffect.PubSub.Publisher]]
    entry.offset = entry.offset + 1
    offer(hub, entry.list[entry.offset])
    accepted = true
    if entry.offset == entry.total then
      Waitlist.remove(publishers, entry)
      entry.resume(EXIT_TRUE)
    end
  end
  if accepted then
    wakeSubscribers(hub)
  end
end

-- Making --------------------------------------------------------------------

---@param capacity any
---@param name string
local function checkCapacity(capacity, name)
  if
    type(capacity) ~= "number"
    or capacity <= 0
    or (capacity ~= huge and floor(capacity) ~= capacity)
  then
    error(
      name .. ": the capacity must be a positive integer or math.huge, got " .. describe(capacity),
      3
    )
  end
end

---@param capacity number
---@param policy "suspend"|"dropping"|"sliding"
---@return leffect.PubSub
local function new(capacity, policy)
  return setmetatable({
    maxSize = capacity,
    policy = policy,
    values = {},
    counts = {},
    publisherIndex = 0,
    subscribersIndex = 0,
    subscriberCount = 0,
    subscriptions = Waitlist.new(),
    publishers = Waitlist.new(),
    hubScope = Scope.makeUnsafe(),
    shutdownHook = Latch.makeUnsafe(false),
    down = false,
    ended = false,
    final = nil,
  }, PubSubMT)
end

---@param capacity number
---@param policy "suspend"|"dropping"|"sliding"
---@return leffect.Effect
local function make(capacity, policy)
  return core.sync(function()
    return new(capacity, policy)
  end)
end

--- A hub that holds up to `capacity` messages. A publish to a full hub
--- waits.
---@param capacity integer
---@return leffect.Effect
function PubSub.bounded(capacity)
  checkCapacity(capacity, "PubSub.bounded")
  return make(capacity, "suspend")
end

--- A hub whose publishes to a full hub are dropped, and succeed with false.
---@param capacity integer
---@return leffect.Effect
function PubSub.dropping(capacity)
  checkCapacity(capacity, "PubSub.dropping")
  return make(capacity, "dropping")
end

--- A hub whose publishes to a full hub drop the oldest held message.
---@param capacity integer
---@return leffect.Effect
function PubSub.sliding(capacity)
  checkCapacity(capacity, "PubSub.sliding")
  return make(capacity, "sliding")
end

--- A hub that is never full.
---@return leffect.Effect
function PubSub.unbounded()
  return make(huge, "suspend")
end

---@param value any
---@return boolean
function PubSub.isPubSub(value)
  return getmetatable(value) == PubSubMT
end

---@param value any
---@return boolean
function PubSub.isSubscription(value)
  return getmetatable(value) == SubscriptionMT
end

-- Publishing ----------------------------------------------------------------

--- What a publish does with the messages that didn't fit (v4's
--- `handleSurplus`).
---@param hub leffect.PubSub
---@param surplus table A list with `n`.
---@return leffect.Effect
local function handleSurplus(hub, surplus)
  local policy = hub.policy
  if policy == "dropping" then
    return EXIT_FALSE
  elseif policy == "sliding" then
    for i = 1, surplus.n do
      local message = surplus[i]
      while not offer(hub, message) do
        slide(hub)
      end
    end
    wakeSubscribers(hub)
    return EXIT_TRUE
  end
  return core.async(function(resume)
    if hub.ended then
      resume(EXIT_FALSE)
      return nil
    end
    ---@type leffect.PubSub.Publisher
    local entry = { list = surplus, offset = 0, total = surplus.n, resume = resume }
    local publishers = hub.publishers
    Waitlist.push(publishers, entry)
    acceptPublishers(hub)
    if hub.down then
      Waitlist.remove(publishers, entry)
      resume(Effect.interrupt)
      return nil
    end
    -- An interrupted publish withdraws the messages not accepted yet.
    return function()
      Waitlist.remove(publishers, entry)
    end
  end)
end

--- Publishes at once if the hub isn't full, and returns whether it did.
--- Never waits, and never slides.
---@param hub leffect.PubSub
---@param message any
---@return boolean
function PubSub.publishUnsafe(hub, message)
  checkHub(hub, "PubSub.publishUnsafe")
  if hub.down or hub.ended then
    return false
  end
  if offer(hub, message) then
    wakeSubscribers(hub)
    return true
  end
  return false
end

--- Succeeds with true once the message is accepted. Succeeds with false if
--- the hub has finished or shut down, or if a dropping hub is full.
---@param hub leffect.PubSub
---@param message any
---@return leffect.Effect
function PubSub.publish(hub, message)
  checkHub(hub, "PubSub.publish")
  return core.suspend(function()
    if hub.down or hub.ended then
      return EXIT_FALSE
    end
    if offer(hub, message) then
      wakeSubscribers(hub)
      return EXIT_TRUE
    end
    return handleSurplus(hub, { message, n = 1 })
  end)
end

--- Publishes a list. Succeeds with false if any message was dropped.
---@param hub leffect.PubSub
---@param messages table
---@return leffect.Effect
function PubSub.publishAll(hub, messages)
  checkHub(hub, "PubSub.publishAll")
  checkList(messages, "PubSub.publishAll")
  return core.suspend(function()
    if hub.down or hub.ended then
      return EXIT_FALSE
    end
    local total = messages.n or #messages
    local surplus, k = { n = 0 }, 0
    if hub.subscriberCount ~= 0 then
      for i = 1, total do
        if k > 0 or not offer(hub, messages[i]) then
          k = k + 1
          surplus[k] = messages[i]
        end
      end
    end
    surplus.n = k
    wakeSubscribers(hub)
    if k == 0 then
      return EXIT_TRUE
    end
    return handleSurplus(hub, surplus)
  end)
end

-- Observing -----------------------------------------------------------------

--- The capacity: a number, not an effect.
---@param hub leffect.PubSub
---@return number
function PubSub.capacity(hub)
  checkHub(hub, "PubSub.capacity")
  return hub.maxSize
end

--- The number of messages the hub holds, which is 0 after shutdown.
---@param hub leffect.PubSub
---@return integer
function PubSub.sizeUnsafe(hub)
  checkHub(hub, "PubSub.sizeUnsafe")
  if hub.down then
    return 0
  end
  return hub.publisherIndex - hub.subscribersIndex
end

---@param hub leffect.PubSub
---@return leffect.Effect
function PubSub.size(hub)
  checkHub(hub, "PubSub.size")
  return core.sync(function()
    return PubSub.sizeUnsafe(hub)
  end)
end

--- Whether `size` equals the capacity.
---@param hub leffect.PubSub
---@return leffect.Effect
function PubSub.isFull(hub)
  checkHub(hub, "PubSub.isFull")
  return core.sync(function()
    return PubSub.sizeUnsafe(hub) == hub.maxSize
  end)
end

--- Whether `size` is 0.
---@param hub leffect.PubSub
---@return leffect.Effect
function PubSub.isEmpty(hub)
  checkHub(hub, "PubSub.isEmpty")
  return core.sync(function()
    return PubSub.sizeUnsafe(hub) == 0
  end)
end

-- Subscribing ---------------------------------------------------------------

--- Ends a subscription, on behalf of the fiber closing its scope: its
--- waiting takers end with an interrupt from that fiber, and it stops
--- holding messages, which can let waiting publishers in.
---@param sub leffect.PubSub.Subscription
---@return leffect.Effect
local function unsubscribe(sub)
  return core.withFiber(function(fiber)
    if sub.closed then
      return exitVoid
    end
    sub.closed = true
    local interrupted = exitFailCause(Cause.interrupt(fiber.id))
    local nodes = Waitlist.clear(sub.takers)
    for i = 1, #nodes do
      wakeNode(nodes[i], interrupted)
    end
    local hub = sub.hub
    Waitlist.remove(hub.subscriptions, sub)
    unsubscribeUnsafe(sub)
    acceptPublishers(hub)
    return exitVoid
  end)
end

--- Succeeds with a Subscription, which lasts until the current scope
--- closes. Without a scope, it dies with `Effect.scope`'s message. Its scope
--- is a child of the hub's, so `shutdown` ends it too.
---@param hub leffect.PubSub
---@return leffect.Effect
function PubSub.subscribe(hub)
  checkHub(hub, "PubSub.subscribe")
  return runtime.uninterruptible(core.flatMap(Effect.scope, function(localScope)
    local scope = Scope.forkUnsafe(hub.hubScope)
    hub.subscriberCount = hub.subscriberCount + 1
    ---@type leffect.PubSub.Subscription
    local sub = setmetatable({
      hub = hub,
      index = hub.publisherIndex,
      unsubscribed = false,
      closed = false,
      takers = Waitlist.new(),
    }, SubscriptionMT)
    Waitlist.push(hub.subscriptions, sub)
    return core.flatMap(Scope.addFinalizer(scope, unsubscribe(sub)), function()
      return core.map(
        Scope.addFinalizerExit(localScope, function(exit)
          return Scope.close(scope, exit)
        end),
        function()
          return sub
        end
      )
    end)
  end))
end

-- Taking --------------------------------------------------------------------

--- Takes with `attempt`, or waits in the subscription's line until it can.
--- A new take doesn't overtake a fiber already waiting on the subscription.
--- A waiter keeps its place until it takes, and an exit frame passes its
--- turn on if it leaves first (§33.2).
---@param sub leffect.PubSub.Subscription
---@param atMost number
---@param attempt fun(): leffect.Effect?
---@return leffect.Effect
local function takeOrWait(sub, atMost, attempt)
  return core.withFiber(function(fiber)
    local takers = sub.takers
    if takers.size == 0 then
      local result = attempt()
      if result then
        return result
      end
    end
    local node = { max = atMost }
    Waitlist.push(takers, node)
    runtime.onExitUnsafe(fiber, function()
      if Waitlist.remove(takers, node) then
        wakeTakers(sub)
      end
      return nil
    end)
    local wait = core.async(function(resume)
      if sub.closed then
        resume(exitVoid)
      else
        -- The wake pass decides, so the waiters ahead keep their messages.
        node.resume = resume
        wakeTakers(sub)
      end
    end)
    local loop
    loop = core.flatMap(wait, function()
      local result = attempt()
      if result then
        Waitlist.remove(takers, node)
        return result
      end
      return loop
    end)
    return loop
  end)
end

--- Takes the next message, waiting for one. After `finish`, every take past
--- the held messages gets the final message.
---@param sub leffect.PubSub.Subscription
---@return leffect.Effect
function PubSub.take(sub)
  checkSubscription(sub, "PubSub.take")
  return takeOrWait(sub, 1, function()
    if sub.closed then
      return Effect.interrupt
    end
    local ok, message = poll(sub)
    if ok then
      acceptPublishers(sub.hub)
      return exitSucceed(message)
    elseif sub.hub.ended then
      return exitSucceed(sub.hub.final)
    end
    return nil
  end)
end

--- Takes every message waiting for this subscription, and waits for at
--- least one.
---@param sub leffect.PubSub.Subscription
---@return leffect.Effect
function PubSub.takeAll(sub)
  checkSubscription(sub, "PubSub.takeAll")
  return takeOrWait(sub, huge, function()
    if sub.closed then
      return Effect.interrupt
    end
    local list = pollUpTo(sub, huge)
    if list.n > 0 then
      acceptPublishers(sub.hub)
      return exitSucceed(list)
    elseif sub.hub.ended then
      return exitSucceed({ sub.hub.final, n = 1 })
    end
    return nil
  end)
end

--- Takes up to `max` messages, without waiting. Never returns the final
--- message.
---@param sub leffect.PubSub.Subscription
---@param atMost number
---@return leffect.Effect
function PubSub.takeUpTo(sub, atMost)
  checkSubscription(sub, "PubSub.takeUpTo")
  return core.suspend(function()
    if sub.closed then
      return Effect.interrupt
    end
    local list = { n = 0 }
    if sub.takers.size == 0 then
      list = pollUpTo(sub, normalize(atMost))
    end
    acceptPublishers(sub.hub)
    return exitSucceed(list)
  end)
end

--- Waits for `min` messages, and takes up to `max` (v4's
--- `takeRemainderLoop`).
---@param sub leffect.PubSub.Subscription
---@param atLeast number
---@param atMost number
---@return leffect.Effect
function PubSub.takeBetween(sub, atLeast, atMost)
  checkSubscription(sub, "PubSub.takeBetween")
  local function loop(acc, lo, hi)
    if hi < lo then
      return exitSucceed(acc)
    end
    return core.flatMap(PubSub.takeUpTo(sub, hi), function(got)
      for i = 1, got.n do
        acc.n = acc.n + 1
        acc[acc.n] = got[i]
      end
      local missing = lo - got.n
      if missing < 1 then
        return exitSucceed(acc)
      end
      return core.flatMap(PubSub.take(sub), function(message)
        acc.n = acc.n + 1
        acc[acc.n] = message
        if missing == 1 then
          return exitSucceed(acc)
        end
        return loop(acc, missing - 1, hi - got.n - 1)
      end)
    end)
  end
  return core.suspend(function()
    return loop({ n = 0 }, normalize(atLeast), normalize(atMost))
  end)
end

--- The number of messages waiting for this subscription.
---@param sub leffect.PubSub.Subscription
---@return leffect.Effect
function PubSub.remaining(sub)
  checkSubscription(sub, "PubSub.remaining")
  return core.suspend(function()
    if sub.closed then
      return Effect.interrupt
    end
    return exitSucceed(heldFor(sub))
  end)
end

-- Ending --------------------------------------------------------------------

--- v4's `endUnsafe`: publishes a final message. Returns false if the hub had
--- already finished or shut down.
---@param hub leffect.PubSub
---@param message any
---@return boolean
function PubSub.finishUnsafe(hub, message)
  checkHub(hub, "PubSub.finishUnsafe")
  if hub.down or hub.ended then
    return false
  end
  hub.ended, hub.final = true, message
  local publishers = Waitlist.clear(hub.publishers)
  for i = 1, #publishers do
    publishers[i].resume(EXIT_FALSE)
  end
  wakeSubscribers(hub)
  return true
end

--- v4's `end`: publishes a final message. Succeeds with true, or with false
--- if the hub had already finished or shut down.
---@param hub leffect.PubSub
---@param message any
---@return leffect.Effect
function PubSub.finish(hub, message)
  checkHub(hub, "PubSub.finish")
  return core.sync(function()
    return PubSub.finishUnsafe(hub, message)
  end)
end

--- Shuts the hub down, uninterruptibly: ends every subscription, interrupts
--- the waiting publishers, and opens the shutdown latch. A second call does
--- nothing.
---@param hub leffect.PubSub
---@return leffect.Effect
function PubSub.shutdown(hub)
  checkHub(hub, "PubSub.shutdown")
  return runtime.uninterruptible(core.withFiber(function(fiber)
    hub.down = true
    if not Latch.openUnsafe(hub.shutdownHook) then
      return exitVoid
    end
    local closing = Scope.close(hub.hubScope, exitFailCause(Cause.interrupt(fiber.id)))
    return core.flatMap(closing, function()
      local interrupted = exitFailCause(Cause.interrupt(fiber.id))
      local publishers = Waitlist.clear(hub.publishers)
      for i = 1, #publishers do
        publishers[i].resume(interrupted)
      end
      return exitVoid
    end)
  end))
end

--- Whether the hub has shut down.
---@param hub leffect.PubSub
---@return boolean
function PubSub.isShutdownUnsafe(hub)
  checkHub(hub, "PubSub.isShutdownUnsafe")
  return hub.down
end

---@param hub leffect.PubSub
---@return leffect.Effect
function PubSub.isShutdown(hub)
  checkHub(hub, "PubSub.isShutdown")
  return core.sync(function()
    return hub.down
  end)
end

--- Waits until the hub shuts down.
---@param hub leffect.PubSub
---@return leffect.Effect
function PubSub.awaitShutdown(hub)
  checkHub(hub, "PubSub.awaitShutdown")
  return Latch.await(hub.shutdownHook)
end

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
  hubMethods[name] = PubSub[name]
end

for _, name in ipairs({ "take", "takeAll", "takeUpTo", "takeBetween", "remaining" }) do
  subMethods[name] = PubSub[name]
end

return PubSub
