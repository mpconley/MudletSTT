--- Derive a scored vocabulary from a sub-word model file.
--
-- Engines that bias recognition toward a word list need the model's scored
-- vocabulary - sherpa-onnx wants bpe.vocab, "piece score" per line - but the
-- published model packages ship only bpe.model, the tokeniser itself. That
-- file is a protobuf, and the two fields needed are the first two of a
-- repeated message, so the conversion sentencepiece is normally required for
-- is a few dozen lines of parsing instead of a dependency an engine pack
-- could not install anyway.
--
-- Pure Lua and no Mudlet globals: testable under busted, and equally usable
-- by a client with no filesystem tooling of its own.
-- @module sttpkg.vocab

sttpkg = sttpkg or {}
local vocab = {}

--- Read a base-128 varint. Returns the value and the next position.
-- Lua 5.1 has no bitwise operators, so this is arithmetic: each byte carries
-- seven bits of value and a continuation flag in the eighth.
function vocab.varint(bytes, position)
  local value, shift = 0, 0
  while true do
    local byte = bytes:byte(position)
    if not byte then return nil, position end
    position = position + 1
    value = value + (byte % 128) * (2 ^ shift)
    if byte < 128 then
      return value, position
    end
    shift = shift + 7
  end
end

--- Decode a little-endian 32-bit float, the wire format protobuf uses for a
-- float field. Written out rather than unpacked because string.unpack does
-- not exist in Lua 5.1.
function vocab.float32(bytes, position)
  local b0, b1, b2, b3 = bytes:byte(position, position + 3)
  if not b3 then return nil, position end

  local sign = (b3 >= 128) and -1 or 1
  local exponent = (b3 % 128) * 2 + math.floor(b2 / 128)
  local mantissa = ((b2 % 128) * 256 + b1) * 256 + b0

  local value
  if exponent == 0 then
    -- Subnormal, including zero
    value = mantissa * 2 ^ -149
  elseif exponent == 255 then
    -- Infinity or not-a-number; neither belongs in a vocabulary, and treating
    -- it as zero keeps a malformed model from poisoning every score after it
    value = 0
  else
    value = (1 + mantissa / 2 ^ 23) * 2 ^ (exponent - 127)
  end

  return sign * value, position + 4
end

--- Skip a field whose contents are not needed, returning the next position.
-- A sub-word model carries the trainer and normaliser specifications
-- alongside the pieces, and the normaliser alone is most of the file.
local function skipField(bytes, position, wireType)
  if wireType == 0 then
    local _, next = vocab.varint(bytes, position)
    return next
  elseif wireType == 1 then
    return position + 8
  elseif wireType == 2 then
    local length, next = vocab.varint(bytes, position)
    if not length then return nil end
    return next + length
  elseif wireType == 5 then
    return position + 4
  end
  -- An unknown wire type means the rest cannot be walked safely
  return nil
end

--- One piece: its text and its score, from a SentencePiece submessage.
local function readPiece(payload)
  local piece, score, position = nil, 0, 1
  while position <= #payload do
    local key, next = vocab.varint(payload, position)
    if not key then break end
    local field, wireType = math.floor(key / 8), key % 8
    position = next

    if field == 1 and wireType == 2 then
      local length, after = vocab.varint(payload, position)
      piece = payload:sub(after, after + length - 1)
      position = after + length
    elseif field == 2 and wireType == 5 then
      score, position = vocab.float32(payload, position)
    else
      position = skipField(payload, position, wireType)
      if not position then break end
    end
  end
  return piece, score
end

--- Every piece in a sub-word model, in the model's own order - which is the
-- order the ids refer to, so it must be preserved.
-- Returns an array of {piece = string, score = number}, or nil and a message.
function vocab.piecesFromModel(contents)
  if type(contents) ~= "string" or contents == "" then
    return nil, "the model file is empty"
  end

  local pieces, position = {}, 1
  while position <= #contents do
    local key, next = vocab.varint(contents, position)
    if not key then break end
    local field, wireType = math.floor(key / 8), key % 8
    position = next

    if field == 1 and wireType == 2 then
      local length, after = vocab.varint(contents, position)
      if not length then break end
      local piece, score = readPiece(contents:sub(after, after + length - 1))
      if piece then
        pieces[#pieces + 1] = { piece = piece, score = score }
      end
      position = after + length
    else
      position = skipField(contents, position, wireType)
      if not position then break end
    end
  end

  if #pieces == 0 then
    return nil, "no vocabulary pieces found - this may not be a sub-word model"
  end
  return pieces
end

--- The vocabulary as an engine expects to read it: one piece and its score
-- per line, separated by a space, in model order.
function vocab.toVocabText(pieces)
  local lines = {}
  for _, entry in ipairs(pieces) do
    -- Nine significant digits round-trips a 32-bit float exactly, and the
    -- score decides how a word is split, so precision here is not cosmetic
    lines[#lines + 1] = string.format("%s %.9g", entry.piece, entry.score)
  end
  return table.concat(lines, "\n") .. "\n"
end

--- Write the scored vocabulary a model implies, next to the model itself.
-- Returns the number of pieces written, or nil and a message.
function vocab.deriveVocabFile(modelPath, vocabPath)
  local model = io.open(modelPath, "rb")
  if not model then
    return nil, "cannot read " .. tostring(modelPath)
  end
  local contents = model:read("*a")
  model:close()

  local pieces, err = vocab.piecesFromModel(contents)
  if not pieces then
    return nil, err
  end

  local out = io.open(vocabPath, "wb")
  if not out then
    return nil, "cannot write " .. tostring(vocabPath)
  end
  out:write(vocab.toVocabText(pieces))
  out:close()

  return #pieces
end

sttpkg.vocab = vocab
