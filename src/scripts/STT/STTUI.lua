--- STT package UI: a microphone command, feature-detected.
-- Uses the addon command API when the running Mudlet provides it; on a core
-- without that API the package still works fully through the `stt` alias.
-- The command pulses while listening so the live-microphone state is always
-- visible, and carries a checkmark for the surfaces that show one.
-- @module sttpkg.ui

sttpkg = sttpkg or {}
sttpkg.ui = sttpkg.ui or {}

-- Lucide's mic, drawn like Mudlet's own toolbar glyphs, one per state. Mudlet
-- tints its own glyphs to the appearance but shows a package icon as it is, so
-- each ink is fixed and clears 3:1 on both the dark and the light toolbar:
-- teal at rest (the package icon's own), white on the blue pulse while
-- listening, and a struck-through mic in Mudlet's error red.
local function iconPath(name)
  local path = getMudletHomeDir() .. "/STT/" .. name .. ".svg"
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
-- Which profile this control belongs to, for the tooltip. Every open profile
-- installs its own copy of this package and adds its own button, and they all
-- read "Speech" - so with two games open there are two identical microphones
-- in one toolbar and nothing saying which is which. The label stays short
-- because that is what the toolbar has room for; the tooltip carries the
-- answer, and it is the tooltip a player checks when two of them puzzle them.
local function profileSuffix()
  if type(getProfileName) ~= "function" then return "" end
  local ok, name = pcall(getProfileName)
  if not ok or type(name) ~= "string" or name == "" then return "" end
  return " [" .. name .. "]"
end

function sttpkg.ui.ensureCommand()
  if type(addCommand) ~= "function" then return end
  sttpkg.ui.teardown()

  -- Both surfaces, deliberately: the main toolbar is hidden on a fresh
  -- profile, so a toolbar-only microphone would be invisible to exactly the
  -- players least likely to know where else to look. The menu entry always
  -- reaches them, and the client places whichever it has.
  local id, why = addCommand{
    name = "Speech",
    icon = iconPath("microphone"),
    tooltip = "Toggle speech recognition" .. profileSuffix(),
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
  -- button, so its answer is not worth acting on. Blue, as Mudlet's own "on"
  -- is: green sits too close to the error red for red-green color blindness
  setCommandPulse(sttpkg.ui.commandId, listening, "#2a82da", "#15416d", 700)
  -- An open microphone has to stay stoppable from wherever the player goes.
  -- Pinning shows this control in whichever window they are in, whatever
  -- profile that window is showing - and only while it is listening, so two
  -- games open still means one Speech button the rest of the time. Guarded
  -- because a Mudlet without the call is simply one where the button stays
  -- with its own profile.
  if type(setCommandPinned) == "function" then
    setCommandPinned(sttpkg.ui.commandId, listening)
  end

  -- The icon changes with the state too, so an error shows on the button
  -- itself rather than only to a player who hovers over it
  local icon, tooltip = "microphone", "Toggle speech recognition"
  if listening then
    icon, tooltip = "microphone-listening", "Speech: listening (click to stop)"
  elseif state == "error" then
    icon, tooltip = "microphone-error", "Speech: error - see the main window"
  end
  setCommandIcon(sttpkg.ui.commandId, iconPath(icon))
  setCommandTooltip(sttpkg.ui.commandId, tooltip .. profileSuffix())
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
