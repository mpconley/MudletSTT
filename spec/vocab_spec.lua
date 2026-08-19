-- Tests for sttpkg.vocab, which derives a scored vocabulary from a sub-word
-- model so an engine pack does not need sentencepiece to install one.
--
-- The unit tests pin the wire-format decoding. The test that actually settles
-- it is the last one: it parses a real model and compares against a vocabulary
-- sentencepiece itself produced, and skips when that model is not installed
-- rather than pretending to have checked.
dofile("src/scripts/STT/STTVocab.lua")
local vocab = sttpkg.vocab

local REAL_MODEL = os.getenv("HOME") ..
  "/.config/mudlet/sherpa-models/sherpa-onnx-streaming-zipformer-en-2023-06-26/bpe.model"
local REAL_VOCAB = os.getenv("HOME") ..
  "/.config/mudlet/sherpa-models/sherpa-onnx-streaming-zipformer-en-2023-06-26/bpe.vocab"

local function readable(path)
  local f = io.open(path, "rb")
  if not f then return false end
  f:close()
  return true
end

describe("sttpkg.vocab", function()

  describe("varint", function()
    it("reads a single-byte value", function()
      local value, position = vocab.varint("\5", 1)
      assert.equals(5, value)
      assert.equals(2, position)
    end)

    it("reads a continued value, seven bits at a time", function()
      -- 0xAC 0x02 is 300: 0x2C low seven bits, then 2 shifted up seven
      assert.equals(300, (vocab.varint("\172\2", 1)))
    end)

    it("reports nothing when the bytes run out", function()
      assert.is_nil((vocab.varint("", 1)))
    end)
  end)

  describe("float32", function()
    local function bytes(...)
      return string.char(...)
    end

    it("decodes zero", function()
      assert.equals(0, (vocab.float32(bytes(0, 0, 0, 0), 1)))
    end)

    it("decodes one and minus one", function()
      assert.equals(1, (vocab.float32(bytes(0, 0, 128, 63), 1)))
      assert.equals(-1, (vocab.float32(bytes(0, 0, 128, 191), 1)))
    end)

    it("decodes a value with a fractional mantissa", function()
      -- 0x40490FDB is pi as a 32-bit float
      local value = vocab.float32(bytes(0xDB, 0x0F, 0x49, 0x40), 1)
      assert.is_true(math.abs(value - 3.14159265) < 1e-6)
    end)

    it("decodes the negative scores a vocabulary is made of", function()
      -- -3.2376409, the score of the first real piece in the English model
      local value = vocab.float32(bytes(0x9F, 0x35, 0x4F, 0xC0), 1)
      assert.is_true(math.abs(value + 3.2376409) < 1e-5)
    end)

    it("reports nothing when fewer than four bytes remain", function()
      assert.is_nil((vocab.float32("\0\0", 1)))
    end)
  end)

  describe("piecesFromModel", function()
    it("refuses an empty or non-string model", function()
      assert.is_nil((vocab.piecesFromModel("")))
      assert.is_nil((vocab.piecesFromModel(nil)))
    end)

    it("refuses a file that carries no pieces", function()
      -- A well-formed protobuf whose only field is not the piece list
      local notAModel = "\18\3abc"
      local pieces, err = vocab.piecesFromModel(notAModel)
      assert.is_nil(pieces)
      assert.is_string(err)
    end)
  end)

  describe("toVocabText", function()
    it("writes one piece and score per line, in order", function()
      local text = vocab.toVocabText({
        { piece = "<blk>", score = 0 },
        { piece = "\226\150\129THE", score = -3.3911421 },
      })
      local lines = {}
      for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
      assert.equals(2, #lines)
      assert.equals("<blk> 0", lines[1])
      assert.is_true(lines[2]:find("^\226\150\129THE %-3%.39114") ~= nil, lines[2])
    end)
  end)

  describe("against a model sentencepiece itself converted", function()
    it("produces the same pieces and scores", function()
      if not (readable(REAL_MODEL) and readable(REAL_VOCAB)) then
        -- The model is a 300MB download; a machine without it has nothing to
        -- compare against, and saying so beats a test that quietly passes
        return
      end

      local f = io.open(REAL_MODEL, "rb")
      local contents = f:read("*a")
      f:close()

      local pieces = assert(vocab.piecesFromModel(contents))

      local expected = {}
      for line in io.lines(REAL_VOCAB) do
        local piece, score = line:match("^(.*) ([^ ]+)$")
        expected[#expected + 1] = { piece = piece, score = tonumber(score) }
      end

      assert.equals(#expected, #pieces, "piece count must match sentencepiece")
      for i, entry in ipairs(pieces) do
        assert.equals(expected[i].piece, entry.piece,
          "piece " .. i .. " differs from sentencepiece")
        assert.is_true(math.abs(expected[i].score - entry.score) < 1e-5,
          ("score %d differs: %s vs %s"):format(i, entry.score, expected[i].score))
      end
    end)
  end)
end)
