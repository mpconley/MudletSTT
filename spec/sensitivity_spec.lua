-- applySensitivity has to tell two refusals apart that the engine reports
-- identically: one it will never honour, and one it simply could not honour
-- yet. Only capabilities.sensitivityTuning separates them, and only the
-- package turns that into something a player reads.
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

describe("sttpkg.applySensitivity", function()
  local function withEngine(canTune, accepts)
    _G.stt = {
      -- bridgeAvailable() tests for stt.init, so a stub without it is a
      -- missing bridge rather than the engine this case is about
      init = function() return true end,
      initialized = function() return true end,
      getInfo = function()
        return { capabilities = { sensitivityTuning = canTune } }
      end,
      setSensitivity = function() return accepts or nil end,
    }
  end

  before_each(function()
    sttpkg.config.sensitivity = "short"
  end)

  it("reports success when the engine took it", function()
    withEngine(true, true)
    assert.is_true(sttpkg.applySensitivity())
  end)

  it("calls an engine that can never tune unsupported", function()
    withEngine(false, nil)
    local applied, why = sttpkg.applySensitivity()
    assert.is_false(applied)
    assert.are.equal("unsupported", why)
  end)

  -- The case this file exists for. sherpa rebuilds its model to change the
  -- endpoint rules and cannot while it is listening, so it refuses exactly as
  -- the macOS backend does - but it keeps the value and will honour it. Told
  -- "this engine does not let its sensitivity be set", a player stops asking
  -- for something that was about to work.
  it("calls a busy engine that can tune deferred, not unsupported", function()
    withEngine(true, nil)
    local applied, why = sttpkg.applySensitivity()
    assert.is_false(applied)
    assert.are.equal("deferred", why)
  end)

  -- A Mudlet predating the flag cannot distinguish them, and guessing
  -- "deferred" there would promise a retry that may never succeed.
  it("falls back to unsupported on a core with no capability flag", function()
    _G.stt = {
      -- bridgeAvailable() tests for stt.init, so a stub without it is a
      -- missing bridge rather than the engine this case is about
      init = function() return true end,
      initialized = function() return true end,
      getInfo = function() return { capabilities = {} } end,
      setSensitivity = function() return nil end,
    }
    local applied, why = sttpkg.applySensitivity()
    assert.is_false(applied)
    assert.are.equal("unsupported", why)
  end)

  it("still succeeds on a core with no capability flag when the engine accepts", function()
    _G.stt = {
      -- bridgeAvailable() tests for stt.init, so a stub without it is a
      -- missing bridge rather than the engine this case is about
      init = function() return true end,
      initialized = function() return true end,
      getInfo = function() return { capabilities = {} } end,
      setSensitivity = function() return true end,
    }
    assert.is_true(sttpkg.applySensitivity())
  end)

  it("is unsupported when there is no bridge at all", function()
    _G.stt = nil
    local applied, why = sttpkg.applySensitivity()
    assert.is_false(applied)
    assert.are.equal("unsupported", why)
  end)
end)
