-- The luv scheduler on a real luv loop (specifications/29-luv.md §29.7).
-- Pending when luv can't be loaded, unless LEFFECT_REQUIRE_LUV is set.
--
-- luv's default handler exits the process on an error inside a callback, so
-- callbacks here only record values; the specs assert after the loop
-- returns. Every spec leaves the default loop with no active handle.

local loaded, uv = pcall(require, "luv")

if not loaded then
  describe("luv scheduler, live", function()
    if os.getenv("LEFFECT_REQUIRE_LUV") then
      it("needs luv, because LEFFECT_REQUIRE_LUV is set", function()
        error("LEFFECT_REQUIRE_LUV is set, but luv can't be loaded: " .. tostring(uv))
      end)
    else
      pending("luv isn't installed", function() end)
    end
  end)
  return
end

local leffect = require("leffect")
local Cause = leffect.Cause
local Effect = leffect.Effect
local LuvScheduler = require("leffect.scheduler.luv")
local h = require("spec.helpers")

describe("luv scheduler, live", function()
  it("sleeps for at least the given time of uv.now()", function()
    local scheduler = LuvScheduler.new({ uv = uv })
    uv.update_time()
    local start = uv.now()
    local exit = scheduler:run(Effect.sleep(20):as("slept"))
    assert.are.equal("slept", h.valueOf(exit))
    assert.is_true(uv.now() - start >= 20)
  end)

  it("times out a slower effect, and ignores the callback that comes after", function()
    local scheduler = LuvScheduler.new({ uv = uv })
    local late = { fired = false }
    -- No canceler: the timer stays, so its resume comes after the timeout.
    local slow = Effect.async(function(resume)
      local timer = uv.new_timer()
      timer:start(60, 0, function()
        timer:close()
        late.fired = true
        resume(Effect.succeed("late"))
      end)
    end)
    local exit, fiber = scheduler:run(slow:timeout(10))
    local found, err = Cause.findError(h.causeOf(exit))
    assert.is_true(found)
    assert.are.equal("TimeoutError", err._tag)
    assert.is_false(late.fired)
    uv.run("default") -- until the late timer fires; nothing else is left
    assert.is_true(late.fired)
    assert.are.equal(exit, fiber.exit)
  end)

  it("delivers the exit to runCallback's onExit while uv.run runs", function()
    local scheduler = LuvScheduler.new({ uv = uv })
    local exits = {}
    Effect.runCallback(Effect.sleep(5):as("done"), {
      scheduler = scheduler,
      onExit = function(exit)
        exits[#exits + 1] = exit
      end,
    })
    uv.run("default")
    assert.are.equal(1, #exits)
    assert.are.equal("done", h.valueOf(exits[1]))
  end)

  it("lets a timer fire between the batches of a busy fiber", function()
    local scheduler = LuvScheduler.new({ uv = uv, maxOpsBeforeYield = 16 })
    local log = {}
    local items = {}
    for i = 1, 200 do
      items[i] = i
    end
    -- The fiber starts a 0 ms timer, then stays busy for many batches.
    local busy = Effect.sync(function()
      local timer = uv.new_timer()
      timer:start(0, 0, function()
        timer:close()
        log[#log + 1] = "timer"
      end)
    end)
      :flatMap(function()
        return Effect.forEach(items, function()
          return Effect.void
        end, { discard = true })
      end)
      :map(function()
        log[#log + 1] = "busy done"
      end)
    local exit = scheduler:run(busy)
    h.valueOf(exit)
    assert.are.same({ "timer", "busy done" }, log)
  end)
end)
