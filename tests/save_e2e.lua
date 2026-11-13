-- End to end: the real game saves itself (START, SAVE, YES) while the watchface runs and writes
-- the battery file. Once a good save is on disk, the file on disk must be a good save after
-- every single callback (a crash could come at any moment), and the final file is the game's.
APPDIR = arg[1]
local wall = 0
os.clock = function() return wall end
local T = dofile('tests/common.lua')
local MAIN = '/data/redbandgb_red.sav'
for _, q in ipairs({ MAIN, MAIN .. '.bak', MAIN .. '.tmp' }) do os.remove(q) end
local mock, R = T.load(APPDIR, { unthrottled = true })
mock.setCacheMax(0)
mock.fire(R.power, mock.EVENT.CLICKED)
local timer, emu = R.timer(), R.emu()
local ctl = dofile('tests/battle_route.lua').new(emu)
local S, frames = 17000, 0
local script = { [S] = 'START', [S + 40] = 'DOWN', [S + 60] = 'DOWN', [S + 80] = 'DOWN', [S + 110] = 'A', [S + 270] = 'A' }
local run = emu.runFrame
emu.runFrame = function()
  local fr = frames
  if fr < S - 100 or fr > S + 1000 then ctl.step(fr) elseif fr == S - 100 then for _, k in ipairs({ 'UP', 'DOWN', 'LEFT', 'RIGHT', 'A', 'B' }) do emu.setButton(k, false) end end
  local k = script[fr]; if k then emu.setButton(k, true) end
  for kk, v in pairs(script) do if fr == kk + 4 then emu.setButton(v, false) end end
  frames = frames + 1
  return run()
end
local function savValid(s) if not s or #s ~= 32768 then return false end local sum = 0 for i = 0x2599, 0x3523 do sum = sum + s:byte(i) end return ((~sum) & 255) == s:byte(0x3524) end
local function get(p) local f = io.open(p, 'rb'); if not f then return nil end local s = f:read('a'); f:close(); return s end
local goodSeen, badAfterGood, checks = false, 0, 0
while frames < S + 900 do
  wall = wall + 0.05
  timer.cb(timer)
  if frames >= S - 100 then
    local s = get(MAIN)
    checks = checks + 1
    if s and savValid(s) then goodSeen = true elseif goodSeen then badAfterGood = badAfterGood + 1 end
  end
end
wall = wall + 2; timer.cb(timer); wall = wall + 2; timer.cb(timer)
local final = get(MAIN)
-- keep playing into wild battles: the game decompresses every battle sprite into its battery
-- RAM (scratch), which must not be written as a save
local writes = R.saveWrites and R.saveWrites() or -1
local inb = 0
while frames < S + 1000 + 16000 do wall = wall + 0.05; timer.cb(timer); if ctl.inBattle then inb = inb + 1 end end
assert(get(MAIN) == final and (writes < 0 or R.saveWrites() == writes), 'the file was written again without a new in-game save (battle sprites in battery RAM)')
assert(goodSeen and badAfterGood == 0, 'the file on disk was not a good save at some moment: ' .. badAfterGood)
assert(savValid(final) and final:sub(0x599) == R.emu().getSRAM():sub(0x599), 'final file is not the game save')
os.execute('cp ' .. MAIN .. ' /tmp/redband_realsave.sav')
for _, q in ipairs({ MAIN, MAIN .. '.bak', MAIN .. '.tmp' }) do os.remove(q) end
print(string.format('save end-to-end OK: real in-game save; file checked after %d callbacks, never half-written once a good save existed; final file = game save; then %d battle frames (sprites decompressed into battery RAM) and no further write (%d writes in total)', checks, inb, R.saveWrites and R.saveWrites() or -1))
