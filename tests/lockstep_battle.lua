-- Compiled-block engine vs the plain interpreter through battles (rival battle + Route 1 wild
-- encounters): CPU registers and all RAM compared every 250 frames.
--   lua5.4 tests/lockstep_battle.lua tools/gbcore_xl.lua [frames]
local new = dofile(arg[1])
local old = dofile('/tmp/gbcore_noaot.lua')
local N = tonumber(arg[2] or '40000')
local f = io.open('rom/pokemon_red.gb', 'rb'); local rom = f:read('a'); f:close()
local function host(m) local c = {}
  return { romBanks = 64, bank0 = function() return m.packBank(rom:sub(1, 16384)) end, bank0bytes = function() return { rom:byte(1, 16384) } end,
    bank = function(n) local t = c[n]; if not t then t = m.packBank(rom:sub(n * 16384 + 1, n * 16384 + 16384)); c[n] = t end; return t end } end
local A, B = new.create(host(new)), old.create(host(old))
local setA = A.setButton
A.setButton = function(b, on) B.setButton(b, on); return setA(b, on) end     -- the same input to both
local ctl = dofile('tests/battle_route.lua').new(A)
local tA, tB = 0, 0
for frame = 0, N - 1 do
  ctl.step(frame)
  local t = os.clock(); A.runFrame(); tA = tA + os.clock() - t
  t = os.clock(); B.runFrame(); tB = tB + os.clock() - t
  if frame % 250 == 249 then
    local sa, sb = A.state(), B.state()
    for _, k in ipairs({ 'pc', 'sp', 'a', 'b', 'c', 'd', 'e', 'h', 'l', 'romBank' }) do
      if sa[k] ~= sb[k] then print('DIVERGED at frame ' .. frame .. ' field ' .. k .. ' battles ' .. table.concat(ctl.events, ' ')); os.exit(1) end end
    for i = 1, 25088 do if A._ram[i] ~= B._ram[i] then print('RAM DIVERGED at frame ' .. frame .. ' key ' .. i .. ' battles ' .. table.concat(ctl.events, ' ')); os.exit(1) end end
  end
end
print(string.format('%s == interpreter through %d frames with %d battles (%s); %.3f vs %.3f ms/frame',
  arg[1]:match('[^/]+$'), N, ctl.battles, table.concat(ctl.events, ' '), tA / N * 1000, tB / N * 1000))
