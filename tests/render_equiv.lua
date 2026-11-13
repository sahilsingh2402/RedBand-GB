-- line-by-line renderer (up to 3.1.0) vs catch-up rendering + tile-row cache (3.2.0): every drawn frame must be byte-identical; CPU + RAM identical
local every = tonumber(arg[1] or '1')
local A = dofile('tests/gbcore_perline_reference.lua')
local B = dofile('tools/gbcore.lua')
local f = io.open('rom/pokemon_red.gb', 'rb'); local rom = f:read('a'); f:close()
local function mk(m, sink)
  local c, n = {}, 0
  return m.create({ romBanks = 64, bank0 = function() return m.packBank(rom:sub(1, 16384)) end, bank0bytes = function() return { rom:byte(1, 16384) } end,
    bank = function(k) local t = c[k]; if not t then t = m.packBank(rom:sub(k * 16384 + 1, k * 16384 + 16384)); c[k] = t end; return t end,
    beginFrame = function(d) n = n + 1; return n % every == 0 end,
    frameReady = function(fb, bgp) sink[#sink + 1] = string.char(bgp) .. string.char(table.unpack(fb, 1, 2880)) .. string.char(table.unpack(fb, 2881, 5760)) end })
end
local fa, fbb = {}, {}
local ga, gb = mk(A, fa), mk(B, fbb)
local P = { { 'START', 1500, 6 }, { 'A', 1620, 6 } }
for k = 0, 99 do P[#P + 1] = { 'A', 1700 + 40 * k, 5 } end
for k = 0, 7 do P[#P + 1] = { 'B', 5800 + 30 * k, 5 } end
local seed = 4711
local function rnd(n) seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n end
local keys = { 'UP', 'DOWN', 'LEFT', 'RIGHT', 'A', 'B', 'START', 'SELECT', 'UP', 'DOWN', 'LEFT', 'RIGHT' }
local fr = 6400
while fr < 14000 do local k = keys[rnd(#keys) + 1]; local h = 5 + rnd(45); P[#P + 1] = { k, fr, h }; fr = fr + h + 3 + rnd(25) end
local at = {}
for _, p in ipairs(P) do at[p[2]] = at[p[2]] or {}; table.insert(at[p[2]], p) end
local hold = {}
local frames, mism, firstBad = 0, 0, nil
for frame = 0, 13999 do
  for _, p in ipairs(at[frame] or {}) do ga.setButton(p[1], true); gb.setButton(p[1], true); hold[#hold + 1] = { p[1], frame + p[3] } end
  for i = #hold, 1, -1 do if hold[i][2] <= frame then ga.setButton(hold[i][1], false); gb.setButton(hold[i][1], false); table.remove(hold, i) end end
  ga.runFrame(); gb.runFrame()
  if #fa ~= #fbb then print('DRAWN FRAME COUNT DIFFERS at frame ' .. frame); os.exit(1) end
  while #fa > 0 do
    local x, y = table.remove(fa), table.remove(fbb)
    frames = frames + 1
    if x ~= y then mism = mism + 1; firstBad = firstBad or frame end
  end
  if frame % 500 == 499 then
    local sa, sb = ga.state(), gb.state()
    for _, k in ipairs({ 'pc', 'sp', 'a', 'b', 'c', 'd', 'e', 'h', 'l', 'romBank' }) do
      if sa[k] ~= sb[k] then print('CPU DIVERGED at frame ' .. frame .. ' ' .. k); os.exit(1) end end
    for i = 1, 25088 do if ga._ram[i] ~= gb._ram[i] then print('RAM DIVERGED at frame ' .. frame .. ' key ' .. i); os.exit(1) end end
  end
end
print(string.format('drawing every %d frame(s): %d drawn frames compared, %d differ%s; CPU + RAM identical over 14,000 frames',
  every, frames, mism, firstBad and (' (first at frame ' .. firstBad .. ')') or ''))
