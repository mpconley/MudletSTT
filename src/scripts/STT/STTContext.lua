--- StickMUD's answer to "what is in reach", as an MCVP context adapter.
--
-- The generic half of this - pulling the words a player would speak out of a
-- display name, holding what is present, answering by slot - lives in
-- MudletMCVP as mcvp.context, because the standard makes in-reach binding
-- part of how a client fills its %item and %living slots rather than
-- something speech invented.
--
-- What stays here is the part no standard can describe: which messages this
-- game sends, and how to read one. The wire shapes are StickMUD's, and
-- deliberately so - here a single-character attrib whose legend lives in the
-- server's own source. Porting to another game means another adapter, not
-- another standard.
--
-- The read half is pure and tested; only registration needs Mudlet.
-- @module sttpkg.context

sttpkg = sttpkg or {}
local context = {}

-- attrib codes, from StickMUD's /bin/daemons/gmcp_d.c:
--   w worn, W wearable armour/clothing, l wielded, c container,
--   t takeable, m monster/NPC, d dead (corpse), "" none
local LIVING_ATTRIB = "m"

local EVENTS = {
  "gmcp.Char.Items.List",
  "gmcp.Char.Items.Add",
  "gmcp.Char.Items.Remove",
}

--- Where a payload's contents belong. Anything unrecognised is ignored rather
-- than guessed into a place.
local function place(payload)
  local location = type(payload) == "table" and payload.location
  if location == "room" or location == "inv" then return location end
  return nil
end

--- Whether an entry is worth remembering, and which slot it fills. Entries
-- carrying no attrib at all are skipped: on this game they are special
-- objects rather than things a player refers to by name.
local function classify(entry)
  if type(entry) ~= "table" or type(entry.name) ~= "string" or entry.name == "" then return nil end
  if entry.attrib == nil or entry.attrib == "" then return nil end
  return entry.attrib == LIVING_ATTRIB and "%living" or "%item"
end

local function asThing(entry)
  local slot = classify(entry)
  if not slot or entry.id == nil then return nil end
  return { id = entry.id, name = entry.name, slot = slot }
end

--- One StickMUD message, as an update mcvp.context can fold in.
-- Char.Items.List replaces a location wholesale; Add and Remove carry one
-- thing. The payload's items field arrives as an empty string rather than an
-- empty array when the location holds nothing - the driver has no distinct
-- empty-array form - so an empty room reads as "" and must not be mistaken
-- for a message that never came.
function context.read(event, payload)
  local where = place(payload)
  if not where then return nil end

  if event == "gmcp.Char.Items.List" then
    local things = {}
    if type(payload.items) == "table" then
      for _, entry in pairs(payload.items) do
        local thing = asThing(entry)
        if thing then things[#things + 1] = thing end
      end
    end
    return { place = where, replace = things }
  end

  if event == "gmcp.Char.Items.Add" then
    local thing = asThing(payload.item)
    return thing and { place = where, add = thing } or nil
  end

  if event == "gmcp.Char.Items.Remove" then
    local entry = payload.item
    if type(entry) == "table" and entry.id ~= nil then
      return { place = where, remove = entry.id }
    end
  end

  return nil
end

context.adapter = { name = "StickMUD Char.Items", events = EVENTS, read = context.read }

--- Hand the adapter to MCVP. Without that package there is nothing to bind
-- in-reach words into, and speech falls back to the published catalog alone.
function context.setup()
  if type(mcvp) ~= "table" or type(mcvp.context) ~= "table" then return false end
  mcvp.context.register(context.adapter)
  return true
end

function context.teardown()
  if type(mcvp) == "table" and type(mcvp.context) == "table" then
    mcvp.context.unregister()
  end
end

--- What is in reach, or nothing when no one is telling us.
function context.inScope(opts)
  if type(mcvp) ~= "table" or type(mcvp.context) ~= "table" then return {} end
  return mcvp.context.inScope(opts)
end

function context.names(opts)
  if type(mcvp) ~= "table" or type(mcvp.context) ~= "table" then return {} end
  return mcvp.context.displayNames(opts)
end

sttpkg.context = context

context.setup()
