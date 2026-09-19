-- Dispatcher for the `stt` alias. All behaviour lives in sttpkg; this only
-- parses the subcommand.
local args = matches[2]
local sub, rest = nil, nil
if args then
  sub, rest = args:match("^(%S+)%s*(.*)$")
end

local function onOff(value)
  return value == "on" or (value ~= "off" and nil)
end

if sub == nil or sub == "toggle" then
  sttpkg.toggle()
elseif sub == "on" then
  sttpkg.enable()
elseif sub == "off" then
  sttpkg.disable()
elseif sub == "status" then
  local state = "no speech bridge in this Mudlet build"
  local capabilities = {}
  if sttpkg.bridgeAvailable() then
    local info = stt.getInfo() or {}
    local modelName = (info.modelPath or ""):match("[^/]+$") or "none"
    state = string.format("engine %s, state %s, model %s", info.backend or "?", info.state or "?", modelName)
    capabilities = info.capabilities or {}
  end
  cecho("<light_slate_gray>[STT] " .. state .. "\n")
  cecho(string.format("<light_slate_gray>[STT] autosend %s, preview %s, correction %s, lowercase %s, timeout %dms\n",
    sttpkg.config.autosend and "on" or "off",
    sttpkg.config.livePreview and "on" or "off",
    sttpkg.config.correction and "on" or "off",
    sttpkg.config.lowercase and "on" or "off",
    sttpkg.config.silenceTimeout or 0))
  -- Whether biasing is on is worth as little as whether it can be: a player
  -- who has turned it on and sees no difference is asking one question, and
  -- only the capability answers it. Said only when the answer is no, because
  -- the yes is the ordinary case and this line is read at a glance.
  --
  -- "== false" and not "not": a capability this Mudlet does not publish reads
  -- nil, and nil is not an answer. sensitivityTuning is nil on every Mudlet up
  -- to 5.0.1, so testing truthiness would invent a limit out of a missing key
  -- and tell every one of those players their engine cannot be tuned.
  local tuningNote = capabilities.sensitivityTuning == false and " (this engine sets its own phrase endings)" or ""
  local biasNote = capabilities.biasing == false and " (this engine or model cannot be biased)" or ""
  cecho(string.format("<light_slate_gray>[STT] sensitivity %s%s, bias %s%s, focus %s\n",
    tostring(sttpkg.config.sensitivity), tuningNote,
    sttpkg.config.biasing and "on" or "off", biasNote,
    sttpkg.config.stopOnFocusLoss and "stop" or "keep"))
  -- Last, because it is the line someone is asked to paste rather than the one
  -- they came for: what is installed, and how current each piece is.
  cecho("<light_slate_gray>[STT] " .. sttpkg.versions() .. "\n")
elseif sub == "autosend" and onOff(rest) ~= nil then
  sttpkg.config.autosend = onOff(rest)
  sttpkg.saveConfig()
  cecho("<light_slate_gray>[STT] autosend " .. rest .. "\n")
elseif sub == "preview" and onOff(rest) ~= nil then
  sttpkg.config.livePreview = onOff(rest)
  sttpkg.saveConfig()
  cecho("<light_slate_gray>[STT] live preview " .. rest .. "\n")
elseif sub == "correct" and onOff(rest) ~= nil then
  sttpkg.config.correction = onOff(rest)
  sttpkg.saveConfig()
  cecho("<light_slate_gray>[STT] correction " .. rest .. "\n")
elseif sub == "lowercase" and onOff(rest) ~= nil then
  sttpkg.config.lowercase = onOff(rest)
  sttpkg.saveConfig()
  cecho("<light_slate_gray>[STT] lowercase " .. rest .. "\n")
elseif sub == "timeout" and tonumber(rest) then
  sttpkg.config.silenceTimeout = math.max(0, math.floor(tonumber(rest)))
  sttpkg.saveConfig()
  if sttpkg.bridgeAvailable() and stt.initialized() then
    stt.setSilenceTimeout(sttpkg.config.silenceTimeout)
  end
  cecho("<light_slate_gray>[STT] silence timeout " .. sttpkg.config.silenceTimeout .. "ms\n")
elseif sub == "sensitivity" and (rest == "short" or rest == "default" or rest == "long") then
  sttpkg.config.sensitivity = rest
  sttpkg.saveConfig()
  local applied, why = sttpkg.applySensitivity()
  if applied then
    cecho("<light_slate_gray>[STT] sensitivity " .. rest .. "\n")
  elseif why == "deferred" then
    -- This engine can tune, it just could not right now - it was listening, mid
    -- phrase, or already in error with its handles alive, which is where a
    -- denied microphone leaves it. The core keeps the value and builds it into the next model
    -- it loads, so telling the player it cannot be set would be wrong twice.
    -- Acknowledged rather than explained: the core has already said why
    -- through sysSTTError, which this package prints, and repeating it here
    -- shows the same sentence twice.
    cecho("<light_slate_gray>[STT] sensitivity " .. rest .. " - not yet in effect\n")
  elseif why == "failed" then
    -- Not a wait-and-see: the engine tried, and what came back is an engine
    -- with nothing loaded. Saying "takes effect at the next model load" here
    -- would send the player away from the one thing that fixes it.
    cecho("<orange>[STT] sensitivity " .. rest
      .. " saved, but the engine could not be rebuilt for it and is now unloaded - run: stt\n")
  else
    -- Saved either way: the setting is the package's, and a later engine may
    -- honour what this one cannot. Not every refusal is a broken build - the
    -- built-in macOS recogniser decides its own endpointing and refuses this
    -- outright, which is a property of that engine and not a fault.
    cecho("<orange>[STT] the current speech engine does not let its sensitivity be set; "
      .. "kept as " .. rest .. " for engines that do\n")
  end
elseif sub == "focus" and (rest == "stop" or rest == "keep") then
  sttpkg.config.stopOnFocusLoss = (rest == "stop")
  sttpkg.saveConfig()
  if rest == "stop" then
    cecho("<light_slate_gray>[STT] listening stops when Mudlet is not the active window\n")
  else
    cecho("<light_slate_gray>[STT] listening continues while other windows are in front\n")
  end
elseif sub == "test" then
  if rest == "stop" then
    if not sttpkg.test.stop() then
      cecho("<light_slate_gray>[STT] no test is running\n")
    end
  elseif rest and rest:find("^phrases") then
    -- An explicit list, for asking one question of the recogniser: "score
    -- guild" against "guild score", say. Semicolons separate phrases; a
    -- trailing number is the pass count, as for the other forms.
    local phrases, passes = sttpkg.test.parsePhraseList(rest:match("^phrases%s*(.*)$"))
    if #phrases == 0 then
      cecho("<orange>[STT] no phrases given - stt test phrases score guild; guild score 3\n")
    else
      sttpkg.test.start(passes, phrases)
    end
  elseif rest and rest:find("^game") then
    -- Phrases from this game's own catalog and what is in reach. Opt-in: a set
    -- drawn from a room is not comparable with the fixed list, nor with a set
    -- drawn from a different room, so it must never replace either silently.
    local passes = tonumber(rest:match("game%s+(%d+)"))
    local phrases = sttpkg.test.gamePhrases()
    if #phrases == 0 then
      cecho("<orange>[STT] no game vocabulary to build phrases from - this game may not publish a catalog\n")
    else
      sttpkg.test.start(passes, phrases)
    end
  elseif rest and rest:find("^repeat") then
    -- The same words again, so two runs are a comparison rather than two
    -- different questions asked of the same recogniser
    local passes = tonumber(rest:match("repeat%s+(%d+)"))
    local phrases = sttpkg.test.lastPhrases()
    if not phrases then
      cecho("<orange>[STT] no earlier phrase set to repeat - run stt test game, scope or phrases first\n")
    else
      sttpkg.test.start(passes, phrases)
    end
  elseif rest and rest:find("^scope") then
    -- Phrases naming what is actually in this room and inventory, which is
    -- the only way to measure whether biasing toward them helps
    local passes = tonumber(rest:match("scope%s+(%d+)"))
    local phrases = sttpkg.test.scopePhrases()
    if #phrases == 0 then
      cecho("<orange>[STT] nothing in reach to build phrases from - try a room with things in it\n")
    else
      sttpkg.test.start(passes, phrases)
    end
  else
    -- "stt test 3" runs the phrases three times: one pass through ten phrases
    -- is too few to tell a real difference from the spread between runs
    sttpkg.test.start(tonumber(rest))
  end
elseif sub == "vocab" then
  -- For a game author reworking a catalog: which of their words can be spoken
  -- at all, and what the biasing budget is currently being spent on
  sttpkg.grade.show(rest)
elseif sub == "model" and rest ~= "" and rest ~= nil then
  local name, err = sttpkg.useModel(rest)
  if name then
    cecho("<light_slate_gray>[STT] loaded " .. name .. "\n")
  else
    cecho("<orange>[STT] " .. tostring(err) .. "\n")
  end
elseif sub == "bias" and onOff(rest) ~= nil then
  sttpkg.config.biasing = onOff(rest)
  sttpkg.saveConfig()
  local applied, why = sttpkg.applyVocabulary()
  if why == "deferred" then
    -- The engine rebuilds its decoder to change what it biases toward and
    -- cannot while it is listening. It has kept the request; saying the model
    -- cannot bias would be wrong, and so would reporting the new count, since
    -- the decoder is still running with the old one.
    cecho(string.format("<light_slate_gray>[STT] biasing %s - takes effect at the next model load,"
      .. " still %d words until then\n", rest, applied))
  elseif sttpkg.config.biasing and why == "nomodel" then
    -- Named apart from the line below it because the two ask for opposite
    -- things: load the model you have, against find a different one.
    cecho("<orange>[STT] biasing on, but no model is loaded to bias - stt on loads one\n")
  elseif sttpkg.config.biasing and why == "unsupported" then
    cecho("<orange>[STT] biasing on, but this model cannot bias its decoding\n")
  elseif sttpkg.config.biasing and why == "nocatalog" then
    cecho("<orange>[STT] biasing on, but no game vocabulary has arrived to bias toward\n")
  else
    cecho(string.format("<light_slate_gray>[STT] biasing %s (%d words)\n", rest, applied))
  end
elseif sub == "models" then
  if not sttpkg.bridgeAvailable() then
    cecho("<orange>[STT] No speech bridge in this Mudlet build.\n")
  else
    for _, engine in ipairs({ "sherpa", "vosk" }) do
      local ok, models = pcall(stt.listModels, engine)
      if ok and models then
        for _, model in ipairs(models) do
          cecho("<light_slate_gray>[STT] " .. engine .. ": " .. model.name .. "\n")
        end
      end
    end
  end
else
  cecho([[<light_slate_gray>[STT] Speech to text:
  stt              toggle listening (also: stt on / stt off)
  stt status       engine, state and settings
  stt autosend on|off    send finals to the game instead of the command line
  stt preview on|off     show partial results live in the command line
  stt correct on|off     correct finals against the game vocabulary (MCVP)
  stt lowercase on|off   lowercase the first letter, the way commands are typed
  stt sensitivity short|default|long   how soon a phrase counts as finished
  stt timeout <ms>       stop after this much silence; 0 keeps listening
  stt focus stop|keep    whether to stop listening when Mudlet loses focus
  stt test [n]     score recognition against set phrases, n passes (stt test stop)
  stt test scope [n]   score phrases naming what is in this room and inventory
  stt test game [n]    score phrases from this game's own catalog and what is in reach
  stt test phrases <a>; <b>; ... [n]   score an explicit list, to compare two wordings
  stt test repeat [n]  run the last built set again, so two runs compare
  stt vocab [n|all]  grade this game's vocabulary for how well it can be spoken
  stt model <name> load a different installed model, to compare them
  stt bias on|off  bias the decoder toward the game's vocabulary (measure it)
  stt models       list installed speech models
]])
end
