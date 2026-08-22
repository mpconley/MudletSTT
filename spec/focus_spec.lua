-- Tests for the two handlers that stop listening when attention moves away.
-- STTCore needs a Mudlet to load, so the globals it touches at load time are
-- stubbed here; the handlers themselves are then called the way Mudlet would
-- call them.
local registered = {}

_G.registerAnonymousEventHandler = function(event, handler)
  registered[event] = handler
  return event
end
_G.killAnonymousEventHandler = function() end
_G.getMudletHomeDir = function() return "." end
_G.cecho = function() end
_G.raiseEvent = function() end
_G.table.save = function() end
_G.table.load = function() end
_G.io.exists = function() return false end

dofile("src/scripts/STT/STTCorrect.lua")
dofile("src/scripts/STT/STTCore.lua")

local stopped
local listening

before_each(function()
  stopped = false
  listening = true
  sttpkg.listening = function() return listening end
  sttpkg.disable = function() stopped = true end
  sttpkg.config.stopOnFocusLoss = true
end)

describe("stopping when the profile is no longer in front", function()
  local function focus(focused) registered["sysProfileFocusChangeEvent"](nil, focused) end

  it("stops listening when this profile goes behind another", function()
    focus(false)
    assert.is_true(stopped)
  end)

  it("does nothing when this profile comes to the front", function()
    focus(true)
    assert.is_false(stopped)
  end)

  it("is not a preference - stopOnFocusLoss does not disable it", function()
    sttpkg.config.stopOnFocusLoss = false
    focus(false)
    assert.is_true(stopped)
  end)

  it("stays quiet when nothing is listening", function()
    listening = false
    focus(false)
    assert.is_false(stopped)
  end)
end)

describe("stopping when Mudlet is not the active application", function()
  local function focus(active) registered["sysApplicationFocusChangeEvent"](nil, active) end

  it("stops listening when Mudlet goes to the background", function()
    focus(false)
    assert.is_true(stopped)
  end)

  it("does nothing when Mudlet comes back to the front", function()
    focus(true)
    assert.is_false(stopped)
  end)

  it("leaves the microphone open when the guard is turned off", function()
    sttpkg.config.stopOnFocusLoss = false
    focus(false)
    assert.is_false(stopped)
  end)

  it("stays quiet when nothing is listening", function()
    listening = false
    focus(false)
    assert.is_false(stopped)
  end)
end)
