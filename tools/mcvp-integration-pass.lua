-- MCVP / STT live integration pass.
--
-- Run this connected to StickMUD, as a Script in the editor or via dofile.
-- Phase 1 checks everything that can be checked without speaking; phase 2 is
-- the spoken run, which needs you.
--
-- The point is evidence, not impressions: every check prints what it saw, so a
-- failure names the layer that failed rather than "speech seemed worse".

_pass = _pass or {}

local function ok(label, detail)
  cecho(string.format("<green>  yes  <reset>%s <dim_grey>%s\n", label, detail or ""))
end

local function no(label, detail)
  cecho(string.format("<red>  no   <reset>%s <dim_grey>%s\n", label, detail or ""))
end

local function note(text)
  cecho(string.format("<dim_grey>       %s\n", text))
end

--- Phase 1: the wire, the catalog, and what is in reach. No microphone.
function _pass.check()
  cecho("\n<cyan>MCVP / STT integration pass - phase 1\n")

  -- 1. The packages
  local hasMcvp = type(mcvp) == "table" and type(mcvp.entries) == "function"
  local hasStt = type(sttpkg) == "table"
  local hasBridge = type(stt) == "table" and type(stt.init) == "function"
  if hasMcvp then
    ok("MudletMCVP loaded")
  else
    no("MudletMCVP loaded", "install it first - context binding lives there now")
  end
  if hasStt then ok("MudletSTT loaded") else no("MudletSTT loaded") end
  if hasBridge then
    ok("speech bridge present in this Mudlet")
  else
    no("speech bridge present", "this build has no stt.* - it needs the speech bridge")
  end
  if not hasMcvp then return end

  -- 2. The catalog: did the server actually send one, and is it usable
  local version = mcvp.version()
  local entries = mcvp.entries()
  local biasable = mcvp.entries({biasable = true})
  if version then
    ok("catalog received", "version=" .. tostring(version))
  else
    no("catalog received", "no Client.Vocabulary yet - check the server negotiated the package")
    note("on the server: gmcpvocab <character> prints what it would send")
  end
  -- mcvp.entries{biasable} spans tiers 1 and 2, which the server caps
  -- separately at 300 and 500. Comparing the combined count against the
  -- tier-1 cap alone reports a healthy catalog as over budget.
  local tierOne = mcvp.entries({biasable = true, maxPriority = 1})
  cecho(string.format("       entries=%d biasable=%d (tier 1: %d)\n", #entries, #biasable, #tierOne))
  if #tierOne > 300 then
    no("tier 1 within the server's cap", #tierOne .. " over 300 - the daemon's demotion pass did not converge")
  elseif #biasable > 800 then
    no("catalog within the server's caps", #biasable .. " over the 300 + 500 the two tiers allow")
  else
    ok("catalog within the server's caps", string.format("tier 1 %d of 300, biasable %d of 800", #tierOne, #biasable))
  end

  -- 3. Context: is anything telling us what is in reach
  if type(mcvp.context) ~= "table" then
    no("mcvp.context present", "this MudletMCVP predates the context split")
  elseif not mcvp.context.bound() then
    no("a context adapter is bound", "STTContext should register one on load")
  else
    ok("a context adapter is bound")
    local inReach = mcvp.context.inScope()
    local items = mcvp.context.inScope({slot = "%item"})
    local livings = mcvp.context.inScope({slot = "%living"})
    cecho(string.format("       in reach: %d words (%d item, %d living)\n", #inReach, #items, #livings))
    if #inReach == 0 then
      note("empty is legitimate in an empty room - move somewhere with objects and rerun")
    else
      note("names: " .. table.concat(mcvp.context.displayNames(), ", "):sub(1, 120))
    end
  end

  -- 4. The engine
  if hasBridge then
    local info = stt.getInfo()
    -- backend names the engine that is loaded, which before stt.init() is
    -- nothing - so it reads "none" even when a library is present and usable
    local backend = info.backend or "?"
    if backend == "none" or backend == "" then
      backend = "not chosen until stt.init()"
    end
    if stt.available() then
      ok("engine library loaded", backend)
    else
      no("engine library loaded", "install one under " .. stt.getLibraryPath())
    end
    if #stt.listModels() > 0 then
      ok("model installed", #stt.listModels() .. " found")
    else
      no("model installed", "nothing under " .. stt.getModelPath())
    end
    if info.words ~= nil then
      cecho(string.format("       capabilities: words=%s vocabulary=%s onDevice=%s\n",
            tostring(info.words), tostring(info.vocabulary), tostring(info.onDevice)))
    end
    -- The comparison is only meaningful on a model that can take words
    if info.vocabulary == false then
      no("this model can be biased", "biasing has no effect - stt model zipformer switches to one that can")
    elseif info.vocabulary then
      ok("this model can be biased")
    end
  end

  -- 5. The join: applyVocabulary() is where in-reach words and the catalog
  -- meet, and it reports how many the engine actually took. Zero with a
  -- catalog present means the two halves are not meeting.
  if hasStt and type(sttpkg.applyVocabulary) == "function" then
    local applied = sttpkg.applyVocabulary()
    if applied > 0 then
      ok("biasing applied", applied .. " words taken by the engine")
      note("in-reach words go in first, then the catalog fills what is left")
    elseif not sttpkg.config or not sttpkg.config.biasing then
      note("biasing is switched off in this profile - stt biasing on")
    else
      no("biasing applied", "nothing was taken; with a catalog present that is the join failing")
    end
  end

  cecho("<cyan>\nPhase 2 is spoken - run _pass.speak() with the microphone ready.\n\n")
end

--- Phase 2: the spoken run. Scores what came back against what was asked for,
-- using the package's own test harness, and prints a comparison.
function _pass.speak(passes)
  if not (sttpkg and sttpkg.test) then
    cecho("<red>MudletSTT's test harness is not loaded\n")
    return
  end
  local phrases = sttpkg.test.scopePhrases(8)
  if #phrases == 0 then
    cecho("<orange>No in-scope phrases - stand somewhere with objects and creatures, then rerun _pass.check()\n")
    return
  end
  cecho("<cyan>Speak each phrase when prompted. These are built from what is actually in reach:\n")
  for _, p in ipairs(phrases) do cecho("  " .. p .. "\n") end
  sttpkg.test.start(passes or 1, phrases)
end


--- Phase 2b: the same phrases spoken twice, once with biasing and once
-- without, scored and compared automatically.
--
-- Two things this is careful about, because getting them wrong is how tuning
-- chases its own tail:
--
--  * The same phrase list is used for both runs, captured once. If you move
--    between runs, what is in reach changes and the comparison is worthless.
--  * The order is randomised. Saying a phrase a second time is easier than
--    the first, so a fixed order credits whichever condition ran second with
--    your practice.
--
-- It also reports the mean input level of each run: two runs are comparable
-- only if the speech arrived comparably.
function _pass.compare(passes)
  if not (sttpkg and sttpkg.test) then
    cecho("<red>MudletSTT's test harness is not loaded\n")
    return
  end
  if sttpkg.test.active() then
    cecho("<orange>a test is already running - stt test stop\n")
    return
  end

  local phrases = sttpkg.test.scopePhrases(8)
  if #phrases == 0 then
    cecho("<orange>No in-scope phrases - stand somewhere with objects and creatures first\n")
    return
  end

  local restore = sttpkg.config and sttpkg.config.biasing
  local biasedFirst = (math.random(2) == 1)
  local order = {biasedFirst, not biasedFirst}
  local results = {}

  cecho("\n<cyan>Biasing comparison - the same phrases, twice\n")
  cecho("<reset>These come from what is in reach right now. Do not move between runs.\n")
  for _, phrase in ipairs(phrases) do cecho("  " .. phrase .. "\n") end
  cecho(string.format("<dim_grey>Order drawn at random: biasing %s first.\n", order[1] and "on" or "off"))

  local function runOne(step)
    if step > #order then
      _pass._compareReport(results, restore)
      return
    end
    local biasing = order[step]
    sttpkg.config.biasing = biasing
    local applied = sttpkg.applyVocabulary()

    -- A biased run that applied nothing is the same condition as the plain
    -- one, so the comparison would be two identical runs and any difference
    -- between them is chance. Not worth sixteen spoken phrases to find out.
    if biasing and applied == 0 then
      cecho("<red>\nThe engine took no biasing words, so there is nothing to compare.\n")
      local info = stt.getInfo()
      if info and info.vocabulary == false then
        cecho("<orange>This model cannot take a vocabulary at all. The streaming Zipformer\n")
        cecho("<orange>can: switch with  stt model zipformer  and run this again.\n")
      else
        cecho("<orange>Check that a catalog has arrived and that words are in reach - _pass.check().\n")
      end
      sttpkg.config.biasing = restore
      sttpkg.applyVocabulary()
      return
    end

    cecho(string.format("\n<white>Run %d of 2: biasing %s (%d words applied)\n",
                        step, biasing and "ON" or "OFF", applied))

    sttpkg.test._lastSummary = nil
    if not sttpkg.test.start(passes or 1, phrases) then
      cecho("<red>the run would not start; comparison abandoned\n")
      sttpkg.config.biasing = restore
      sttpkg.applyVocabulary()
      return
    end

    -- Waits for the run to end rather than guessing how long speaking takes
    local function watch()
      if sttpkg.test.active() then
        tempTimer(2, watch)
        return
      end
      local summary = sttpkg.test._lastSummary
      if not summary then
        cecho("<orange>that run was stopped before it finished - comparison abandoned\n")
        sttpkg.config.biasing = restore
        sttpkg.applyVocabulary()
        return
      end
      results[#results + 1] = {biasing = biasing, applied = applied, summary = summary}
      tempTimer(1, function() runOne(step + 1) end)
    end
    tempTimer(2, watch)
  end

  runOne(1)
end

function _pass._compareReport(results, restore)
  local on, off
  for _, r in ipairs(results) do
    if r.biasing then on = r else off = r end
  end
  if not (on and off) then return end

  local function pct(x) return math.floor(x * 100 + 0.5) end
  cecho("\n<cyan>Biasing comparison\n")
  cecho(string.format("<white>                biased   plain    difference\n"))
  cecho(string.format("  exact         %-8s %-8s %+d points\n",
        pct(on.summary.exactRate) .. "%", pct(off.summary.exactRate) .. "%",
        pct(on.summary.exactRate) - pct(off.summary.exactRate)))
  cecho(string.format("  word errors   %-8s %-8s %+d points\n",
        pct(on.summary.wordErrorRate) .. "%", pct(off.summary.wordErrorRate) .. "%",
        pct(on.summary.wordErrorRate) - pct(off.summary.wordErrorRate)))
  cecho(string.format("  first word lost   %-2d       %-2d\n",
        on.summary.firstWordLost, off.summary.firstWordLost))
  cecho(string.format("  heard nothing     %-2d       %-2d\n",
        on.summary.heardNothing, off.summary.heardNothing))
  cecho(string.format("<dim_grey>  input level   %.3f    %.3f\n",
        on.summary.meanPeakLevel, off.summary.meanPeakLevel))

  -- Whether the two runs are comparable comes before what they say
  local louder = math.max(on.summary.meanPeakLevel, off.summary.meanPeakLevel)
  local quieter = math.min(on.summary.meanPeakLevel, off.summary.meanPeakLevel)
  if quieter > 0 and louder / quieter > 1.5 then
    cecho("<orange>  The runs did not arrive comparably - one was half again as loud.\n")
    cecho("<orange>  Treat the difference above as noise and run it again.\n")
  elseif on.summary.phrases < 8 then
    cecho("<dim_grey>  Few phrases: a point or two here is variance, not signal.\n")
  end
  cecho(string.format("<dim_grey>  %d words were applied when biased.\n", on.applied))

  sttpkg.config.biasing = restore
  sttpkg.applyVocabulary()
  cecho(string.format("<dim_grey>  biasing restored to %s\n\n", tostring(restore)))
end

_pass.check()
