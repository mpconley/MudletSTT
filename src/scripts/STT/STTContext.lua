--- What is in reach right now: the nouns a player is about to say.
--
-- The vocabulary catalog carries what a game publishes and rarely changes -
-- verbs, socials, channels, shortcuts. It deliberately does not carry the
-- things standing in front of you, because those turn over constantly and
-- versioning them would defeat the caching the protocol is built on. The
-- standard's answer is that a client binds its %item and %living slots from
-- whatever room and inventory data the game already sends, and samples that
-- when input capture begins. This is that binding.
--
-- The wire shapes are StickMUD's, and deliberately so: every game encodes
-- this differently - here a single-character attrib whose legend lives in the
-- server's own source - which is exactly why the protocol describes no schema
-- for it. Porting to another game means another adapter, not another standard.
--
-- The parsing half is pure Lua and tested; only the event wiring needs Mudlet.
-- @module sttpkg.context

sttpkg = sttpkg or {}
local context = {}

-- attrib codes, from StickMUD's /bin/daemons/gmcp_d.c:
--   w worn, W wearable armour/clothing, l wielded, c container,
--   t takeable, m monster/NPC, d dead (corpse), "" none
local LIVING_ATTRIB = "m"

-- Words that are never what a player says to refer to a thing. "A bottle of
-- beer" is spoken as "get beer" or "get bottle"; nobody says the article.
local NOT_SPOKEN = {
  a = true, an = true, the = true, of = true, some = true,
  ["and"] = true, with = true, in_ = true,
}

-- Short words make poor biasing and correction targets - they collide with
-- everything - and the same floor is applied to catalog words
local MIN_NOUN_LENGTH = 3

--- The words a player would actually say to refer to something, from the name
-- the game displays for it. Returns an array, lowercased.
function context.nouns(displayName)
  local out, seen = {}, {}
  for word in tostring(displayName or ""):lower():gmatch("[%a']+") do
    if #word >= MIN_NOUN_LENGTH and not NOT_SPOKEN[word] and not seen[word] then
      seen[word] = true
      out[#out + 1] = word
    end
  end
  return out
end

function context.newState()
  return { room = {}, inv = {} }
end

--- Which bucket a payload's location names. Anything unrecognised is ignored
-- rather than guessed into one.
local function bucket(state, location)
  if location == "room" then return state.room end
  if location == "inv" then return state.inv end
  return nil
end

--- Whether an entry is worth remembering. Entries carrying no attrib at all
-- are skipped: on this game they are special objects rather than things a
-- player refers to by name.
local function keep(entry)
  return type(entry) == "table"
    and type(entry.name) == "string"
    and entry.name ~= ""
    and entry.attrib ~= nil
    and entry.attrib ~= ""
end

--- Replace everything known about one location. The payload's items field
-- arrives as an empty string rather than an empty array when the location
-- holds nothing - the driver has no distinct empty-array form - so an empty
-- room reads as "" and must not be treated as a missing message.
function context.applyList(state, payload)
  local into = payload and bucket(state, payload.location)
  if not into then return state end

  for id in pairs(into) do into[id] = nil end

  local items = payload.items
  if type(items) == "table" then
    for _, entry in pairs(items) do
      if keep(entry) and entry.id then
        into[entry.id] = { name = entry.name, attrib = entry.attrib }
      end
    end
  end
  return state
end

function context.applyAdd(state, payload)
  local into = payload and bucket(state, payload.location)
  local entry = payload and payload.item
  if into and keep(entry) and entry.id then
    into[entry.id] = { name = entry.name, attrib = entry.attrib }
  end
  return state
end

function context.applyRemove(state, payload)
  local into = payload and bucket(state, payload.location)
  local entry = payload and payload.item
  if into and type(entry) == "table" and entry.id then
    into[entry.id] = nil
  end
  return state
end

--- Every distinct noun in reach, most-recently-seen order not guaranteed.
-- Deduplicated because a room can hold thirty torches, and thirty copies of
-- one word would spend a biasing budget on nothing.
-- opts.living selects only creatures, opts.item only objects; omit for both.
function context.words(state, opts)
  opts = opts or {}
  local out, seen = {}, {}
  for _, place in ipairs({ state.room, state.inv }) do
    for _, entry in pairs(place) do
      local living = (entry.attrib == LIVING_ATTRIB)
      local wanted = true
      if opts.living then wanted = living end
      if opts.item then wanted = not living end
      if wanted then
        for _, word in ipairs(context.nouns(entry.name)) do
          if not seen[word] then
            seen[word] = true
            out[#out + 1] = word
          end
        end
      end
    end
  end
  return out
end

--- The full display names in reach, which is what a test harness prompts with
-- and what a person would read.
function context.names(state)
  local out, seen = {}, {}
  for _, place in ipairs({ state.room, state.inv }) do
    for _, entry in pairs(place) do
      if not seen[entry.name] then
        seen[entry.name] = true
        out[#out + 1] = entry.name
      end
    end
  end
  return out
end

-- Live state and the Mudlet wiring below; everything above is pure.

context.state = context.state or context.newState()
context._handlers = context._handlers or {}

function context.inScope(opts)
  return context.words(context.state, opts)
end

function context.setup()
  for _, id in pairs(context._handlers) do
    killAnonymousEventHandler(id)
  end
  context._handlers = {}

  if type(registerAnonymousEventHandler) ~= "function" then return end

  -- One handler per GMCP message this game sends about things in reach
  context._handlers.list = registerAnonymousEventHandler("gmcp.Char.Items.List", function()
    context.applyList(context.state, gmcp.Char.Items.List)
  end)
  context._handlers.add = registerAnonymousEventHandler("gmcp.Char.Items.Add", function()
    context.applyAdd(context.state, gmcp.Char.Items.Add)
  end)
  context._handlers.remove = registerAnonymousEventHandler("gmcp.Char.Items.Remove", function()
    context.applyRemove(context.state, gmcp.Char.Items.Remove)
  end)
end

function context.teardown()
  for _, id in pairs(context._handlers) do
    killAnonymousEventHandler(id)
  end
  context._handlers = {}
  context.state = context.newState()
end

sttpkg.context = context

if type(registerAnonymousEventHandler) == "function" then
  context.setup()
end
