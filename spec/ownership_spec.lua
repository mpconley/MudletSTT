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

describe("being told another profile took the microphone", function()
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
  it("names the profile that took it", function()
    handover("StickMUD")
    assert.is_true(saidSomethingAbout("StickMUD"))
  end)

  it("puts the control back to not-listening", function()
    handover("StickMUD")
    assert.is_true(refreshed)
  end)
end)
