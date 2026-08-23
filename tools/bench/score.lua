-- Score the .tsv files run-matrix.py produced, using the package's own scorer
-- so the numbers mean what "stt test" means.
--
--   lua score.lua results/*.tsv
dofile((arg[0]:match("^(.*)/") or ".") .. "/../../src/scripts/STT/STTTest.lua")
local test = sttpkg.test

local rows = {}
for _, path in ipairs(arg) do
  local exact, errors, words, lostFirst, blank, total = 0, 0, 0, 0, 0, 0
  local realtime
  for line in io.lines(path) do
    if line:match("^#") then
      realtime = tonumber(line:match("rtf=([%d%.]+)")) or realtime
    else
      local ref, heard = line:match("^([^\t]*)\t(.*)$")
      if ref and ref ~= "" then
        total = total + 1
        if heard == "" then blank = blank + 1 end
        local s = test.score(ref, heard)
        if s.exact then exact = exact + 1 end
        errors = errors + s.errors
        if not s.firstWord then lostFirst = lostFirst + 1 end
        local _, spaces = ref:gsub("%S+", "")
        words = words + spaces
      end
    end
  end
  rows[#rows + 1] = {
    name = (path:match("([^/]+)%.tsv$") or path):gsub("^sherpa%-onnx%-", ""),
    exact = total > 0 and exact / total or 0,
    wer = words > 0 and errors / words or 0,
    lostFirst = lostFirst, blank = blank, total = total, realtime = realtime,
  }
end

table.sort(rows, function(a, b) return a.exact > b.exact end)

print(string.format("%-56s %6s %5s %6s %6s %8s", "configuration", "exact", "wer", "lost1", "blank", "realtime"))
for _, r in ipairs(rows) do
  print(string.format("%-56s %5d%% %4d%% %6d %6d %7s",
    r.name, math.floor(r.exact * 100 + 0.5), math.floor(r.wer * 100 + 0.5),
    r.lostFirst, r.blank, r.realtime and string.format("%.2fx", r.realtime) or "-"))
end
