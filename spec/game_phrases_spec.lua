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

-- STTCorrect too: the pool filtering asks the corrector whether a probe word
-- is close to vocabulary, and without it loaded that check silently answers
-- "no" for everything - so the spec would pass while the filter did nothing.
dofile("src/scripts/STT/STTCorrect.lua")
-- The builder asks the grader whether a word can be said at all, so a run does
-- not spend passes on words that are a vocabulary finding rather than a
-- recognition one
dofile("src/scripts/STT/STTGrade.lua")
dofile("src/scripts/STT/STTTest.lua")

local test = sttpkg.test

-- Shaped like the live StickMUD catalog: channels and message commands carry
-- %text, a few commands carry fillable patterns, and tier 1 holds the verbs
-- said constantly.
local CATALOG = {
  commands = {
    { word = "kill", syntax = "kill %living", priority = 1 },
    { word = "get", syntax = "get %item", priority = 1 },
    -- Several patterns taking the same slot, as the real catalog has: get,
    -- eat, wear, open and drink all name an item, and taking the first match
    -- for each is what produced six ways of saying "beer"
    { word = "examine", syntax = "examine %item", priority = 1 },
    { word = "drop", syntax = "drop %item", priority = 1 },
    -- Not carrier verbs: nothing here can know a lantern is inedible
    { word = "eat", syntax = "eat %item", priority = 1 },
    { word = "wear", syntax = "wear %item", priority = 1 },
    { word = "help", syntax = "help %word", priority = 3 },
    { word = "where", syntax = "where %player", priority = 3 },
    { word = "cast", syntax = "cast %spell", priority = 1 },
    { word = "look", priority = 1 },
    { word = "score", priority = 1 },
    { word = "ab", priority = 1 },
    { word = "wizlock", priority = 3 },
    -- StickMUD really does have this as a command, which is what makes the
    -- pool filtering worth having: a probe word that is also vocabulary scores
    -- the catalog rather than the recogniser
    { word = "weather", priority = 3 },
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
  -- The body is checked against what the decoder is steered toward, not against
  -- the whole catalog: correction never runs inside a %text span, so only
  -- biasing can change a body
  sttpkg.biasWords = function() return { "kill", "get", "examine" } end
  sttpkg.context = {
    names = function(opts)
      if opts.slot == "%item" then return { "A brass lantern" } end
      if opts.slot == "%living" then return { "Ironpelt the boar" } end
      return {}
    end,
    inScope = function(opts)
      if opts.slot == "%item" then return { "brass", "lantern" } end
      if opts.slot == "%living" then return { "ironpelt", "boar" } end
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
    assert.equals("wiz i will be back in a moment", test.fillPattern("wiz %text"))
  end)

  -- The first version of the pool was "hello there everyone", against a game
  -- with a social called hallo: a body coming back wrong could then mean the
  -- prose was corrupted or that the decoder heard a genuinely ambiguous word,
  -- and the run could not say which
  -- The first version assembled a body from a filtered word pool and produced
  -- "the today is rather", which is not language: the decoder had nothing to
  -- constrain the parse and split "today" into "to day" on every pass
  it("uses a whole sentence rather than assembled words", function()
    local body = test.proseBody()
    assert.is_truthy(body:find(" "))
    assert.is_truthy(body:match("^%a[%a%s]+$"))
  end)

  -- A candidate colliding with the catalog is skipped for the next one, so a
  -- body that comes back wrong means the recogniser and nothing else
  -- Checked against the bias list alone. Against the whole catalog every
  -- candidate collided on a real game - 2109 correctable words - and a run
  -- went out with no body phrase and nothing said about it
  it("skips a sentence naming a word the decoder is steered toward", function()
    assert.equals("i will be back in a moment", test.proseBody())
    sttpkg.biasWords = function() return { "moment" } end
    assert.equals("let me check on something first", test.proseBody())
  end)

  it("answers nothing when every candidate is biased toward", function()
    sttpkg.biasWords = function() return { "moment", "check", "sounds", "minute" } end
    assert.is_nil(test.proseBody())
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
    assert.is_true(has(test.gamePhrases(), "wiz i will be back in a moment"))
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

  -- Six ways of saying "beer" is what taking the first match every time
  -- produced in a live run, including "eat beer" and "wear beer"
  it("names different things when there are different things in reach", function()
    sttpkg.context.names = function(opts)
      if opts.slot == "%item" then return { "A brass lantern", "A coil of rope", "A glass flask" } end
      if opts.slot == "%living" then return { "Ironpelt the boar" } end
      return {}
    end
    -- Only the verbs that take an item, so a help topic or a creature cannot
    -- stand in for variety that is not there
    local ITEM_VERBS = { get = true, examine = true, drop = true }
    local items = {}
    for _, phrase in ipairs(test.gamePhrases()) do
      local verb, noun = phrase:match("^(%a+)%s+(%a+)$")
      if verb and ITEM_VERBS[verb] then items[noun] = true end
    end
    local distinct = 0
    for _ in pairs(items) do distinct = distinct + 1 end
    assert.is_true(distinct > 1)
  end)

  -- "drink checklist" and "wear clear" came out of a live run. Nothing here can
  -- know a lantern is inedible, so a verb that does not fit anything is only
  -- ever asked for bare, where it needs no object to make sense.
  it("does not pair a verb with an object that makes no sense of it", function()
    local phrases = test.gamePhrases()
    for _, phrase in ipairs(phrases) do
      assert.is_falsy(phrase:match("^eat "), "built a phrase pairing eat with whatever was in reach")
      assert.is_falsy(phrase:match("^wear "), "built a phrase pairing wear with whatever was in reach")
    end
  end)

  -- A word with no English pronunciation cannot be said, so a spoken run
  -- learns nothing by asking for it and its failure counts against a number
  -- meant to describe the recogniser. "stt vocab" reports these statically.
  --
  -- Only what is certain is excluded. "gec" is pronounceable - it is simply
  -- not a word - so it stays, and its failure is a real finding about whether
  -- that command is usable by voice at all.
  it("leaves out words that have no pronunciation", function()
    CATALOG.commands[#CATALOG.commands + 1] = { word = "tset", priority = 1 }
    CATALOG.commands[#CATALOG.commands + 1] = { word = "tth", priority = 1 }
    CATALOG.commands[#CATALOG.commands + 1] = { word = "gec", priority = 1 }
    local phrases = test.gamePhrases(20)
    for _ = 1, 3 do CATALOG.commands[#CATALOG.commands] = nil end
    assert.is_false(has(phrases, "tset"))
    assert.is_false(has(phrases, "tth"))
    assert.is_true(has(phrases, "gec"))
  end)

  it("honours the limit it is given", function()
    assert.is_true(#test.gamePhrases(3) <= 3)
  end)

  it("answers nothing at all without a catalog", function()
    _G.mcvp = nil
    assert.equals(0, #test.gamePhrases())
  end)
end)
