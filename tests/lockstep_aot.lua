local new = dofile(arg[1] or 'tools/gbcore.lua')
local old = dofile('/tmp/gbcore_noaot.lua')
local f = io.open('rom/pokemon_red.gb', 'rb'); local rom = f:read('a'); f:close()
local function host(m) local c = {}
  return { romBanks = 64, bank0 = function() return m.packBank(rom:sub(1, 16384)) end, bank0bytes = function() return { rom:byte(1, 16384) } end,
    bank = function(n) local t = c[n]; if not t then t = m.packBank(rom:sub(n * 16384 + 1, n * 16384 + 16384)); c[n] = t end; return t end } end
local A, B = new.create(host(new)), old.create(host(old))
local P = { { 'START', 1500, 6 }, { 'A', 1620, 6 } }
for k = 0, 99 do P[#P + 1] = { 'A', 1700 + 40 * k, 5 } end
for k = 0, 7 do P[#P + 1] = { 'B', 5800 + 30 * k, 5 } end
P[#P + 1] = { 'RIGHT', 6100, 51 }; P[#P + 1] = { 'DOWN', 6200, 102 }; P[#P + 1] = { 'LEFT', 6340, 68 }
local seed = 13579
local function rnd(n) seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n end
local keys = { 'UP', 'DOWN', 'LEFT', 'RIGHT', 'A', 'B', 'START', 'SELECT' }
local fr = 6983
while fr < 14000 do local k = keys[rnd(#keys) + 1]; local h = 5 + rnd(45); P[#P + 1] = { k, fr, h }; fr = fr + h + 3 + rnd(25) end
local at = {}
for _, p in ipairs(P) do at[p[2]] = at[p[2]] or {}; table.insert(at[p[2]], p) end
local held, tA, tB = {}, 0, 0
for frame = 0, 13999 do
  for _, p in ipairs(at[frame] or {}) do A.setButton(p[1], true); B.setButton(p[1], true); held[#held + 1] = { p[1], frame + p[3] } end
  for i = #held, 1, -1 do if held[i][2] <= frame then A.setButton(held[i][1], false); B.setButton(held[i][1], false); table.remove(held, i) end end
  local t = os.clock(); A.runFrame(); tA = tA + os.clock() - t
  t = os.clock(); B.runFrame(); tB = tB + os.clock() - t
  if frame % 500 == 499 then
    local sa, sb = A.state(), B.state()
    for _, k in ipairs({ 'pc', 'sp', 'a', 'b', 'c', 'd', 'e', 'h', 'l', 'romBank' }) do
      if sa[k] ~= sb[k] then print('DIVERGED at frame ' .. frame .. ' field ' .. k); os.exit(1) end end
    for i = 1, 25088 do if A._ram[i] ~= B._ram[i] then print('RAM DIVERGED at frame ' .. frame .. ' key ' .. i); os.exit(1) end end
  end
end
print(string.format('compiled-block core == interpreter core for 14000 frames (CPU registers + all RAM every 500 frames); speed: %.3f -> %.3f ms/frame (x%.2f)', tB / 14 , tA / 14, tB / tA))
