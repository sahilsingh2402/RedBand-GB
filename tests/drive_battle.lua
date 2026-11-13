-- Intense scenes through the real watchface loop: the rival battle and Route 1 wild encounters
-- (battle transitions, flashes, sprite/move animations, many ROM banks). Every shown frame is
-- drawn by the LVGL stand-in from raw memory and must be exactly what was presented.
--   bandhost32 <capKB> tests/drive_battle.lua <app dir>/ <frames> [freeKB]
local dir, maxFrames, freeKB, mode = arg[1], tonumber(arg[2]), tonumber(arg[3] or ''), arg[4]
local memrun = mode == 'mem'      -- measure the watchface's own heap: no stand-in cache, few draws
local T = dofile('tests/common.lua')
local mock, R = T.load(dir, { unthrottled = true, meminfo = freeKB and T.meminfo(freeKB) or nil })
if memrun then mock.setCacheMax(0) end
mock.fire(R.power, mock.EVENT.CLICKED)
local timer = R.timer()
local emu = R.emu()
local frames = 0
local ctl
local function hook()
  emu = R.emu()
  local run = emu.runFrame
  emu.runFrame = function() ctl.step(frames); frames = frames + 1; return run() end
end
ctl = dofile('tests/battle_route.lua').new(emu)
hook()
local shownChecked, mismatches, lastShown, battleFrames, inBattleShown = 0, 0, R.shown(), 0, 0
local peak, bankStart = 0, R.bankLoads()
local banksInBattle, banksOut, bLast, wasIn = 0, 0, R.bankLoads(), false
while frames < maxFrames do
  if timer.paused then print('TIMER PAUSED at ' .. frames .. ': ' .. tostring(R.errmsg())); break end
  if R.emu() ~= emu then ctl = dofile('tests/battle_route.lua').new(R.emu()); hook() end
  timer.cb(timer)
  local bl = R.bankLoads()
  if ctl.inBattle then banksInBattle = banksInBattle + (bl - bLast); battleFrames = battleFrames + 1 else banksOut = banksOut + (bl - bLast) end
  bLast = bl
  if R.shown() ~= lastShown then
    lastShown = R.shown()
    if ctl.inBattle then inBattleShown = inBattleShown + 1 end
    if lastShown % (memrun and 50 or 1) == 0 then
      local ok = pcall(mock.refresh)
      if ok then shownChecked = shownChecked + 1; if not T.shown_matches(mock, R) then mismatches = mismatches + 1 end end
    end
  end
  local kb = collectgarbage('count'); if kb > peak then peak = kb end
end
local _, hostPeak = heap_usage()
print(string.format('engine %s | frames %d | battles %s | shown %d (%d in battle) | checks %d mismatches %d | ROM bank loads: %d in battle, %d outside | Lua heap peak %.0f KB | out-of-memory rescues %d | problems %d | stopped %s',
  (R.core()), frames, table.concat(ctl.events, ' '), R.shown(), inBattleShown, shownChecked, mismatches, banksInBattle, banksOut, peak, R.lowMem(), #mock.problems, tostring(R.emu() == nil)))
