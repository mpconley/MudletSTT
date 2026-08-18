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
  "wear leather armor",
  "cast fireball at troll",
  "put coins in bag",
}

-- Seconds to wait for a phrase before recording it as not heard
local PHRASE_TIMEOUT = 12

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

--- Aggregate scores into the numbers worth comparing between settings.
function test.summarize(scores)
  local total = #scores
  local exact, firstWordLost, silent, errorSum, wordSum = 0, 0, 0, 0, 0
  for _, score in ipairs(scores) do
    if score.exact then exact = exact + 1 end
    if not score.firstWord then firstWordLost = firstWordLost + 1 end
    if score.heardNothing then silent = silent + 1 end
    errorSum = errorSum + score.errors
    wordSum = wordSum + #test.tokens(score.expected)
  end
  return {
    phrases = total,
    exact = exact,
    exactRate = total > 0 and (exact / total) or 0,
    firstWordLost = firstWordLost,
    heardNothing = silent,
    wordErrorRate = wordSum > 0 and (errorSum / wordSum) or 0,
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
end

local function settingsLine()
  local engine, model, sensitivity = "?", "none", "?"
  if sttpkg.bridgeAvailable() then
    local info = stt.getInfo()
    engine = info.backend or "?"
    model = (info.modelPath or ""):match("[^/]+$") or "none"
    sensitivity = info.sensitivity or tostring(sttpkg.config.sensitivity)
  end
  return string.format("engine %s, model %s, sensitivity %s, correction %s",
    engine, model, sensitivity, sttpkg.config.correction and "on" or "off")
end

local prompt

local function finishPhrase(heard)
  local run = test._run
  if not run then return end
  clearTimer()

  local expected = run.phrases[run.index]
  local score = test.score(expected, heard)
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
    test.report()
  else
    prompt()
  end
end

prompt = function()
  local run = test._run
  if not run then return end
  cecho(string.format("<white>[%d/%d] say: <cyan>%s\n", run.index, #run.phrases, run.phrases[run.index]))
  run.timerId = tempTimer(PHRASE_TIMEOUT, function() finishPhrase(nil) end)
end

--- Begin a run. Recognised text is scored instead of reaching the game, so a
-- test can be run while connected without playing the character.
function test.start(phrases)
  if test.active() then
    cecho("<orange>[STT] a test is already running - stt test stop\n")
    return false
  end
  if not sttpkg.ensureInit() then return false end

  test._run = { index = 1, phrases = phrases or test.phrases, scores = {}, wasListening = sttpkg.listening() }
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
  prompt()
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

  test._lastSummary = summary
  test.stop(true)
end

--- Called by STTCore for every final result while a test is running.
function test.submit(text)
  if not test.active() then return false end
  finishPhrase(text)
  return true
end
