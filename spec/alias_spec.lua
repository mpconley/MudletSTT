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

describe("the stt alias, on test phrases", function()
  local started

  before_each(function()
    started = nil
    _G.sttpkg = {
      config = {},
      saveConfig = function() end,
      test = {
        parsePhraseList = function(text)
          if text == "score guild; guild score 3" then
            return { "score guild", "guild score" }, 3
          end
          return {}, nil
        end,
        start = function(passes, phrases) started = { passes = passes, phrases = phrases } return true end,
        stop = function() return false end,
        lastPhrases = function() return nil end,
        gamePhrases = function() return {} end,
        scopePhrases = function() return {} end,
      },
      grade = { show = function() end },
    }
  end)

  it("runs the list it was given, with the pass count", function()
    runAlias("test phrases score guild; guild score 3")
    assert.same({ "score guild", "guild score" }, started.phrases)
    assert.equals(3, started.passes)
  end)

  it("says so when the list is empty", function()
    local out = runAlias("test phrases")
    assert.is_nil(started)
    assert.is_truthy(out:find("no phrases"))
  end)
end)

-- The help block is the only place a player who has not read the manual can
-- find a sub-command. "stt test phrases" was documented in the README and the
-- manual and missing here, so it was undiscoverable from inside Mudlet.
describe("the stt alias, on its own help", function()
  before_each(function()
    _G.sttpkg = { config = {}, saveConfig = function() end }
  end)

  it("lists every test sub-command it accepts", function()
    local said = runAlias("help")
    assert.is_truthy(said:find("stt test phrases", 1, true))
    assert.is_truthy(said:find("stt test scope", 1, true))
    assert.is_truthy(said:find("stt test game", 1, true))
    assert.is_truthy(said:find("stt test repeat", 1, true))
  end)
end)

-- stt status is the line a player is asked to paste when speech is not doing
-- what they expect, so what it leaves out is what nobody can answer for them.
-- It reported the sensitivity mode and never whether the engine could be tuned,
-- and reported biasing not at all - neither the setting nor whether the loaded
-- model can honour it, which is the whole of "I turned bias on and nothing
-- changed".
describe("the stt alias, on status", function()
  local capabilities

  before_each(function()
    capabilities = {}
    _G.sttpkg = {
      config = {
        autosend = false, livePreview = true, correction = true, lowercase = true,
        silenceTimeout = 0, sensitivity = "default", biasing = true, stopOnFocusLoss = true,
      },
      saveConfig = function() end,
      bridgeAvailable = function() return true end,
      versions = function() return "STT 1.5.0" end,
    }
    _G.stt = {
      getInfo = function()
        return {backend = "sherpa", state = "ready", modelPath = "/models/zipformer", capabilities = capabilities}
      end,
    }
  end)

  it("reports whether biasing is on, which it never used to say at all", function()
    _G.sttpkg.config.biasing = true
    assert.is_truthy(runAlias("status"):find("bias on", 1, true))
    _G.sttpkg.config.biasing = false
    assert.is_truthy(runAlias("status"):find("bias off", 1, true))
  end)

  it("says when the loaded model cannot be biased", function()
    capabilities = {biasing = false}
    assert.is_truthy(runAlias("status"):find("cannot be biased", 1, true))
  end)

  it("stays quiet about biasing when the engine can do it", function()
    capabilities = {biasing = true}
    local said = runAlias("status")
    assert.is_truthy(said:find("bias on", 1, true))
    assert.is_falsy(said:find("cannot be biased", 1, true))
  end)

  it("says when the engine sets its own phrase endings", function()
    capabilities = {sensitivityTuning = false}
    assert.is_truthy(runAlias("status"):find("sets its own phrase endings", 1, true))
  end)

  -- The case that matters most, because it is every shipping Mudlet today:
  -- sensitivityTuning is absent, not false. Reading a missing key as "no"
  -- would tell all of those players their engine cannot be tuned when nothing
  -- has said so.
  it("invents no limit from a capability this Mudlet does not publish", function()
    capabilities = {biasing = true}
    local said = runAlias("status")
    assert.is_falsy(said:find("sets its own phrase endings", 1, true))
    assert.is_falsy(said:find("cannot be biased", 1, true))
  end)

  it("still reports settings when there is no speech bridge to ask", function()
    _G.sttpkg.bridgeAvailable = function() return false end
    local said = runAlias("status")
    assert.is_truthy(said:find("no speech bridge", 1, true))
    assert.is_truthy(said:find("bias on", 1, true))
    assert.is_falsy(said:find("cannot be biased", 1, true))
  end)
end)
