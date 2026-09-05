-- The alias is the only place the sensitivity outcomes become sentences a
-- player reads. Everything else here can be right and a player still be told
-- the wrong thing, because the mapping is string comparisons written by hand:
-- mistype one and it falls through to the next branch with every other spec
-- still green. That is not the bug this change fixes - the comparisons are new
-- here - but it is the way this change would come undone.
--
-- busted sandboxes a spec chunk's own globals, so everything the dofile'd
-- alias reads has to be set through _G explicitly.
local printed

_G.cecho = function(text) printed[#printed + 1] = text end
_G.echo = function(text) printed[#printed + 1] = text end

local function runAlias(argument)
  printed = {}
  _G.matches = {[1] = "stt", [2] = argument}
  dofile("src/aliases/STT/STTAlias.lua")
  return table.concat(printed, "")
end

describe("the stt alias, on sensitivity", function()
  local outcome, reason

  before_each(function()
    outcome, reason = true, nil
    _G.sttpkg = {
      config = {},
      saveConfig = function() end,
      applySensitivity = function() return outcome, reason end,
    }
  end)

  it("confirms a sensitivity the engine took", function()
    outcome, reason = true, nil
    local said = runAlias("sensitivity long")
    assert.is_truthy(said:find("sensitivity long", 1, true))
    assert.is_falsy(said:find("does not let", 1, true))
  end)

  -- The case the change is for. Told "does not let its sensitivity be set", a
  -- player stops asking for something the engine had already agreed to do at
  -- its next model load.
  it("does not call a deferred change unsupported", function()
    outcome, reason = false, "deferred"
    local said = runAlias("sensitivity long")
    assert.is_falsy(said:find("does not let", 1, true),
                    "a change the engine kept was reported as one it refuses outright")
    assert.is_truthy(said:find("not yet in effect", 1, true))
  end)

  -- And the opposite advice, which must not read as "wait".
  it("tells a failed rebuild apart from a deferral", function()
    outcome, reason = false, "failed"
    local said = runAlias("sensitivity long")
    assert.is_truthy(said:find("could not be rebuilt", 1, true))
    assert.is_falsy(said:find("not yet in effect", 1, true),
                    "an engine left unloaded was reported as merely waiting")
  end)

  it("still says outright refusals are outright", function()
    outcome, reason = false, "unsupported"
    local said = runAlias("sensitivity long")
    assert.is_truthy(said:find("does not let its sensitivity be set", 1, true))
  end)

  it("saves the setting whatever the engine answered", function()
    outcome, reason = false, "unsupported"
    runAlias("sensitivity long")
    assert.are.equal("long", sttpkg.config.sensitivity)
  end)
end)
