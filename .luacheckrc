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
  "addToolbarButton", "removeToolbarButton", "setToolbarButtonState",
  "setToolbarButtonIcon", "setToolbarButtonTooltip", "setToolbarButtonEnabled",
  "setToolbarButtonPulse",
  "stt", "mcvp",
  -- Set by Mudlet for alias and trigger scripts
  "matches",
}

-- The package's own namespace, written by its scripts and read across them
globals = { "sttpkg" }

files["spec"] = {
  read_globals = { "describe", "it", "before_each", "after_each", "assert", "sttpkg" },
}
