-- applyVocabulary reports a count, and a count of zero used to mean four
-- different things. The one that mattered is a deferral: sherpa rebuilds its
-- decoder to change what it biases toward and cannot while it is listening, so
-- it keeps the request and answers no - and the player was told "this model
-- cannot bias its decoding" about a model that had been biasing a minute
-- earlier.
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

describe("sttpkg.applyVocabulary", function()
  local function withEngine(canBias, accepts)
    _G.stt = {
      init = function() return true end,
      getInfo = function() return { capabilities = { biasing = canBias } } end,
      setVocabulary = function() return accepts end,
    }
  end

  before_each(function()
    sttpkg.config.biasing = true
    sttpkg._biasWords = 0
    _G.mcvp = { entries = function() return {{ word = "heartwood" }, { word = "ironpelt" }} end }
  end)

  it("reports the count when the engine took the words", function()
    withEngine(true, true)
    local applied, why = sttpkg.applyVocabulary()
    assert.is_true(applied > 0)
    assert.is_nil(why)
  end)

  -- The case this file exists for.
  it("calls a refusal from a model that can bias deferred", function()
    withEngine(true, false)
    local _, why = sttpkg.applyVocabulary()
    assert.are.equal("deferred", why)
  end)

  it("calls a refusal from a model that cannot bias unsupported", function()
    withEngine(false, false)
    local applied, why = sttpkg.applyVocabulary()
    assert.are.equal(0, applied)
    assert.are.equal("unsupported", why)
  end)

  -- The count is what the decoder is running, not what was last asked for. A
  -- deferred change that zeroed it labelled a quality-test run "biasing 0
  -- words" while the decoder still held the whole list.
  it("keeps the running count when a change is deferred", function()
    withEngine(true, true)
    local applied = sttpkg.applyVocabulary()
    assert.is_true(applied > 0)

    withEngine(true, false)
    local stillApplied, why = sttpkg.applyVocabulary()
    assert.are.equal("deferred", why)
    assert.are.equal(applied, stillApplied, "the decoder's word count changed on a change it refused")
  end)

  it("keeps the running count when switching off is deferred", function()
    withEngine(true, true)
    local applied = sttpkg.applyVocabulary()

    sttpkg.config.biasing = false
    withEngine(true, false)
    local stillApplied, why = sttpkg.applyVocabulary()
    assert.are.equal("deferred", why)
    assert.are.equal(applied, stillApplied, "biasing reported as off while the decoder still had the words")
  end)

  it("says so when no catalog has arrived", function()
    withEngine(true, true)
    _G.mcvp = nil
    local _, why = sttpkg.applyVocabulary()
    assert.are.equal("nocatalog", why)
  end)
end)
