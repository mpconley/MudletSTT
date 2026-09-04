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

    it("separates a phrase that always fails from one that sometimes does", function()
      local scores = {
        test.score("wear leather boots", "wear weather boots"),
        test.score("wear leather boots", "where weather boots"),
        test.score("kill goblin", "kill goblin"),
        test.score("kill goblin", "kilgun"),
      }
      local rows = test.byPhrase(scores)
      local byName = {}
      for _, row in ipairs(rows) do byName[row.expected] = row end

      assert.equals(2, byName["wear leather boots"].failures)
      assert.equals(2, byName["wear leather boots"].attempts)
      assert.equals(1, byName["kill goblin"].failures)
      assert.equals(2, byName["kill goblin"].attempts)
    end)

    it("counts repeats of the same misrecognition together", function()
      local scores = {
        test.score("wear leather boots", "wear weather boots"),
        test.score("wear leather boots", "wear weather boots"),
      }
      local rows = test.byPhrase(scores)
      assert.equals(2, rows[1].heard["wear weather boots"])
    end)

    it("handles an empty run without dividing by zero", function()
      local summary = test.summarize({})
      assert.equals(0, summary.phrases)
      assert.equals(0, summary.exactRate)
      assert.equals(0, summary.wordErrorRate)
    end)
  end)
end)

-- The runner half needs Mudlet, but the timer bookkeeping does not: what it
-- has to get right is that nothing stays armed once a run is over, and a
-- stubbed tempTimer/killTimer pair is enough to see that. Left unstopped, the
-- level sampler re-arms itself forever and outlives the package.
describe("sttpkg.test timer lifecycle", function()
  local armed

  before_each(function()
    armed = {}
    local nextId = 0
    _G.tempTimer = function()
      nextId = nextId + 1
      armed[nextId] = true
      return nextId
    end
    _G.killTimer = function(id)
      armed[id] = nil
      return true
    end
    _G.cecho = function() end
    sttpkg.disable = function() end
    sttpkg.listening = function() return true end
  end)

  local function armedCount()
    local n = 0
    for _ in pairs(armed) do n = n + 1 end
    return n
  end

  it("cancels every timer a run owns, including the warm-up", function()
    test._run = {
      timerId = tempTimer(), levelTimerId = tempTimer(), warmupTimerId = tempTimer(),
      wasListening = true,
    }
    assert.equals(3, armedCount())

    test.stop(true)

    assert.is_false(test.active())
    -- Only the drain timer stop() arms itself is left
    assert.equals(1, armedCount())
  end)

  it("shutdown leaves nothing armed at all", function()
    test._run = {
      timerId = tempTimer(), levelTimerId = tempTimer(), warmupTimerId = tempTimer(),
      wasListening = true,
    }

    test.shutdown()

    assert.is_false(test.active())
    assert.equals(0, armedCount())
    assert.is_false(test._draining)
  end)

  it("shutdown is safe with no run in progress", function()
    test._run = nil
    assert.has_no.errors(function() test.shutdown() end)
    assert.equals(0, armedCount())
  end)
end)
