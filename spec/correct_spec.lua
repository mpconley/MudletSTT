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
end)
