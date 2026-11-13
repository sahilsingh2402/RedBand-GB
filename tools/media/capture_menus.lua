-- Capture for the second wide showcase: the scripted route through Oak's lab and the rival
-- battle to Route 1, then the START menu (party, CHARMANDER's stats, trainer card, a real save),
-- then back to wild battles. Every 4th frame from frame 7700, with the held buttons.
--   lua5.4 tools/media/capture_menus.lua <out.bin> 23000      (from the repository root)
local out, last = arg[1], tonumber(arg[2])
local m = dofile('tools/gbcore.lua')
local f = io.open('rom/pokemon_red.gb', 'rb'); local rom = f:read('a'); f:close()
local c = {}
local frame, FB, BGP = 0, nil, 0
local gb = m.create({ romBanks = 64, bank0 = function() return m.packBank(rom:sub(1, 16384)) end,
  bank = function(n) local t = c[n]; if not t then t = m.packBank(rom:sub(n * 16384 + 1, n * 16384 + 16384)); c[n] = t end; return t end,
  beginFrame = function() return frame % 4 == 0 end, frameReady = function(fb, bgp) FB, BGP = fb, bgp end })
local BIT = { RIGHT = 1, LEFT = 2, UP = 4, DOWN = 8, A = 16, B = 32, SELECT = 64, START = 128 }
local mask = 0
local set = gb.setButton
gb.setButton = function(b, on) if on then mask = mask | BIT[b] else mask = mask & ~BIT[b] end return set(b, on) end
local ctl = dofile('tests/battle_route.lua').new(gb)
local S = 17000
local script = {
  [S] = 'START', [S + 50] = 'A',                 -- POKEMON
  [S + 140] = 'A', [S + 190] = 'A',              -- CHARMANDER -> STATS
  [S + 330] = 'A', [S + 470] = 'B', [S + 530] = 'B',   -- page 2, back, back to menu
  [S + 590] = 'DOWN', [S + 610] = 'DOWN', [S + 640] = 'A',   -- RED: trainer card
  [S + 800] = 'B', [S + 860] = 'DOWN', [S + 900] = 'A', [S + 1060] = 'A',   -- SAVE, YES
}
local o = io.open(out, 'wb')
for fr = 0, last do
  frame = fr; FB = nil
  if fr < S - 100 or fr > S + 1500 then ctl.step(fr)
  elseif fr == S - 100 then for _, k in ipairs({ 'UP', 'DOWN', 'LEFT', 'RIGHT', 'A', 'B' }) do gb.setButton(k, false) end end
  local k = script[fr]; if k then gb.setButton(k, true) end
  for kk, v in pairs(script) do if fr == kk + 5 then gb.setButton(v, false) end end
  gb.runFrame()
  if fr % 4 == 0 and FB and fr >= 7700 then o:write(string.pack('<I4BB', fr, mask, BGP), string.char(table.unpack(FB, 1, 5760))) end
end
o:close()
print('captured to', last, 'battles', ctl.battles, table.concat(ctl.events, ' '))
