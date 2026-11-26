--- Queue: passes messages from producers to consumers, each message to one
--- consumer (specifications/37-queue.md §37, 4.1.5's `Queue` module).
---
--- ```lua
--- local program = Effect.gen(function(run)
---   local queue = run(Queue.bounded(16))
---   run(queue:offer("hello"))
---   return run(queue:take())
--- end)
--- ```
---
--- A queue is Open, then Closing once it ends with messages left, then
--- Done. Waiting takers keep their place in line until they take, and a
--- woken taker takes when its wakeup runs (specifications/33-primitives.md
--- §33.2). Waiting offers are moved in, in order, when room frees.

local Cause = require("leffect.cause")
local Waitlist = require("leffect.waitlist")
local core = require("leffect.core")
local runtime = require("leffect.runtime")

local error, floor, getmetatable, huge, min, setmetatable, type =
  error, math.floor, getmetatable, math.huge, math.min, setmetatable, type

local describe = runtime.describe
local exitSucceed, exitFailCause, exitVoid = core.exitSucceed, core.exitFailCause, core.exitVoid
local EXIT_TRUE, EXIT_FALSE = exitSucceed(true), exitSucceed(false)

---A queue of messages.
---@class leffect.Queue
---@field capacity number math.huge when unbounded; 0 for a rendezvous queue
---@field strategy "suspend"|"dropping"|"sliding"
---@field state "Open"|"Closing"|"Done"
---@field exit leffect.Exit.Failure? The failure, once the queue is Closing or Done.
---@field items table The buffered messages, from index `first`.
---@field first integer
---@field count integer The number of buffered messages.
---@field takers leffect.Waitlist Waiting takes and peeks.
---@field offers leffect.Waitlist Waiting offers.
---@field awaiters leffect.Waitlist
---@field offer fun(self: leffect.Queue, message: any): leffect.Effect
---@field offerUnsafe fun(self: leffect.Queue, message: any): boolean
---@field offerAll fun(self: leffect.Queue, messages: table): leffect.Effect
---@field offerAllUnsafe fun(self: leffect.Queue, messages: table): table
---@field take fun(self: leffect.Queue): leffect.Effect
---@field takeAll fun(self: leffect.Queue): leffect.Effect
---@field takeN fun(self: leffect.Queue, n: number): leffect.Effect
---@field takeBetween fun(self: leffect.Queue, atLeast: number, atMost: number): leffect.Effect
---@field peek fun(self: leffect.Queue): leffect.Effect
---@field takeUnsafe fun(self: leffect.Queue): leffect.Exit?
---@field clear fun(self: leffect.Queue): leffect.Effect
---@field finish fun(self: leffect.Queue): leffect.Effect
---@field finishUnsafe fun(self: leffect.Queue): boolean
---@field fail fun(self: leffect.Queue, err: any): leffect.Effect
---@field failCause fun(self: leffect.Queue, cause: leffect.Cause): leffect.Effect
---@field failCauseUnsafe fun(self: leffect.Queue, cause: leffect.Cause): boolean
---@field interrupt fun(self: leffect.Queue): leffect.Effect
---@field shutdown fun(self: leffect.Queue): leffect.Effect
---@field shutdownUnsafe fun(self: leffect.Queue): boolean
---@field await fun(self: leffect.Queue): leffect.Effect
---@field collect fun(self: leffect.Queue): leffect.Effect
---@field size fun(self: leffect.Queue): leffect.Effect
---@field sizeUnsafe fun(self: leffect.Queue): integer
---@field isFull fun(self: leffect.Queue): leffect.Effect
---@field isFullUnsafe fun(self: leffect.Queue): boolean

---A waiting take, or peek.
---@class leffect.Queue.Taker
---@field peek boolean?
---@field min integer
---@field max number
---@field resume fun(effect: leffect.Effect)? Cleared once woken.

---A waiting offer: one message, or what is left of a list.
---@class leffect.Queue.Offer
---@field message any
---@field list table?
---@field offset integer
---@field total integer
---@field resume fun(effect: leffect.Effect)

local methods = {}

local QueueMT = { __index = methods, __name = "leffect.Queue" }

local Queue = {}

---@param value any
---@param name string
local function checkQueue(value, name)
  if getmetatable(value) ~= QueueMT then
    error(name .. ": expected a Queue, got " .. describe(value), 3)
  end
end

---@param value any
---@param name string
local function checkEffect(value, name)
  if not core.isEffect(value) then
    error(name .. ": expected an effect, got " .. describe(value), 3)
  end
end

--- v4's `Count.normalize`: a fraction rounds down, and NaN or a count that
--- isn't positive means 0.
---@param n any
---@return number
local function normalize(n)
  if type(n) ~= "number" or n ~= n or n <= 0 then
    return 0
  end
  return floor(n)
end

--- Whether `cause` is a normal end: a Done failure, and no other failure or
--- defect (v4's `filterDone`).
---@param cause leffect.Cause
---@return boolean
local function isDoneCause(cause)
  local done = false
  local reasons = cause.reasons
  for i = 1, #reasons do
    local reason = reasons[i]
    local tag = reason._tag
    if tag == "Fail" then
      if not Cause.isDone(reason.error) then
        return false
      end
      done = true
    elseif tag == "Die" then
      return false
    end
  end
  return done
end

-- The buffer ----------------------------------------------------------------

---@param q leffect.Queue
---@param message any
local function append(q, message)
  q.items[q.first + q.count] = message
  q.count = q.count + 1
end

---@param q leffect.Queue
---@return any
local function shift(q)
  local first = q.first
  local message = q.items[first]
  q.items[first] = nil
  q.first = first + 1
  q.count = q.count - 1
  return message
end

--- Removes up to `n` messages from the front, and returns them as a list.
---@param q leffect.Queue
---@param n number
---@return table
local function shiftN(q, n)
  local k = min(n, q.count)
  local list = { n = k }
  for i = 1, k do
    list[i] = shift(q)
  end
  return list
end

---@param q leffect.Queue
local function clearBuffer(q)
  q.items, q.first, q.count = {}, 1, 0
end

--- The number of waiting takes, peeks left out.
---@param q leffect.Queue
---@return integer
local function takeWaiters(q)
  local n = 0
  local node = q.takers.head
  while node do
    if not node.peek then
      n = n + 1
    end
    node = node._next
  end
  return n
end

--- The messages of the waiting offers.
---@param q leffect.Queue
---@return integer
local function offeredCount(q)
  local n = 0
  local entry = q.offers.head
  while entry do
    if entry.list then
      n = n + entry.total - entry.offset
    else
      n = n + 1
    end
    entry = entry._next
  end
  return n
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

--- How many messages a taker that wants `atLeast` needs before it is ready
--- (v4's `canTake`): never more than the capacity, and one while Closing.
---@param q leffect.Queue
---@param atLeast integer
---@return integer
local function needed(q, atLeast)
  if q.state == "Closing" then
    return 1
  end
  local capacity = q.capacity
  if capacity == 0 then
    capacity = 1
  end
  return min(atLeast, capacity)
end

---@param q leffect.Queue
---@param atLeast integer
---@return boolean
local function canTake(q, atLeast)
  return q.count >= needed(q, atLeast)
    or (q.capacity <= 0 and q.state ~= "Done" and q.offers.size > 0)
end

--- The wake pass for takers (§37.4). It walks the line in order, budgeting
--- what is buffered: each taker that would be ready with what is left is
--- woken, and what it will take is subtracted. Takers woken earlier count
--- the same way. A peek takes nothing, and leaves the line when woken.
---@param q leffect.Queue
local function wakeTakers(q)
  local takers = q.takers
  if q.state == "Done" or takers.size == 0 then
    return
  end
  local left = q.count
  if q.capacity <= 0 then
    left = left + offeredCount(q)
  end
  local node = takers.head
  while node and left > 0 do
    local nextNode = node._next
    if node.peek then
      if q.count > 0 then
        Waitlist.remove(takers, node)
        wakeNode(node, exitVoid)
      end
    elseif left >= needed(q, node.min) then
      left = left - min(node.max, left)
      wakeNode(node, exitVoid)
    end
    node = nextNode
  end
end

--- Moves the queue to Done with `exit`, and fails every waiting taker and
--- awaiter with it.
---@param q leffect.Queue
---@param exit leffect.Exit.Failure
local function finalize(q, exit)
  if q.state == "Done" then
    return
  end
  q.state, q.exit = "Done", exit
  clearBuffer(q)
  local takers = Waitlist.clear(q.takers)
  for i = 1, #takers do
    wakeNode(takers[i], exit)
  end
  local awaiters = Waitlist.clear(q.awaiters)
  for i = 1, #awaiters do
    awaiters[i].resume(exit)
  end
end

---@param entry leffect.Queue.Offer
local function resumeUnoffered(entry)
  local list = entry.list
  if not list then
    entry.resume(EXIT_FALSE)
    return
  end
  local rest, k = { n = 0 }, 0
  for i = entry.offset + 1, entry.total do
    k = k + 1
    rest[k] = list[i]
  end
  rest.n = k
  entry.resume(exitSucceed(rest))
end

--- Takes one message from the first waiting offer, for a rendezvous queue.
---@param q leffect.Queue
---@return any
local function takeOffer(q)
  local entry = q.offers.head --[[@as leffect.Queue.Offer]]
  if not entry.list then
    Waitlist.remove(q.offers, entry)
    entry.resume(EXIT_TRUE)
    return entry.message
  end
  entry.offset = entry.offset + 1
  local message = entry.list[entry.offset]
  if entry.offset == entry.total then
    Waitlist.remove(q.offers, entry)
    entry.resume(exitSucceed({ n = 0 }))
  end
  return message
end

--- After a take: moves waiting offers in, in order, as far as there is room
--- (v4's `releaseCapacity`), or ends a drained Closing queue.
---@param q leffect.Queue
local function releaseCapacity(q)
  if q.state == "Done" then
    return
  end
  local offers = q.offers
  if offers.size == 0 then
    if q.state == "Closing" and q.count == 0 then
      finalize(q, q.exit --[[@as leffect.Exit.Failure]])
    end
    return
  end
  local moved = false
  local entry = offers.head
  while entry do
    local nextEntry = entry._next
    local room = q.capacity - q.count
    if room <= 0 then
      break
    end
    moved = true
    local list = entry.list
    if not list then
      append(q, entry.message)
      Waitlist.remove(offers, entry)
      entry.resume(EXIT_TRUE)
    else
      while entry.offset < entry.total and room > 0 do
        entry.offset = entry.offset + 1
        append(q, list[entry.offset])
        room = room - 1
      end
      if entry.offset < entry.total then
        break
      end
      Waitlist.remove(offers, entry)
      entry.resume(exitSucceed({ n = 0 }))
    end
    entry = nextEntry
  end
  if moved then
    wakeTakers(q)
  end
end

-- Making --------------------------------------------------------------------

local STRATEGIES = { suspend = true, dropping = true, sliding = true }

---@param capacity any
---@param strategy any
---@param name string
---@return leffect.Queue
local function new(capacity, strategy, name)
  if capacity == nil then
    capacity = huge
  end
  if
    type(capacity) ~= "number"
    or capacity < 0
    or (capacity ~= huge and floor(capacity) ~= capacity)
  then
    error(
      name
        .. ": the capacity must be a non-negative integer or math.huge, got "
        .. describe(capacity),
      3
    )
  end
  if strategy == nil then
    strategy = "suspend"
  elseif not STRATEGIES[strategy] then
    error(
      name
        .. ': the strategy must be "suspend", "dropping" or "sliding", got '
        .. describe(strategy),
      3
    )
  end
  return setmetatable({
    capacity = capacity,
    strategy = strategy,
    state = "Open",
    exit = nil,
    items = {},
    first = 1,
    count = 0,
    takers = Waitlist.new(),
    offers = Waitlist.new(),
    awaiters = Waitlist.new(),
  }, QueueMT)
end

--- An effect that succeeds with a new queue. `options.capacity` defaults to
--- `math.huge`, and `options.strategy` to `"suspend"`.
---@param options { capacity: number?, strategy: ("suspend"|"dropping"|"sliding")? }?
---@return leffect.Effect
function Queue.make(options)
  local capacity, strategy
  if options ~= nil then
    if type(options) ~= "table" then
      error("Queue.make: expected an options table, got " .. describe(options), 2)
    end
    capacity, strategy = options.capacity, options.strategy
  end
  new(capacity, strategy, "Queue.make")
  return core.sync(function()
    return new(capacity, strategy, "Queue.make")
  end)
end

--- A queue of capacity `n`, whose offers wait when it is full.
---@param n integer
---@return leffect.Effect
function Queue.bounded(n)
  new(n, nil, "Queue.bounded")
  return Queue.make({ capacity = n })
end

--- A queue of capacity `n` that rejects new messages when it is full.
---@param n integer
---@return leffect.Effect
function Queue.dropping(n)
  new(n, nil, "Queue.dropping")
  return Queue.make({ capacity = n, strategy = "dropping" })
end

--- A queue of capacity `n` that drops its oldest message when it is full.
---@param n integer
---@return leffect.Effect
function Queue.sliding(n)
  new(n, nil, "Queue.sliding")
  return Queue.make({ capacity = n, strategy = "sliding" })
end

--- A queue with no limit.
---@return leffect.Effect
function Queue.unbounded()
  return Queue.make(nil)
end

---@param value any
---@return boolean
function Queue.isQueue(value)
  return getmetatable(value) == QueueMT
end

-- Offering ------------------------------------------------------------------

--- Adds the message at once if it fits, and returns whether it did. Never
--- waits.
---@param q leffect.Queue
---@param message any
---@return boolean
function Queue.offerUnsafe(q, message)
  checkQueue(q, "Queue.offerUnsafe")
  if q.state ~= "Open" then
    return false
  end
  local capacity = q.capacity
  if q.count >= capacity then
    local sliding = q.strategy == "sliding"
    if capacity <= 0 then
      -- A rendezvous queue takes a message only for a taker that waits.
      local waiting = takeWaiters(q)
      if waiting > (sliding and 0 or q.count) then
        append(q, message)
        if sliding then
          while q.count > waiting do
            shift(q)
          end
        end
        wakeTakers(q)
        return true
      end
      return sliding
    elseif sliding then
      shift(q)
      append(q, message)
      return true
    end
    return false
  end
  append(q, message)
  wakeTakers(q)
  return true
end

--- Waits in line for room, or resumes at once if the queue isn't open.
--- Returns the canceler that withdraws the offer.
---@param q leffect.Queue
---@param entry leffect.Queue.Offer
---@return fun()?
local function waitToOffer(q, entry)
  if q.state ~= "Open" then
    resumeUnoffered(entry)
    return nil
  end
  local offers = q.offers
  Waitlist.push(offers, entry)
  return function()
    if q.state == "Done" then
      return
    end
    Waitlist.remove(offers, entry)
    if q.state == "Closing" and offers.size == 0 and q.count == 0 then
      finalize(q, q.exit --[[@as leffect.Exit.Failure]])
    end
  end
end

--- Adds the message, and succeeds with true. Succeeds with false when the
--- queue isn't open, or when a dropping queue is full. On a full suspending
--- queue, it waits until the message gets in.
---@param q leffect.Queue
---@param message any
---@return leffect.Effect
function Queue.offer(q, message)
  checkQueue(q, "Queue.offer")
  return core.suspend(function()
    if Queue.offerUnsafe(q, message) then
      return EXIT_TRUE
    elseif q.state ~= "Open" or q.strategy ~= "suspend" then
      return EXIT_FALSE
    end
    return core.async(function(resume)
      if Queue.offerUnsafe(q, message) then
        resume(EXIT_TRUE)
        return nil
      end
      return waitToOffer(q, { message = message, offset = 0, total = 1, resume = resume })
    end)
  end)
end

--- The length of a list of messages: its field `n`, or `#`.
---@param messages table
---@return integer
local function lengthOf(messages)
  return messages.n or #messages
end

--- Adds what fits at once, and returns the rest as a list with `n`.
---@param q leffect.Queue
---@param messages table
---@return table
function Queue.offerAllUnsafe(q, messages)
  checkQueue(q, "Queue.offerAllUnsafe")
  if type(messages) ~= "table" then
    error("Queue.offerAllUnsafe: expected a list, got " .. describe(messages), 2)
  end
  local total = lengthOf(messages)
  local function rest(from)
    local list, k = {}, 0
    for i = from, total do
      k = k + 1
      list[k] = messages[i]
    end
    list.n = k
    return list
  end
  if q.state ~= "Open" then
    return rest(1)
  end
  local capacity = q.capacity
  if capacity <= 0 then
    capacity = takeWaiters(q)
  end
  if q.capacity == huge or q.strategy == "sliding" then
    for i = 1, total do
      append(q, messages[i])
    end
    if q.strategy == "sliding" then
      while q.count > capacity do
        shift(q)
      end
    end
    wakeTakers(q)
    return { n = 0 }
  end
  local free = capacity - q.count
  if free <= 0 then
    return rest(1)
  end
  local k = min(free, total)
  for i = 1, k do
    append(q, messages[i])
  end
  wakeTakers(q)
  return rest(k + 1)
end

--- Adds a list, and succeeds with a list of the messages it didn't add. A
--- suspending queue adds what fits, and waits to add the rest.
---@param q leffect.Queue
---@param messages table
---@return leffect.Effect
function Queue.offerAll(q, messages)
  checkQueue(q, "Queue.offerAll")
  if type(messages) ~= "table" then
    error("Queue.offerAll: expected a list, got " .. describe(messages), 2)
  end
  return core.async(function(resume)
    local remaining = Queue.offerAllUnsafe(q, messages)
    if remaining.n == 0 or q.strategy == "dropping" then
      resume(exitSucceed(remaining))
      return nil
    end
    return waitToOffer(q, { list = remaining, offset = 0, total = remaining.n, resume = resume })
  end)
end

-- Taking --------------------------------------------------------------------

--- An Exit: a success with the oldest message, or the queue's failure once
--- it is Done. nil if neither is ready. Never waits.
---@param q leffect.Queue
---@return leffect.Exit?
function Queue.takeUnsafe(q)
  checkQueue(q, "Queue.takeUnsafe")
  if q.state == "Done" then
    return q.exit
  end
  if q.count > 0 then
    local message = shift(q)
    releaseCapacity(q)
    return exitSucceed(message)
  elseif q.capacity <= 0 and q.offers.size > 0 then
    local message = takeOffer(q)
    releaseCapacity(q)
    return exitSucceed(message)
  end
  return nil
end

--- Takes between `atLeast` and `atMost` messages if the queue is ready.
---@param q leffect.Queue
---@param atLeast integer
---@param atMost number
---@return leffect.Exit?
local function takeBetweenUnsafe(q, atLeast, atMost)
  if q.state == "Done" then
    return q.exit
  elseif atMost <= 0 or atLeast <= 0 then
    return exitSucceed({ n = 0 })
  elseif not canTake(q, atLeast) then
    return nil
  end
  local messages
  if q.count > 0 then
    messages = shiftN(q, atMost)
  else
    messages = { takeOffer(q), n = 1 }
  end
  releaseCapacity(q)
  return exitSucceed(messages)
end

--- Takes with `attempt`, or waits in line until it can (§33.2). The waiter
--- keeps its place until it takes, and an exit frame passes its turn on if
--- it leaves first.
---@param q leffect.Queue
---@param atLeast integer
---@param atMost number
---@param attempt fun(): leffect.Exit?
---@return leffect.Effect
local function takeOrWait(q, atLeast, atMost, attempt)
  return core.withFiber(function(fiber)
    local exit = attempt()
    if exit then
      return exit
    end
    local takers = q.takers
    ---@type leffect.Queue.Taker
    local node = { min = atLeast, max = atMost }
    Waitlist.push(takers, node)
    runtime.onExitUnsafe(fiber, function()
      if Waitlist.remove(takers, node) then
        wakeTakers(q)
      end
      return nil
    end)
    local wait = core.async(function(resume)
      if q.state == "Done" or canTake(q, atLeast) then
        resume(exitVoid)
      else
        node.resume = resume
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

--- Takes the oldest message, waiting for one. Once the queue is Done, it
--- fails with the queue's error.
---@param q leffect.Queue
---@return leffect.Effect
function Queue.take(q)
  checkQueue(q, "Queue.take")
  return takeOrWait(q, 1, 1, function()
    return Queue.takeUnsafe(q)
  end)
end

--- Waits for `atLeast` messages, and takes up to `atMost`. Counts are
--- normalized: a fraction rounds down, and NaN or a count that isn't
--- positive means 0.
---@param q leffect.Queue
---@param atLeast number
---@param atMost number
---@return leffect.Effect
function Queue.takeBetween(q, atLeast, atMost)
  checkQueue(q, "Queue.takeBetween")
  local lo, hi = normalize(atLeast), normalize(atMost)
  return takeOrWait(q, lo, hi, function()
    return takeBetweenUnsafe(q, lo, hi)
  end)
end

--- Waits for `n` messages, and takes `n`.
---@param q leffect.Queue
---@param n number
---@return leffect.Effect
function Queue.takeN(q, n)
  checkQueue(q, "Queue.takeN")
  return Queue.takeBetween(q, n, n)
end

--- Takes every buffered message, waiting for at least one.
---@param q leffect.Queue
---@return leffect.Effect
function Queue.takeAll(q)
  checkQueue(q, "Queue.takeAll")
  return Queue.takeBetween(q, 1, huge)
end

--- The oldest message, which stays in the queue. Waits for one.
---@param q leffect.Queue
---@return leffect.Effect
function Queue.peek(q)
  checkQueue(q, "Queue.peek")
  local peek
  local wait = core.async(function(resume)
    if q.state == "Done" then
      resume(q.exit)
      return nil
    elseif q.count > 0 then
      resume(exitVoid)
      return nil
    end
    local node = { peek = true, min = 1, max = 0, resume = resume }
    Waitlist.push(q.takers, node)
    return function()
      Waitlist.remove(q.takers, node)
    end
  end)
  peek = core.suspend(function()
    if q.state == "Done" then
      return q.exit
    elseif q.count > 0 then
      return exitSucceed(q.items[q.first])
    end
    return core.flatMap(wait, function()
      return peek
    end)
  end)
  return peek
end

--- Takes every buffered message at once, and lets waiting offers in.
---@param q leffect.Queue
---@return table
local function takeAllUnsafe(q)
  if q.count > 0 then
    local messages = shiftN(q, q.count)
    releaseCapacity(q)
    return messages
  elseif q.state ~= "Done" and q.offers.size > 0 then
    local messages = { takeOffer(q), n = 1 }
    releaseCapacity(q)
    return messages
  end
  return { n = 0 }
end

--- Removes every buffered message, without waiting, and succeeds with them.
--- On a Done queue, succeeds with an empty list if it ended with `finish`,
--- and fails with its error otherwise.
---@param q leffect.Queue
---@return leffect.Effect
function Queue.clear(q)
  checkQueue(q, "Queue.clear")
  return core.suspend(function()
    if q.state == "Done" then
      local exit = q.exit --[[@as leffect.Exit.Failure]]
      if isDoneCause(exit.cause) then
        return exitSucceed({ n = 0 })
      end
      return exit
    end
    return exitSucceed(takeAllUnsafe(q))
  end)
end

-- Ending --------------------------------------------------------------------

--- Ends the queue with `cause`. Returns false if it had already ended.
---@param q leffect.Queue
---@param cause leffect.Cause
---@return boolean
function Queue.failCauseUnsafe(q, cause)
  checkQueue(q, "Queue.failCauseUnsafe")
  if q.state ~= "Open" then
    return false
  end
  local exit = exitFailCause(cause)
  if q.offers.size == 0 and q.count == 0 then
    finalize(q, exit)
    return true
  end
  q.state, q.exit = "Closing", exit
  wakeTakers(q)
  return true
end

--- Ends the queue with `cause`. Succeeds with true, or with false if it had
--- already ended.
---@param q leffect.Queue
---@param cause leffect.Cause
---@return leffect.Effect
function Queue.failCause(q, cause)
  checkQueue(q, "Queue.failCause")
  return core.sync(function()
    return Queue.failCauseUnsafe(q, cause)
  end)
end

--- Ends the queue with the error `err`.
---@param q leffect.Queue
---@param err any
---@return leffect.Effect
function Queue.fail(q, err)
  checkQueue(q, "Queue.fail")
  return Queue.failCause(q, Cause.fail(err))
end

--- v4's `endUnsafe`: ends the queue with `Cause.Done()`.
---@param q leffect.Queue
---@return boolean
function Queue.finishUnsafe(q)
  checkQueue(q, "Queue.finishUnsafe")
  return Queue.failCauseUnsafe(q, Cause.fail(Cause.Done()))
end

--- v4's `end`: ends the queue with `Cause.Done()`. Succeeds with true, or
--- with false if the queue had already ended.
---@param q leffect.Queue
---@return leffect.Effect
function Queue.finish(q)
  checkQueue(q, "Queue.finish")
  return Queue.failCause(q, Cause.fail(Cause.Done()))
end

--- Ends the queue with an interrupt from the current fiber.
---@param q leffect.Queue
---@return leffect.Effect
function Queue.interrupt(q)
  checkQueue(q, "Queue.interrupt")
  return core.withFiber(function(fiber)
    return Queue.failCause(q, Cause.interrupt(fiber.id))
  end)
end

--- Ends the queue at once, without draining: drops the buffered messages,
--- fails the waiting takers and awaiters, and resumes the waiting offers
--- with what they didn't add. Returns false if it was already Done.
---@param q leffect.Queue
---@return boolean
function Queue.shutdownUnsafe(q)
  checkQueue(q, "Queue.shutdownUnsafe")
  if q.state == "Done" then
    return false
  end
  local exit = q.exit
  if q.state == "Open" then
    exit = exitFailCause(Cause.interrupt())
  end
  local offers = Waitlist.clear(q.offers)
  finalize(q, exit --[[@as leffect.Exit.Failure]])
  for i = 1, #offers do
    resumeUnoffered(offers[i])
  end
  return true
end

--- Ends the queue at once. Succeeds with false if it was already Done.
---@param q leffect.Queue
---@return leffect.Effect
function Queue.shutdown(q)
  checkQueue(q, "Queue.shutdown")
  return core.sync(function()
    return Queue.shutdownUnsafe(q)
  end)
end

--- Waits until the queue is Done. Succeeds if it ended with `finish`, and
--- fails with its error otherwise.
---@param q leffect.Queue
---@return leffect.Effect
function Queue.await(q)
  checkQueue(q, "Queue.await")
  return core.async(function(resume)
    local function settle(exit)
      if isDoneCause(exit.cause) then
        resume(exitVoid)
      else
        resume(exit)
      end
    end
    if q.state == "Done" then
      settle(q.exit)
      return nil
    end
    local node = { resume = settle }
    Waitlist.push(q.awaiters, node)
    return function()
      Waitlist.remove(q.awaiters, node)
    end
  end)
end

--- Takes until the queue is Done. If it ended with `finish`, succeeds with
--- all the messages, as a list with `n`. Otherwise fails with its error.
---@param q leffect.Queue
---@return leffect.Effect
function Queue.collect(q)
  checkQueue(q, "Queue.collect")
  local takeAll = core.exit(Queue.takeAll(q))
  return core.suspend(function()
    local out, k = {}, 0
    local loop
    loop = core.flatMap(takeAll, function(exit)
      if exit._op == core.OP_SUCCESS then
        local items = exit.value
        for i = 1, items.n do
          k = k + 1
          out[k] = items[i]
        end
        return loop
      elseif isDoneCause(exit.cause) then
        out.n = k
        return exitSucceed(out)
      end
      return exit
    end)
    return loop
  end)
end

--- Runs `effect`, then ends the queue: with `finish` if `effect` succeeds,
--- and with `failCause` and its cause if it fails. Succeeds with whether this
--- call ended the queue.
---@param effect leffect.Effect
---@param q leffect.Queue
---@return leffect.Effect
function Queue.into(effect, q)
  checkEffect(effect, "Queue.into")
  checkQueue(q, "Queue.into")
  return runtime.uninterruptibleMask(function(restore)
    return core.flatMap(core.exit(restore(effect)), function(exit)
      if exit._op == core.OP_SUCCESS then
        return Queue.finish(q)
      end
      return Queue.failCause(q, exit.cause)
    end)
  end)
end

--- The number of buffered messages, which is 0 once the queue is Done.
---@param q leffect.Queue
---@return integer
function Queue.sizeUnsafe(q)
  checkQueue(q, "Queue.sizeUnsafe")
  if q.state == "Done" then
    return 0
  end
  return q.count
end

---@param q leffect.Queue
---@return leffect.Effect
function Queue.size(q)
  checkQueue(q, "Queue.size")
  return core.sync(function()
    return Queue.sizeUnsafe(q)
  end)
end

--- Whether `size` equals the capacity.
---@param q leffect.Queue
---@return boolean
function Queue.isFullUnsafe(q)
  checkQueue(q, "Queue.isFullUnsafe")
  return Queue.sizeUnsafe(q) == q.capacity
end

---@param q leffect.Queue
---@return leffect.Effect
function Queue.isFull(q)
  checkQueue(q, "Queue.isFull")
  return core.sync(function()
    return Queue.isFullUnsafe(q)
  end)
end

for _, name in ipairs({
  "offer",
  "offerUnsafe",
  "offerAll",
  "offerAllUnsafe",
  "take",
  "takeAll",
  "takeN",
  "takeBetween",
  "peek",
  "takeUnsafe",
  "clear",
  "finish",
  "finishUnsafe",
  "fail",
  "failCause",
  "failCauseUnsafe",
  "interrupt",
  "shutdown",
  "shutdownUnsafe",
  "await",
  "collect",
  "size",
  "sizeUnsafe",
  "isFull",
  "isFullUnsafe",
}) do
  methods[name] = Queue[name]
end

return Queue
