--- STT package UI: a microphone toolbar button, feature-detected.
-- Uses the addon toolbar API when the running Mudlet provides it; on a core
-- without that API the package still works fully through the `stt` alias.
-- The button pulses while listening so the live-microphone state is always
-- visible.
-- @module sttpkg.ui

sttpkg = sttpkg or {}
sttpkg.ui = sttpkg.ui or {}

local function iconPath()
  local path = getMudletHomeDir() .. "/STT/microphone.png"
  if io.exists(path) then return path end
  return ""
end

--- Create the button, replacing any earlier one.
-- Button and handler are always made as a pair. Reusing a surviving
-- sttpkg.ui.buttonId would orphan the button: the id and the toolbar control
-- both outlive a package uninstall - the id sits in the profile's Lua state,
-- the control is owned by the profile - but the handler that was registered
-- by the removed script does not. That left a button which silently did
-- nothing after a reinstall.
function sttpkg.ui.ensureButton()
  if type(addToolbarButton) ~= "function" then return end
  if sttpkg.ui.buttonId then removeToolbarButton(sttpkg.ui.buttonId) end
  if sttpkg.ui.clickHandler then killAnonymousEventHandler(sttpkg.ui.clickHandler) end
  sttpkg.ui.buttonId = nil
  sttpkg.ui.clickHandler = nil

  local id = addToolbarButton("Speech", iconPath(), "Toggle speech recognition")
  if not id then return end
  sttpkg.ui.buttonId = id
  sttpkg.ui.clickHandler = registerAnonymousEventHandler("sysToolbarButtonClicked", function(_, clickedId)
    if tostring(clickedId) == tostring(sttpkg.ui.buttonId) then sttpkg.toggle() end
  end)
  -- Adopt the engine's current state: listening may already be running from
  -- before this package was (re)loaded
  sttpkg.ui.refresh(sttpkg.listening() and "listening" or "ready")
end

--- Reflect a recogniser state on the button; called by STTCore's state
-- handler and safe to call with no button present.
function sttpkg.ui.refresh(state)
  if not sttpkg.ui.buttonId then return end
  local listening = state == "listening"
  setToolbarButtonState(sttpkg.ui.buttonId, state or "")
  if type(setToolbarButtonPulse) == "function" then
    setToolbarButtonPulse(sttpkg.ui.buttonId, listening, "#22aa44", "#116622", 700)
  end
  local tooltip = "Toggle speech recognition"
  if listening then
    tooltip = "Speech: listening (click to stop)"
  elseif state == "error" then
    tooltip = "Speech: error - see the main window"
  end
  setToolbarButtonTooltip(sttpkg.ui.buttonId, tooltip)
end

sttpkg.ui.ensureButton()
