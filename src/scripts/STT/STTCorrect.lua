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

--- Match the longest phrase the leading tokens form, exactly or as a unique
-- near miss within the budget for the joined length. Returns the phrase and
-- how many tokens it covers, or nil and 0. Only phrases of two or more
-- tokens live here; a single token is correct.token's job.
function correct.phrase(tokens, lex)
  if not (lex and lex.phrases and lex.longest and lex.longest >= 2) then
    return nil, 0
  end
  for count = math.min(lex.longest, #tokens), 2, -1 do
    local bucket = lex.phrases[count]
    if bucket then
      local joined = table.concat(tokens, " ", 1, count):lower()
      if bucket.exact[joined] then return joined, count end
      local budget = correct.maxDistance(#joined)
      if budget > 0 then
        local best, bestDist, tied = nil, budget + 1, false
        for _, phrase in ipairs(bucket.list) do
          local d = correct.distance(joined, phrase, budget)
          if d < bestDist then
            best, bestDist, tied = phrase, d, false
          elseif d == bestDist and d <= budget and phrase ~= best then
            tied = true
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

--- Correct a phrase: the first token against the leading lexicon (command
-- words), every later token against the argument lexicon (targets, items).
-- Either lexicon may be nil to skip that position. Returns the corrected
-- text and how many tokens changed.
--
-- A message body is never touched. Once the leading word is known, its syntax
-- pattern says where the player's own words begin, and nothing from there on
-- is a correction candidate. Without this, "wiz say hello" had its last word
-- matched against the whole argument lexicon and came out as "wiz say hallo",
-- because hallo is a social - so the client rewrote what the player said, on a
-- channel, in front of everyone reading it.
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
    if phrase then
      local original = table.concat(tokens, " ", 1, consumed):lower()
      if original ~= phrase then count = count + 1 end
      out[#out + 1] = phrase
      local entry = leadingLex.exact[phrase]
      proseFrom = entry and correct.proseFrom(entry.syntax) or nil
      -- The pattern counts the phrase's own tokens, so the boundary is
      -- already in line-token terms
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
        local entry = leadingLex.exact[(fixed or token):lower()]
        proseFrom = entry and correct.proseFrom(entry.syntax) or nil
      end
    end
    index = index + 1
  end
  return table.concat(out, " "), count
end

sttpkg.correct = correct
