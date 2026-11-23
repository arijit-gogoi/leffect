--- The run loop.
---
--- A `while` loop over an explicit continuation stack. It descends through
--- combinators, pushing them as frames, until it reaches a leaf instruction.
--- It evaluates the leaf to an outcome, then pops frames until one supplies
--- the next effect. It never recurses, so chains of any depth are safe.
---
--- Every call into user code goes through `xpcall(f, debug.traceback, arg)`.
--- A throw becomes a defect (`Die`) carrying the traceback, and the loop
--- unwinds it like any other failure. The loop never mutates effect tables,
--- so one effect can be run many times.

local Cause = require("leffect.cause")
local core = require("leffect.core")

local getmetatable, pcall, tostring, type, xpcall = getmetatable, pcall, tostring, type, xpcall
local traceback = debug.traceback

local EffectMT = core.EffectMT
local OP_SUCCESS = core.OP_SUCCESS
local OP_FAILURE = core.OP_FAILURE
local OP_SYNC = core.OP_SYNC
local OP_MAP = core.OP_MAP
local OP_ON_SUCCESS = core.OP_ON_SUCCESS
local OP_ON_FAILURE = core.OP_ON_FAILURE
local exitSucceed, exitFailCause = core.exitSucceed, core.exitFailCause
local die = Cause.die

---@param value any
---@return leffect.Cause.Die
local function invalidEffect(value)
  -- A broken __tostring must not make the loop throw.
  local ok, text = pcall(tostring, value)
  if not ok or type(text) ~= "string" then
    text = type(value)
  end
  return die("Not a valid effect: " .. text)
end

---@param effect leffect.Effect
---@return leffect.Exit
local function runLoop(effect)
  local stack, top = {}, 0 ---@type leffect.Instruction[], integer
  local current = effect --[[@as leffect.Instruction]]

  while true do
    -- Descend: push continuation frames until a leaf instruction.
    local op
    while true do
      if getmetatable(current) ~= EffectMT then
        op = nil
        break
      end
      op = current._op
      if op == OP_MAP or op == OP_ON_SUCCESS or op == OP_ON_FAILURE then
        top = top + 1
        stack[top] = current
        current = current.first
      else
        break
      end
    end

    -- Evaluate the leaf: success with `value`, or failure with `cause`.
    local isSuccess, value, cause
    if op == OP_SUCCESS then
      isSuccess, value = true, current.value
    elseif op == OP_FAILURE then
      isSuccess, cause = false, current.cause
    elseif op == OP_SYNC then
      local ok, result = xpcall(current.thunk, traceback)
      if ok then
        isSuccess, value = true, result
      else
        isSuccess, cause = false, die(result)
      end
    else
      isSuccess, cause = false, invalidEffect(current)
    end

    -- Unwind: pop frames until one supplies the next effect.
    local resumed = false
    while top > 0 and not resumed do
      local frame = stack[top]
      stack[top] = nil
      top = top - 1
      local frameOp = frame._op
      if isSuccess then
        if frameOp == OP_MAP then
          local ok, result = xpcall(frame.f, traceback, value)
          if ok then
            value = result
          else
            isSuccess, cause = false, die(result)
          end
        elseif frameOp == OP_ON_SUCCESS then
          local ok, result = xpcall(frame.f, traceback, value)
          if ok then
            current, resumed = result, true
          else
            isSuccess, cause = false, die(result)
          end
        end
      elseif frameOp == OP_ON_FAILURE then
        local ok, result = xpcall(frame.f, traceback, cause)
        if ok then
          current, resumed = result, true
        else
          cause = die(result)
        end
      end
    end

    if not resumed then
      if isSuccess then
        return exitSucceed(value)
      end
      return exitFailCause(cause)
    end
  end
end

local runtime = {}

--- Runs `effect` on the current stack and returns its Exit. An Exit is
--- returned as is. Never throws.
---@param effect leffect.Effect
---@return leffect.Exit
function runtime.runSyncExit(effect)
  if core.isExit(effect) then
    return effect --[[@as leffect.Exit]]
  end
  return runLoop(effect)
end

return runtime
