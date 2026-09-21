-- One recogniser is shared between every open profile, so a Mudlet that tracks
-- who holds the microphone changes two things this package had taken for
-- granted: stopping can be refused, and the session can end because another
-- game asked for it rather than because this one did.
--
-- STTCore needs a Mudlet to load, so the globals it touches at load time are
-- stubbed here; the handlers are then called the way Mudlet would call them.
local registered = {}

_G.registerAnonymousEventHandler = function(event, handler)
  registered[event] = handler
  return event
end
_G.killAnonymousEventHandler = function() end
_G.getMudletHomeDir = function() return "." end
_G.raiseEvent = function() end
_G.table.save = function() end
_G.table.load = function() end
_G.io.exists = function() return false end

local said

_G.cecho = function(text) said[#said + 1] = text end

dofile("src/scripts/STT/STTCorrect.lua")
dofile("src/scripts/STT/STTCore.lua")

local function saidSomethingAbout(fragment)
  for _, line in ipairs(said) do
    if line:find(fragment, 1, true) then return true end
  end
  return false
end

before_each(function()
  said = {}
end)

describe("stopping a session this profile may not own", function()
  it("says it stopped when the stop was taken", function()
    _G.stt = { init = function() return true end, listening = function() return true end,
               stop = function() return true end }
    assert.is_true(sttpkg.disable())
    assert.is_true(saidSomethingAbout("stopped"))
  end)

  -- The case an older Mudlet still reaches: stt.listening() there answers for
  -- the shared engine, so a profile holding nothing gets past the guard, has
  -- its stop refused, and would otherwise report a stop that never happened
  -- while another game carried on listening.
  it("says nothing when the stop was refused", function()
    _G.stt = { init = function() return true end, listening = function() return true end,
               stop = function() return nil, "another profile is listening" end }
    local stopped = sttpkg.disable()
    assert.is_nil(stopped)
    assert.is_false(saidSomethingAbout("stopped"))
  end)

  it("does not reach the bridge at all when this profile is not listening", function()
    local asked = false
    _G.stt = { init = function() return true end, listening = function() return false end,
               stop = function() asked = true return true end }
    sttpkg.disable()
    assert.is_false(asked)
    assert.is_false(saidSomethingAbout("stopped"))
  end)
end)

-- Leaving is not finishing. A stop because this profile went behind another,
-- or Mudlet went behind another application, has no use for the half-sentence
-- a stop would finalise and hand over as a command.
describe("stopping because attention moved away", function()
  local called

  local function bridge(withCancel)
    called = {}
    _G.stt = { init = function() return true end, listening = function() return true end,
               stop = function() called[#called + 1] = "stop" return true end }
    if withCancel then
      _G.stt.cancel = function() called[#called + 1] = "cancel" return true end
    end
  end

  it("throws the phrase away where Mudlet can", function()
    bridge(true)
    assert.is_true(sttpkg.disable(true))
    assert.are.same({ "cancel" }, called)
    assert.is_true(saidSomethingAbout("stopped"))
  end)

  it("still stops on a Mudlet with no stt.cancel", function()
    bridge(false)
    assert.is_true(sttpkg.disable(true))
    assert.are.same({ "stop" }, called)
  end)

  it("keeps an ordinary stop finalising", function()
    bridge(true)
    sttpkg.disable()
    assert.are.same({ "stop" }, called)
  end)

  -- No final arrives to replace the live preview, so without this the words
  -- that were thrown away sit in the command line one Return from being sent
  describe("the live preview of what was thrown away", function()
    local cmdLine

    before_each(function()
      cmdLine = "say test"
      sttpkg._preview = "say test"
      _G.getCmdLine = function() return cmdLine end
      _G.clearCmdLine = function() cmdLine = "" end
    end)

    after_each(function()
      _G.getCmdLine, _G.clearCmdLine = nil, nil
      sttpkg._preview = nil
    end)

    it("is cleared", function()
      bridge(true)
      sttpkg.disable(true)
      assert.are.equal("", cmdLine)
    end)

    it("leaves what the player typed over it", function()
      cmdLine = "say something else"
      bridge(true)
      sttpkg.disable(true)
      assert.are.equal("say something else", cmdLine)
    end)

    -- Where only stt.stop() exists the phrase is finalised, and the final
    -- replaces the preview the ordinary way
    it("is left for the final on a Mudlet with no stt.cancel", function()
      bridge(false)
      sttpkg.disable(true)
      assert.are.equal("say test", cmdLine)
    end)

    it("is left when the cancel was refused", function()
      bridge(true)
      _G.stt.cancel = function() return nil, "another profile is listening" end
      sttpkg.disable(true)
      assert.are.equal("say test", cmdLine)
    end)
  end)
end)

describe("being told another profile asked for the microphone", function()
  local refreshed

  before_each(function()
    refreshed = false
    sttpkg.ui = sttpkg.ui or {}
    sttpkg.ui.refresh = function() refreshed = true end
  end)

  local function handover(who) registered["sysSTTHandover"](nil, who) end

  -- The state change that follows a handover says only that listening stopped,
  -- which is what a stop this profile asked for looks like too. Without the
  -- notice the player watches their microphone close for no reason they can see.
  it("names the profile that asked for it", function()
    handover("StickMUD")
    assert.is_true(saidSomethingAbout("StickMUD asked for the microphone"))
    assert.is_false(saidSomethingAbout("took"))
  end)

  it("puts the control back to not-listening", function()
    handover("StickMUD")
    assert.is_true(refreshed)
  end)
end)
