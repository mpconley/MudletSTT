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

-- Named in one place so a new timer cannot be added and forgotten here. An id
-- left armed outlives the package: tempTimer ids belong to the profile, not to
-- the script that armed them, so uninstalling does not reap them.
local RUN_TIMER_FIELDS = { "timerId", "levelTimerId", "warmupTimerId" }

local function clearTimer()
  if not test._run then return end
  for _, field in ipairs(RUN_TIMER_FIELDS) do
    if test._run[field] then
      killTimer(test._run[field])
      test._run[field] = nil
    end
  end
end

local function settingsLine()
  local engine, model, sensitivity = "?", "none", "?"
  if sttpkg.bridgeAvailable() then
    local info = stt.getInfo()
    engine = (info.backend ~= "" and info.backend) or "none loaded"
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

prompt = function()
  local run = test._run
  if not run then return end
  cecho(string.format("<white>[%d/%d] say: <cyan>%s\n", run.index, #run.phrases, run.phrases[run.index]))
  run.peakLevel = 0
  run.timerId = tempTimer(PHRASE_TIMEOUT, function() finishPhrase(nil) end)
  stopSampling()
  sampleLevel()
end

--- Phrases built from what is actually in reach, so a run measures the words
-- a player would really say here rather than a fixed list that may name
-- nothing this game has. Verbs come from what the catalog says takes an item.
function test.scopePhrases(limit)
  if not (sttpkg.context and sttpkg.context.inScope) then return {} end
  limit = limit or 8

  local phrases = {}
  for _, word in ipairs(sttpkg.context.inScope({ slot = "%item" })) do
    phrases[#phrases + 1] = "get " .. word
    if #phrases >= limit then break end
  end
  for _, word in ipairs(sttpkg.context.inScope({ slot = "%living" })) do
    if #phrases >= limit then break end
    phrases[#phrases + 1] = "kill " .. word
  end
  return phrases
end

-- Short forms are abbreviations rather than words, and a recogniser steered
-- toward one prefers it to the word it abbreviates - the same reason biasing
-- leaves them out. A phrase set is also spoken aloud by a person, so anything
-- that is not plainly letters has no business in it.
local MIN_SPOKEN_LENGTH = 3

local function speakable(word)
  return type(word) == "string" and #word >= MIN_SPOKEN_LENGTH and word:find("^%a+$") ~= nil
end

-- A body has to be prose the catalog does not contain, or the phrase scores
-- vocabulary again by accident. Not enough on its own, though: the first
-- version of this used "hello there everyone", and StickMUD has a social
-- called hallo - so a body coming back as "hallo there everyone" could not be
-- told apart from prose being corrupted, when the decoder had simply heard a
-- word that is genuinely ambiguous. A probe has to be far from the catalog
-- acoustically, not merely absent from it.
--
-- So the pool is ordinary words, and any that the catalog would consider a
-- correction candidate are dropped before the body is built. What is left is
-- prose whose failure means the recogniser and nothing else.
local PROSE_POOL = { "the", "weather", "today", "is", "rather", "pleasant", "outside" }
local PROSE_WORDS = 4

function test.proseBody()
  local lex = nil
  if mcvp and mcvp.entries and sttpkg.correct and sttpkg.correct.lexicon then
    lex = sttpkg.correct.lexicon(mcvp.entries({ correctable = true }))
  end
  local words = {}
  for _, word in ipairs(PROSE_POOL) do
    -- An exact match is vocabulary; anything the corrector would change is one
    -- edit from vocabulary. Either way the probe scores the catalog.
    local tooClose = lex ~= nil and (lex.exact[word] ~= nil or sttpkg.correct.token(word, lex) ~= nil)
    if not tooClose then
      words[#words + 1] = word
      if #words >= PROSE_WORDS then break end
    end
  end
  if #words < 2 then return nil end
  return table.concat(words, " ")
end

local function firstInScope(slot)
  if not (sttpkg.context and sttpkg.context.inScope) then return nil end
  for _, word in ipairs(sttpkg.context.inScope({ slot = slot }) or {}) do
    if speakable(word) then return word end
  end
  return nil
end

local function firstOfCategory(category)
  if not (mcvp and mcvp.entries) then return nil end
  for _, entry in ipairs(mcvp.entries({ category = category }) or {}) do
    if speakable(entry.word) then return entry.word end
  end
  return nil
end

--- Fill a syntax pattern with words that are actually here, or nil when a slot
-- cannot be filled. A pattern naming something the game has not published
-- yields nothing rather than a phrase with a hole in it.
function test.fillPattern(syntax, pick)
  if type(syntax) ~= "string" then return nil end
  pick = pick or firstInScope
  local out = {}
  for token in syntax:gmatch("%S+") do
    if token:sub(1, 1) ~= "%" then
      out[#out + 1] = token
    elseif token == "%text" then
      local body = test.proseBody()
      if not body then return nil end
      out[#out + 1] = body
    elseif token == "%item" or token == "%living" then
      local word = pick(token)
      if not word then return nil end
      out[#out + 1] = word
    elseif token == "%direction" then
      local word = firstOfCategory("directions")
      if not word then return nil end
      out[#out + 1] = word
    elseif token == "%word" then
      local word = firstOfCategory("helptopics")
      if not word then return nil end
      out[#out + 1] = word
    else
      -- %player, or a class this client does not know: unfillable
      return nil
    end
  end
  return table.concat(out, " ")
end

--- A phrase set built from this game's own vocabulary and what is in reach,
-- rather than from a fixed list of plausible MUD English.
--
-- The fixed list is deliberately free of words that vary by dialect, so it
-- scores the recogniser rather than a dictionary - but it also names almost
-- nothing any particular game has, which means biasing has little to rescue
-- and its effect is mostly invisible to a run. This set is the other way
-- round: tier-1 verbs are the short words recognisers actually lose, filled
-- patterns name what is standing in front of the character, and one message
-- body checks that prose survives the trip untouched.
--
-- Opt-in, and returned rather than stored, because a set drawn from a room
-- changes when the character walks: two runs of different sets are not a
-- comparison, and comparing settings is the entire purpose of this harness.
function test.gamePhrases(limit)
  limit = tonumber(limit) or 10
  if not (mcvp and mcvp.entries) then return {} end

  local phrases, seen = {}, {}
  local function add(text)
    if text and text ~= "" and not seen[text] and #phrases < limit then
      seen[text] = true
      phrases[#phrases + 1] = text
    end
  end

  -- Rotate through what is in reach rather than naming the same thing in every
  -- phrase. Taking the first match each time produced a run that was six ways
  -- of saying "beer", including "eat beer" and "wear beer" - phrases nobody
  -- would say, whose failures score the absurdity rather than the vocabulary.
  local pools, cursors = {}, {}
  local function rotate(slot)
    if not pools[slot] then
      pools[slot] = {}
      local inScope = sttpkg.context and sttpkg.context.inScope
      for _, word in ipairs((inScope and sttpkg.context.inScope({ slot = slot })) or {}) do
        if speakable(word) then pools[slot][#pools[slot] + 1] = word end
      end
    end
    local pool = pools[slot]
    if #pool == 0 then return nil end
    cursors[slot] = (cursors[slot] or 0) + 1
    return pool[((cursors[slot] - 1) % #pool) + 1]
  end

  -- Patterns first: they carry the nouns, and they are the ones that can fail
  -- to fill, so letting them claim their places before the bare verbs keeps a
  -- run from being all verbs whenever the room is empty.
  for _, entry in ipairs(mcvp.entries({ category = "commands" }) or {}) do
    if entry.syntax and speakable(entry.word) then
      add(test.fillPattern(entry.syntax, rotate))
    end
  end

  -- One message body, whichever command carries the first %text pattern
  for _, entry in ipairs(mcvp.entries({ category = "channels" }) or {}) do
    if entry.syntax and entry.syntax:find("%%text") and speakable(entry.word) then
      add(test.fillPattern(entry.syntax, rotate))
      break
    end
  end

  -- Then the bare verbs a character says constantly. maxPriority 1 is the tier
  -- the catalog reserves for exactly those.
  for _, entry in ipairs(mcvp.entries({ category = "commands", maxPriority = 1 }) or {}) do
    if not entry.syntax and speakable(entry.word) then
      add(entry.word)
    end
  end

  add(firstOfCategory("directions"))
  return phrases
end

--- The last set built from the game or the room, or nil when only the fixed
-- list has been run. What makes a second run a comparison rather than a
-- different question.
function test.lastPhrases()
  return test._lastPhrases
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
  local set = phrases or test.phrases
  -- Kept so "stt test repeat" can ask the same question twice. Only a built
  -- set is worth remembering; the fixed list is always available by name.
  if phrases then
    test._lastPhrases = set
    cecho("<light_slate_gray>[STT] phrase set for this run:\n")
    for i, phrase in ipairs(set) do
      cecho(string.format("<light_slate_gray>  %d. %s\n", i, phrase))
    end
  end
  test._run = { index = 1, pass = 1, passes = passes, phrases = set,
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
    test._run.warmupTimerId = tempTimer(MICROPHONE_WARMUP_SECONDS, function() prompt() end)
  end
  return true
end

-- Seconds to keep swallowing results after a run ends. Stopping the engine
-- makes it flush whatever it had decoded, which arrives as a final once the
-- run is over: that speech was said to the test and must not reach the game
-- just because the test finished before it did.
local DRAIN_SECONDS = 2

-- Only a level this close to silence is worth remarking on: it means the
-- microphone is barely picking anything up. A higher bar was tried and proved
-- worthless - runs at 0.016 and 0.019 scored 67% and 87%, so within the range
-- this system actually operates in, loudness does not predict accuracy and a
-- warning about it only misleads. The figure is still reported, because two
-- runs are comparable only if the speech arrived comparably, and because a
-- dead microphone should be obvious.
local NEAR_SILENT_INPUT = 0.005

function test.stop(quiet)
  if not test.active() then return false end
  clearTimer()
  local wasListening = test._run.wasListening
  test._run = nil
  test._draining = true
  test._drainTimerId = tempTimer(DRAIN_SECONDS, function() test._draining = false end)
  if not wasListening then sttpkg.disable() end
  if not quiet then cecho("<light_slate_gray>[STT] test stopped\n")  end
  return true
end

--- Stop a run and cancel everything it scheduled, for a package going away.
-- stop() on its own is not enough here, because it arms the drain timer, and
-- draining exists to keep a late final away from the game through handlers
-- that teardown is removing in the same breath.
function test.shutdown()
  test.stop(true)
  if test._drainTimerId then
    killTimer(test._drainTimerId)
    test._drainTimerId = nil
  end
  test._draining = false
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
    summary.meanPeakLevel < NEAR_SILENT_INPUT and " <orange>(near silence - check the microphone)" or ""))

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
-- Returning true means the result has been dealt with and must go no further.
function test.submit(text)
  if test._draining then
    -- The engine's parting flush, belonging to a run that has ended
    return true
  end
  if not test.active() then return false end
  finishPhrase(text)
  return true
end
