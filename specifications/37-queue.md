# Queue

Part IV (M4) of the [Leffect specifications](README.md).

## 37. Queue

A Queue passes messages from producers to consumers. Each message goes to one
consumer (`Queue.ts` at 4.1.5). A v4 queue can also end, or fail with an
error. Consumers then drain what is left, and after that they see the end.

### 37.1 Done

v4 marks a normal end with a special error, `Cause.Done` (Cause.ts 1334). M4
adds it to `Cause`:
- **`Cause.Done(value?)`** returns a tagged error, `{ _tag = "Done", value =
  value }`, with a private metatable. Without a value it returns one shared
  table, as v4 does.
- **`Cause.isDone(x)`** checks the metatable, so a plain `{ _tag = "Done" }`
  isn't a Done.
- **`finish(queue)`** fails the queue with `Cause.Done()`. Consumers then fail
  with it, and `catchTag(effect, "Done", f)` catches it.
- **v4's `Pull` module stays with Stream** (Later). It handles Done for
  streams. Three queue functions treat Done as success: `await`, `clear` and
  `collect`. They use a private helper, which follows v4's `filterDone`
  (Pull.ts 238): a cause counts as Done when it has a Done failure and no
  other failure or defect.

### 37.2 States, strategies and capacity

```lua
---@class leffect.Queue
---@field capacity number -- math.huge when unbounded; 0 for a rendezvous queue
---@field strategy "suspend"|"dropping"|"sliding"
---@field state "Open"|"Closing"|"Done"
---@field exit leffect.Exit? -- the failure, once the queue is Closing or Done
```

The buffered messages, and the lines of takers, offers and awaiters, are
private fields too (§33.3).

The three states:
- **Open:** offers are accepted.
- **Closing:** the queue has ended, but messages are still buffered or offers
  are still waiting. It enters this state through `finish`, `fail`,
  `failCause` or `interrupt`.
  - New offers succeed with false.
  - Offers that were already waiting still get in, as consumers drain.
  - Takers take what is left, even if that is fewer messages than they asked
    for.
- **Done:** nothing is left, or the queue was shut down.
  - Takes fail with the queue's exit.
  - Offers succeed with false.
  - `size` is 0.

A queue that ends with nothing buffered and no waiting offers goes straight to
Done.

**Strategies** decide what happens when the queue is full:
- `"suspend"`, the default: offers wait.
- `"dropping"`: the new message is rejected, and `offer` succeeds with false.
- `"sliding"`: the oldest message is dropped, and the new one is accepted.

**Capacity** is a non-negative integer, or `math.huge`, which is the default.
Capacity 0 makes a rendezvous queue: an offer waits until a taker takes its
message (the `capacity <= 0` branches in v4). Capacity 0 is below the cut line
(§40).

| Constructor | Queue |
|---|---|
| `Queue.make(options?)` | `options.capacity` defaults to `math.huge`, and `options.strategy` to `"suspend"`. |
| `Queue.bounded(n)` | Capacity `n`, `"suspend"`. |
| `Queue.dropping(n)`, `Queue.sliding(n)` | Capacity `n`, with that strategy. |
| `Queue.unbounded()` | No limit. |

### 37.3 Offering

| Function | Semantics |
|---|---|
| `Queue.offer(queue, message)` | Adds the message, and succeeds with true. Succeeds with false when the queue isn't open, or when a dropping queue is full. On a full suspending queue, it waits. |
| `Queue.offerUnsafe(queue, message)` | Adds the message at once if it fits, and returns whether it did. Never waits. |
| `Queue.offerAll(queue, messages)` | Adds a list, and succeeds with a list of the messages it didn't add. That list is empty, unless the queue isn't open or is a dropping queue that filled up. A suspending queue adds what fits, and waits to add the rest. |
| `Queue.offerAllUnsafe(queue, messages)` | Adds what fits at once, and returns the rest. |

- **Waiting offers are served in order.** When a take makes room, the first
  waiting offer's message moves in, and that offer succeeds with true. A
  waiting `offerAll` moves in as far as there is room. It succeeds with an
  empty list once all its messages are in (`releaseCapacity`, Queue.ts 2126).
- This is the handoff of §33.2. If the offerer is interrupted in the wake
  tick, its message stays in the queue (§14).
- **A waiting offer that is interrupted** before its message moves in is
  removed. Its message never arrives.
- **On a sliding queue,** `offerAll` keeps the newest messages, up to the
  capacity, and succeeds with an empty list.

### 37.4 Taking

| Function | Semantics |
|---|---|
| `Queue.take(queue)` | Takes the oldest message, waiting for one. Once the queue is Done, it fails with the queue's error. |
| `Queue.takeAll(queue)` | Takes every buffered message, waiting for at least one. |
| `Queue.takeN(queue, n)` | Waits for `n` messages, and takes `n`. Below the cut line. |
| `Queue.takeBetween(queue, min, max)` | Waits for `min` messages, and takes up to `max`. Below the cut line. |
| `Queue.peek(queue)` | The oldest message, which stays in the queue. Waits for one. |
| `Queue.takeUnsafe(queue)` | An Exit: a success with the oldest message, or the queue's failure once it is Done. nil if neither is ready. Never waits. |
| `Queue.clear(queue)` | Removes every buffered message, without waiting, and succeeds with them. Lets waiting offers in. |

- **Minimums** follow v4's `canTake` (Queue.ts 2069):
  - A taker that needs `min` messages is ready once `min` are buffered.
  - It never needs more than the capacity, since the queue can't hold more.
  - While the queue is Closing, one message is enough.
  - `takeBetween(q, 0, k)` and `takeN(q, 0)` succeed at once with an empty
    list.
- **Waiting takers follow §33.2.** They keep their place in line, and a woken
  taker takes when it runs. The wake pass works like this:
  - It walks the waiting takers in order. It starts from the number of
    buffered messages, plus, at capacity 0, the messages of waiting offers.
  - It wakes each taker that would be ready with what is left.
  - It subtracts what that taker will take: `math.min(max, left)`. Takers it
    woke earlier count the same way.
  - A `peek` takes nothing. It is woken like a taker, but it leaves the line
    when it is woken, as a wait that consumes nothing does (§33.2).
  - The pass stops when nothing is left.

  The pass runs after an offer adds messages, when the queue starts Closing,
  and when a taker leaves.
- **A new `take` doesn't look at the waiting takers,** as in v4. If a message
  is buffered, the new take gets it. A woken taker that then finds nothing
  waits again, in its place.
- **Taking makes room,** which lets waiting offers in (§37.3).
- **The end of Closing.** While the queue is Closing, the take that removes
  the last message moves the queue to Done, if no offers are waiting. The other
  waiting takers then fail with the queue's exit.
- **`clear` on a Done queue** succeeds with an empty list if the queue ended
  with `finish`. Otherwise it fails with the queue's error.

### 37.5 Ending and observing

| Function | Semantics |
|---|---|
| `Queue.finish(queue)`, `finishUnsafe(queue)` | v4's `end`. Ends the queue with `Cause.Done()`. Succeeds with true, or with false if the queue had already ended. |
| `Queue.fail(queue, error)`, `failCause(queue, cause)`, `failCauseUnsafe(queue, cause)` | Ends the queue with a failure. |
| `Queue.interrupt(queue)` | Ends the queue with an interrupt from the current fiber. |
| `Queue.shutdown(queue)`, `shutdownUnsafe(queue)` | Ends the queue at once. Succeeds with false if it was already Done. |
| `Queue.await(queue)` | Waits until the queue is Done. Succeeds if it ended with `finish`, and fails with its error otherwise. |
| `Queue.collect(queue)` | Takes until the queue is Done. If it ended with `finish`, succeeds with all the messages. Below the cut line. |
| `Queue.into(effect, queue)` | Runs `effect`, then ends the queue: with `finish` if `effect` succeeds, and with `failCause` and its cause if it fails. Below the cut line. |
| `Queue.size(queue)`, `sizeUnsafe(queue)` | The number of buffered messages, which is 0 once the queue is Done. Waiting offers don't count. |
| `Queue.isFull(queue)`, `isFullUnsafe(queue)` | Whether `size` equals the capacity. |
| `Queue.isQueue(x)` | Type check. |

- **Ending works once.** Later calls change nothing, and succeed with false.
- **`shutdown` doesn't drain.** It:
  - drops the buffered messages;
  - fails the waiting takers and awaiters;
  - resumes the waiting offers with false, or a waiting `offerAll` with the
    messages it didn't add.

  An open queue ends with an interrupt cause that has no fiber id. A queue
  that is already Closing keeps its exit.
- **Some v4 functions aren't provided:**
  - `asEnqueue`, `asDequeue`, `isEnqueue` and `isDequeue` concern TypeScript
    types.
  - v4's `flush` and `flushUnsafe` force its deferred wake task (§33.4),
    which Leffect doesn't have.
  - `poll` returns an Option, so it waits for an Option type (§15).
    `takeUnsafe` covers the same need.
