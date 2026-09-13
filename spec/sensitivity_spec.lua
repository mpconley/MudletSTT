-- applySensitivity has to tell apart refusals the engine reports identically.
-- stt.setSensitivity() says only "no", and says it for three reasons that want
-- three different answers from the player. Mudlet publishes enough to separate
-- them without a capability flag: getInfo().sensitivity is the mode the engine
-- is actually in, so a core that kept the value reads it back and one that can
-- never tune does not, and the state either side of the call says whether a
-- rebuild ran and died. Only the package turns any of that into something a
-- player reads.
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

  -- Stubs the engine on the keys Mudlet really has. `keeps` is the one that
  -- carries the distinction: a core that declines for now still stores the
  -- mode and reports it back, and a core that cannot tune at all leaves the
  -- readback where it was - which is exactly what Vosk does when libvosk has
  -- no endpointer symbol, since it stores the mode only on the way out.
  --
  -- The two states stay separate because the code reads both, and a stub that
  -- answered the same thing twice could not tell a rebuild that failed from an
  -- engine that was already in error before the call.
  local function withEngine(opts)
    opts = opts or {}
    asked = nil
    local called = false
    local mode = opts.sensitivityBefore or "default"
    _G.stt = {
      -- bridgeAvailable() tests for stt.init, so a stub without it is a
      -- missing bridge rather than the engine this case is about
      init = function() return true end,
      getInfo = function()
        return {
          sensitivity = mode,
          state = called and (opts.stateAfter or opts.stateBefore or "ready")
            or (opts.stateBefore or "ready"),
        }
      end,
      setSensitivity = function(requested)
        asked = requested
        called = true
        if opts.accepts or opts.keeps then mode = requested end
        return opts.accepts or nil
      end,
    }
  end

  before_each(function()
    sttpkg.config.sensitivity = "short"
  end)

  it("reports success when the engine took it", function()
    withEngine({ accepts = true })
    assert.is_true(sttpkg.applySensitivity())
  end)

  -- The shape every shipping Mudlet produces, and the one nothing covered
  -- while the specs asked about a capability key. Vosk refuses only when the
  -- library has no endpointer symbol, which no waiting or reloading changes.
  it("calls a refusal that left the mode alone unsupported", function()
    withEngine({ sensitivityBefore = "default" })
    local applied, why = sttpkg.applySensitivity()
    assert.is_false(applied)
    assert.are.equal("unsupported", why)
  end)

  -- The case this file exists for. An engine that rebuilds its model to change
  -- the endpoint rules cannot while it is listening, so it refuses exactly as
  -- a backend that can never tune does - but it keeps the value, and saying so
  -- is what the readback is for. Told "this engine does not let its
  -- sensitivity be set", a player stops asking for something about to work.
  it("calls a refusal that kept the mode deferred, not unsupported", function()
    withEngine({ keeps = true, stateBefore = "listening", stateAfter = "listening" })
    local applied, why = sttpkg.applySensitivity()
    assert.is_false(applied)
    assert.are.equal("deferred", why)
  end)

  -- The readback only means the engine kept what it was handed if the mode
  -- moved. An engine that can never tune, sitting in the mode the player has
  -- configured - Vosk without the endpointer symbol answers "default", which
  -- is also Mudlet's default - refuses without moving anything, and calling
  -- that "not yet in effect" promises a load that will change nothing.
  -- The setting is in force: it is the mode the engine is in.
  it("reports success when the engine was already in the requested mode", function()
    withEngine({ sensitivityBefore = "short" })
    assert.is_true(sttpkg.applySensitivity())
  end)

  -- The opposite advice, and the reason "deferred" alone was not enough. An
  -- idle engine rebuilds to change the endpoint rules, and a rebuild that
  -- fails leaves nothing loaded - "takes effect at the next model load" would
  -- send the player away from the one thing that fixes it.
  it("calls a rebuild that killed the engine failed, not deferred", function()
    withEngine({ stateBefore = "ready", stateAfter = "error" })
    local applied, why = sttpkg.applySensitivity()
    assert.is_false(applied)
    assert.are.equal("failed", why)
  end)

  -- A dead rebuild may well have stored the mode on its way down, so the
  -- readback and the state disagree. The state wins: one of the two answers
  -- tells the player to wait for a load that is not coming.
  it("prefers failed over deferred when a dead rebuild kept the mode", function()
    withEngine({ keeps = true, stateBefore = "ready", stateAfter = "error" })
    local applied, why = sttpkg.applySensitivity()
    assert.is_false(applied)
    assert.are.equal("failed", why)
  end)

  -- The case that reading only the state afterwards gets wrong. A denied
  -- microphone leaves the engine in error with its handles alive; asked to
  -- retune from there it never rebuilds, declines exactly as a busy engine
  -- does, and says so itself. Calling that a failed rebuild contradicts the
  -- engine's own message on the line above it.
  it("does not call an engine already in error a failed rebuild", function()
    withEngine({ keeps = true, stateBefore = "error", stateAfter = "error" })
    local applied, why = sttpkg.applySensitivity()
    assert.is_false(applied)
    assert.are.equal("deferred", why)
  end)

  -- The configured value has to be the one offered. Every other case here uses
  -- "short", which is also the fallback, so none of them can tell the two apart.
  it("offers the configured mode rather than the fallback", function()
    withEngine({ accepts = true })
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

  -- getInfo() is documented as always answering, but a core too old to report
  -- its mode reports nothing to compare against - and a nil readback is not a
  -- kept value. Unsupported is the honest reading: it promises no retry.
  it("is unsupported when the core reports no mode to read back", function()
    _G.stt = {
      init = function() return true end,
      getInfo = function() return { state = "ready" } end,
      setSensitivity = function() return nil end,
    }
    local applied, why = sttpkg.applySensitivity()
    assert.is_false(applied)
    assert.are.equal("unsupported", why)
  end)

  it("still succeeds on a core that reports no mode when the engine accepts", function()
    _G.stt = {
      init = function() return true end,
      getInfo = function() return { state = "ready" } end,
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
