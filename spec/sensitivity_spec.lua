-- applySensitivity has to tell apart refusals the engine reports identically.
-- capabilities.sensitivityTuning separates the one it can never honour from
-- the ones it might; the state before and after the call separates a rebuild
-- that ran and failed from one that never ran at all. Only the package turns
-- any of that into something a player reads.
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
  local asked

  -- The two states are separate because the code reads both, and a stub that
  -- answered the same thing twice could not tell a rebuild that failed from an
  -- engine that was already in error before the call - which is the pair that
  -- matters, and the one an earlier version of this file could not express.
  local function withEngine(canTune, accepts, stateBefore, stateAfter)
    asked = nil
    local called = false
    _G.stt = {
      -- bridgeAvailable() tests for stt.init, so a stub without it is a
      -- missing bridge rather than the engine this case is about
      init = function() return true end,
      getInfo = function()
        return {
          capabilities = { sensitivityTuning = canTune },
          state = called and (stateAfter or stateBefore or "ready") or (stateBefore or "ready"),
        }
      end,
      setSensitivity = function(mode)
        asked = mode
        called = true
        return accepts or nil
      end,
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
    withEngine(true, nil, "listening", "listening")
    local applied, why = sttpkg.applySensitivity()
    assert.is_false(applied)
    assert.are.equal("deferred", why)
  end)

  -- The opposite advice, and the reason "deferred" alone was not enough. An
  -- idle sherpa rebuilds its model to change the endpoint rules, and a rebuild
  -- that fails leaves nothing loaded - "takes effect at the next model load"
  -- would send the player away from the one thing that fixes it.
  it("calls a rebuild that killed the engine failed, not deferred", function()
    withEngine(true, nil, "ready", "error")
    local applied, why = sttpkg.applySensitivity()
    assert.is_false(applied)
    assert.are.equal("failed", why)
  end)

  -- The case that reading only the state afterwards gets wrong. A denied
  -- microphone leaves sherpa in error with its handles alive; asked to retune
  -- from there it never rebuilds, declines exactly as a busy engine does, and
  -- says so itself. Calling that a failed rebuild contradicts the engine's own
  -- message on the line above it.
  it("does not call an engine already in error a failed rebuild", function()
    withEngine(true, nil, "error", "error")
    local applied, why = sttpkg.applySensitivity()
    assert.is_false(applied)
    assert.are.equal("deferred", why)
  end)

  -- The configured value has to be the one offered. Every other case here uses
  -- "short", which is also the fallback, so none of them can tell the two apart.
  it("offers the configured mode rather than the fallback", function()
    withEngine(true, true)
    sttpkg.config.sensitivity = "long"
    sttpkg.applySensitivity()
    assert.are.equal("long", asked)
  end)

  -- A Mudlet with the bridge but no setter at all - anything predating
  -- stt.setSensitivity. Calling it would throw up through the alias.
  it("is unsupported when the bridge has no setter", function()
    _G.stt = { init = function() return true end, getInfo = function() return {} end }
    local applied, why = sttpkg.applySensitivity()
    assert.is_false(applied)
    assert.are.equal("unsupported", why)
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
