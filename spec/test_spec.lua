-- Tests for sttpkg.test scoring. The runner half needs Mudlet and is not
-- covered here; the scoring half is what results are judged by, so it is.
dofile("src/scripts/STT/STTTest.lua")
local test = sttpkg.test

describe("sttpkg.test scoring", function()
  describe("normalize", function()
    it("lowercases, trims and collapses whitespace", function()
      assert.equals("kill goblin", test.normalize("  Kill   GOBLIN "))
    end)

    it("drops sentence punctuation a recogniser adds", function()
      assert.equals("look", test.normalize("Look."))
      assert.equals("stop look and listen", test.normalize("Stop, look and listen!"))
    end)
  end)

  describe("sequenceDistance", function()
    it("counts word substitutions, insertions and deletions", function()
      assert.equals(0, test.sequenceDistance({ "a", "b" }, { "a", "b" }))
      assert.equals(1, test.sequenceDistance({ "a", "b" }, { "a", "c" }))
      assert.equals(1, test.sequenceDistance({ "a", "b" }, { "b" }))
      assert.equals(2, test.sequenceDistance({ "a", "b" }, {}))
    end)
  end)

  describe("score", function()
    it("marks an exact match, ignoring case and punctuation", function()
      local s = test.score("kill goblin", "Kill goblin.")
      assert.is_true(s.exact)
      assert.equals(0, s.errors)
      assert.is_true(s.firstWord)
      assert.equals(0, s.wordErrorRate)
    end)

    it("flags a lost first word separately from the error count", function()
      local s = test.score("say stop look and listen", "stop look and listen")
      assert.is_false(s.exact)
      assert.equals(1, s.errors)
      assert.is_false(s.firstWord)
    end)

    it("counts a substituted word without blaming the first", function()
      local s = test.score("sit bench", "sit bunch")
      assert.equals(1, s.errors)
      assert.is_true(s.firstWord)
    end)

    it("reports hearing nothing", function()
      local s = test.score("look", nil)
      assert.is_true(s.heardNothing)
      assert.is_false(s.firstWord)
      assert.equals(1, s.errors)
    end)

    it("scales the error rate by phrase length", function()
      local short = test.score("look", "book")
      local long = test.score("put coins in bag", "put coins in bug")
      assert.equals(1, short.wordErrorRate)
      assert.equals(0.25, long.wordErrorRate)
    end)
  end)

  describe("summarize", function()
    it("aggregates exactness, first-word loss and silence", function()
      local scores = {
        test.score("look", "look"),
        test.score("say stop", "stop"),
        test.score("north", nil),
        test.score("kill goblin", "kill goblin"),
      }
      local summary = test.summarize(scores)
      assert.equals(4, summary.phrases)
      assert.equals(2, summary.exact)
      assert.equals(0.5, summary.exactRate)
      assert.equals(2, summary.firstWordLost)
      assert.equals(1, summary.heardNothing)
    end)

    it("computes word error rate over all words, not per phrase", function()
      -- 1 error in "say stop" plus 1 in "north" over 5 expected words
      local scores = {
        test.score("look", "look"),
        test.score("say stop", "stop"),
        test.score("north", nil),
      }
      local summary = test.summarize(scores)
      assert.equals(2 / 4, summary.wordErrorRate)
    end)

    it("handles an empty run without dividing by zero", function()
      local summary = test.summarize({})
      assert.equals(0, summary.phrases)
      assert.equals(0, summary.exactRate)
      assert.equals(0, summary.wordErrorRate)
    end)
  end)
end)
