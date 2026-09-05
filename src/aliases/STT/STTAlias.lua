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
  if sttpkg.bridgeAvailable() then
    local info = stt.getInfo()
    local modelName = (info.modelPath or ""):match("[^/]+$") or "none"
    state = string.format("engine %s, state %s, model %s", info.backend or "?", info.state or "?", modelName)
  end
  cecho("<light_slate_gray>[STT] " .. state .. "\n")
  cecho(string.format("<light_slate_gray>[STT] autosend %s, preview %s, correction %s, lowercase %s, timeout %dms\n",
    sttpkg.config.autosend and "on" or "off",
    sttpkg.config.livePreview and "on" or "off",
    sttpkg.config.correction and "on" or "off",
    sttpkg.config.lowercase and "on" or "off",
    sttpkg.config.silenceTimeout or 0))
  cecho(string.format("<light_slate_gray>[STT] sensitivity %s, focus %s\n",
    tostring(sttpkg.config.sensitivity),
    sttpkg.config.stopOnFocusLoss and "stop" or "keep"))
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
  local applied = sttpkg.applyVocabulary()
  if sttpkg.config.biasing and applied == 0 then
    cecho("<orange>[STT] biasing on, but this model cannot bias its decoding\n")
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
  stt model <name> load a different installed model, to compare them
  stt bias on|off  bias the decoder toward the game's vocabulary (measure it)
  stt models       list installed speech models
]])
end
