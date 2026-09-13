-- Tests for sttpkg.correct - each block names the policy it pins.
dofile("src/scripts/STT/STTCorrect.lua")
local correct = sttpkg.correct

local function lex(words)
  local entries = {}
  for _, word in ipairs(words) do entries[#entries + 1] = { word = word } end
  return correct.lexicon(entries)
end

describe("sttpkg.correct", function()
  describe("distance", function()
    it("is zero for equal strings", function()
      assert.equals(0, correct.distance("kill", "kill", 2))
    end)

    it("counts substitutions, insertions and deletions", function()
      assert.equals(1, correct.distance("quik", "quick", 2))
      assert.equals(1, correct.distance("kills", "kill", 2))
      assert.equals(2, correct.distance("swrod", "sword", 2))
    end)

    it("reports cutoff + 1 for anything beyond the cutoff", function()
      assert.equals(3, correct.distance("abcdefgh", "zyxwvuts", 2))
      assert.equals(2, correct.distance("ab", "zyxw", 1))
    end)
  end)

  describe("maxDistance policy", function()
    it("gives short words no budget at all", function()
      assert.equals(0, correct.maxDistance(2))
      assert.equals(0, correct.maxDistance(3))
    end)

    it("scales the budget with length", function()
      assert.equals(1, correct.maxDistance(4))
      assert.equals(1, correct.maxDistance(6))
      assert.equals(2, correct.maxDistance(7))
    end)
  end)

  describe("token", function()
    local vocabulary = lex({ "kill", "quick", "sword", "inventory", "north" })

    it("leaves vocabulary words alone", function()
      assert.is_nil(correct.token("kill", vocabulary))
      assert.is_nil(correct.token("Kill", vocabulary))
    end)

    it("corrects a near miss to the unique closest word", function()
      assert.equals("quick", correct.token("quik", vocabulary))
      assert.equals("inventory", correct.token("inventroy", vocabulary))
    end)

    it("refuses short tokens outright", function()
      assert.is_nil(correct.token("kil", vocabulary))
    end)

    it("refuses when two candidates tie", function()
      local ambiguous = lex({ "bear", "beat" })
      assert.is_nil(correct.token("beap", ambiguous))
    end)

    it("prefers the strictly closest candidate when a farther one is also in budget", function()
      local vocab = lex({ "hammers", "hammer" })
      -- "hammmer" is 1 edit from "hammer" and 2 from "hammers"; both are in
      -- the length-7 budget of 2, and the closer one wins without a tie
      assert.equals("hammer", correct.token("hammmer", vocab))
    end)

    it("refuses when nothing is in budget", function()
      assert.is_nil(correct.token("xylophone", vocabulary))
    end)
  end)

  describe("phrase", function()
    local vocabulary = lex({ "score guild", "resign guild", "word of recall", "kill", "score" })

    it("indexes phrases by word count and records the longest", function()
      assert.equals(3, vocabulary.longest)
      assert.is_true(vocabulary.phrases[2].exact["score guild"] ~= nil)
      assert.is_true(vocabulary.phrases[3].exact["word of recall"] ~= nil)
      assert.is_nil(vocabulary.phrases[2].exact["kill"])
    end)

    it("matches an exact phrase and reports the tokens it covers", function()
      local fixed, consumed = correct.phrase({ "score", "guild", "now" }, vocabulary)
      assert.equals("score guild", fixed)
      assert.equals(2, consumed)
    end)

    it("prefers the longest phrase", function()
      local fixed, consumed = correct.phrase({ "word", "of", "recall" }, vocabulary)
      assert.equals("word of recall", fixed)
      assert.equals(3, consumed)
    end)

    it("corrects a near-miss phrase within the joined budget", function()
      local fixed, consumed = correct.phrase({ "scor", "guild" }, vocabulary)
      assert.equals("score guild", fixed)
      assert.equals(2, consumed)
    end)

    it("refuses a tie between phrases", function()
      local ambiguous = lex({ "score guild", "scare guild" })
      local fixed, consumed = correct.phrase({ "scire", "guild" }, ambiguous)
      assert.is_nil(fixed)
      assert.equals(0, consumed)
    end)

    it("returns nothing when no phrase fits", function()
      local fixed, consumed = correct.phrase({ "kill", "goblin" }, vocabulary)
      assert.is_nil(fixed)
      assert.equals(0, consumed)
    end)

    it("returns nothing for a lexicon with no phrases", function()
      local plain = lex({ "kill", "look" })
      assert.equals(1, plain.longest)
      assert.is_nil((correct.phrase({ "kill", "look" }, plain)))
    end)

    it("never lets a single token be corrected into a phrase", function()
      -- A phrase is a leading-position unit; as a candidate for one token
      -- it would manufacture a command in argument position.
      local mixed = lex({ "score guild", "scoreguil" })
      -- "scoreguild" is one edit from both; only the single-token
      -- candidate may win, so the answer is the decoy, never the phrase
      assert.equals("scoreguil", correct.token("scoreguild", mixed))
      for _, word in ipairs(mixed.list) do
        assert.is_nil(word:find(" "), word)
      end
    end)
  end)

  describe("lowerFirst", function()
    it("lowercases only the first character", function()
      assert.equals("smile", correct.lowerFirst("Smile"))
      assert.equals("kill Grendel", correct.lowerFirst("Kill Grendel"))
    end)

    it("leaves already-lowercase and empty text alone", function()
      assert.equals("look", correct.lowerFirst("look"))
      assert.equals("", correct.lowerFirst(""))
      assert.equals("", correct.lowerFirst(nil))
    end)
  end)

  describe("commandCase", function()
    it("lowers an all-capitals transcript entirely", function()
      assert.equals("kill goblin", correct.commandCase("KILL GOBLIN"))
      assert.equals("look", correct.commandCase("LOOK"))
    end)

    it("lowers only the first letter of sentence-cased text", function()
      assert.equals("kill Grendel", correct.commandCase("Kill Grendel"))
    end)

    it("leaves text that is already command-cased alone", function()
      assert.equals("get sword", correct.commandCase("get sword"))
    end)

    it("treats text with no letters at all as unchanged", function()
      assert.equals("", correct.commandCase(""))
      assert.equals("123", correct.commandCase("123"))
    end)
  end)

  describe("apply", function()
    local leading = lex({ "kill", "look", "inventory" })
    local argument = lex({ "goblin", "sword", "north" })

    it("corrects the first token against the leading lexicon only", function()
      local text, count = correct.apply("kilm goblin", leading, argument)
      assert.equals("kill goblin", text)
      assert.equals(1, count)
    end)

    it("corrects later tokens against the argument lexicon only", function()
      local text, count = correct.apply("kill gobln", leading, argument)
      assert.equals("kill goblin", text)
      assert.equals(1, count)
    end)

    it("does not cross lexicons", function()
      -- "goblin" is not a leading word, so a leading-position near miss of
      -- it stays as recognised
      local text, count = correct.apply("gobln sword", leading, argument)
      assert.equals("gobln sword", text)
      assert.equals(0, count)
    end)

    it("passes clean phrases through untouched", function()
      local text, count = correct.apply("kill goblin", leading, argument)
      assert.equals("kill goblin", text)
      assert.equals(0, count)
    end)

    it("tolerates nil lexicons and empty text", function()
      local text, count = correct.apply("kill goblin", nil, nil)
      assert.equals("kill goblin", text)
      assert.equals(0, count)
      text, count = correct.apply("", leading, argument)
      assert.equals("", text)
      assert.equals(0, count)
    end)
  end)

  describe("apostrophes", function()
    -- No decoder tried here emits them: "Tamarindo's hook" comes back as
    -- "tamarindos hook" every time, in every model
    local possessives = correct.lexicon({
      { word = "tamarindo's" }, { word = "captain's" }, { word = "hook" },
    })

    -- These two are long enough for the distance budget to reach on its own;
    -- they are here because they are the words a real session lost, and they
    -- must keep working however the matching is reorganised
    it("puts back an apostrophe the engine could not say", function()
      assert.are.equal("tamarindo's", correct.token("tamarindos", possessives))
      assert.are.equal("captain's", correct.token("captains", possessives))
    end)

    it("leaves a word that is already right alone", function()
      assert.is_nil(correct.token("hook", possessives))
      assert.is_nil(correct.token("tamarindo's", possessives))
    end)

    it("does not invent an apostrophe for a word the vocabulary spells plainly", function()
      local plain = correct.lexicon({ { word = "its" }, { word = "hook" } })
      assert.is_nil(correct.token("its", plain))
    end)

    -- The edit-distance budget is zero at three characters and one up to six,
    -- so the fuzzy matcher cannot reach these however obvious they look. The
    -- bare form is the only thing that can.
    it("reaches short words the distance budget cannot", function()
      local short = correct.lexicon({ { word = "it's" }, { word = "we're" } })
      assert.are.equal("it's", correct.token("its", short))
      assert.are.equal("we're", correct.token("were", short))
    end)
  end)
end)

-- A phrase match must never be the reason an unambiguous word changes. Joining
-- tokens inflates the edit budget: "get chest" is nine characters and earns 2,
-- where "get" alone earns 0 and "chest" earns 1. Because the phrase attempt
-- runs before any single-token check, that surplus was enough to rewrite a word
-- the player said exactly right - against StickMUD's real multi-word help
-- topics, "get chest" came out "sea chest" and "kill giant" came out
-- "hill giant".
describe("a phrase outbidding a token", function()
  -- A mortal's real leading vocabulary: ordinary Diku verbs alongside the
  -- multi-word help topics that live in the same catalog.
  local leading = lex({
    "get", "kill", "look", "say", "score",
    "sea chest", "hill giant", "dark elf",
  })
  local args = lex({ "chest", "giant", "world" })

  it("leaves a line alone when the phrase would replace an exact first word", function()
    assert.equals("get chest", (correct.apply("get chest", leading, args)))
  end)

  it("leaves it alone even when only one edit separates the phrase", function()
    -- "kill giant" is one edit from "hill giant", and the joined budget is 2,
    -- so only the exactness of "kill" itself refuses this one.
    assert.equals("kill giant", (correct.apply("kill giant", leading, args)))
  end)

  it("caps the joined budget at what the tokens would have had apart", function()
    -- 0 for "get" plus 1 for "chest" is 1, where the joined string claims 2
    assert.equals(2, correct.maxDistance(#"get chest"))
    assert.is_nil((correct.phrase({ "get", "chest" }, leading)))
  end)

  it("still corrects a phrase whose first word is not itself a word", function()
    local vocabulary = lex({ "score guild", "kill", "score" })
    local fixed, consumed = correct.phrase({ "scor", "guild" }, vocabulary)
    assert.equals("score guild", fixed)
    assert.equals(2, consumed)
  end)

  it("still corrects a later token of a phrase whose first word is exact", function()
    -- The rule is about a candidate that would replace token 1, not about any
    -- fuzzy match on a line whose first word happens to be a real word
    local vocabulary = lex({ "priest officers", "priest", "say" })
    local fixed, consumed = correct.phrase({ "priest", "oficers" }, vocabulary)
    assert.equals("priest officers", fixed)
    assert.equals(2, consumed)
  end)

  it("matches a phrase that consumes the whole line", function()
    local vocabulary = lex({ "score guild", "score", "kill" })
    local out, count = correct.apply("score guild", vocabulary, args)
    assert.equals("score guild", out)
    assert.equals(0, count)
  end)

  it("prefers an exact shorter phrase over a longer near miss", function()
    local vocabulary = lex({ "take all", "take all coins", "bake all coins" })
    local fixed, consumed = correct.phrase({ "take", "all", "coins" }, vocabulary)
    assert.equals("take all coins", fixed)
    assert.equals(3, consumed)
    -- and the exact two-token one wins when the three-token line is a miss
    fixed, consumed = correct.phrase({ "take", "all", "coinz" }, vocabulary)
    assert.equals("take all", fixed)
    assert.equals(2, consumed)
  end)

  -- Pinned behaviour: a tie at the longest length is not fatal to the whole
  -- attempt. The fuzzy pass keeps walking down the lengths, so a shorter
  -- length that matches unambiguously still wins.
  it("falls through a tie at the longest length to a shorter unambiguous match", function()
    local vocabulary = lex({ "take all", "take all coins", "bake all coins" })
    local fixed, consumed = correct.phrase({ "wake", "all", "coins" }, vocabulary)
    assert.equals("take all", fixed)
    assert.equals(2, consumed)
  end)
end)
