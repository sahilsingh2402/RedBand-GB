-- SAFE/FAST hand the running game to another engine size through a save state. On the core:
-- the game continued by the other engine must be identical (CPU + all RAM) to the game that
-- never changed engine, through battles. On the watchface: UNSAFE swaps L -> XL with 4.5 MB
-- free, SAFE swaps back, every shown frame drawn exactly, the game never stops.
APPDIR = arg[1]
local f = io.open('rom/pokemon_red.gb', 'rb'); local rom = f:read('a'); f:close()
local function host(m) local c = {}
  return { romBanks = 64, bank0 = function() return m.packBank(rom:sub(1, 16384)) end, bank0bytes = function() return { rom:byte(1, 16384) } end,
    bank = function(n) local t = c[n]; if not t then t = m.packBank(rom:sub(n * 16384 + 1, n * 16384 + 16384)); c[n] = t end; return t end } end
local S, XL = dofile('tools/gbcore_s.lua'), dofile('tools/gbcore_xl.lua')
local A, B = S.create(host(S)), S.create(host(S))
local setA = A.setButton
local function mirror(on) A.setButton = function(b, v) on.setButton(b, v); return setA(b, v) end end
mirror(B)
local ctl = dofile('tests/battle_route.lua').new(A)
local SWITCH, N = 11000, 24000
for frame = 0, N - 1 do
  if frame == SWITCH then          -- B: S engine -> XL engine via save state, as the watchface does
    local st = B.saveState()
    local nb = XL.create(host(XL)); nb.loadState(st); B = nb; mirror(B)
  elseif frame == SWITCH + 6000 then
    local st = B.saveState()
    local nb = S.create(host(S)); nb.loadState(st); B = nb; mirror(B)
  end
  ctl.step(frame); A.runFrame(); B.runFrame()
  if frame % 500 == 499 then
    local sa, sb = A.state(), B.state()
    for _, k in ipairs({ 'pc', 'sp', 'a', 'b', 'c', 'd', 'e', 'h', 'l', 'romBank' }) do assert(sa[k] == sb[k], 'CPU differs at frame ' .. frame .. ' (' .. k .. ')') end
    for i = 1, 25088 do assert(A._ram[i] == B._ram[i], 'RAM differs at frame ' .. frame) end
  end
end
print(string.format('engine handoff OK (core): S -> XL at %d, XL -> S at %d, identical to the unchanged game through %d frames with %d battles', SWITCH, SWITCH + 6000, N, ctl.battles))
-- watchface
local T = dofile('tests/common.lua')
local MEMF = T.meminfo(4500)
local mock, R = T.load(APPDIR, { unthrottled = true, meminfo = MEMF })
mock.fire(R.power, mock.EVENT.CLICKED)
local timer = R.timer()
assert(R.core() == 'L', 'SAFE with 4.5 MB free must start the L engine, got ' .. tostring(R.core()))
local function run(n) local bad = 0 for _ = 1, n do local s0 = R.shown(); timer.cb(timer); if R.shown() ~= s0 then mock.refresh(); if not T.shown_matches(mock, R) then bad = bad + 1 end end end return bad end
local bad = run(300)
local e0 = R.emu()
mock.fire(R.browse, mock.EVENT.CLICKED)
assert(R.fast() and R.core() == 'XL' and R.emu() ~= e0 and R.coreSwaps() == 1, 'UNSAFE did not hand the game to the XL engine')
bad = bad + run(300)
mock.fire(R.browse, mock.EVENT.CLICKED)
assert(not R.fast() and R.core() == 'L' and R.coreSwaps() == 2, 'SAFE did not hand the game back to the L engine')
bad = bad + run(300)
assert(bad == 0 and R.emu() and not timer.paused and #mock.problems == 0, 'frames wrong or stopped after a handoff')
-- FAST drops back to SAFE by itself when the band gets short of memory
mock.fire(R.browse, mock.EVENT.CLICKED); assert(R.fast(), 'FAST again')
local fh = io.open(MEMF, 'w'); fh:write(string.format('%11s%11s%11s%11s%11s%7s%7s%s\n', 'total', 'used', 'free', 'maxused', 'maxfree', 'nused', 'nfree', 'name'))
fh:write(string.format('%11d%11d%11d%11d%11d%7d%7d %s\n', 9000000, 7000000, 2000 * 1024, 7000000, 1000000, 400, 20, 'Umem')); fh:close()
R.mem.checkAt, R.mem.checkKB = 0, 0
local t = os.clock() while os.clock() - t < 1.5 do timer.cb(timer) end
assert(not R.fast() and R.emu() and not timer.paused, 'FAST did not fall back to SAFE when memory got short')
print('engine handoff OK (watchface): SAFE L -> UNSAFE XL -> SAFE L, every shown frame exact, never stopped; FAST falls back to SAFE when memory gets short')
