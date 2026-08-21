--- STT package UI: a microphone command, feature-detected.
-- Uses the addon command API when the running Mudlet provides it; on a core
-- without that API the package still works fully through the `stt` alias.
-- The command pulses while listening so the live-microphone state is always
-- visible, and carries a checkmark for the surfaces that show one.
-- @module sttpkg.ui

sttpkg = sttpkg or {}
sttpkg.ui = sttpkg.ui or {}

local function iconPath()
  local path = getMudletHomeDir() .. "/STT/microphone.png"
  if io.exists(path) then return path end
  return ""
end

--- Create the command, replacing any earlier one.
-- Command and handler are always made as a pair. Reusing a surviving
-- sttpkg.ui.commandId would orphan the command: the id and the control both
-- outlive a package uninstall - the id sits in the profile's Lua state, the
-- control is owned by the profile - but the handler that was registered by
-- the removed script does not. That left a button which silently did nothing
-- after a reinstall.
function sttpkg.ui.ensureCommand()
  if type(addCommand) ~= "function" then return end
  sttpkg.ui.teardown()

  -- Both surfaces, deliberately: the main toolbar is hidden on a fresh
  -- profile, so a toolbar-only microphone would be invisible to exactly the
  -- players least likely to know where else to look. The menu entry always
  -- reaches them, and the client places whichever it has.
  local id, why = addCommand{
    name = "Speech",
    icon = iconPath(),
    tooltip = "Toggle speech recognition",
    menuPath = "Speech",
    surfaces = {"menu", "toolbar"},
  }
  if not id then
    -- A refusal carries a reason a player can act on - a taken shortcut, a
    -- hidden toolbar - so it is worth showing rather than failing silently
    cecho("<orange>[STT] The speech control could not be placed: " .. tostring(why) .. "\n")
    return
  end

  sttpkg.ui.commandId = id
  sttpkg.ui.clickHandler = registerAnonymousEventHandler("sysCommandClicked", function(_, clickedId)
    if clickedId == sttpkg.ui.commandId then sttpkg.toggle() end
  end)
  -- Adopt the engine's current state: listening may already be running from
  -- before this package was (re)loaded
  sttpkg.ui.refresh(sttpkg.listening() and "listening" or "ready")
end

--- Reflect a recogniser state on the command; called by STTCore's state
-- handler and safe to call with no command present.
function sttpkg.ui.refresh(state)
  if not sttpkg.ui.commandId then return end
  local listening = state == "listening"

  -- The checkmark is the part every surface can show, including ones with no
  -- room for a colour - a menu entry, or a command line indicator
  setCommandChecked(sttpkg.ui.commandId, listening)
  -- The pulse is the toolbar's refinement, and refuses on a command with no
  -- button, so its answer is not worth acting on
  setCommandPulse(sttpkg.ui.commandId, listening, "#22aa44", "#116622", 700)

  local tooltip = "Toggle speech recognition"
  if listening then
    tooltip = "Speech: listening (click to stop)"
  elseif state == "error" then
    tooltip = "Speech: error - see the main window"
  end
  setCommandTooltip(sttpkg.ui.commandId, tooltip)
end

--- Remove the command and its handler, so a control never outlives the code
-- that answers it. Called before creating a replacement, and by the
-- uninstall handler in STTCore.
function sttpkg.ui.teardown()
  if sttpkg.ui.commandId and type(removeCommand) == "function" then
    removeCommand(sttpkg.ui.commandId)
  end
  if sttpkg.ui.clickHandler then
    killAnonymousEventHandler(sttpkg.ui.clickHandler)
  end
  sttpkg.ui.commandId = nil
  sttpkg.ui.clickHandler = nil
end

sttpkg.ui.ensureCommand()
