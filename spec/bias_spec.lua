-- How the biasing budget is spent. The order is the whole point: the caller
-- fills a fixed list from the front and stops, so what comes first is what
-- gets biased at all.
_G.registerAnonymousEventHandler = function(event) return event end
_G.killAnonymousEventHandler = function() end
_G.getMudletHomeDir = function() return "." end
_G.cecho = function() end
_G.raiseEvent = function() end
_G.table.save = function() end
_G.table.load = function() end
_G.io.exists = function() return false end

dofile("src/scripts/STT/STTCorrect.lua")
dofile("src/scripts/STT/STTCore.lua")

local function catalogOf(words)
  local entries = {}
  for _, word in ipairs(words) do entries[#entries + 1] = { word = word } end
  return entries
end

before_each(function()
  _G.mcvp = { entries = function() return catalogOf({ "kill", "north", "gossip" }) end }
  sttpkg.context = { inScope = function() return { "ironpelt", "shepherd" } end }
end)

describe("sttpkg.biasWords", function()
  it("spends the budget on what is in reach before the catalog", function()
    assert.same({ "ironpelt", "shepherd", "kill", "north", "gossip" }, sttpkg.biasWords())
  end)

  it("cuts at the budget, so in-reach words survive and catalog words do not", function()
    assert.same({ "ironpelt", "shepherd", "kill" }, sttpkg.biasWords(3))
  end)

  it("leaves out one and two letter forms, which are aliases", function()
    -- Boosting "n" is how "north" came back as "n". The cut is at three, so
    -- "inv" stays: it is an abbreviation too, but the rule is length, not
    -- whether a word looks like one.
    _G.mcvp = { entries = function() return catalogOf({ "n", "se", "inv", "flee" }) end }
    sttpkg.context = { inScope = function() return {} end }
    assert.same({ "inv", "flee" }, sttpkg.biasWords())
  end)

  it("says a word once, however many copies are in reach", function()
    sttpkg.context = { inScope = function() return { "bench", "bench", "bench" } end }
    assert.same({ "bench", "kill", "north", "gossip" }, sttpkg.biasWords())
  end)

  it("works with no catalog at all, so a profile without MCVP still biases", function()
    _G.mcvp = nil
    assert.same({ "ironpelt", "shepherd" }, sttpkg.biasWords())
  end)
end)
