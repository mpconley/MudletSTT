-- A message body is the player's own words. MCVP says so normatively - a
-- client MUST never correct, complete or bias a span covered by %text - and
-- the reason is that getting it wrong is public: correcting a word inside a
-- channel message rewrites what the player said in front of everyone reading.
--
-- The reported failure was "wiz say hello" coming out as "wiz say hallo",
-- because hallo is a social on StickMUD and the last token was matched against
-- the whole argument lexicon.
dofile("src/scripts/STT/STTCorrect.lua")

local correct = sttpkg.correct

-- Shaped like what mcvp.entries() returns, which is what correct.lexicon()
-- stores whole - the syntax pattern travels with the word.
local function lex(entries) return correct.lexicon(entries) end

local channels = lex({
  { word = "wiz", syntax = "wiz %text" },
  { word = "say", syntax = "say %text" },
  { word = "tell", syntax = "tell %player %text" },
  { word = "kill", syntax = "kill %living" },
  { word = "look" },
  { word = "cast", syntax = "cast %spell" },
})

-- "hello" is deliberately absent: on StickMUD the social is "hallo" and there
-- is no "hello" in the catalog at all, which is the whole reason the spoken
-- word was a correction candidate. A fixture carrying both would match
-- "hello" exactly, never correct it, and pass whether the boundary works or not.
local arguments = lex({
  { word = "hallo" },
  { word = "ironpelt" },
  { word = "bob" },
})

describe("finding where prose begins", function()
  it("puts it after the verb for a bare message command", function()
    assert.equals(2, correct.proseFrom("say %text"))
  end)

  it("keeps a correctable slot ahead of it", function()
    assert.equals(3, correct.proseFrom("tell %player %text"))
  end)

  it("finds none in a pattern that takes vocabulary throughout", function()
    assert.is_nil(correct.proseFrom("kill %living"))
  end)

  -- The standard makes an unrecognised class unparseable on purpose, so that
  -- adding a class later is a non-event for a client this old rather than a
  -- client guessing at a slot it has never heard of.
  it("refuses a pattern carrying a class it does not know", function()
    assert.is_nil(correct.proseFrom("cast %spell"))
  end)

  it("answers nothing for an entry with no pattern at all", function()
    assert.is_nil(correct.proseFrom(nil))
  end)
end)

describe("correcting around a message body", function()
  -- The reported bug, exactly as it was said.
  it("leaves a channel message alone", function()
    local out, count = correct.apply("wiz say hello", channels, arguments)
    assert.equals("wiz say hello", out)
    assert.equals(0, count)
  end)

  it("leaves a say alone", function()
    assert.equals("say hello", (correct.apply("say hello", channels, arguments)))
  end)

  it("still corrects the name in a tell, but not the message", function()
    -- "bobb" is one edit from the known player, "hello" would otherwise be
    -- one from "hallo" - only the first is a correction candidate here
    local out = correct.apply("tell bobb hello", channels, arguments)
    assert.equals("tell bob hello", out)
  end)

  it("still corrects arguments of a command that takes vocabulary", function()
    assert.equals("kill ironpelt", (correct.apply("kill ironpel", channels, arguments)))
  end)

  it("corrects everything after a verb whose pattern it cannot parse", function()
    -- cast %spell is unparseable, so no boundary is taken from it - the entry
    -- falls back to ordinary argument correction rather than being trusted
    assert.equals("cast hallo", (correct.apply("cast hallo", channels, arguments)))
  end)

  it("corrects arguments after a verb with no pattern", function()
    assert.equals("look hallo", (correct.apply("look hallo", channels, arguments)))
  end)

  -- A channel name misheard and put right is still a channel, so the body it
  -- introduces has to be protected on the strength of what it turned out to be
  it("protects the body of a channel whose own name needed correcting", function()
    local out = correct.apply("wizz say hello", channels, arguments)
    assert.equals("wiz say hello", out)
  end)
end)
