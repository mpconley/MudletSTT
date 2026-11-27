-- Each state of the speech control has its own icon, so a player can tell
-- resting, listening and broken apart without hovering for the tooltip and
-- without relying on the pulse's color alone.
_G.getMudletHomeDir = function() return "/home" end
_G.io.exists = function() return true end
_G.registerAnonymousEventHandler = function() return "handler" end
_G.killAnonymousEventHandler = function() end
_G.getProfileName = function() return "StickMUD" end
_G.setCommandChecked = function() return true end
_G.setCommandPulse = function() return true end
_G.setCommandTooltip = function() return true end
_G.setCommandPinned = function() return true end

local icon

_G.setCommandIcon = function(_, path)
  icon = path
  return true
end

dofile("src/scripts/STT/STTUI.lua")

before_each(function()
  icon = nil
  sttpkg.ui.commandId = 7
end)

describe("the speech control's icon", function()
  it("is the resting mic when ready", function()
    sttpkg.ui.refresh("ready")
    assert.are.equal("/home/STT/microphone.svg", icon)
  end)

  it("is the listening mic while listening", function()
    sttpkg.ui.refresh("listening")
    assert.are.equal("/home/STT/microphone-listening.svg", icon)
  end)

  it("is the struck-through mic on an error", function()
    sttpkg.ui.refresh("error")
    assert.are.equal("/home/STT/microphone-error.svg", icon)
  end)

  it("goes back to the resting mic when listening stops", function()
    sttpkg.ui.refresh("listening")
    sttpkg.ui.refresh("ready")
    assert.are.equal("/home/STT/microphone.svg", icon)
  end)
end)
