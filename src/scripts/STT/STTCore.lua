--- STT package core: engine bootstrap, listening toggle, result routing.
-- Consumes the stt.* bridge (sysSTT* events) and routes recognised speech
-- into the command line - or straight to the game in autosend mode - with
-- MCVP vocabulary correction applied when the MudletMCVP package is
-- installed. Uses only APIs present in both desktop Mudlet and mudlet-web;
-- everything engine-side lives behind the stt.* bridge contract.
-- @module sttpkg

sttpkg = sttpkg or {}
assert(sttpkg.correct, "STTCorrect must load before STTCore - check scripts.json order")

sttpkg.config = sttpkg.config or {
  autosend = false,     -- true: finals go to the game; false: into the command line
  livePreview = true,   -- partials appear in the command line while speaking
  correction = true,    -- apply MCVP vocabulary correction to finals
  lowercase = true,     -- lowercase the first character, the way commands are typed
  silenceTimeout = 0,   -- ms of silence before listening self-stops; 0 = open-ended
  -- "short" suits what this package is for: commands are a word or two, and
  -- waiting out a dictation-length pause before each one is the difference
  -- between talking to a game and dictating to it
  sensitivity = "short",
}

local CONFIG_FILE = "stt-package-config.lua"

local function configPath()
  return getMudletHomeDir() .. "/" .. CONFIG_FILE
end

function sttpkg.saveConfig()
  table.save(configPath(), sttpkg.config)
end

function sttpkg.loadConfig()
  if io.exists(configPath()) then
    local loaded = {}
    table.load(configPath(), loaded)
    for key, value in pairs(loaded) do sttpkg.config[key] = value end
  end
end

--- Whether the running Mudlet carries the stt.* bridge at all.
function sttpkg.bridgeAvailable()
  return type(stt) == "table" and type(stt.init) == "function"
end

--- Path of the best installed model: sherpa-onnx engines first for their
-- accuracy and hands-free endpointing, then Vosk, then whatever a
-- single-engine core reports.
function sttpkg.findModel()
  local ok, models = pcall(stt.listModels, "sherpa")
  if ok and models and models[1] then return models[1].path end
  ok, models = pcall(stt.listModels, "vosk")
  if ok and models and models[1] then return models[1].path end
  -- Cores predating the engine argument reject it; ask plainly
  ok, models = pcall(stt.listModels)
  if ok and models and models[1] then return models[1].path end
  return nil
end

function sttpkg.ensureInit()
  if not sttpkg.bridgeAvailable() then
    cecho("<orange>[STT] This Mudlet build has no speech-to-text support.\n")
    return false
  end
  if stt.isInitialized() then return true end
  local model = sttpkg.findModel()
  if not model then
    cecho("<orange>[STT] No speech model installed. Install an engine pack, or place a model under stt.getModelPath().\n")
    return false
  end
  local ok, err = stt.init(model)
  if not ok then
    cecho("<red>[STT] Could not load the speech model: " .. tostring(err) .. "\n")
    return false
  end
  if (sttpkg.config.silenceTimeout or 0) > 0 then
    stt.setSilenceTimeout(sttpkg.config.silenceTimeout)
  end
  sttpkg.applySensitivity()
  return true
end

--- Push the configured sensitivity to the engine, if this core has the
-- setting at all. Applied after the model loads, so an engine that rebuilds
-- to change its endpointing does so once, here, rather than mid-session.
function sttpkg.applySensitivity()
  if not sttpkg.bridgeAvailable() or type(stt.setSensitivity) ~= "function" then
    return false
  end
  return stt.setSensitivity(sttpkg.config.sensitivity or "short") and true or false
end

function sttpkg.listening()
  return sttpkg.bridgeAvailable() and stt.isListening()
end

function sttpkg.enable()
  if not sttpkg.ensureInit() then return end
  stt.start()
  -- Reported rather than assumed: start can be refused, and a microphone
  -- that is not actually live is the one failure worth never guessing about
  if sttpkg.listening() then
    cecho("<green>[STT] listening\n")
  end
end

function sttpkg.disable()
  if sttpkg.bridgeAvailable() and stt.isListening() then
    stt.stop()
    cecho("<light_slate_gray>[STT] stopped\n")
  end
end

function sttpkg.toggle()
  if sttpkg.listening() then
    sttpkg.disable()
  else
    sttpkg.enable()
  end
end

-- Correction lexicons, rebuilt only when the MCVP catalog version moves.
sttpkg._lex = sttpkg._lex or { version = nil, leading = nil, argument = nil }

local function lexicons()
  if not (mcvp and mcvp.entries and mcvp.version) then return nil, nil end
  local version = mcvp.version()
  if not version then return nil, nil end
  if sttpkg._lex.version ~= version then
    sttpkg._lex.version = version
    sttpkg._lex.leading = sttpkg.correct.lexicon(mcvp.entries({ correctable = true, leading = true }))
    sttpkg._lex.argument = sttpkg.correct.lexicon(mcvp.entries({ correctable = true, leading = false }))
  end
  return sttpkg._lex.leading, sttpkg._lex.argument
end

--- Recognised text with MCVP correction applied, when enabled and available.
function sttpkg.correctText(text)
  if not sttpkg.config.correction then return text end
  local leading, argument = lexicons()
  if not leading then return text end
  local corrected = sttpkg.correct.apply(text, leading, argument)
  return corrected
end

--- Recognised text as a command line: corrected, then cased the way a player
-- would have typed it.
function sttpkg.prepare(text)
  local prepared = sttpkg.correctText(text)
  if sttpkg.config.lowercase then
    prepared = sttpkg.correct.lowerFirst(prepared)
  end
  return prepared
end

-- Event routing. Handlers are re-registered wholesale on reload so a
-- package update never leaves stale ones behind.
sttpkg._handlers = sttpkg._handlers or {}

-- What this package last wrote into the command line, so it can tell its own
-- preview from something the player typed and is still working on
sttpkg._preview = sttpkg._preview or nil

--- True when the command line holds nothing but this package's own preview,
-- and may therefore be overwritten or cleared without losing typing. A core
-- without getCmdLine() cannot tell, and keeps the old always-write behaviour.
local function cmdLineIsOurs()
  if type(getCmdLine) ~= "function" then return true end
  local current = getCmdLine()
  return current == "" or current == sttpkg._preview
end

local function handleFinal(_, text)
  local corrected = sttpkg.prepare(text)
  if sttpkg.config.autosend then
    send(corrected)
    -- Only our own preview is cleared; half-typed input survives being
    -- spoken over
    if cmdLineIsOurs() then
      clearCmdLine()
      sttpkg._preview = nil
    end
  else
    printCmdLine(corrected)
    sttpkg._preview = corrected
  end
  -- Both forms surface so other packages can consume speech without
  -- re-implementing correction
  raiseEvent("sttPackageResult", corrected, text)
end

local function handlePartial(_, text)
  -- Also previewed in autosend mode: the words appear as they are heard and
  -- vanish when the final is sent, which is the only sign the microphone is
  -- live when nothing is left in the command line to look at
  if sttpkg.config.livePreview then
    -- Cased like the final that will replace it, so the preview does not
    -- visibly re-case itself at the end of every utterance. Correction is
    -- deliberately not applied here: a half-spoken word is not yet a
    -- misrecognition to fix.
    if sttpkg.config.lowercase then
      text = sttpkg.correct.lowerFirst(text)
    end
    printCmdLine(text)
    sttpkg._preview = text
  end
end

local function handleError(_, message)
  cecho("<red>[STT] " .. tostring(message) .. "\n")
end

local function handleState(_, state)
  sttpkg._state = state
  if sttpkg.ui and sttpkg.ui.refresh then sttpkg.ui.refresh(state) end
  raiseEvent("sttPackageState", state)
end

-- This package's installed name, as declared in mfile. Needed because the
-- uninstall event names the package being removed and every installed
-- package hears it.
local PACKAGE_NAME = "STT"

--- Give back everything this package took: a live microphone, the toolbar
-- button, and the event handlers. Mudlet raises the uninstall event before
-- it deletes the package's scripts, so this still runs.
function sttpkg.teardown()
  sttpkg.disable()
  if sttpkg.ui and sttpkg.ui.teardown then
    sttpkg.ui.teardown()
  end
  for _, id in pairs(sttpkg._handlers) do
    killAnonymousEventHandler(id)
  end
  sttpkg._handlers = {}
end

function sttpkg.setup()
  for _, id in pairs(sttpkg._handlers) do
    killAnonymousEventHandler(id)
  end
  sttpkg._handlers = {
    final = registerAnonymousEventHandler("sysSTTResult", handleFinal),
    partial = registerAnonymousEventHandler("sysSTTPartialResult", handlePartial),
    error = registerAnonymousEventHandler("sysSTTError", handleError),
    state = registerAnonymousEventHandler("sysSTTStateChanged", handleState),
    uninstall = registerAnonymousEventHandler("sysUninstall", function(_, name)
      if name == PACKAGE_NAME then sttpkg.teardown() end
    end),
  }
  sttpkg.loadConfig()
end

sttpkg.setup()
