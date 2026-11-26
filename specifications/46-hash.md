# Hash

Part V (M5) of the [Leffect specifications](README.md).

## 46. Hash

`leffect.hash`, exported as `Hash`.

| Function | Semantics |
|---|---|
| `Hash.hash(v)` | The hash of any value (§44.1). Equal values get equal hashes. |
| `Hash.symbol` | `"__hash"`, the metatable field (§44.3). |
| `Hash.isHash(v)` | Whether `v` is a table or userdata whose metatable has a function `__hash`. |
| `Hash.random(v)` | A number given to `v` the first time, then the same number for as long as `v` lives. |
| `Hash.combine(a, b)` | Combines two hashes, in order. |
| `Hash.number(n)` | The hash of a number. |
| `Hash.string(s)` | The hash of a string. |
| `Hash.array(list)` | The hash of `list[1]` to `list[list.n or #list]`, in order. |
| `Hash.structure(t)` | The hash of every entry of `t`, in any order. |
| `Hash.structureKeys(t, keys)` | The hash of the entries of `t` under the keys in the list `keys`, in any order. |

v4's `optimize` is left out. It keeps hashes inside V8's small integers, and
Leffect's hashes are already small (§46.1).

### 46.1 Arithmetic

The common subset has no bitwise operators (CLAUDE.md), so v4's MurmurHash
finalizer and its `Math.imul` can't be written portably. Leffect hashes with
plain arithmetic instead (decision 69):
- **Every hash is an integer from 0 to P − 1,** with P = 2^31 − 1 =
  2147483647, a prime.
- **Every intermediate value is a non-negative integer below 2^53,** so
  doubles hold it exactly, on LuaJIT as on Lua 5.4.
- **Values are reduced with `math.fmod`,** never `%`. LuaJIT computes `a % b`
  as `a - floor(a / b) * b`, which isn't exact for large `a`.
- **`mulmod(a, b)`,** for `a` and `b` below P, splits `a` into
  `ah * 65536 + al`. It returns
  `fmod(fmod(ah * b, P) * 65536 + al * b, P)`. No product reaches 2^48.
- One code path serves both runtimes, so a value has the same hash on both.
  v4's numbers can't be matched anyway: it hashes strings by UTF-16 code
  unit, and Lua strings are bytes (§14).

The functions, with K1 = 506952114, K2 = 99338860, K3 = 1119006262 and
C = 1831565813, each below P:

```
mix(h)         = mulmod(fmod(h + C, P), K3)
combine(a, b)  = mix(fmod(mulmod(a, K1) + mulmod(b, K2), P))
string(s)      = h = 5381; for each byte c of s, in order:
                 h = fmod(h * 33 + c, P)
```

K1, K2 and K3 are v4's constants `0x9e3779b1`, `0x85ebca6b` and `0xc2b2ae35`,
reduced mod P.

### 46.2 Values

- **Numbers** (`Hash.number`):
  - A whole number whose magnitude is below 2^53 hashes to
    `fmod(n, P)`, plus P if that is negative. So `1` and `1.0` hash alike,
    and so do `-0.0` and `0`. On Lua 5.4 the result is an integer.
  - NaN, `math.huge` and `-math.huge` hash as the strings `"NaN"`,
    `"Infinity"` and `"-Infinity"`, as `String(n)` reads in v4. `fmod` of an
    infinity is NaN, so infinities never take the first path.
  - Any other number hashes as the string `string.format("%.17g", n)`. That
    covers fractions, and whole numbers of magnitude 2^53 or more. A Lua 5.4
    integer of that size goes the same way, so it hashes like the float it
    equals.
  - `math.type` isn't used, since LuaJIT lacks it.
- **Strings** hash by bytes (§46.1). `"\0"` and bytes above 127 are bytes like
  any other.
- **Booleans and nil** hash as the strings `"true"`, `"false"` and `"nil"`,
  then `mix`, as v4 hashes `String(v)`.
- **Functions, coroutines and userdata without `__hash`** get
  `Hash.random(v)`, and so do tables with a metatable but no `__hash`.
  `Hash.random` numbers values from a counter, then applies `mix` (decision
  70). v4 uses `Math.random`, and the number only has to stay the same for
  the value. A counter doesn't touch `math.random`'s state, and makes failing
  specs repeatable.

### 46.3 Tables

- **A plain table** hashes with `Hash.structure`. It starts at 12289, and
  adds `combine(hash(k), hash(v))` for each entry, mod P. Addition doesn't
  depend on the order, and `pairs` has none. v4 uses `^` there, for the same
  reason.
- **`Hash.array`** starts at 6151, and folds `combine(h, hash(item))` over
  the items in order, as v4 does.
- **A table with `__hash`** returns what `__hash(t)` returns. It must be a
  number. Anything else raises, naming the metatable's `__name` if it has
  one.
- **Cycles.** A table met again while it is being hashed hashes as the string
  `"[Circular]"`, as in v4. A table whose hash went through such a back edge
  depends on where the walk entered. So it isn't memoized, even within the
  call (v4's `backEdges`).
