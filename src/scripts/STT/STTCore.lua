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
  silenceTimeout = 0,   -- ms of silence before listening self-stops; 0 = open-ended
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
  return true
end

function sttpkg.listening()
  return sttpkg.bridgeAvailable() and stt.isListening()
end

function sttpkg.enable()
  if not sttpkg.ensureInit() then return end
  stt.start()
end

function sttpkg.disable()
  if sttpkg.bridgeAvailable() and stt.isListening() then stt.stop() end
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

-- Event routing. Handlers are re-registered wholesale on reload so a
-- package update never leaves stale ones behind.
sttpkg._handlers = sttpkg._handlers or {}

local function handleFinal(_, text)
  local corrected = sttpkg.correctText(text)
  if sttpkg.config.autosend then
    send(corrected)
    clearCmdLine()
  else
    printCmdLine(corrected)
  end
  -- Both forms surface so other packages can consume speech without
  -- re-implementing correction
  raiseEvent("sttPackageResult", corrected, text)
end

local function handlePartial(_, text)
  if sttpkg.config.livePreview and not sttpkg.config.autosend then
    printCmdLine(text)
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

function sttpkg.setup()
  for _, id in pairs(sttpkg._handlers) do
    killAnonymousEventHandler(id)
  end
  sttpkg._handlers = {
    final = registerAnonymousEventHandler("sysSTTResult", handleFinal),
    partial = registerAnonymousEventHandler("sysSTTPartialResult", handlePartial),
    error = registerAnonymousEventHandler("sysSTTError", handleError),
    state = registerAnonymousEventHandler("sysSTTStateChanged", handleState),
  }
  sttpkg.loadConfig()
end

sttpkg.setup()
