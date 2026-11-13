-- Capture real gameplay for the showcase GIF: every 4th game frame (15 per second of game time)
-- of a scripted new game, with the buttons held at that moment.
--   lua5.4 tools/gif_capture.lua <out.bin> <lastFrame>
--   lua5.4 -e "ROUTE_FILE='tests/battle_route.lua'" tools/gif_capture.lua <out.bin> <lastFrame>   (battles)
local out, last = arg[1], tonumber(arg[2] or '8400')
local m = dofile('tools/gbcore.lua')
local f = io.open('rom/pokemon_red.gb', 'rb'); local rom = f:read('a'); f:close()
local c = {}
local frame, FB, BGP = 0, nil, 0
local gb = m.create({ romBanks = 64, bank0 = function() return m.packBank(rom:sub(1, 16384)) end,
  bank = function(n) local t = c[n]; if not t then t = m.packBank(rom:sub(n * 16384 + 1, n * 16384 + 16384)); c[n] = t end; return t end,
  beginFrame = function() return frame % 4 == 0 end,
  frameReady = function(fb, bgp) FB, BGP = fb, bgp end })
local BIT = { RIGHT = 1, LEFT = 2, UP = 4, DOWN = 8, A = 16, B = 32, SELECT = 64, START = 128 }
local mask = 0
local set = gb.setButton
gb.setButton = function(b, on) if on then mask = mask | BIT[b] else mask = mask & ~BIT[b] end return set(b, on) end
local ctl = dofile(ROUTE_FILE or 'tools/gif_route.lua').new(gb)
local o = io.open(out, 'wb')
local n = 0
for fr = 0, last do
  frame = fr
  FB = nil
  ctl.step(fr)
  gb.runFrame()
  if fr % 4 == 0 and FB then
    o:write(string.pack('<I4BB', fr, mask, BGP), string.char(table.unpack(FB, 1, 5760)))
    n = n + 1
  end
end
o:close()
print('captured', n, 'frames')
