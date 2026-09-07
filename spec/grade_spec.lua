-- Grading a catalog for speech. The words below are real StickMUD commands,
-- because the point of this is to answer a game author about their own game
-- and the classes were drawn from looking at theirs.
--
-- What it must not do is overclaim. It can say a word has no English
-- pronunciation; it cannot say whether a recogniser has met a word before, so
-- unusual words are left alone - those are what biasing is for.
dofile("src/scripts/STT/STTCorrect.lua")
dofile("src/scripts/STT/STTGrade.lua")

local grade = sttpkg.grade

local function problemsOf(word)
  return grade.problems(word)
end

describe("words that cannot be spoken at all", function()
  it("finds one with no vowel", function()
    assert.is_true(problemsOf("tth").noVowel)
    assert.is_true(problemsOf("chd").noVowel)
  end)

  it("finds one opening with a cluster English never uses", function()
    -- "tset" scored heard-nothing or "t" six times out of six in live testing
    assert.is_true(problemsOf("tset").impossibleOnset)
    assert.is_true(problemsOf("dflame").impossibleOnset)
  end)

  it("finds one carrying a digit", function()
    assert.is_true(problemsOf("osc8").nonLetters)
    assert.is_true(problemsOf("who2").nonLetters)
  end)

  it("leaves an ordinary word alone", function()
    assert.same({}, problemsOf("examine"))
    assert.same({}, problemsOf("sharpen"))
  end)

  -- An unusual game word is not a defect. It is the case biasing exists for,
  -- and reporting it would tell an author to delete their own vocabulary.
  it("does not flag a word merely for being unfamiliar", function()
    assert.same({}, problemsOf("ironpelt"))
    assert.same({}, problemsOf("gnome"))
  end)

  it("allows an onset English does use", function()
    assert.same({}, problemsOf("ghost"))
    assert.same({}, problemsOf("throw"))
    assert.same({}, problemsOf("gnaw"))
    assert.same({}, problemsOf("write"))
  end)
end)

describe("coined words that shadow real ones", function()
  -- The dictionary is passed in, not reached for, so the grading stays pure
  -- Lua like the rest of the analysis here and a client with a different
  -- speller supplies its own. This one answers the way Hunspell does.
  local DICTIONARY = {
    knows = function(w)
      return ({ test = true, set = true, port = true, gate = true })[w] == true
    end,
    suggest = function(w)
      if w == "tset" then return { "test", "set" } end
      if w == "dport" then return { "port" } end
      if w == "ironpelt" then return { "interpret" } end
      -- A real word a speller would still offer neighbours for, so the guard
      -- that skips known words is exercised rather than assumed
      if w == "test" then return { "text" } end
      return {}
    end,
  }

  it("names what a coined command would be taken for", function()
    assert.equals("port", grade.collisions({ "dport" }, DICTIONARY)["dport"])
  end)

  -- A game's own nouns are supposed to be unfamiliar; that is what biasing is
  -- for. Only shadowing an everyday word is worth reporting.
  it("says nothing about a game word that resembles nothing", function()
    assert.is_nil(grade.collisions({ "ironpelt" }, DICTIONARY)["ironpelt"])
  end)

  it("says nothing about a word the dictionary knows", function()
    assert.is_nil(grade.collisions({ "test" }, DICTIONARY)["test"])
  end)

  -- A client with no speller loses this class and keeps every other one
  -- A speller answers a compound with the words it is made of, and inserting a
  -- space is one edit - so these passed a distance check and produced 250
  -- findings against a real catalog, almost all of them this
  it("ignores a suggestion that is two words", function()
    local speller = {
      knows = function() return false end,
      suggest = function(w)
        if w == "autogold" then return { "auto gold" } end
        return {}
      end,
    }
    assert.is_nil(grade.collisions({ "autogold" }, speller)["autogold"])
  end)

  it("does nothing at all without a dictionary", function()
    assert.same({}, grade.collisions({ "dport" }))
    assert.same({}, grade.collisions({ "dport" }, { knows = function() return false end }))
  end)
end)

describe("words too short to survive", function()
  it("separates a single letter from a pair", function()
    assert.is_true(problemsOf("a").singleLetter)
    assert.is_nil(problemsOf("a").tooShort)
    assert.is_true(problemsOf("ab").tooShort)
    assert.is_nil(problemsOf("ab").singleLetter)
  end)

  it("leaves three letters alone", function()
    assert.is_nil(problemsOf("get").tooShort)
  end)
end)

describe("the report", function()
  local ENTRIES = {
    { word = "kill", priority = 1 },
    { word = "get", priority = 1 },
    { word = "tset", priority = 1 },
    { word = "tth", priority = 1 },
    { word = "ab", priority = 3 },
    { word = "eviscerate", priority = 1 },
    { word = "examine", priority = 1 },
  }

  it("counts what tier 1 is being spent on", function()
    local report = grade.report(ENTRIES)
    assert.equals(6, report.tierOne)
    -- kill, get, eviscerate, examine are sayable; tset and tth are not
    assert.equals(4, report.tierOneSayable)
  end)

  -- Long and colliding words are still words somebody can say, so they must
  -- not count against the figure that answers "is the budget reaching anyone"
  it("counts a long word as sayable", function()
    local report = grade.report({ { word = "eviscerate", priority = 1 } })
    assert.equals(1, report.tierOneSayable)
  end)

  -- "accessibility" is thirteen letters and perfectly ordinary. Flagging it
  -- told an author to rework a word that was never going to fail.
  it("does not call a long word unusual when the speller knows it", function()
    local speller = { knows = function() return true end, suggest = function() return {} end }
    local report = grade.report({ { word = "accessibility", priority = 1 } }, speller)
    assert.equals(0, report.counts.long)
  end)

  -- A word published in two categories is one word. A real report listed
  -- "ghelp, ghelp" and counted it twice.
  it("counts a word once however many categories publish it", function()
    local report = grade.report({
      { word = "tset", priority = 1 },
      { word = "tset", priority = 3 },
    })
    assert.equals(1, report.counts.impossibleOnset)
  end)

  it("gathers each class", function()
    local report = grade.report(ENTRIES)
    assert.equals(1, report.counts.noVowel)
    assert.equals(1, report.counts.impossibleOnset)
    assert.equals(1, report.counts.tooShort)
    assert.equals(1, report.counts.long)
  end)

  it("answers for an empty catalog without erroring", function()
    local report = grade.report({})
    assert.equals(0, report.total)
    assert.equals(0, report.tierOne)
  end)
end)
