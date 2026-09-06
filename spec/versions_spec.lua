-- The line a troubleshooter is asked to paste. It has to be right about which
-- piece is which: the package version and the game's catalog version look
-- alike and mean nothing alike, and reading a stale catalog as an out-of-date
-- addon sends someone after the wrong thing.
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

describe("sttpkg.versions", function()
  before_each(function()
    _G.getPackageInfo = function(name)
      return ({ STT = { version = "1.2.3" }, MCVP = { version = "2.0.2" } })[name] or {}
    end
    _G.getMudletVersion = function() return "5.0.1" end
    _G.mcvp = { version = function() return 4 end }
  end)

  it("names the installed package versions", function()
    local line = sttpkg.versions()
    assert.is_truthy(line:find("STT 1.2.3", 1, true))
    assert.is_truthy(line:find("MCVP 2.0.2", 1, true))
    assert.is_truthy(line:find("Mudlet 5.0.1", 1, true))
  end)

  -- The distinction the line exists to keep straight.
  it("keeps the game's catalog version apart from the package version", function()
    local line = sttpkg.versions()
    assert.is_truthy(line:find("catalog v4", 1, true),
                     "the catalog version should be labelled as the game's, got: " .. line)
    assert.is_falsy(line:find("MCVP 4", 1, true), "the catalog version was printed as the package version")
  end)

  -- Nothing here requires the provider to be MCVP, so the line must not report
  -- as though it did.
  it("says a provider is present even when it is not a package it can name", function()
    _G.getPackageInfo = function() return {} end
    local line = sttpkg.versions()
    assert.is_truthy(line:find("provider present", 1, true), "got: " .. line)
  end)

  it("says so when no vocabulary provider is installed at all", function()
    _G.mcvp = nil
    local line = sttpkg.versions()
    assert.is_truthy(line:find("no vocabulary provider installed", 1, true), "got: " .. line)
  end)

  it("says so when the game has sent no catalog yet", function()
    _G.mcvp = { version = function() return nil end }
    local line = sttpkg.versions()
    assert.is_truthy(line:find("no catalog received yet", 1, true), "got: " .. line)
  end)

  -- An older Mudlet has neither call; the line still has to come out.
  it("survives a Mudlet with no version or package API", function()
    _G.getPackageInfo = nil
    _G.getMudletVersion = nil
    local line = sttpkg.versions()
    assert.is_string(line)
    assert.is_truthy(line:find("STT unknown", 1, true), "got: " .. line)
  end)
end)
