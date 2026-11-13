-- A real in-game save (START, SAVE, YES) on the real core: the battery RAM passes through
-- half-written states before the game's checksum is final, which is why only a finished,
-- settled save may be written to the file.
local m = dofile('tools/gbcore.lua')
local f = io.open('rom/pokemon_red.gb', 'rb'); local rom = f:read('a'); f:close()
local c = {}
local gb = m.create({ romBanks = 64, bank0 = function() return m.packBank(rom:sub(1, 16384)) end,
  bank = function(n) local t = c[n]; if not t then t = m.packBank(rom:sub(n * 16384 + 1, n * 16384 + 16384)); c[n] = t end; return t end })
local function valid(s) local sum = 0 for i = 0x2599, 0x3523 do sum = sum + s:byte(i) end return ((~sum) & 255) == s:byte(0x3524) end
local ctl = dofile('tests/battle_route.lua').new(gb)
local S = 17000
local script = { [S] = 'START', [S + 40] = 'DOWN', [S + 60] = 'DOWN', [S + 80] = 'DOWN', [S + 110] = 'A', [S + 270] = 'A' }
local flips, last, firstValid = 0, nil, nil
for frame = 0, S + 900 do
  if frame < S - 100 then ctl.step(frame) elseif frame == S - 100 then for _, k in ipairs({ 'UP', 'DOWN', 'LEFT', 'RIGHT', 'A', 'B' }) do gb.setButton(k, false) end end
  local k = script[frame]; if k then gb.setButton(k, true) end
  for kk, v in pairs(script) do if frame == kk + 4 then gb.setButton(v, false) end end
  gb.runFrame()
  if frame >= S then
    local v = valid(gb.getSRAM())
    if last ~= nil and v ~= last then flips = flips + 1 end
    if v and not firstValid then firstValid = frame end
    last = v
  end
end
assert(last == true and flips >= 2, 'expected a finished save after passing through half-written states')
print(string.format('in-game save: checksum valid from frame %d, %d valid/invalid flips while saving, final save valid', firstValid, flips))
