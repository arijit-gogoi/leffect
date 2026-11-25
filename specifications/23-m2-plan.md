# M2 specs, implementation order and decisions

Part II (M2) of the [Leffect specifications](README.md).

## 23. Specs for M2

Write these before the code. First, §17's specs for the re-pin. The rest go in
new files: `spec/gen_spec.lua`, `catch_spec.lua`, `context_spec.lua`,
`scope_spec.lua`, `resource_spec.lua` and `foreach_spec.lua`.

**gen** (moved here from §12)
- Values flow through `run()`; the body's first return value is the result.
- A failing `run()` never returns: code after it doesn't execute, and a
  `pcall` around it doesn't catch it.
- A Lua error in the body becomes a `Die` holding the raw error, with a
  traceback that contains the body's line number on both runtimes. A thrown
  table stays the defect.
- A raw `coroutine.yield` inside gen becomes a defect.
- `Leffect.run` raises a clear error when called outside gen, and when called
  from a user coroutine inside the body.
- `run(x)` with a non-effect dies with "Not a valid effect".
- A helper function called by the body can call `Leffect.run`.
- An interrupt during `run(sleep(...))` abandons the coroutine, and runs the
  `ensuring` added outside.
- Running one gen effect twice runs the body twice, from the start.
- Nested gens work.
- A gen body may return an effect, which comes back as a plain value.
- A gen body that calls `run()` 1e5 times in a loop doesn't overflow.

**Typed catches and `exit`**
- `catchTag`:
  - it recovers a matching `_tag`, and passes the error to the handler;
  - a list of tags works;
  - other errors keep failing, or go to `orElse`.
- Errors that aren't tables (a string, a number, nil) never match, and never
  raise.
- An error whose `_tag` comes from a metatable class matches.
- `catchTags` dispatches on `_tag`. A tag with no case keeps failing, or goes
  to `orElse`.
- `catchIf` follows its predicate.
- None of them recover a defect, an interrupt, or a cause that holds a Die.
- `Effect.exit` succeeds with the exit, for a success, a failure and a
  defect.

**Context**
- A fiber forked inside `scoped` sees the same scope, daemon or not.
- After a nested `scoped` ends, by success, failure or interrupt,
  `Effect.scope` sees the outer scope again.
- A scope's finalizers run in the outer context: inside one, `Effect.scope`
  is the outer scope.
- When the body of a nested `scoped` is interrupted at its first step, the
  inner scope still closes, and a finalizer outside it sees the outer scope.

**Scope**
- Finalizers run newest first, each with the close exit.
- Closing twice runs them once.
- Adding to a closed scope runs the finalizer at once, with the close exit.
- A failing or throwing finalizer doesn't stop the others. The close fails
  with all their reasons, in run order.
- Closing is uninterruptible: interrupting the closing fiber doesn't cut a
  sleeping finalizer short.
- A forked scope:
  - it closes with its parent, at its own position;
  - closed first, it detaches, and the parent doesn't close it again;
  - forking a closed scope gives a closed scope.
- `Effect.scope` outside `scoped` dies with §19.2's message.
- `Scope.provide` doesn't close the scope.
- A scope with 1e5 finalizers closes without overflowing.
- Below the cut line:
  - `"parallel"` runs finalizers at the same time (two 100 ms finalizers end
    at 100 ms), and combines their exits;
  - `scopedWith` passes the scope, and closes it;
  - `Scope.use` closes the scope with the effect's exit.

**Resources**
- `acquireRelease`:
  - the release runs when the scope closes, with the resource and the exit;
  - a failed acquire releases nothing;
  - an interrupt during acquire lets acquire finish, then the release runs,
    and the exit is the interrupt;
  - with `interruptible = true`, an interrupt stops acquire, and nothing is
    released;
  - resources are released in reverse order of acquisition;
  - a failing release is added to the cause.
- `acquireUseRelease`:
  - the release runs after `use` succeeds, fails or is interrupted;
  - `use` is interruptible, and acquire isn't.
- `addFinalizer` gets the exit.
- `forkScoped`: closing the scope interrupts the fiber, and waits for it. A
  fiber that ended earlier leaves no finalizer behind.
- `forkIn` on a closed scope gives an interrupted fiber that ran none of its
  code.

**forEach and all**
- One at a time by default:
  - `f` runs in order, only when the item's turn comes;
  - the results keep order, and carry `n`.
- The first failure stops the run: later items never start.
- 1e5 items, one at a time, don't overflow.
- Shape of the result:
  - nil results count in `n`;
  - `discard` returns nil;
  - an empty list gives `{ n = 0 }`;
  - `f` gets indexes that count from 1;
  - `list.n` sets the length.
- `concurrency = 2` never runs more than two at once. The results keep input
  order when items finish out of order. `"unbounded"` starts them all at once.
- A failure:
  - interrupts the running workers, and waits for their finalizers before
    failing;
  - a second worker's non-interrupt failure is added, with defects elected.
- Interrupting the parent interrupts every worker, and waits for them.
- Inside `uninterruptible`, a failing worker doesn't cut the others short.
- `f` throws on item 2 of the first batch, with `concurrency` of 2 or more.
  Item 1's worker is interrupted before it starts, since forks start on the
  next tick, so it runs none of its code. `forEach` fails with the Die once
  that worker has exited, instead of leaving it running.
- `f` throws during a later refill. The running workers are interrupted, and
  their finalizers run before `forEach` fails with the Die.
- An invalid `concurrency` is a defect.
- `all`:
  - a list gives the values, with `n`;
  - a record gives the same keys, and runs in sorted key order;
  - `t.n` marks a list;
  - `discard` and `concurrency` work.

## 24. Implementation order for M2

These make M2 done:

1. **The re-pin** (§17):
   - `Cause.electDefects`, `findRecoverableError` and the new `combine`;
   - defect election in `FinalizerResult` and `raceAll`;
   - the skip rule's handling of interrupts and Fails (§5.3);
   - `catchAll` on `findRecoverableError`;
   - updates to the M1 specs these change.
2. `Effect.exit`, `catchIf`, `catchTag` and `catchTags`.
3. `gen` (§9).
4. The context: `leffect.context`, `fiber.context`, inheritance in
   `forkUnsafe`, and the `SetContext` frame.
5. Scope, sequential only:
   - `Scope.make`, `makeUnsafe`, `addFinalizer`, `addFinalizerExit`, `close`,
     `fork` and `provide`;
   - `Effect.scope`, `scoped` and `addFinalizer`.
6. `acquireRelease`, `acquireUseRelease`, `forkIn` and `forkScoped`.
7. `forkUnsafe`'s `"inherit"`, then `forEach` (one at a time, then
   concurrently), then `all`.

Below the cut line, built last:

8. The `"parallel"` finalizer strategy.
9. `Effect.scopedWith` and `Scope.use`.

**Modules.**
- `leffect.context` is new and internal.
- `leffect.scope` is new and public, exported from `init.lua` as `Scope`.
- `core` gets `OP_GEN` and `exit`.
- `runtime` gets the `Gen` op and the `SetContext` frame.
- `leffect.effect` gets the rest.
- `init.lua` also exports `run` (§9).
- Every new module goes into the rockspec's `build.modules`.

## 25. M2 decisions taken on the user's behalf (2026-11-25)

The user picked option (a), a minimal fiber context for the Scope, and asked
for this design. These were decided here, and the user approved them with the
design on 2026-11-25.

21. **The context** is an immutable table keyed by strings, and internal until
    M3. Only `"leffect/Scope"` exists (§18).
22. **Context and scope frames are pushed directly** inside `withFiber`, never
    built as effects (§18, §19.4).
23. **`Leffect.run`** is `require("leffect").run`, the same function the gen
    body gets (§9).
24. **Lists from `forEach` and `all` carry `n`.** Indexes count from 1, and
    `all` sorts a record's keys (§22).
25. **`catchAll` keeps its name.** `catchIf`, `catchTag` and `catchTags` take
    an optional `orElse`, as in v4 (§21).
26. **Finalizer callbacks may return nil**, as `onExit`'s can (§14).
27. **`forkIn` and `forkScoped` take no options**, and their forks start on the
    next tick (§20.3).
28. **Running the release in the acquire-time context waits for M3** (§15).
29. **The cut line** (§24): the parallel strategy, `scopedWith` and
    `Scope.use` come last.
30. **`Effect.exit` is public**, and Scope uses it too (§21).
