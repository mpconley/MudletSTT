-- Static analysis settings for the package.
--
-- The value here is catching a call to something that does not exist: a local
-- declared below the function that uses it resolves to a nil global, which
-- Lua only complains about when that line finally runs - in this package's
-- case, in the middle of a live microphone test.

std = "lua51"

-- Mudlet's API, which these scripts run inside rather than require
read_globals = {
  "cecho", "echo", "send", "raiseEvent",
  "printCmdLine", "clearCmdLine", "getCmdLine",
  "tempTimer", "killTimer",
  "registerAnonymousEventHandler", "killAnonymousEventHandler",
  "getMudletHomeDir", "io", "table",
  -- Read only for the version line "stt status" prints, and both guarded with
  -- type() before use: an older Mudlet without either still has to work
  "getPackageInfo", "getMudletVersion", "getProfileName",
  -- Mudlet fills this in from the game's GMCP messages
  "gmcp",
  -- The addon command API, which replaced the split toolbar/menu functions
  "addCommand", "removeCommand", "enableCommand", "disableCommand",
  "setCommandChecked", "setCommandIcon", "setCommandTooltip", "setCommandPulse",
  "stt", "mcvp",
  -- Set by Mudlet for alias and trigger scripts
  "matches",
}

-- The package's own namespace, written by its scripts and read across them
globals = { "sttpkg" }

-- tools/ is not packaged - these are scripts a developer pastes into a live
-- profile, so they see the package's namespaces plus Mudlet's own
files["tools"] = {
  globals = {"_pass", "sttpkg"},
  read_globals = {"mcvp", "stt", "tempTimer"},
}

-- sttpkg is writable here: a spec that exercises one part of the package
-- stands the rest of it up as stubs
files["spec"] = {
  globals = { "sttpkg" },
  read_globals = { "describe", "it", "before_each", "after_each", "assert" },
}
