-- The fixed phrase set is deliberately free of dialect-varying words, so it
-- scores the recogniser rather than a dictionary. What it cannot do is show
-- what biasing is worth: it names almost nothing any particular game has, so
-- the biasing list has nothing in the run to rescue and its effect stays
-- invisible. A set built from the game's own catalog asks the other question.
--
-- Only the building is covered here, because only the building is worth
-- covering: it is pure, and it is where the judgement lives. That a run
-- remembers its set for "stt test repeat" is a field written on the way
-- through start(), and reaching it meant stubbing timers, the bridge, config
-- and the UI - six stubs of unrelated machinery propping up one assertion,
-- which tests the stubs more than the code.
_G.getMudletHomeDir = function() return "." end
_G.io.exists = function() return false end
_G.cecho = function() end
_G.registerAnonymousEventHandler = function() return "handler" end
_G.killAnonymousEventHandler = function() end
_G.tempTimer = function() return 1 end

dofile("src/scripts/STT/STTTest.lua")

local test = sttpkg.test

-- Shaped like the live StickMUD catalog: channels and message commands carry
-- %text, a few commands carry fillable patterns, and tier 1 holds the verbs
-- said constantly.
local CATALOG = {
  commands = {
    { word = "kill", syntax = "kill %living", priority = 1 },
    { word = "get", syntax = "get %item", priority = 1 },
    { word = "help", syntax = "help %word", priority = 3 },
    { word = "where", syntax = "where %player", priority = 3 },
    { word = "cast", syntax = "cast %spell", priority = 1 },
    { word = "look", priority = 1 },
    { word = "score", priority = 1 },
    { word = "ab", priority = 1 },
    { word = "wizlock", priority = 3 },
  },
  channels = {
    { word = "wiz", syntax = "wiz %text", priority = 2 },
  },
  directions = {
    { word = "north", priority = 1 },
  },
  helptopics = {
    { word = "fishing", priority = 3 },
  },
}

before_each(function()
  _G.mcvp = {
    entries = function(opts)
      opts = opts or {}
      local out = {}
      for name, entries in pairs(CATALOG) do
        if not opts.category or opts.category == name then
          for _, e in ipairs(entries) do
            if not (opts.maxPriority and (e.priority or 3) > opts.maxPriority) then
              out[#out + 1] = e
            end
          end
        end
      end
      return out
    end,
  }
  sttpkg.context = {
    inScope = function(opts)
      if opts.slot == "%item" then return { "lantern" } end
      if opts.slot == "%living" then return { "ironpelt" } end
      return {}
    end,
  }
  test._lastPhrases = nil
end)

local function has(list, text)
  for _, v in ipairs(list) do if v == text then return true end end
  return false
end

describe("filling a pattern from what is here", function()
  it("binds a creature standing in the room", function()
    assert.equals("kill ironpelt", test.fillPattern("kill %living"))
  end)

  it("puts prose where the message goes", function()
    assert.equals("wiz hello there everyone", test.fillPattern("wiz %text"))
  end)

  -- A pattern naming something the game has not published yields nothing
  -- rather than a phrase with a hole in it
  it("refuses a slot it cannot fill", function()
    assert.is_nil(test.fillPattern("where %player"))
  end)

  it("refuses a class it does not know", function()
    assert.is_nil(test.fillPattern("cast %spell"))
  end)
end)

describe("building a set from the game", function()
  it("names what is actually in the room", function()
    local phrases = test.gamePhrases()
    assert.is_true(has(phrases, "kill ironpelt"))
    assert.is_true(has(phrases, "get lantern"))
  end)

  it("includes one message body, to check prose survives the trip", function()
    assert.is_true(has(test.gamePhrases(), "wiz hello there everyone"))
  end)

  it("includes the bare verbs a character says constantly", function()
    assert.is_true(has(test.gamePhrases(), "look"))
  end)

  -- Tier 3 is most of a catalog and is not what anybody speaks in a hurry
  it("leaves the rarely-spoken out", function()
    assert.is_false(has(test.gamePhrases(), "wizlock"))
  end)

  -- Short forms are abbreviations; steering a recogniser toward one makes it
  -- prefer the abbreviation to the word it abbreviates
  it("leaves the abbreviations out", function()
    assert.is_false(has(test.gamePhrases(), "ab"))
  end)

  it("honours the limit it is given", function()
    assert.is_true(#test.gamePhrases(3) <= 3)
  end)

  it("answers nothing at all without a catalog", function()
    _G.mcvp = nil
    assert.equals(0, #test.gamePhrases())
  end)
end)
