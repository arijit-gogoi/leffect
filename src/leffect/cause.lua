--- Cause: the full story of why an effect failed.
---
--- As in Effect v4, a cause is a flat list of reasons, in the order they
--- happened. A reason is an expected failure (`Fail`), a defect (`Die`) or an
--- interruption (`Interrupt`).

---@class leffect.Cause.Fail
---@field _tag "Fail"
---@field error any The expected error, usually a tagged table.

---@class leffect.Cause.Die
---@field _tag "Die"
---@field defect any The thrown value, unchanged.
---@field trace string? The traceback captured where the runtime caught it.

---@class leffect.Cause.Interrupt
---@field _tag "Interrupt"
---@field fiberId integer? The fiber that requested the interruption, if any.

---@alias leffect.Cause.Reason leffect.Cause.Fail|leffect.Cause.Die|leffect.Cause.Interrupt

---@class leffect.Cause
---@field reasons leffect.Cause.Reason[]

---An error value created by the runtime: a tagged table with a message.
---@class leffect.RuntimeError
---@field _tag string
---@field message string

---@class leffect.AsyncFiberError : leffect.RuntimeError
---@field fiber table The fiber that didn't finish.

local getmetatable, setmetatable = getmetatable, setmetatable

local CauseMT = { __name = "leffect.Cause" }

local Cause = {}

---@param reasons leffect.Cause.Reason[]
---@return leffect.Cause
local function make(reasons)
  return setmetatable({ reasons = reasons }, CauseMT)
end

--- The cause with no reasons. Combining with it changes nothing.
Cause.empty = make({})

---@param err any
---@return leffect.Cause
function Cause.fail(err)
  return make({ { _tag = "Fail", error = err } })
end

---@param defect any
---@param trace string?
---@return leffect.Cause
function Cause.die(defect, trace)
  return make({ { _tag = "Die", defect = defect, trace = trace } })
end

---@param fiberId integer?
---@return leffect.Cause
function Cause.interrupt(fiberId)
  return make({ { _tag = "Interrupt", fiberId = fiberId } })
end

--- A cause holding a copy of `reasons`, duplicates included.
---@param reasons leffect.Cause.Reason[]
---@return leffect.Cause
function Cause.fromReasons(reasons)
  local copy = {}
  for i = 1, #reasons do
    copy[i] = reasons[i]
  end
  return make(copy)
end

---@param value any
---@return boolean
function Cause.isCause(value)
  return getmetatable(value) == CauseMT
end

---@param cause leffect.Cause
---@return boolean
function Cause.isEmpty(cause)
  return cause.reasons[1] == nil
end

--- Two reasons are the same if they are one table, or have the same tag and
--- raw-equal payloads.
---@param a table
---@param b table
---@return boolean
local function sameReason(a, b)
  if a == b then
    return true
  end
  local tag = a._tag
  if tag ~= b._tag then
    return false
  elseif tag == "Fail" then
    return a.error == b.error
  elseif tag == "Die" then
    return a.defect == b.defect
  end
  return a.fiberId == b.fiberId
end

--- The reasons of `left`, followed by those of `right` that `left` doesn't
--- already have (v4's `causeCombine`). Returns `left` when `right` adds nothing.
---@param left leffect.Cause
---@param right leffect.Cause
---@return leffect.Cause
function Cause.combine(left, right)
  local a, b = left.reasons, right.reasons
  local na, nb = #a, #b
  if na == 0 then
    return right
  elseif nb == 0 then
    return left
  end
  local merged, n = {}, na
  for i = 1, na do
    merged[i] = a[i]
  end
  for j = 1, nb do
    local reason = b[j]
    local seen = false
    for i = 1, n do
      if sameReason(merged[i], reason) then
        seen = true
        break
      end
    end
    if not seen then
      n = n + 1
      merged[n] = reason
    end
  end
  if n == na then
    return left
  end
  return make(merged)
end

---@param cause leffect.Cause
---@param tag string
---@param field string
---@return any[] values
---@return integer count
local function collect(cause, tag, field)
  local values, count = {}, 0
  local reasons = cause.reasons
  for i = 1, #reasons do
    local reason = reasons[i]
    if reason._tag == tag then
      count = count + 1
      values[count] = reason[field]
    end
  end
  return values, count
end

---@param cause leffect.Cause
---@param tag string
---@return table?
local function find(cause, tag)
  local reasons = cause.reasons
  for i = 1, #reasons do
    local reason = reasons[i]
    if reason._tag == tag then
      return reason
    end
  end
  return nil
end

--- Returns the errors of all `Fail` reasons, in order, and their count. The
--- count matters when an error is nil.
---@param cause leffect.Cause
---@return any[] errors
---@return integer count
function Cause.failures(cause)
  return collect(cause, "Fail", "error")
end

--- Returns the defects of all `Die` reasons, in order, and their count.
---@param cause leffect.Cause
---@return any[] defects
---@return integer count
function Cause.defects(cause)
  return collect(cause, "Die", "defect")
end

--- Returns the distinct IDs of the fibers that interrupted, in order.
---@param cause leffect.Cause
---@return integer[]
function Cause.interruptors(cause)
  local ids, n, seen = {}, 0, {}
  local reasons = cause.reasons
  for i = 1, #reasons do
    local reason = reasons[i]
    if reason._tag == "Interrupt" then
      local id = reason.fiberId
      if id ~= nil and not seen[id] then
        seen[id] = true
        n = n + 1
        ids[n] = id
      end
    end
  end
  return ids
end

--- Returns `true, error` for the first `Fail` reason, or `false` if there is none.
---@param cause leffect.Cause
---@return boolean found
---@return any error
function Cause.findError(cause)
  local reason = find(cause, "Fail")
  if reason then
    return true, reason.error
  end
  return false, nil
end

--- Returns `true, defect` for the first `Die` reason, or `false` if there is none.
---@param cause leffect.Cause
---@return boolean found
---@return any defect
function Cause.findDefect(cause)
  local reason = find(cause, "Die")
  if reason then
    return true, reason.defect
  end
  return false, nil
end

--- True if the cause has an expected failure.
---@param cause leffect.Cause
---@return boolean
function Cause.hasFails(cause)
  return find(cause, "Fail") ~= nil
end

--- True if the cause has a defect.
---@param cause leffect.Cause
---@return boolean
function Cause.hasDies(cause)
  return find(cause, "Die") ~= nil
end

--- True if the cause has an interruption.
---@param cause leffect.Cause
---@return boolean
function Cause.hasInterrupts(cause)
  return find(cause, "Interrupt") ~= nil
end

--- True if the cause has at least one reason, and every reason is an
--- interruption.
---@param cause leffect.Cause
---@return boolean
function Cause.hasInterruptsOnly(cause)
  local reasons = cause.reasons
  local n = #reasons
  if n == 0 then
    return false
  end
  for i = 1, n do
    if reasons[i]._tag ~= "Interrupt" then
      return false
    end
  end
  return true
end

--- Reduces a cause to a single value to throw, as Effect TS does: the first
--- error, else the first defect, else a message about interruption, else a
--- message about the empty cause.
---@param cause leffect.Cause
---@return any
function Cause.squash(cause)
  local reason = find(cause, "Fail")
  if reason then
    return reason.error
  end
  reason = find(cause, "Die")
  if reason then
    return reason.defect
  end
  if find(cause, "Interrupt") then
    return "All fibers interrupted without error"
  end
  return "Empty cause"
end

local ErrorMT = {
  __name = "leffect.RuntimeError",
  __tostring = function(err)
    return err._tag .. ": " .. err.message
  end,
}

--- The error `Effect.timeout` fails with.
---@param message string?
---@return leffect.RuntimeError
function Cause.TimeoutError(message)
  return setmetatable(
    { _tag = "TimeoutError", message = message or "Operation timed out" },
    ErrorMT
  )
end

--- The defect `Effect.runSync` dies with when the effect doesn't finish
--- synchronously.
---@param fiber table The fiber that didn't finish.
---@return leffect.AsyncFiberError
function Cause.AsyncFiberError(fiber)
  return setmetatable({
    _tag = "AsyncFiberError",
    message = "An asynchronous effect was executed with Effect.runSync",
    fiber = fiber,
  }, ErrorMT)
end

return Cause
