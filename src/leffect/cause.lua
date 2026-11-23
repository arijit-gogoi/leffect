--- Cause: the full story of why an effect failed.
---
--- A cause is a tree. Its leaves are expected failures (`Fail`), defects
--- (`Die`) and interruptions (`Interrupt`). `Sequential` and `Parallel` join
--- causes that happened one after the other or at the same time. Queries walk
--- the leaves left to right, without recursion, so deep causes are safe.

---@class leffect.Cause.Fail
---@field _tag "Fail"
---@field error any The expected error, usually a tagged table.

---@class leffect.Cause.Die
---@field _tag "Die"
---@field defect any The thrown value; a traceback string for thrown strings.

---@class leffect.Cause.Interrupt
---@field _tag "Interrupt"
---@field fiberId any The fiber that requested the interruption.

---@class leffect.Cause.Sequential
---@field _tag "Sequential"
---@field left leffect.Cause
---@field right leffect.Cause

---@class leffect.Cause.Parallel
---@field _tag "Parallel"
---@field left leffect.Cause
---@field right leffect.Cause

---@alias leffect.Cause
---| leffect.Cause.Fail
---| leffect.Cause.Die
---| leffect.Cause.Interrupt
---| leffect.Cause.Sequential
---| leffect.Cause.Parallel

local getmetatable, setmetatable = getmetatable, setmetatable

local CauseMT = { __name = "leffect.Cause" }

local Cause = {}

---@param err any
---@return leffect.Cause.Fail
function Cause.fail(err)
  return setmetatable({ _tag = "Fail", error = err }, CauseMT)
end

---@param defect any
---@return leffect.Cause.Die
function Cause.die(defect)
  return setmetatable({ _tag = "Die", defect = defect }, CauseMT)
end

---@param fiberId any
---@return leffect.Cause.Interrupt
function Cause.interrupt(fiberId)
  return setmetatable({ _tag = "Interrupt", fiberId = fiberId }, CauseMT)
end

---@param left leffect.Cause
---@param right leffect.Cause
---@return leffect.Cause.Sequential
function Cause.sequential(left, right)
  return setmetatable({ _tag = "Sequential", left = left, right = right }, CauseMT)
end

---@param left leffect.Cause
---@param right leffect.Cause
---@return leffect.Cause.Parallel
function Cause.parallel(left, right)
  return setmetatable({ _tag = "Parallel", left = left, right = right }, CauseMT)
end

---@param value any
---@return boolean
function Cause.isCause(value)
  return getmetatable(value) == CauseMT
end

-- Both walks below go down the left spine and keep the right branches on an
-- explicit stack, so leaves are visited left to right without recursion.

--- Returns the first leaf, left to right, whose tag is `tag`, or nil.
---@param cause leffect.Cause
---@param tag string
---@return leffect.Cause?
local function findLeaf(cause, tag)
  local nodeTag = cause._tag
  if nodeTag ~= "Sequential" and nodeTag ~= "Parallel" then
    -- A single leaf, the common case: no stack needed.
    if nodeTag == tag then
      return cause
    end
    return nil
  end
  local node, stack, top = cause, {}, 0
  while true do
    nodeTag = node._tag
    if nodeTag == "Sequential" or nodeTag == "Parallel" then
      top = top + 1
      stack[top] = node.right
      node = node.left
    elseif nodeTag == tag then
      return node
    elseif top == 0 then
      return nil
    else
      node = stack[top]
      stack[top] = nil
      top = top - 1
    end
  end
end

--- Collects `leaf[field]` for every leaf whose tag is `tag`, left to right.
---@param cause leffect.Cause
---@param tag string
---@param field string
---@return any[] values
---@return integer count
local function collect(cause, tag, field)
  local values, count = {}, 0
  local node, stack, top = cause, {}, 0
  while true do
    local nodeTag = node._tag
    if nodeTag == "Sequential" or nodeTag == "Parallel" then
      top = top + 1
      stack[top] = node.right
      node = node.left
    else
      if nodeTag == tag then
        count = count + 1
        values[count] = node[field]
      end
      if top == 0 then
        return values, count
      end
      node = stack[top]
      stack[top] = nil
      top = top - 1
    end
  end
end

--- Returns the errors of all `Fail` leaves, left to right, and their count.
--- The count matters when an error is nil.
---@param cause leffect.Cause
---@return any[] errors
---@return integer count
function Cause.failures(cause)
  return collect(cause, "Fail", "error")
end

--- Returns the defects of all `Die` leaves, left to right, and their count.
---@param cause leffect.Cause
---@return any[] defects
---@return integer count
function Cause.defects(cause)
  return collect(cause, "Die", "defect")
end

--- Returns `true, error` for the first `Fail` leaf, or `false` if there is none.
---@param cause leffect.Cause
---@return boolean found
---@return any error
function Cause.findError(cause)
  local leaf = findLeaf(cause, "Fail")
  if leaf then
    return true, leaf.error
  end
  return false, nil
end

--- Returns `true, defect` for the first `Die` leaf, or `false` if there is none.
---@param cause leffect.Cause
---@return boolean found
---@return any defect
function Cause.findDefect(cause)
  local leaf = findLeaf(cause, "Die")
  if leaf then
    return true, leaf.defect
  end
  return false, nil
end

--- True if the cause contains an expected failure.
---@param cause leffect.Cause
---@return boolean
function Cause.isFailure(cause)
  return findLeaf(cause, "Fail") ~= nil
end

--- True if the cause contains a defect.
---@param cause leffect.Cause
---@return boolean
function Cause.isDie(cause)
  return findLeaf(cause, "Die") ~= nil
end

--- True if the cause contains an interruption.
---@param cause leffect.Cause
---@return boolean
function Cause.isInterrupted(cause)
  return findLeaf(cause, "Interrupt") ~= nil
end

--- True if every leaf of the cause is an interruption.
---@param cause leffect.Cause
---@return boolean
function Cause.isInterruptedOnly(cause)
  return findLeaf(cause, "Fail") == nil and findLeaf(cause, "Die") == nil
end

--- Reduces a cause to a single value to throw: the first error, else the first
--- defect, else a message saying the fiber was interrupted (as Effect TS does).
---@param cause leffect.Cause
---@return any
function Cause.squash(cause)
  local found, value = Cause.findError(cause)
  if found then
    return value
  end
  found, value = Cause.findDefect(cause)
  if found then
    return value
  end
  return "All fibers interrupted without error"
end

return Cause
