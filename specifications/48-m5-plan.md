# M5 specs, implementation order and decisions

Part V (M5) of the [Leffect specifications](README.md).

## 48. Specs for M5

Write these before the code, in new files `spec/hash_spec.lua` and
`spec/equal_spec.lua`. Below the cut line, the specs of §47 extend
`spec/cause_spec.lua`, `exit_spec.lua` and `context_spec.lua`. No earlier
spec changes.

**Hash** (§46)
- **Golden values.** A fixed corpus hashes to fixed numbers, written in the
  spec. Busted runs it on both runtimes, so LuaJIT and Lua 5.4 must agree.
  The corpus:
  - `""`, `"a"`, `"hello"`, a string with `"\0"` and one with bytes above 127;
  - `0`, `1`, `-1`, `2^31 - 1`, `2^53 - 1`, `2^53`, `0.5`, `-0.1`;
  - `true`, `false`, nil;
  - `{}`, `{ 1, 2, 3 }`, `{ a = 1 }`;
  - `Hash.combine(1, 2)` and `Hash.combine(2, 1)`.
- Every hash is an integer from 0 to 2^31 − 2.
- **Numbers:**
  - `1` and `1.0` hash alike, and so do `-0.0` and `0`;
  - NaN, `math.huge` and `-math.huge` each have one hash;
  - a negative whole number hashes into range;
  - on Lua 5.4, `2^60` as an integer and as a float hash alike.
- `Hash.random` gives a value the same number on every call, and two tables
  different numbers.
- `{ 1, 2 }` and `{ [2] = 2, [1] = 1 }` hash alike, whatever order `pairs`
  takes. `Hash.array({ 1, 2 })` differs from `Hash.array({ 2, 1 })`.
- `Hash.array` honours a list's `n`, nil items included.
- A table with a metatable but no `__hash` hashes with `Hash.random`. A table
  with `__hash` returns what `__hash` returns. A `__hash` that returns a
  non-number raises.
- **Cycles:** a table that holds itself hashes, and so do two tables that
  hold each other.
- **No cache across calls:** change a table between two calls, and the second
  hash reflects the change.

**Equal** (§44, §45)
- Primitives: equal strings, numbers and booleans; `1` and `1.0`; NaN and
  NaN; `-0.0` and `0`. Different types are never equal, `"1"` and `1`
  included.
- Functions and coroutines compare by reference.
- **Plain tables compare structurally:**
  - nested tables;
  - an array and its equivalent record;
  - different entry counts;
  - a missing key;
  - lists with `n`.
- **Table keys** match structurally: `{ [{ 1 }] = "a" }` equals
  `{ [{ 1 }] = "a" }`, and not `{ [{ 1 }] = "b" }`. Several keys whose hashes
  collide still match one to one.
- **Metatables:**
  - two tables with the same metatable and no `__equals` are equal only if
    they are the same table;
  - `__equals` decides when both sides have it, and only after the hashes
    match;
  - one side with `__equals` and one without gives false;
  - `__eq` is never called.
- `byReferenceUnsafe` makes a plain table compare by reference.
- **Cycles:** two tables that each hold themselves are equal, and a cycle
  with a different value inside is not.
- **No cache across calls:** compare, change one table, and compare again.
  The second result reflects the change.
- **Errors:** a raising `__equals` propagates, and the next call works.
- A deep chain of 10,000 nested tables compares and hashes without
  overflowing the stack, and in linear time. If recursion can't reach that
  depth on both runtimes, the depth is lowered to the largest one that
  passes, and the spec records it.
- `asEquivalence()` returns `equals`. `isEqual` and `isHash` check the
  metatable.

**Below the cut line** (§47)
- **Cause:**
  - equal causes, in order;
  - Dies with equal defects and different traces are equal;
  - Interrupts compare by fiber ID.
- **`Cause.combine`:**
  - drops a Fail whose error is a different but equal table;
  - keeps the first of each set, in order;
  - returns the left cause when nothing is added;
  - a raising `__equals` on an error neither raises nor drops anything.
- **Exit:** equal Successes and Failures; a Success never equals a Failure;
  an exit never equals another effect; two equal effects that aren't exits
  compare by reference.
- **Done and Context:** as in §47.3.

## 49. Implementation order for M5

These make M5 done:

1. **`leffect.hash`** (§46): `mulmod`, `mix`, `combine`, `string`, `number`,
   `random`, then `hash` with `structure`, `structureKeys`, `array`, the
   per-call memo and cycles.
2. **`leffect.equal`** (§44, §45): `equals` with the path for cycles, key
   matching by hash group, `isEqual`, `asEquivalence` and
   `byReferenceUnsafe`.

Below the cut line, built last:

3. Cause's protocol, then `Cause.combine` under Equal (§47.1).
4. Exit's protocol on the effect metatable (§47.2).
5. `Cause.Done`'s and Context's protocols (§47.3).

**Modules.**
- **New public modules:** `leffect.hash` and `leffect.equal`. `init.lua`
  exports them as `Hash` and `Equal`.
- **Changed modules, below the cut line:** `leffect.cause`, `leffect.core`
  (the effect metatable) and `leffect.context`.
- **The rockspec:** `build.modules` gets the new modules. There is no new
  dependency.

**Once M5 is built:**
- label §11's invariants and §14's rows "(M5)" instead of "(M5 design)";
- remove the §15 question on structural dedupe, if step 3 is built;
- update CLAUDE.md's Layout and the README's status line.

## 50. M5 decisions taken on the user's behalf (2026-11-26)

On 2026-11-26 the user asked for the next item from the Later list: "Choose
one that depends on the least number of Parts/milestones." These choices
were made here, and wait for the user's approval.

65. **Equal and Hash come next, as M5.** Of the Later items, they alone
    import nothing from the runtime (§44). The others need more:
    - Schedule needs a Clock;
    - Clock and Random are services, so they need Context (Part III);
    - logging and tracing need the fiber context and a clock.

    Calling this M5 follows the milestone numbering. Equivalence and Data are
    left out (§15).
66. **A table with a metatable compares by reference,** unless its metatable
    has `__equals` (§44.1). In v4, class instances without `Equal` compare
    structurally, Ref and Fiber included. In Leffect, every runtime object
    (fibers, scopes, schedulers, queues, Refs) is such a table. Its fields
    reach closures, waitlists, schedulers and cycles. Comparing them
    structurally would be slow, and wrong as soon as they change. Plain
    tables compare structurally, as v4's plain objects and arrays do.

    The other choice: compare every table structurally, and require the same
    metatable. That is closer to v4, but makes `Equal.equals(fiberA,
    fiberB)` walk both fibers.
67. **The protocol is `__equals` and `__hash` on the metatable** (§44.3), read
    with `rawget`. This is the Lua idiom (`__eq`, `__tostring`), and the
    lookup runs no code. `Equal.symbol` and `Hash.symbol` name the fields.
68. **No cache across calls** (§44.4). v4 caches hashes and outermost results
    across calls, and says an object must not change after its first hash or
    comparison. Lua code changes plain tables all the time, so Leffect
    memoizes only within one top-level call. Results are then always
    current. The cost is a new walk on each call.

    The other choice: cache across calls in weak tables, with v4's warning.
69. **Hashing uses plain arithmetic mod 2^31 − 1** (§46.1). The common subset
    has no bitwise operators. One code path gives the same values on LuaJIT
    and Lua 5.4. Hash values differ from v4's, which can't be matched anyway.

    The other choice: LuaJIT's `bit` library, and a chunk with native
    operators loaded on 5.4. That is faster, but has two code paths to keep
    identical.
70. **`Hash.random` counts instead of drawing** (§46.2). It never touches
    `math.random`'s state, and specs are repeatable.
71. **A Die's `trace` isn't part of its equality** (§47.1).
72. **`Cause.combine` guards user methods with `pcall`** (§47.1). The run loop
    calls it, and the runtime never throws.
73. **Left out of v4's API** (§45, §46): the one-argument `equals`,
    `byReference`, `makeCompareSet`, `makeCompareMap` and `Hash.optimize`.
74. **The cut line** (§49). Equality for Cause, Exit, `Cause.Done` and
    Context comes last. Equal and Hash stand without it.
