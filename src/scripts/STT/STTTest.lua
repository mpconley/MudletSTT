--- Recognition quality harness.
-- Prompts with phrases, listens for what comes back, and scores it - so
-- settings can be compared with numbers instead of impressions. The scoring
-- half is pure Lua and tested under busted; the running half drives the
-- prompts and collects results.
--
-- The phrase set is deliberately weighted toward what game speech is made of
-- and where recognisers fail: bare one-word commands, and phrases whose first
-- word carries the meaning.
-- @module sttpkg.test

sttpkg = sttpkg or {}
sttpkg.test = sttpkg.test or {}
local test = sttpkg.test

test.phrases = {
  "look",
  "north",
  "inventory",
  "get sword",
  "kill goblin",
  "sit bench",
  "say stop look and listen",
  -- Not "armor": recognisers trained on prose write "armour", and a game whose
  -- own vocabulary spells it that way makes the model right and the phrase
  -- wrong. A fixed list has to avoid words that differ across dialects, or it
  -- scores the dictionary rather than the recogniser.
  "wear leather boots",
  "cast fireball at troll",
  "put coins in bag",
}

-- Seconds to wait for a phrase before recording it as not heard
local PHRASE_TIMEOUT = 12

-- A microphone just opened is not yet delivering audio: the device takes a
-- moment to start, and a phrase spoken into that gap is simply not there to
-- recognise. Prompting immediately after starting to listen made the first
-- phrase of a run fail for reasons that had nothing to do with the engine.
local MICROPHONE_WARMUP_SECONDS = 1.5

--- Lowercased, trimmed, single-spaced text, so scoring compares words rather
-- than spacing and case.
function test.normalize(text)
  text = tostring(text or ""):lower()
  text = text:gsub("[%.,!%?;:]", " ")
  text = text:gsub("%s+", " ")
  return (text:gsub("^%s*(.-)%s*$", "%1"))
end

function test.tokens(text)
  local out = {}
  for word in test.normalize(text):gmatch("%S+") do
    out[#out + 1] = word
  end
  return out
end

--- Word-level edit distance between two token arrays: how many words would
-- have to be substituted, inserted or deleted to turn one into the other.
function test.sequenceDistance(a, b)
  local la, lb = #a, #b
  local prev = {}
  for j = 0, lb do prev[j] = j end
  for i = 1, la do
    local cur = { [0] = i }
    for j = 1, lb do
      local cost = (a[i] == b[j]) and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    end
    prev = cur
  end
  return prev[lb]
end

--- Score one heard phrase against what was asked for.
-- exact: the words match outright.
-- errors/wordErrorRate: word-level edits needed, absolute and per expected word.
-- firstWord: whether the opening word survived - tracked on its own because a
-- command's first word is its verb, so losing it costs the whole phrase
-- however well the rest was heard.
function test.score(expected, heard)
  local want = test.tokens(expected)
  local got = test.tokens(heard)
  local errors = test.sequenceDistance(want, got)
  return {
    expected = test.normalize(expected),
    heard = test.normalize(heard),
    exact = errors == 0,
    errors = errors,
    wordErrorRate = #want > 0 and (errors / #want) or 0,
    firstWord = #want > 0 and got[1] == want[1],
    heardNothing = #got == 0,
  }
end

--- Group scores by phrase and count how often each failed. A phrase that
-- fails every time is a different animal from one that fails now and then:
-- the first is a fault worth chasing, the second is the recogniser being
-- itself, and a single run cannot tell them apart.
function test.byPhrase(scores)
  local order, seen = {}, {}
  for _, score in ipairs(scores) do
    local key = score.expected
    if not seen[key] then
      seen[key] = { expected = key, attempts = 0, failures = 0, heard = {} }
      order[#order + 1] = seen[key]
    end
    local row = seen[key]
    row.attempts = row.attempts + 1
    if not score.exact then
      row.failures = row.failures + 1
      local heard = score.heardNothing and "(nothing)" or score.heard
      row.heard[heard] = (row.heard[heard] or 0) + 1
    end
  end
  return order
end

--- Aggregate scores into the numbers worth comparing between settings.
-- Input level is averaged in alongside the accuracy figures: two runs of the
-- same settings are only comparable if the speech arrived comparably, and
-- runs have differed by more than any setting did.
function test.summarize(scores)
  local total = #scores
  local exact, firstWordLost, silent, errorSum, wordSum, levelSum = 0, 0, 0, 0, 0, 0
  for _, score in ipairs(scores) do
    if score.exact then exact = exact + 1 end
    if not score.firstWord then firstWordLost = firstWordLost + 1 end
    if score.heardNothing then silent = silent + 1 end
    errorSum = errorSum + score.errors
    wordSum = wordSum + #test.tokens(score.expected)
    levelSum = levelSum + (score.peakLevel or 0)
  end
  return {
    phrases = total,
    exact = exact,
    exactRate = total > 0 and (exact / total) or 0,
    firstWordLost = firstWordLost,
    heardNothing = silent,
    wordErrorRate = wordSum > 0 and (errorSum / wordSum) or 0,
    meanPeakLevel = total > 0 and (levelSum / total) or 0,
  }
end

function test.active()
  return test._run ~= nil
end

local function clearTimer()
  if test._run and test._run.timerId then
    killTimer(test._run.timerId)
    test._run.timerId = nil
  end
  if test._run and test._run.levelTimerId then
    killTimer(test._run.levelTimerId)
    test._run.levelTimerId = nil
  end
end

local function settingsLine()
  local engine, model, sensitivity = "?", "none", "?"
  if sttpkg.bridgeAvailable() then
    local info = stt.getInfo()
    engine = info.backend or "?"
    model = (info.modelPath or ""):match("[^/]+$") or "none"
    sensitivity = info.sensitivity or tostring(sttpkg.config.sensitivity)
  end
  local correction = "off"
  if sttpkg.config.correction then
    local words = sttpkg.vocabularySize and sttpkg.vocabularySize() or nil
    correction = words and string.format("on (%d words)", words) or "on (no vocabulary)"
  end
  -- Biasing is the one setting that changes what the decoder itself does
  -- rather than what happens to its output, so a run has to say whether it
  -- was in effect
  local biasing = "unsupported by this model"
  if sttpkg.bridgeAvailable() then
    local info = stt.getInfo()
    if info.capabilities and info.capabilities.biasing then
      biasing = string.format("%d words", sttpkg._biasWords or 0)
    end
  end

  return string.format("engine %s, model %s, sensitivity %s, correction %s, biasing %s",
    engine, model, sensitivity, correction, biasing)
end

local prompt

local function finishPhrase(heard)
  local run = test._run
  if not run then return end
  clearTimer()

  stopSampling()

  local expected = run.phrases[run.index]
  local score = test.score(expected, heard)
  score.peakLevel = run.peakLevel or 0
  run.scores[#run.scores + 1] = score

  if score.exact then
    cecho(string.format("  <green>heard: %s\n", score.heard))
  elseif score.heardNothing then
    cecho("  <red>heard nothing\n")
  else
    cecho(string.format("  <orange>heard: %s <light_slate_gray>(%d word %s%s)\n",
      score.heard, score.errors, score.errors == 1 and "error" or "errors",
      score.firstWord and "" or ", first word lost"))
  end

  run.index = run.index + 1
  if run.index > #run.phrases then
    if run.pass < run.passes then
      run.pass = run.pass + 1
      run.index = 1
      cecho(string.format("<white>-- pass %d of %d --\n", run.pass, run.passes))
      prompt()
    else
      test.report()
    end
  else
    prompt()
  end
end

-- How loudly the phrase arrived, sampled while it is being spoken. Without
-- it a phrase the engine misheard and one the microphone barely received look
-- identical in the results, and they call for opposite remedies.
local LEVEL_SAMPLE_SECONDS = 0.1

local function sampleLevel()
  local run = test._run
  if not run then return end
  if sttpkg.bridgeAvailable() then
    local level = stt.getInfo().audioLevel or 0
    if level > run.peakLevel then run.peakLevel = level end
  end
  run.levelTimerId = tempTimer(LEVEL_SAMPLE_SECONDS, sampleLevel)
end

local function stopSampling()
  local run = test._run
  if run and run.levelTimerId then
    killTimer(run.levelTimerId)
    run.levelTimerId = nil
  end
end

prompt = function()
  local run = test._run
  if not run then return end
  cecho(string.format("<white>[%d/%d] say: <cyan>%s\n", run.index, #run.phrases, run.phrases[run.index]))
  run.peakLevel = 0
  run.timerId = tempTimer(PHRASE_TIMEOUT, function() finishPhrase(nil) end)
  stopSampling()
  sampleLevel()
end

--- Begin a run. Recognised text is scored instead of reaching the game, so a
-- test can be run while connected without playing the character.
function test.start(passes, phrases)
  if test.active() then
    cecho("<orange>[STT] a test is already running - stt test stop\n")
    return false
  end
  if not sttpkg.ensureInit() then return false end

  passes = math.max(1, math.floor(tonumber(passes) or 1))
  test._run = { index = 1, pass = 1, passes = passes, phrases = phrases or test.phrases,
                scores = {}, wasListening = sttpkg.listening() }
  if not test._run.wasListening then
    sttpkg.enable()
  end
  if not sttpkg.listening() then
    test._run = nil
    cecho("<red>[STT] could not start listening, so there is nothing to measure\n")
    return false
  end

  cecho("<white>[STT] quality test: " .. settingsLine() .. "\n")
  cecho("<light_slate_gray>Say each phrase, then pause. Nothing is sent to the game. Stop with: stt test stop\n")

  if test._run.wasListening then
    -- Already open, so already delivering audio
    prompt()
  else
    cecho("<light_slate_gray>Waiting for the microphone to open...\n")
    tempTimer(MICROPHONE_WARMUP_SECONDS, function() prompt() end)
  end
  return true
end

function test.stop(quiet)
  if not test.active() then return false end
  clearTimer()
  local wasListening = test._run.wasListening
  test._run = nil
  if not wasListening then sttpkg.disable() end
  if not quiet then cecho("<light_slate_gray>[STT] test stopped\n")  end
  return true
end

function test.report()
  local run = test._run
  if not run then return end
  local summary = test.summarize(run.scores)
  clearTimer()

  cecho("<white>[STT] results: " .. settingsLine() .. "\n")
  cecho(string.format("<white>  exact %d/%d (%d%%), word error rate %d%%\n",
    summary.exact, summary.phrases, math.floor(summary.exactRate * 100 + 0.5),
    math.floor(summary.wordErrorRate * 100 + 0.5)))
  cecho(string.format("<white>  first word lost %d, heard nothing %d\n",
    summary.firstWordLost, summary.heardNothing))
  cecho(string.format("<white>  mean input level %.3f%s\n", summary.meanPeakLevel,
    summary.meanPeakLevel < 0.08 and " <orange>(quiet - speak up or move closer before comparing runs)" or ""))

  -- Which phrases failed, and how consistently. A phrase missed every pass is
  -- a fault with a cause worth finding; one missed occasionally is variance,
  -- and treating the second as the first is how tuning chases its own tail.
  local rows = test.byPhrase(run.scores)
  local reported = false
  for _, row in ipairs(rows) do
    if row.failures > 0 then
      if not reported then
        cecho("<white>  failures:\n")
        reported = true
      end
      local variants = {}
      for heard, count in pairs(row.heard) do
        variants[#variants + 1] = count > 1 and string.format("%s x%d", heard, count) or heard
      end
      table.sort(variants)
      cecho(string.format("<light_slate_gray>    %s (%d/%d): %s\n",
        row.expected, row.failures, row.attempts, table.concat(variants, ", ")))
    end
  end

  test._lastSummary = summary
  test.stop(true)
end

--- Called by STTCore for every final result while a test is running.
function test.submit(text)
  if not test.active() then return false end
  finishPhrase(text)
  return true
end
