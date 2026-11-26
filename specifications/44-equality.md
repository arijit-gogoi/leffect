# Equality: the shared model, and Equal

Part V (M5) of the [Leffect specifications](README.md).

## 44. Equal and Hash: the shared model

M5 builds structural equality and hashing, from CLAUDE.md's Later list. It
follows 4.1.5's `Equal.ts` and `Hash.ts`, with their helpers in
`internal/equal.ts` and `internal/hash.ts`. Neither module imports anything
from the runtime. They need no fiber, scheduler or Context, so M5 depends on
no earlier Part (decision 65). Below the cut line, Cause, Exit, `Cause.Done`
and Context get their own equality (§47).

- **Equal** (§45) answers whether two values are equal: `Equal.equals(a, b)`.
- **Hash** (§46) gives a value a number such that equal values get equal
  numbers: `Hash.hash(v)`.

Every check in `Equal.equals` starts by comparing hashes, as in v4. So a type
that defines its own equality must define a matching hash.

### 44.1 How each kind of value compares

| Value | Equal when | Hash |
|---|---|---|
| nil, booleans, strings | `rawequal` | from the value (§46.2) |
| numbers | `==`, so `1` equals `1.0` and `-0.0` equals `0`. NaN equals NaN, as in v4 | from the value, so `1` and `1.0` hash alike |
| functions, coroutines, light userdata | `rawequal` (v4: functions by reference) | a number given to this value once (`Hash.random`) |
| a table or full userdata whose metatable has `__equals` | its `__equals` decides. If only one side has `__equals`, they aren't equal | its metatable's `__hash` |
| any other table or userdata with a metatable | `rawequal` (decision 66) | `Hash.random` |
| a plain table (no metatable) | structurally (§44.2) | structurally (§46.3) |
| a plain table passed to `Equal.byReferenceUnsafe` | `rawequal` | `Hash.random` |

Values of different Lua types are never equal. In Lua 5.4, `1` and `1.0` are
both of type `"number"`, so they compare by value.

### 44.2 Structural equality of plain tables

Two plain tables are equal when they have the same keys, and each key's
values are equal. This is v4's comparison of records and Maps, merged,
because a Lua table is both:
- **The entry counts must match.** Counting uses `pairs`, so the array part
  and the hash part count alike. `{ 1, 2 }` equals `{ [1] = 1, [2] = 2 }`.
- **A key that compares by identity** is looked up with `rawget`. Numbers,
  strings, booleans, functions, and tables with a metatable but no
  `__equals` are such keys. A float key that is a whole number is the same
  key as the integer, as Lua stores it.
- **A key that compares structurally** is a plain table, or a value with
  `__equals`. Such keys are matched one to one, within groups of equal key
  hashes, as v4 matches the entries of a Map (`compareHashed`). For example,
  `{ [{ 1 }] = "a" }` equals `{ [{ 1 }] = "a" }`, though the two keys are
  different tables.
- **The metatable isn't compared,** since both tables have none.
- **Lists with a field `n`** need nothing special. `n` is a key like any
  other.

**Cycles.** Equality is coinductive, as in v4. While comparing a pair, a
repeat of a pair already on the path counts as equal. So two tables that each
hold themselves are equal.

### 44.3 Where the protocol lives

A type defines its equality and hash as fields of its metatable, like Lua's
own `__eq` and `__tostring` (decision 67):

```lua
local PointMT = {
  __equals = function(self, that)
    return self.x == that.x and self.y == that.y
  end,
  __hash = function(self)
    return Hash.combine(Hash.number(self.x), Hash.number(self.y))
  end,
}
```

- The fields are read with `rawget` on the metatable, never through
  `__index`, so looking for them runs no code. v4 looks for a property
  (`hasProperty`), which a getter could intercept.
- `Equal.symbol` is `"__equals"`, and `Hash.symbol` is `"__hash"`. So
  `mt[Equal.symbol] = f` works, as `[Equal.symbol]` does in v4.
- `__equals(self, that)` is called only after the two hashes match, and only
  when both sides have `__equals`. It's called on the first argument's
  metatable.
- **Lua's `__eq` isn't used.** `Equal.equals` never calls `==` on two tables.
  Its result doesn't depend on whether both tables share one `__eq`, a rule
  that LuaJIT and Lua 5.4 apply differently.
- A plain table can't carry the protocol, because it has no metatable. In v4,
  a plain object can carry `[Equal.symbol]` as an own property (§14).

### 44.4 Caches

v4 keeps two caches across calls, in WeakMaps:
- each object's hash;
- each outermost pair's equality result.

So v4 says an object must not change after its first hash or comparison.
Plain Lua tables are the everyday mutable container, so Leffect doesn't keep
either cache across calls (decision 68):
- **Within one top-level call** of `Equal.equals` or `Hash.hash`, each
  table's hash is computed once, then reused. This keeps comparing nested
  tables linear, since each level checks hashes first.
- **The memo is dropped when the call returns.** So `t` may change between
  two calls, and the second call sees the change.
- `Hash.random` does keep its numbers across calls, in a table with weak
  keys. It has to, since the number stands for the value's identity.

### 44.5 Errors

- On built-in values, `Equal.equals` and `Hash.hash` never raise, and always
  end, cycles included.
- A raising `__equals` or `__hash` propagates out of the top-level call. The
  call first clears its path and memo, so the next call starts clean. v4 does
  the same with `try`/`finally`.

## 45. Equal

`leffect.equal`, exported as `Equal`:

| Function | Semantics |
|---|---|
| `Equal.equals(a, b)` | Whether `a` and `b` are equal (§44.1). Never raises on built-in values. |
| `Equal.isEqual(v)` | Whether `v` is a table or userdata whose metatable has a function `__equals`. |
| `Equal.symbol` | `"__equals"`, the metatable field (§44.3). |
| `Equal.asEquivalence()` | Returns `Equal.equals`, as a two-argument function. |
| `Equal.byReferenceUnsafe(t)` | Marks the plain table `t` to compare by reference, and returns `t`. The mark is kept in a table with weak keys. |

- **`equals` takes exactly two arguments.** v4's `equals(that)` returns a
  predicate when given one argument. In Lua, `equals(x)` can't be told from
  `equals(x, nil)`, and nil is a value (§14).
- **The order of checks** follows v4's `compareBoth`:
  1. `rawequal(a, b)` gives true.
  2. Different types give false.
  3. Two NaNs give true.
  4. Any other pair that isn't two tables or two full userdata gives false.
  5. A table marked by `byReferenceUnsafe` on either side gives false.
  6. For two tables or two userdata, §44.1 decides. Before a structural
     comparison or a call to `__equals`, different hashes give false.
- **Not provided:**
  - `byReference`, which in v4 wraps the object in a Proxy. Lua has no
    transparent proxy: `pairs` and `#` wouldn't see through one on LuaJIT;
  - `makeCompareSet` and `makeCompareMap`, which take iterables, until a
    HashSet or HashMap needs them (§15).
