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
    assert.same({}, problemsOf("throw"))
    assert.same({}, problemsOf("gnaw"))
    assert.same({}, problemsOf("write"))
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
