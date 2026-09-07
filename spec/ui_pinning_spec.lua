-- An open microphone has to stay stoppable from whatever window the player is
-- in, which on a Mudlet that places commands per profile means pinning the
-- control while it is listening and only while it is listening. Pinning it
-- permanently would put the button back in every window at once, which is the
-- duplicate the per-profile placement removed.
--
-- STTUI is loaded directly here: no other spec needs it, and the command API
-- it feature-detects is exactly what has to be stubbed to see the calls.
_G.getMudletHomeDir = function() return "." end
_G.io.exists = function() return false end
_G.registerAnonymousEventHandler = function() return "handler" end
_G.killAnonymousEventHandler = function() end
_G.getProfileName = function() return "StickMUD" end

local pinned

_G.setCommandChecked = function() return true end
_G.setCommandPulse = function() return true end
_G.setCommandTooltip = function() return true end
_G.setCommandPinned = function(_, state)
  pinned = state
  return true
end

dofile("src/scripts/STT/STTUI.lua")

before_each(function()
  pinned = nil
  sttpkg.ui.commandId = 7
end)

describe("keeping a live microphone reachable", function()
  it("pins the control while listening", function()
    sttpkg.ui.refresh("listening")
    assert.is_true(pinned)
  end)

  it("unpins it as soon as listening stops", function()
    sttpkg.ui.refresh("listening")
    sttpkg.ui.refresh("ready")
    assert.is_false(pinned)
  end)

  -- An error is not a live microphone, so the control belongs back with its own
  -- profile rather than following the player around announcing a fault.
  it("unpins it on an error", function()
    sttpkg.ui.refresh("listening")
    sttpkg.ui.refresh("error")
    assert.is_false(pinned)
  end)

  it("does nothing at all with no command placed", function()
    sttpkg.ui.commandId = nil
    sttpkg.ui.refresh("listening")
    assert.is_nil(pinned)
  end)
end)

describe("a Mudlet without the pinning call", function()
  -- The package still works on a core that places every command in one window;
  -- the button simply stays with its own profile there.
  it("refreshes without erroring", function()
    local saved = _G.setCommandPinned
    _G.setCommandPinned = nil
    assert.has_no.errors(function() sttpkg.ui.refresh("listening") end)
    _G.setCommandPinned = saved
  end)
end)
