-- Tests for the StickMUD context adapter: turning this game's room and
-- inventory messages into the updates mcvp.context folds in. The generic half
-- - noun extraction, holding what is present, answering by slot - is tested
-- in MudletMCVP, not here.
--
-- The payloads are copied from a real StickMUD session, quirks included: an
-- empty location arrives as the string "" rather than an empty array, item
-- names are display phrases with articles, and a room can hold thirty copies
-- of one thing.
dofile("src/scripts/STT/STTContext.lua")
local context = sttpkg.context

local function entry(id, name, attrib)
  return { id = id, name = name, attrib = attrib, icon = 0 }
end

local LIST = "gmcp.Char.Items.List"
local ADD = "gmcp.Char.Items.Add"
local REMOVE = "gmcp.Char.Items.Remove"

describe("the StickMUD context adapter", function()

  describe("Char.Items.List", function()
    it("replaces a location with what it now holds", function()
      local update = context.read(LIST, { location = "room", items = {
        entry(1, "A torch", "t"),
        entry(2, "An old elf", "m"),
      }})
      assert.equal("room", update.place)
      assert.same({ id = 1, name = "A torch", slot = "%item" }, update.replace[1])
      assert.same({ id = 2, name = "An old elf", slot = "%living" }, update.replace[2])
    end)

    it("reads the driver's empty location as empty, not as no message", function()
      -- StickMUD sends "" rather than [] for a location holding nothing, and
      -- an empty room has to clear the room rather than leave it stale
      local update = context.read(LIST, { location = "room", items = "" })
      assert.equal("room", update.place)
      assert.same({}, update.replace)
    end)

    it("keeps inventory and room apart", function()
      assert.equal("inv", context.read(LIST, { location = "inv", items = {} }).place)
    end)

    it("ignores a location this game does not name", function()
      assert.is_nil(context.read(LIST, { location = "elsewhere", items = {} }))
      assert.is_nil(context.read(LIST, { items = {} }))
      assert.is_nil(context.read(LIST, nil))
    end)
  end)

  describe("classification", function()
    it("calls the monster attrib a living thing and everything else an item", function()
      local update = context.read(LIST, { location = "room", items = {
        entry(1, "A dead rat", "d"),
        entry(2, "A rat", "m"),
        entry(3, "A worn cloak", "w"),
      }})
      assert.same({ "%item", "%living", "%item" },
                  { update.replace[1].slot, update.replace[2].slot, update.replace[3].slot })
    end)

    it("skips an entry with no attrib, which is a special object here", function()
      local update = context.read(LIST, { location = "room", items = {
        entry(1, "A signpost", ""),
        entry(2, "A torch", "t"),
      }})
      assert.equal(1, #update.replace)
      assert.equal("A torch", update.replace[1].name)
    end)
  end)

  describe("Char.Items.Add and Remove", function()
    it("carries one arrival", function()
      local update = context.read(ADD, { location = "room", item = entry(7, "A sword", "t") })
      assert.same({ place = "room", add = { id = 7, name = "A sword", slot = "%item" } }, update)
    end)

    it("carries one departure by id, without needing to know what it was", function()
      local update = context.read(REMOVE, { location = "room", item = { id = 7 } })
      assert.same({ place = "room", remove = 7 }, update)
    end)

    it("ignores an arrival it cannot name or place", function()
      assert.is_nil(context.read(ADD, { location = "room", item = entry(8, "", "t") }))
      assert.is_nil(context.read(ADD, { location = "room" }))
      assert.is_nil(context.read(REMOVE, { location = "room", item = {} }))
    end)
  end)

  describe("without MudletMCVP", function()
    it("binds nothing and answers with nothing, rather than erroring", function()
      -- mcvp is absent in this spec run, which is the state of a profile that
      -- has the speech package but not the vocabulary one
      assert.is_false(context.setup())
      assert.same({}, context.inScope())
      assert.same({}, context.names())
    end)
  end)
end)
