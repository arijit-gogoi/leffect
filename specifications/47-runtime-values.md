# Equality for the runtime's values

Part V (M5) of the [Leffect specifications](README.md).

## 47. Cause, Exit, Done and Context

Below the cut line. In v4, these values define `[Equal.symbol]` and
`[Hash.symbol]`. Each has its own metatable in Leffect, so under decision 66
they would compare by reference. M5 gives each the protocol of §44.3, as v4
does. This is the only change M5 makes to earlier modules.

### 47.1 Cause

Following `CauseImpl` and the reason classes (`internal/core.ts` 165, 264,
370; `internal/effect.ts` 129):
- **Two causes are equal** when they have the same number of reasons, and the
  reasons are equal in order.
- **Two reasons are equal** when they have the same `_tag`, and:
  - for Fail, their `error`s are equal;
  - for Die, their `defect`s are equal. **`trace` isn't compared**
    (decision 71). It records where the runtime caught the defect, so no two
    Dies from different places would ever be equal. v4 compares its
    `annotations` instead, which hold no stack;
  - for Interrupt, their `fiberId`s are `==`.
- **The hashes:** a reason hashes as `combine(string(_tag), hash(payload))`,
  with `fiberId` as an Interrupt's payload. A cause hashes as `Hash.array` of
  its reason hashes.

**`Cause.combine` dedupes under Equal,** as 4.1.5's `causeCombine` does
(§2.1). This closes the open question in §15:
- Reasons are grouped by hash, and a reason is dropped when an equal one is
  already in its group. The first of each set of equal reasons stays, in
  order, as today.
- If the result has the same reasons as the left cause, `combine` returns
  the left cause, as today.
- **`combine` must never raise,** because the run loop calls it (CLAUDE.md:
  the runtime never throws). A user `__equals` or `__hash` can raise. So
  `combine` hashes and compares under `pcall`. If either raises for a reason,
  that reason is compared with today's rule instead: the same table, or the
  same `_tag` and `==` payloads. v4 doesn't guard here (decision 72).

### 47.2 Exit

Exits are effects, and every effect shares one metatable. So the effect
metatable gets the protocol, and it first tells exits from other effects:
- **Two exits are equal** when they have the same `_tag`, and their values
  (Success) or causes (Failure) are equal, as v4's exit prototype does
  (`internal/core.ts` 560).
- **An exit hashes** as `combine(string(_tag), hash(value or cause))`.
- **Any other effect** compares by reference, and hashes with `Hash.random`.
  An exit never equals an effect that isn't an exit.

### 47.3 Done and Context

- **`Cause.Done`:** two Dones are equal when their values are equal. A Done
  hashes as `combine(string("Done"), hash(value))`.
- **Context** (`Context.ts` 637): two contexts are equal when they hold the
  same keys, and equal services under each key. A context hashes as
  `Hash.number` of its number of services, as in v4.
