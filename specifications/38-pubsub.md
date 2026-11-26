# PubSub

Part IV (M4) of the [Leffect specifications](README.md).

## 38. PubSub

A PubSub, or hub, broadcasts each message to every subscriber (`PubSub.ts` at
4.1.5). Unlike a queue's consumers, subscribers don't compete: each one has its
own subscription, and takes its own copy of each message.

```lua
local program = Effect.scoped(Effect.gen(function(run)
  local hub = run(PubSub.bounded(16))
  local sub = run(hub:subscribe())
  run(hub:publish("hello"))
  return run(sub:take())
end))
```

### 38.1 Making and publishing

| Function | Semantics |
|---|---|
| `PubSub.bounded(capacity)` | A hub that holds up to `capacity` messages. A publish to a full hub waits. |
| `PubSub.dropping(capacity)` | A publish to a full hub is dropped, and succeeds with false. |
| `PubSub.sliding(capacity)` | A publish to a full hub drops the oldest message the hub holds. |
| `PubSub.unbounded()` | A hub that is never full. |
| `PubSub.publish(hub, message)` | Succeeds with true once the message is accepted. Succeeds with false if the hub has finished or shut down, or if a dropping hub is full. |
| `PubSub.publishAll(hub, messages)` | The same for a list. Succeeds with false if any message was dropped. |
| `PubSub.publishUnsafe(hub, message)` | Publishes at once if the hub isn't full, and returns whether it did. It never waits and never slides, as in v4. |
| `PubSub.capacity(hub)` | The capacity: a number, not an effect. |
| `PubSub.size(hub)`, `sizeUnsafe(hub)` | The number of messages the hub holds, which is 0 after shutdown. |
| `PubSub.isFull(hub)`, `isEmpty(hub)` | Whether `size` equals the capacity, or 0. |
| `PubSub.isPubSub(x)` | Type check. |

- **What the hub holds.** It holds a message until every subscriber that was
  subscribed when the message was published has taken it, or has
  unsubscribed.
  - So the slowest subscriber decides how full the hub is.
  - A message published while there are no subscribers isn't held at all. The
    publish still succeeds with true.
- **Capacity** is a positive integer, or `math.huge`. Anything else raises, as
  in v4 (`ensureCapacity`, PubSub.ts 2532).
- **Waiting publishes.** On a bounded hub, a waiting publish is accepted when
  room frees, in order, and then succeeds with true. This is the handoff of
  §33.2.
  - `publishAll` waits until its last message is accepted.
  - An interrupted publish withdraws the messages that weren't accepted yet.
    The ones already accepted stay.
- **Sliding** drops the oldest held message for every subscriber that hasn't
  taken it yet.

### 38.2 Subscribing and taking

| Function | Semantics |
|---|---|
| `PubSub.subscribe(hub)` | Succeeds with a Subscription, which lasts until the current scope closes. Without a scope, it dies with `Effect.scope`'s message. |
| `PubSub.take(sub)` | Takes the next message, waiting for one. |
| `PubSub.takeAll(sub)` | Takes every message waiting for this subscription, and waits for at least one. |
| `PubSub.takeUpTo(sub, max)` | Takes up to `max` messages, without waiting. |
| `PubSub.takeBetween(sub, min, max)` | Waits for `min` messages, and takes up to `max`. Below the cut line. |
| `PubSub.remaining(sub)` | The number of messages waiting for this subscription. |

- **A subscription receives** the messages published after it subscribed, in
  order, once each.
- **Several fibers can take from one subscription.** They share its messages,
  and each message goes to one of them. A new take doesn't overtake a fiber
  that is already waiting on the same subscription. v4 checks for that
  (`pollers.length`, PubSub.ts 1336).
- **Waiting takers follow §33.2.** A woken taker takes its message when it
  runs, so an interrupt in the wake tick loses nothing.
  - v4 hands the message over through a Deferred instead (`pollForItem`,
    PubSub.ts 1396).
  - That is safe in v4 only because its resume runs inline (§14).
- **When the subscription's scope closes,** the subscription ends:
  - a taker that was already woken gets the messages its wake pass counted
    for it, in line order. In v4 they would already be in its Deferred;
  - its other waiting takers end with an interrupt from the fiber that closes
    the scope;
  - a later take interrupts the fiber that makes it (`Effect.interrupt`), and
    so does `remaining`;
  - it stops holding messages, which can let waiting publishers in.
- **The subscription's scope is a child of the hub's own scope**
  (`Scope.forkUnsafe`, PubSub.ts 1263). So `shutdown` ends every
  subscription. A subscription made after `shutdown` has already ended.

### 38.3 Ending

| Function | Semantics |
|---|---|
| `PubSub.finish(hub, message)`, `finishUnsafe(hub, message)` | v4's `end`. Publishes a final message. Succeeds with true, or with false if the hub had already finished or shut down. |
| `PubSub.shutdown(hub)` | Shuts the hub down, uninterruptibly. It ends every subscription, then interrupts the publishers still waiting, and opens the shutdown latch. Ending the subscriptions frees room, so a waiting publish can get in and succeed with true first, as in v4 (PubSub.ts 822). |
| `PubSub.isShutdown(hub)`, `isShutdownUnsafe(hub)` | Whether the hub has shut down. |
| `PubSub.awaitShutdown(hub)` | Waits until the hub shuts down. |

- **After `finish`:**
  - later publishes succeed with false, and so do the ones that were waiting;
  - each subscriber takes its held messages, then the final one;
  - a subscriber that subscribes after `finish` gets the final message too.
- **The final message is sticky,** as in v4. Every take after it gets it
  again, so consumers must treat it as the end.
  - It doesn't count against capacity, so a bounded hub can't drop it.
  - `takeUpTo` never returns it.
- **After `shutdown`:**
  - publishes succeed with false;
  - takes interrupt the fiber that makes them;
  - `size` is 0;
  - `awaitShutdown` continues at once.

  A second `shutdown` does nothing.
- **The shutdown latch is a Latch** (§35.2), as in v4.

### 38.4 Replay

This is below the cut line (§40).

`bounded`, `dropping` and `sliding` also accept `{ capacity = n, replay = k }`,
and `unbounded` accepts `{ replay = k }`:
- **The hub remembers the last `k` messages published,** whether anyone is
  subscribed or not.
- **A new subscription takes those first,** oldest first, then live messages.
- **Replayed messages don't count against capacity.**
- **Sliding and replay.** A subscription can still be reading its replayed
  messages when a sliding hub drops a live message that it hasn't seen. That
  message then joins the end of the subscription's replay, and the oldest
  replayed message leaves it. This follows v4 (`ReplayWindowImpl.sync`,
  PubSub.ts 2979).

### 38.5 Internals

- **One buffer serves every strategy.** It is a table of messages, indexed
  by publish number, as v4's bounded buffers are, without the modulo.
  - Each held message counts the subscribers that still have to take it.
  - A subscription holds the number of its next message.
  - The hub holds the messages from the oldest one that is still counted;
    their number is `size`.
- **v4 has four buffers that behave the same:**
  - one for capacity 1;
  - one for powers of two, which indexes with `&`;
  - one for other capacities;
  - an unbounded list.

  Lua's common subset has no bitwise operators, and one table is enough (§14).
- **Custom buffers and strategies stay internal.** v4's
  `make({ atomicPubSub, strategy })`, `makeAtomicBounded`,
  `makeAtomicUnbounded` and the strategy classes let users plug in their own
  buffer and strategy (§15).
