--- STT correction engine.
-- Pure Lua, no Mudlet globals: everything here is testable under busted
-- alone. Corrects recognised speech against a known vocabulary - in practice
-- the MCVP merged catalog - so near-misses from the recogniser land on real
-- game words. Conservative by design: a token is only replaced when exactly
-- one vocabulary word sits within a length-scaled edit-distance budget, so
-- ambiguity and short words are left untouched rather than guessed at.
-- Loaded first by scripts.json order; STTCore wires it to the stt.* events.
-- @module sttpkg.correct

sttpkg = sttpkg or {}
local correct = {}

--- Levenshtein distance between two lowercase strings, with a cutoff: any
-- distance beyond it is reported as cutoff + 1, letting callers abandon rows
-- early instead of measuring exactly how wrong a hopeless candidate is.
function correct.distance(a, b, cutoff)
  local la, lb = #a, #b
  if a == b then return 0 end
  if math.abs(la - lb) > cutoff then return cutoff + 1 end
  local prev = {}
  for j = 0, lb do prev[j] = j end
  for i = 1, la do
    local cur = { [0] = i }
    local rowMin = i
    local ca = a:byte(i)
    for j = 1, lb do
      local cost = (ca == b:byte(j)) and 0 or 1
      local v = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
      cur[j] = v
      if v < rowMin then rowMin = v end
    end
    if rowMin > cutoff then return cutoff + 1 end
    prev = cur
  end
  local d = prev[lb]
  if d > cutoff then return cutoff + 1 end
  return d
end

--- Edit budget for a token of this length. Short words correct to too many
-- neighbours ("go"/"do"/"no"), so they get no budget at all.
function correct.maxDistance(len)
  if len <= 3 then
    return 0
  elseif len <= 6 then
    return 1
  end
  return 2
end

--- Build a lookup from vocabulary entries (mcvp.entries() shape: each has a
-- .word; anything else on the entry is ignored here). Later duplicates of a
-- word are dropped so the first entry wins.
--- A word with its apostrophes taken out. Engines do not emit them: every
-- decoder tried here returns "tamarindos" for "Tamarindo's" and "captains"
-- for "captain's", every time. Matching on this form lets the apostrophe be
-- put back rather than counted as a word the vocabulary does not have.
function correct.deapostrophe(word)
  return (word:gsub("'", ""))
end

function correct.lexicon(entries)
  local lex = { exact = {}, list = {}, bare = {}, phrases = {}, longest = 1 }
  for _, entry in ipairs(entries or {}) do
    local word = tostring(entry.word or ""):lower()
    if word ~= "" and not lex.exact[word] then
      lex.exact[word] = entry
      -- Only the first spelling claims a bare form, so "its" cannot be
      -- rewritten to "it's" by a later entry
      local bare = correct.deapostrophe(word)
      if bare ~= word and not lex.bare[bare] then
        lex.bare[bare] = word
      end
      -- A multi-word entry is matched as one unit at the start of a line,
      -- longest first, so it is filed by how many tokens it covers and kept
      -- out of the single-token candidate list: as a candidate for one
      -- token it would manufacture a command phrase in argument position.
      local count = select(2, word:gsub("%S+", ""))
      if count < 2 then
        lex.list[#lex.list + 1] = word
      else
        local bucket = lex.phrases[count]
        if not bucket then
          bucket = { exact = {}, list = {} }
          lex.phrases[count] = bucket
        end
        bucket.exact[word] = entry
        bucket.list[#bucket.list + 1] = word
        if count > lex.longest then lex.longest = count end
      end
    end
  end
  table.sort(lex.list)
  for _, bucket in pairs(lex.phrases) do table.sort(bucket.list) end
  return lex
end

--- Correct one token against a lexicon. Returns the replacement word, or nil
-- to leave the token alone - because it is already a vocabulary word, has no
-- budget, has no candidate in budget, or has more than one equally close
-- candidate (a tie is ambiguity, not a correction).
function correct.token(token, lex)
  local lower = token:lower()
  if lex.exact[lower] then return nil end
  -- The whole word is right and only the apostrophe is missing, which is not
  -- a recognition error to be scored against a budget
  if lex.bare and lex.bare[lower] then return lex.bare[lower] end
  local budget = correct.maxDistance(#lower)
  if budget == 0 then return nil end
  local best, bestDist, tied = nil, budget + 1, false
  for _, word in ipairs(lex.list) do
    local d = correct.distance(lower, word, budget)
    if d < bestDist then
      best, bestDist, tied = word, d, false
    elseif d == bestDist and d <= budget and word ~= best then
      tied = true
    end
  end
  if best and bestDist <= budget and not tied then return best end
  return nil
end

--- Match the longest phrase the leading tokens form. Two passes over the
-- lengths, each longest-first: every length is tried for an exact match before
-- any length is tried for a near miss. Exact therefore always wins, so a
-- two-token entry carrying a %text pattern is never displaced by a three-token
-- near miss that carries none.
--
-- The fuzzy pass is deliberately meaner than the joined string alone would
-- make it, because a phrase must never be the reason an unambiguous word
-- changes. Joining inflates the budget - "get chest" is nine characters and
-- earns 2, where "get" alone earns 0 and "chest" earns 1 - so the budget is
-- capped at the sum of the tokens' own budgets, and a candidate whose first
-- word differs from a token 1 the lexicon already spells exactly is refused
-- outright. Each rule catches cases the other does not: the cap stops
-- "get chest" becoming "sea chest", the exact-first-word rule stops
-- "kill giant" becoming "hill giant".
--
-- Returns the phrase and how many tokens it covers, or nil and 0. Only phrases
-- of two or more tokens live here; a single token is correct.token's job.
function correct.phrase(tokens, lex)
  if not (lex and lex.phrases and lex.longest and lex.longest >= 2) then
    return nil, 0
  end
  local longest = math.min(lex.longest, #tokens)
  for count = longest, 2, -1 do
    local bucket = lex.phrases[count]
    if bucket then
      local joined = table.concat(tokens, " ", 1, count):lower()
      if bucket.exact[joined] then return joined, count end
    end
  end
  -- Token 1 as the lexicon spells it, when it knows the word at all. A fuzzy
  -- candidate proposing something else in that slot is not a correction of a
  -- mishearing; it is an overwrite of a word the player got right.
  local first = tokens[1] and tokens[1]:lower() or nil
  local firstExact = (first and lex.exact[first]) and first or nil
  for count = longest, 2, -1 do
    local bucket = lex.phrases[count]
    if bucket then
      local joined = table.concat(tokens, " ", 1, count):lower()
      local budget = correct.maxDistance(#joined)
      local apart = 0
      for i = 1, count do apart = apart + correct.maxDistance(#tokens[i]) end
      if apart < budget then budget = apart end
      if budget > 0 then
        local best, bestDist, tied = nil, budget + 1, false
        for _, phrase in ipairs(bucket.list) do
          if not (firstExact and phrase:match("^%S+") ~= firstExact) then
            local d = correct.distance(joined, phrase, budget)
            if d < bestDist then
              best, bestDist, tied = phrase, d, false
            elseif d == bestDist and d <= budget and phrase ~= best then
              tied = true
            end
          end
        end
        if best and bestDist <= budget and not tied then return best, count end
      end
    end
  end
  return nil, 0
end

--- Lowercase the first character. Recognisers that produce natural prose
-- sentence-case their output ("Smile"), which is not how MUD commands are
-- written. Only the first character changes, so proper nouns later in the
-- phrase - player and item names - keep the case they were recognised with.
function correct.lowerFirst(text)
  text = tostring(text or "")
  return text:sub(1, 1):lower() .. text:sub(2)
end

--- Case a phrase the way a player would have typed it. Two recogniser
-- conventions have to be met: prose models sentence-case their output
-- ("Smile"), and sub-word models trained on upper-cased text return the lot
-- in capitals ("KILL GOBLIN"). Text carrying no lower case at all is taken as
-- the second kind and lowered throughout; anything else only loses its first
-- capital, so proper nouns in arguments survive.
function correct.commandCase(text)
  text = tostring(text or "")
  if text:find("%u") and not text:find("%l") then
    return text:lower()
  end
  return correct.lowerFirst(text)
end

-- The closed set of slot classes MCVP defines. A pattern using anything else
-- is unparseable, and the standard is explicit that a client meeting one MUST
-- apply no slot correction for that entry rather than guessing - which is what
-- makes a future addition a non-event for a client this old.
local SLOT_CLASSES = {
  ["%living"] = true,
  ["%item"] = true,
  ["%player"] = true,
  ["%direction"] = true,
  ["%word"] = true,
  ["%text"] = true,
}

--- Where a pattern stops being vocabulary and becomes the player's own words,
-- as a 1-based token index, or nil for a pattern with no prose in it.
--
-- "say %text" answers 2, so everything after the verb is left alone. "tell
-- %player %text" answers 3, keeping the name correctable and walling off only
-- the message. The boundary comes from the pattern and never from guessing at
-- whitespace, which is why a game publishing no pattern gets no boundary.
function correct.proseFrom(syntax)
  if type(syntax) ~= "string" then return nil end
  local index, prose = 0, nil
  for token in syntax:gmatch("%S+") do
    index = index + 1
    if token:sub(1, 1) == "%" then
      if not SLOT_CLASSES[token] then return nil end
      if token == "%text" then prose = index end
    end
  end
  return prose
end

--- The prose boundary the lexicon declares for one word, as a 1-based token
-- index, or nil when it has no entry, no pattern, or a pattern with no %text.
local function boundaryOf(lex, word)
  local entry = lex and lex.exact[tostring(word):lower()]
  return entry and correct.proseFrom(entry.syntax) or nil
end

--- Correct a line: a leading multi-word catalog word as one unit if one
-- matches, otherwise the first token against the leading lexicon (command
-- words); every later token against the argument lexicon (targets, items).
-- Either lexicon may be nil to skip that position. Returns the corrected
-- text and how many tokens changed.
--
-- A message body is never touched. Once the leading word is known, its syntax
-- pattern says where the player's own words begin, and nothing from there on
-- is a correction candidate. Without this, "wiz say hello" had its last word
-- matched against the whole argument lexicon and came out as "wiz say hallo",
-- because hallo is a social - so the client rewrote what the player said, on a
-- channel, in front of everyone reading it.
--
-- The invariant that keeps the phrase path from undoing that: a phrase is
-- never accepted when it would cross a boundary token 1 has already
-- established. Token 1's own entry - found from the corrected spelling of that
-- token, not the spoken one - is consulted whatever the phrase matched, and if
-- its pattern puts the player's words at or before where the phrase
-- ends, the phrase is reaching into prose - it is refused and the line falls
-- through to the single-token path, which walls the body off correctly. A
-- catalog holding both "say" (pattern "say %text") and "say hello" is the
-- case: the phrase would consume "say hello", inherit no boundary from an
-- entry that has none, and leave the greeting after it correctable again.
-- Where both entries name a boundary, the stricter - smaller - index wins.
--
-- Deliberately not matched: a multi-word word whose position is "argument".
-- Phrases are indexed away from the single-token candidate list, and that
-- index is read only at the start of a line, so such a word reaches no
-- consulted index. Matching one mid-line would have to guess where an
-- argument begins, and a wrong guess manufactures a command out of a player's
-- words - the same public failure the boundary above exists to prevent. Every
-- multi-word word published in practice is leading-position.
function correct.apply(text, leadingLex, argumentLex)
  local tokens = {}
  for token in tostring(text or ""):gmatch("%S+") do tokens[#tokens + 1] = token end

  local out, count, proseFrom = {}, 0, nil
  local index = 1

  -- A multi-word catalog word is one unit at the start of the line, and
  -- has to be matched before any token is corrected on its own: "guild"
  -- alone would be pulled toward some other leading word, and the entry's
  -- syntax, keyed by the whole phrase, would never be found.
  if leadingLex and #tokens >= 2 then
    local phrase, consumed = correct.phrase(tokens, leadingLex)
    -- The lookup takes token 1 as corrected rather than as heard, for the same
    -- reason the single-token path below does: a command word misheard and put
    -- right is still that command, and the boundary its pattern declares has
    -- to hold on the strength of what it turned out to be. Reading the spoken
    -- form finds no entry for a mishearing, so "whispr wall hello there" took
    -- no boundary from "whisper %player %text" and had its message rewritten.
    local firstWord = phrase and (correct.token(tokens[1], leadingLex) or tokens[1])
    local firstFrom = firstWord and boundaryOf(leadingLex, firstWord) or nil
    -- A phrase that reaches at or past token 1's own boundary is spanning
    -- into the player's words: refuse it rather than carry the longer match
    if phrase and not (firstFrom and firstFrom <= consumed) then
      local original = table.concat(tokens, " ", 1, consumed):lower()
      if original ~= phrase then count = count + 1 end
      out[#out + 1] = phrase
      -- The pattern counts the phrase's own tokens, so the boundary is
      -- already in line-token terms
      proseFrom = boundaryOf(leadingLex, phrase)
      if firstFrom and (not proseFrom or firstFrom < proseFrom) then
        proseFrom = firstFrom
      end
      index = consumed + 1
    end
  end

  while index <= #tokens do
    local token = tokens[index]
    if proseFrom and index >= proseFrom then
      out[#out + 1] = token
    else
      local lex = (index == 1) and leadingLex or argumentLex
      local fixed = lex and correct.token(token, lex) or nil
      if fixed then
        count = count + 1
        out[#out + 1] = fixed
      else
        out[#out + 1] = token
      end
      -- Read from the corrected word rather than the spoken one: a channel
      -- name misheard and put right is still a channel, and its message body
      -- has to be protected on the strength of what it turned out to be.
      if index == 1 and leadingLex then
        proseFrom = boundaryOf(leadingLex, fixed or token)
      end
    end
    index = index + 1
  end
  return table.concat(out, " "), count
end

sttpkg.correct = correct
