--- Grades a game's published vocabulary for how well it can be spoken.
--
-- A game author reworking a catalog for speech needs to know which words are
-- costing them and why. This reports classes of problem with the words in
-- each, and deliberately does not produce a score: a single number predicting
-- recognition success would be inventing precision nobody has measured, and it
-- would be acted on.
--
-- Static analysis of the catalog, so what it can say is bounded. It can say a
-- word has no English pronunciation; it cannot say whether a recogniser has
-- met a word before. The classes are drawn conservatively for that reason -
-- what is reported is reported because it is certain, and words that are
-- merely unusual are left alone, since unusual game words are exactly what
-- biasing exists to rescue.
--
-- One class was built and then removed: words sitting one edit from ordinary
-- English, which is how "hallo" catches a player saying "hello". Deciding that
-- needs to know what counts as an ordinary word, and a short hand-written list
-- cannot - anything missing from it reads as game-specific, so the first run
-- against a real catalog advised renaming get, kill, look and map, which
-- measure perfect in practice. It is worth having with a real frequency list
-- behind it and worth nothing without one.
--
-- sttpkg.vocab is the bpe.vocab derivation and unrelated; this is sttpkg.grade.
-- @module sttpkg.grade

sttpkg = sttpkg or {}
sttpkg.grade = sttpkg.grade or {}
local grade = sttpkg.grade

-- Consonant clusters an English word can open with. A word beginning with
-- anything else has no pronunciation a recogniser trained on English will
-- produce, so no amount of biasing reaches it.
local ONSETS = {
  [""] = true,
  b = true, c = true, d = true, f = true, g = true, h = true, j = true, k = true,
  l = true, m = true, n = true, p = true, q = true, r = true, s = true, t = true,
  v = true, w = true, x = true, y = true, z = true,
  bl = true, br = true, ch = true, cl = true, cr = true, dr = true, dw = true,
  fl = true, fr = true, gl = true, gn = true, gr = true, kn = true, ph = true,
  pl = true, pr = true, ps = true, qu = true, rh = true, sc = true, sh = true,
  sk = true, sl = true, sm = true, sn = true, sp = true, sq = true, st = true,
  sw = true, th = true, tr = true, tw = true, wh = true, wr = true,
  scr = true, shr = true, sph = true, spl = true, spr = true, squ = true,
  str = true, thr = true,
}

--- Every class this can find, in the order a report shows them.
grade.classes = {
  { key = "nonLetters", title = "carry characters that cannot be spoken",
    advice = "Digits and punctuation have no pronunciation. Give these a spoken alias, "
      .. "or accept they are typed only." },
  { key = "noVowel", title = "have no vowel",
    advice = "Not sayable at all. An alias is the only thing that makes these reachable by voice." },
  { key = "impossibleOnset", title = "open with a cluster English does not use",
    advice = "No English pronunciation begins this way, so no recogniser will emit it however hard it is biased." },
  { key = "singleLetter", title = "are a single letter",
    advice = "Perfect for typing and hopeless for speech. Keep them and give each a spoken twin." },
  { key = "tooShort", title = "are two letters or fewer",
    advice = "A recogniser prefers the word an abbreviation stands for. "
      .. "Biasing already refuses to steer toward these." },
  { key = "long", title = "are long and unusual",
    advice = "Biasing reweights what the decoder already considered and cannot add a word the beam never held." },
}

local function lower(word)
  return tostring(word or ""):lower()
end

--- The consonants a word opens with; "" when it opens with a vowel.
function grade.onset(word)
  return lower(word):match("^([^aeiouy]*)") or ""
end

function grade.hasVowel(word)
  return lower(word):find("[aeiouy]") ~= nil
end

--- The classes one word falls into, as a set.
function grade.problems(word)
  local w = lower(word)
  local found = {}
  if w == "" then return found end

  if w:find("[^a-z%-'%s]") then
    found.nonLetters = true
  end
  -- Only for words long enough that shortness is not already the answer. A
  -- two-letter abbreviation with no vowel is reported as an abbreviation, once,
  -- rather than appearing in two classes that give different advice.
  -- Neither of these is the story for a word of one or two letters: that is
  -- already reported below, once, with advice of its own. Saying "cc" both
  -- cannot be pronounced and is an abbreviation is two answers to one question.
  if #w >= 3 then
    if not grade.hasVowel(w) then
      found.noVowel = true
    elseif not ONSETS[grade.onset(w)] then
      found.impossibleOnset = true
    end
  end
  if #w == 1 then
    found.singleLetter = true
  elseif #w <= 2 then
    found.tooShort = true
  end
  if #w >= 10 then
    found.long = true
  end
  return found
end

--- Every word the catalog publishes, with the tier it carries.
function grade.catalogWords()
  local out = {}
  if not (mcvp and mcvp.entries) then return out end
  for _, entry in ipairs(mcvp.entries({}) or {}) do
    if type(entry.word) == "string" and entry.word ~= "" then
      out[#out + 1] = { word = entry.word, priority = entry.priority or 3 }
    end
  end
  return out
end

--- The findings. Pure, so its shape can be tested with no game attached.
--
-- Only what makes a word unsayable counts against tier 1: a long word or a
-- colliding one is still a word somebody can say, and the tier-1 figure is
-- meant to answer "is the biasing budget being spent on anything reachable".
function grade.report(entries)
  entries = entries or grade.catalogWords()

  local found, counts = {}, {}
  for _, class in ipairs(grade.classes) do
    found[class.key] = {}
    counts[class.key] = 0
  end

  local tierOne, tierOneSayable = 0, 0
  for _, entry in ipairs(entries) do
    local problems = grade.problems(entry.word)
    local unsayable = problems.nonLetters or problems.noVowel
      or problems.impossibleOnset or problems.singleLetter or problems.tooShort
    if entry.priority == 1 then
      tierOne = tierOne + 1
      if not unsayable then tierOneSayable = tierOneSayable + 1 end
    end
    for key in pairs(problems) do
      if found[key] then
        found[key][#found[key] + 1] = entry.word
        counts[key] = counts[key] + 1
      end
    end
  end

  for _, class in ipairs(grade.classes) do
    table.sort(found[class.key])
  end

  return {
    total = #entries,
    tierOne = tierOne,
    tierOneSayable = tierOneSayable,
    found = found,
    counts = counts,
  }
end

-- How many of a class to name before saying how many more there are. A class
-- holding two hundred words teaches nothing by printing all of them.
local SHOWN_PER_CLASS = 12

--- Print the findings.
function grade.show(limit)
  if not (mcvp and mcvp.entries) then
    cecho("<orange>[STT] no vocabulary to grade - this game publishes no catalog\n")
    return false
  end

  local report = grade.report()
  if report.total == 0 then
    cecho("<orange>[STT] the catalog is empty\n")
    return false
  end

  limit = tonumber(limit) or SHOWN_PER_CLASS
  cecho(string.format("<white>[STT] vocabulary: %d words, %d in tier 1\n", report.total, report.tierOne))

  if report.tierOne > 0 then
    local share = math.floor((report.tierOneSayable / report.tierOne) * 100 + 0.5)
    -- The figure worth tracking while reworking a catalog: tier 1 is what the
    -- biasing budget is spent from, so an unsayable word there costs a slot
    -- that a word somebody says could have had.
    cecho(string.format(
      "<white>  %d%% of tier 1 is sayable <light_slate_gray>(%d of %d; the rest cannot be reached by voice)\n",
      share, report.tierOneSayable, report.tierOne))
  end

  local clean = true
  for _, class in ipairs(grade.classes) do
    local words = report.found[class.key]
    if #words > 0 then
      clean = false
      cecho(string.format("\n<yellow>%d %s\n", #words, class.title))
      local shown = {}
      for i = 1, math.min(#words, limit) do
        shown[#shown + 1] = words[i]
      end
      cecho("<light_slate_gray>  " .. table.concat(shown, ", "))
      if #words > limit then
        cecho(string.format(" <light_slate_gray>... and %d more", #words - limit))
      end
      cecho("\n<light_slate_gray>  " .. class.advice .. "\n")
    end
  end

  if clean then
    cecho("<green>  nothing found that cannot be spoken\n")
  end
  return true
end
