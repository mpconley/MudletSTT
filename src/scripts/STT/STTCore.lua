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
  -- Path of the model "stt model" last loaded, so a restart does not drop
  -- back to whichever one sorts first. They are not interchangeable: only
  -- some can be biased at all, so the choice is worth keeping.
  model = "",
  -- On, measured 2026-08-23 with tools/mcvp-integration-pass.lua: 24 paired
  -- phrases per condition on a streaming Zipformer, 79% exact biased against
  -- 63% plain, first-word losses 2 against 5. What carries this is the
  -- per-phrase breakdown rather than the percentage - "symbol" came back as
  -- the non-word "simbal" on every plain attempt and on none of the biased
  -- ones, and client-side correction cannot rescue that either, distance 2 on
  -- six letters being outside its budget. It is not free: two phrases got
  -- worse under biasing, which is what "stt bias off" is for. Twenty-four
  -- trials carry the direction and no more, so do not quote the 16 points as
  -- a settled figure.
  biasing = true,
  -- Measured, not assumed: "short" was the obvious choice for commands and
  -- lost to "default" on every number "stt test" reports - a one-word command
  -- can be cut off before the decoder has emitted it. A wrong command costs
  -- more than a slow one, so accuracy wins the default and "short" stays
  -- available for anyone who prefers the speed.
  sensitivity = "default",
  -- Stop listening when Mudlet itself stops being the active application.
  -- Unlike the profile-focus rule below this one is a preference, not a
  -- correctness fix: speech said while another window is in front is not
  -- addressed to the wrong game, it is only possibly not addressed to a game
  -- at all. Dictating while reading a map or a wiki page in a browser is a
  -- real way to use this, so "stt focus keep" turns it off - it defaults on
  -- because a microphone left open to a room nobody is playing in is the
  -- more expensive mistake.
  stopOnFocusLoss = true,
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
--- Every installed model, whichever engine provides it.
local function installedModels()
  local all = {}
  for _, engine in ipairs({ "sherpa", "vosk" }) do
    local ok, models = pcall(stt.listModels, engine)
    if ok and models then
      for _, model in ipairs(models) do all[#all + 1] = model end
    end
  end
  if #all == 0 then
    -- Cores predating the engine argument reject it; ask plainly
    local ok, models = pcall(stt.listModels)
    if ok and models then all = models end
  end
  return all
end

function sttpkg.findModel()
  -- A model chosen with "stt model" outlives the session that chose it. If it
  -- has since been removed, the preference order below takes over rather than
  -- leaving speech with nothing to load.
  local remembered = sttpkg.config.model
  if remembered and remembered ~= "" then
    for _, model in ipairs(installedModels()) do
      if model.path == remembered then return model.path end
    end
  end

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
  if stt.initialized() then return true end
  local model = sttpkg.findModel()
  -- A backend built into the operating system - macOS's own recogniser today -
  -- has no model on disk and is reached by init() with no argument. Two things
  -- otherwise hide it. Asking for a model and giving up when there is none is
  -- the obvious one. The other is subtler and commoner: listModels() answers
  -- from disk without the engine library, so a machine holding models for an
  -- engine it can no longer load finds one, hands it over, and reports the
  -- refusal - having never asked what else could run.
  local ok, err
  if model then
    ok, err = stt.init(model)
  end
  if not ok then
    ok, err = stt.init()
    if ok and model then
      -- Say what happened rather than starting something they did not ask for.
      -- The reason itself is not repeated: the core already raised it as
      -- sysSTTError and this package prints those, so echoing modelError here
      -- shows the same paragraph of search paths twice.
      cecho("<light_slate_gray>[STT] using the speech recognition built into this "
        .. "system instead, which needs no engine or model installed\n")
    end
  end
  if not ok then
    cecho("<red>[STT] Could not load the speech model: " .. tostring(err) .. "\n")
    return false
  end
  if (sttpkg.config.silenceTimeout or 0) > 0 then
    stt.setSilenceTimeout(sttpkg.config.silenceTimeout)
  end
  sttpkg.applySensitivity()
  sttpkg.applyVocabulary()
  return true
end

-- The engine scores every biasing word against every alternative path, so the
-- list has to be a shortlist rather than a dictionary. MCVP's own tiers do the
-- choosing: biasable already drops protected words and the lowest-priority
-- tier, and this caps what is left.
local MAX_BIAS_WORDS = 300

-- Single letters and pairs are movement and command aliases - n, s, ne, inv -
-- and boosting them is how "north" came back as "n". They carry the least
-- meaning and the most weight, so they are left out of biasing entirely.
local MIN_BIAS_WORD_LENGTH = 3

--- The words that would be biased toward right now, in the order they are
-- spent. Separate from applyVocabulary() so the choice can be tested, and so
-- tools/bench can write out the exact list a live profile would have used
-- rather than a reimplementation of it that drifts.
-- @param limit optional budget override, for measuring what the cap costs
function sttpkg.biasWords(limit)
  limit = limit or MAX_BIAS_WORDS
  local words, seen = {}, {}
  local function offer(word)
    word = tostring(word or ""):lower()
    if #word >= MIN_BIAS_WORD_LENGTH and not seen[word] and #words < limit then
      seen[word] = true
      words[#words + 1] = word
    end
  end

  -- What is in reach goes in first: these are the words about to be spoken,
  -- and if the budget ever truncated before them the biasing would lose most
  -- of its value. Measured on a real recording of eight commands, a 50-word
  -- budget spent so the in-scope words fell off the end scored 4/8 phrases
  -- exact against 6/8 with them kept.
  --
  -- What is NOT true, and was written here before any of it was measured, is
  -- that the rest of the catalog is "commands the recogniser already gets
  -- right" and so a poor use of the budget. The command verbs are what fix
  -- "YET HEART" into "get heartwood" and "TILL IRON PELT" into "kill
  -- ironpelt". Biasing the in-scope nouns alone scores 4/8, the verbs alone
  -- 4/8, and the two together 6/8 - neither half buys anything on its own,
  -- because a phrase is a verb and a noun and both have to be reached.
  --
  -- Nor does the wrong order make biasing "worse than not biasing at all":
  -- it scored the same as no useful biasing, not below it. The budget itself
  -- is not the constraint either - 25 words and 600 words score identically,
  -- so MAX_BIAS_WORDS is nowhere near where dilution would start.
  if sttpkg.context and sttpkg.context.inScope then
    for _, word in ipairs(sttpkg.context.inScope()) do
      offer(word)
    end
  end

  if mcvp and mcvp.entries then
    for _, entry in ipairs(mcvp.entries({ biasable = true })) do
      offer(entry.word)
    end
  end
  return words
end

--- Push the game's vocabulary into the decoder, where a backend can bias
-- recognition toward it. Returns the number of words applied, 0 when the
-- backend declined - which is not a failure but the signal to keep relying on
-- client-side correction instead.
function sttpkg.applyVocabulary()
  if not sttpkg.bridgeAvailable() or type(stt.setVocabulary) ~= "function" then
    return 0
  end
  if not (mcvp and mcvp.entries) then return 0 end
  if not sttpkg.config.biasing then
    -- Withdraw anything applied earlier, so turning it off takes effect
    -- rather than waiting for a restart
    if (sttpkg._biasWords or 0) > 0 then stt.setVocabulary({}) end
    sttpkg._biasWords = 0
    return 0
  end

  local words = sttpkg.biasWords()
  if #words == 0 then return 0 end

  sttpkg._biasWords = stt.setVocabulary(words) and #words or 0
  return sttpkg._biasWords
end

--- Push the configured sensitivity to the engine, if this core has the
-- setting at all. Applied after the model loads, so an engine that rebuilds
-- to change its endpointing does so once, here, rather than mid-session.
-- Four outcomes, because the caller has four things to say and the engine's
-- own boolean says only "no". It does return a message alongside, and the two
-- refusals word it differently - but matching on message text is the kind of
-- coupling that breaks silently when someone rewords a string, so the state
-- around the call is read instead. capabilities.sensitivityTuning answers the
-- permanent question before the attempt; the state before and after answers
-- what the attempt did.
--
-- Returns true when the setting is in force. Otherwise false and why:
--   "unsupported"  nothing here can tune it - this engine never can, or this
--                  Mudlet has no setter, or it is too old to say which of the
--                  two a refusal was. Stop offering either way.
--   "deferred"     it can, but not just now; the core kept the value and will
--                  build it in at its next model load
--   "failed"       it rebuilt and the rebuild did not come back, leaving the
--                  engine worse off than before with nothing loaded
-- The value is saved by the caller either way, so the difference is only in
-- what the player is told - but "deferred" and "failed" are opposite advice,
-- one to wait and one to act.
function sttpkg.applySensitivity()
  if not sttpkg.bridgeAvailable() or type(stt.setSensitivity) ~= "function" then
    return false, "unsupported"
  end

  -- nil on a core predating the flag, where the two really are indivisible -
  -- treat that as before rather than promising a retry that may never work
  local capabilities = (stt.getInfo() or {}).capabilities
  local canTune = capabilities and capabilities.sensitivityTuning
  if canTune ~= true then
    if stt.setSensitivity(sttpkg.config.sensitivity or "short") then
      return true
    end
    return false, "unsupported"
  end

  -- Read before the attempt, not only after it. sherpa rebuilds the model to
  -- change its endpoint rules, and it only does that from idle: from anything
  -- else it declines and keeps the value for the next load. So a rebuild can
  -- only have run - and only have failed - if the engine was idle going in.
  --
  -- Reading the state afterwards alone gets this wrong in a way that matters.
  -- An engine already sitting in error with its handles alive, which is where
  -- a denied microphone leaves it, declines exactly as a busy one does and
  -- says so - and would then be reported as a rebuild that had killed it,
  -- contradicting the engine's own message on the line above.
  local stateBefore = (stt.getInfo() or {}).state

  if stt.setSensitivity(sttpkg.config.sensitivity or "short") then
    return true
  end

  if stateBefore == "ready" and (stt.getInfo() or {}).state == "error" then
    return false, "failed"
  end
  return false, "deferred"
end

--- Load a specific installed model by name fragment, so alternatives can be
-- compared rather than accepted. Returns the model name on success.
function sttpkg.useModel(fragment)
  if not sttpkg.bridgeAvailable() then return nil, "no speech bridge in this Mudlet build" end
  fragment = tostring(fragment or ""):lower()

  for _, engine in ipairs({ "sherpa", "vosk" }) do
    local ok, models = pcall(stt.listModels, engine)
    if ok and models then
      for _, model in ipairs(models) do
        if model.name:lower():find(fragment, 1, true) then
          local wasListening = sttpkg.listening()
          if wasListening then stt.stop() end
          local loaded, err = stt.init(model.path)
          if not loaded then return nil, tostring(err) end
          sttpkg.applySensitivity()
          -- Biasing is a property of the model, so a switch has to re-offer
          -- the vocabulary: the model just loaded may accept what the last
          -- one refused
          sttpkg.applyVocabulary()
          sttpkg.config.model = model.path
          sttpkg.saveConfig()
          if wasListening then stt.start() end
          return model.name
        end
      end
    end
  end
  return nil, "no installed model matches " .. fragment
end

function sttpkg.listening()
  return sttpkg.bridgeAvailable() and stt.listening()
end

function sttpkg.enable()
  if not sttpkg.ensureInit() then return end
  -- Sampled here rather than tracked continuously, as the vocabulary standard
  -- directs: what is in reach matters at the moment listening begins
  sttpkg.applyVocabulary()
  stt.start()
  -- Reported rather than assumed: start can be refused, and a microphone
  -- that is not actually live is the one failure worth never guessing about
  if sttpkg.listening() then
    cecho("<green>[STT] listening\n")
  end
end

function sttpkg.disable()
  if sttpkg.bridgeAvailable() and stt.listening() then
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

  -- The catalog carries commands, socials, channels and directions - never
  -- the things standing in front of you, deliberately. So a noun in this room
  -- or your pack could never be corrected: "get wor" had no way back to
  -- "worn", because "worn" is only ever an in-reach word. Those words are
  -- argument-position by nature, so they join the argument lexicon.
  --
  -- Rebuilt per call rather than cached: what is in reach changes with every
  -- room, and it is a couple of dozen words against a catalog of hundreds.
  local argument = sttpkg._lex.argument
  if sttpkg.context and sttpkg.context.inScope then
    local inReach = sttpkg.context.inScope()
    if #inReach > 0 then
      local entries = {}
      for _, word in ipairs(inReach) do entries[#entries + 1] = { word = word } end
      for _, word in ipairs(argument.list) do entries[#entries + 1] = { word = word } end
      argument = sttpkg.correct.lexicon(entries)
    end
  end

  return sttpkg._lex.leading, argument
end

--- How many words correction actually has to work with, or nil when no
-- vocabulary is loaded at all. "Correction on" with nothing to correct
-- against looks identical to correction working, which would quietly
-- misattribute a test result, so the harness reports this rather than the
-- setting alone.
function sttpkg.vocabularySize()
  local leading, argument = lexicons()
  if not leading then return nil end
  return #leading.list + (argument and #argument.list or 0)
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
    prepared = sttpkg.correct.commandCase(prepared)
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
  -- A test scores what was heard rather than acting on it, so a run can be
  -- done while connected without the character doing what was said
  if sttpkg.test and sttpkg.test.submit and sttpkg.test.submit(corrected) then
    return
  end
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
  -- A test scores speech rather than acting on it, and writing a preview into
  -- the command line during one makes a scored phrase look like a routed
  -- command - which is exactly how a stalled test was misread as bad routing
  if sttpkg.test and sttpkg.test.active and sttpkg.test.active() then
    return
  end
  -- Also previewed in autosend mode: the words appear as they are heard and
  -- vanish when the final is sent, which is the only sign the microphone is
  -- live when nothing is left in the command line to look at
  if sttpkg.config.livePreview then
    -- Cased like the final that will replace it, so the preview does not
    -- visibly re-case itself at the end of every utterance. Correction is
    -- deliberately not applied here: a half-spoken word is not yet a
    -- misrecognition to fix.
    if sttpkg.config.lowercase then
      text = sttpkg.correct.commandCase(text)
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
  -- A quality test left running keeps re-arming its level sampler every tenth
  -- of a second, and nothing else ever stops it: the run is only cleared by
  -- test.stop(), and the timers it holds belong to the profile rather than to
  -- this package, so removing the package leaves them firing until Mudlet
  -- restarts. Updating raises sysUninstall too, so this is the ordinary
  -- upgrade path and not only a deliberate removal.
  if sttpkg.test and sttpkg.test.shutdown then
    sttpkg.test.shutdown()
  end
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
    -- Speech belongs to the profile that was in front when it was spoken.
    -- Tabbing to another game leaves this profile's handlers holding the
    -- microphone, so a phrase said to the new game is routed by the old one -
    -- and with autosend on, sent to it. Not a setting: a command reaching the
    -- wrong game is wrong, not a preference.
    focus = registerAnonymousEventHandler("sysProfileFocusChangeEvent", function(_, focused)
      if focused or not sttpkg.listening() then return end
      sttpkg.disable()
      cecho("<orange>[STT] Stopped listening - this profile is no longer in front.\n")
    end),
    -- Every profile hears this one, so each stops its own microphone; a
    -- Mudlet without the event simply never fires it and nothing changes.
    appFocus = registerAnonymousEventHandler("sysApplicationFocusChangeEvent", function(_, active)
      if active or not sttpkg.config.stopOnFocusLoss or not sttpkg.listening() then return end
      sttpkg.disable()
      cecho("<orange>[STT] Stopped listening - Mudlet is not the active window.\n")
    end),
  }
  sttpkg.loadConfig()
end

sttpkg.setup()
