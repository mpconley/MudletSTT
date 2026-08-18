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
    state = string.format("engine %s, state %s, model %s", info.backend or "?", info.state or "?", (info.modelPath or ""):match("[^/]+$") or "none")
  end
  cecho("<light_slate_gray>[STT] " .. state .. "\n")
  cecho(string.format("<light_slate_gray>[STT] autosend %s, preview %s, correction %s, timeout %dms\n",
    sttpkg.config.autosend and "on" or "off",
    sttpkg.config.livePreview and "on" or "off",
    sttpkg.config.correction and "on" or "off",
    sttpkg.config.silenceTimeout or 0))
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
elseif sub == "timeout" and tonumber(rest) then
  sttpkg.config.silenceTimeout = math.max(0, math.floor(tonumber(rest)))
  sttpkg.saveConfig()
  if sttpkg.bridgeAvailable() and stt.isInitialized() then
    stt.setSilenceTimeout(sttpkg.config.silenceTimeout)
  end
  cecho("<light_slate_gray>[STT] silence timeout " .. sttpkg.config.silenceTimeout .. "ms\n")
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
  stt timeout <ms>       stop after this much silence; 0 keeps listening
  stt models       list installed speech models
]])
end
