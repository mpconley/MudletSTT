-- Tests for sttpkg.context, which turns a game's room and inventory messages
-- into the nouns a player is about to say.
--
-- The payloads here are copied from a real StickMUD session, quirks included:
-- an empty location arrives as the string "" rather than an empty array, item
-- names are display phrases with articles, and a room can hold thirty copies
-- of one thing.
dofile("src/scripts/STT/STTContext.lua")
local context = sttpkg.context

local function entry(id, name, attrib)
  return { id = id, name = name, attrib = attrib, icon = 0 }
end

describe("sttpkg.context", function()

  describe("nouns", function()
    it("drops the article a player never says", function()
      assert.same({ "bottle", "beer" }, context.nouns("A bottle of beer"))
      assert.same({ "torch" }, context.nouns("A torch"))
    end)

    it("keeps every content word, so either can be spoken", function()
      assert.same({ "lucky", "coin" }, context.nouns("A lucky coin"))
      assert.same({ "magic", "chalk" }, context.nouns("A magic chalk"))
    end)

    it("drops words too short to be worth biasing toward", function()
      -- "of" and "an" are stopwords; "elf" survives at three letters
      assert.same({ "old", "elf" }, context.nouns("An old elf"))
    end)

    it("survives punctuation, empty and missing names", function()
      assert.same({ "grendel" }, context.nouns("Grendel!"))
      assert.same({}, context.nouns(""))
      assert.same({}, context.nouns(nil))
    end)
  end)

  describe("applyList", function()
    it("reads a room full of things", function()
      local state = context.newState()
      context.applyList(state, {
        location = "room",
        items = {
          entry("a1", "A bottle of beer", "t"),
          entry("a2", "A torch", "t"),
          entry("a3", "Grendel", "m"),
        },
      })
      local words = context.words(state)
      table.sort(words)
      -- "A bottle of beer" is two nouns, either of which a player may say
      assert.same({ "beer", "bottle", "grendel", "torch" }, words)
    end)

    it("treats an empty location sent as a string as empty, not as absent", function()
      local state = context.newState()
      context.applyList(state, { location = "room", items = { entry("a1", "A torch", "t") } })
      context.applyList(state, { location = "room", items = "" })
      assert.same({}, context.words(state))
    end)

    it("replaces rather than merges, because a list is the whole location", function()
      local state = context.newState()
      context.applyList(state, { location = "room", items = { entry("a1", "A torch", "t") } })
      context.applyList(state, { location = "room", items = { entry("a2", "A shield", "W") } })
      assert.same({ "shield" }, context.words(state))
    end)

    it("keeps room and inventory apart", function()
      local state = context.newState()
      context.applyList(state, { location = "room", items = { entry("a1", "A torch", "t") } })
      context.applyList(state, { location = "inv", items = { entry("b1", "A sword", "l") } })
      local words = context.words(state)
      table.sort(words)
      assert.same({ "sword", "torch" }, words)
    end)

    it("ignores a location it does not know", function()
      local state = context.newState()
      context.applyList(state, { location = "vault", items = { entry("a1", "A torch", "t") } })
      assert.same({}, context.words(state))
    end)

    it("skips entries carrying no attrib at all", function()
      -- On this game those are special objects rather than things a player
      -- refers to by name
      local state = context.newState()
      context.applyList(state, {
        location = "room",
        items = { entry("a1", "Tim the Enchanter", ""), entry("a2", "A torch", "t") },
      })
      assert.same({ "torch" }, context.words(state))
    end)
  end)

  describe("deduplication", function()
    it("counts thirty torches once", function()
      local items = {}
      for i = 1, 30 do
        items[#items + 1] = entry("id" .. i, "A torch", "t")
      end
      local state = context.newState()
      context.applyList(state, { location = "room", items = items })
      assert.same({ "torch" }, context.words(state),
        "a biasing budget spent thirty times on one word is a budget wasted")
    end)
  end)

  describe("add and remove", function()
    it("adds one thing without disturbing the rest", function()
      local state = context.newState()
      context.applyList(state, { location = "room", items = { entry("a1", "A torch", "t") } })
      context.applyAdd(state, { location = "room", item = entry("a2", "A shield", "W") })
      local words = context.words(state)
      table.sort(words)
      assert.same({ "shield", "torch" }, words)
    end)

    it("removes by id, which is what the game sends", function()
      local state = context.newState()
      context.applyList(state, {
        location = "room",
        items = { entry("a1", "A torch", "t"), entry("a2", "A shield", "W") },
      })
      context.applyRemove(state, { location = "room", item = entry("a1", "A torch", "t") })
      assert.same({ "shield" }, context.words(state))
    end)

    it("ignores a removal for something it never had", function()
      local state = context.newState()
      context.applyList(state, { location = "room", items = { entry("a1", "A torch", "t") } })
      context.applyRemove(state, { location = "room", item = entry("zz", "A ghost", "t") })
      assert.same({ "torch" }, context.words(state))
    end)
  end)

  describe("classification", function()
    local function scoped()
      local state = context.newState()
      context.applyList(state, {
        location = "room",
        items = { entry("a1", "A torch", "t"), entry("a2", "Grendel", "m") },
      })
      return state
    end

    it("separates creatures from objects for slot-aware use", function()
      assert.same({ "grendel" }, context.words(scoped(), { living = true }))
      assert.same({ "torch" }, context.words(scoped(), { item = true }))
    end)

    it("offers both together for biasing, which needs no distinction", function()
      local words = context.words(scoped())
      table.sort(words)
      assert.same({ "grendel", "torch" }, words)
    end)
  end)

  describe("names", function()
    it("reports the display names a person would read", function()
      local state = context.newState()
      context.applyList(state, {
        location = "room",
        items = { entry("a1", "A bottle of beer", "t"), entry("a2", "A bottle of beer", "t") },
      })
      assert.same({ "A bottle of beer" }, context.names(state))
    end)
  end)
end)
