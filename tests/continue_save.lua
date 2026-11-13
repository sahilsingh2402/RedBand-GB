-- Continue from a real save (made by the game itself) through the watchface: title, CONTINUE,
-- then play on with talking (A), walking and menus, under a given engine size, view, display
-- path and old settings file. Nothing may fail, stop or show a problem.
--   bandhost32 0 tests/continue_save.lua <app>/ <save file> <engine S|L|XL> <view> <cfg line> [frames]
APPDIR = arg[1]
local SAVE, ENGINE, VIEW, CFGLINE, N = arg[2], arg[3], arg[4], arg[5] or '', tonumber(arg[6] or '20000')
local T = dofile('tests/common.lua')
os.execute('mkdir -p /data; cp ' .. SAVE .. ' /data/redbandgb_red.sav')
local cfg = 'view=' .. VIEW .. '\n' .. CFGLINE:gsub(';', '\n') .. '\n'
local mock, R = T.load(APPDIR, { unthrottled = true, keepSaves = true, core = ENGINE, cfg = cfg })
mock.fire(R.power, mock.EVENT.CLICKED)
local timer, emu = R.timer(), R.emu()
assert(emu, 'did not start: ' .. tostring(R.errmsg()))
local frames = 0
local seed = 5
local function rnd(n) seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n end
local keys = { 'UP', 'DOWN', 'LEFT', 'RIGHT', 'A', 'A', 'A', 'B', 'START', 'UP', 'DOWN', 'LEFT', 'RIGHT' }
local script = { [400] = 'START', [700] = 'A', [900] = 'A', [1100] = 'A', [1300] = 'A' }   -- title, CONTINUE, info box
local held, releaseAt = nil, 0
local run = emu.runFrame
local function hook(e) local r = e.runFrame; e.runFrame = function() frames = frames + 1; return r() end end
hook(emu)
local mism, checks, last = 0, 0, R.shown()
while frames < N do
  if held and frames >= releaseAt then mock.fire(R.buttons[({ UP = 'U', DOWN = 'D', LEFT = 'L', RIGHT = 'R' })[held] or held], mock.EVENT.RELEASED); held = nil end
  if not held then
    local k = script[frames - frames % 1] 
    for f = frames - 3, frames do if script[f] then k = script[f]; script[f] = nil end end
    if not k and frames > 1500 and rnd(30) == 0 then k = keys[rnd(#keys) + 1] end
    if k then held = k; releaseAt = frames + 4 + rnd(30); mock.fire(R.buttons[({ UP = 'U', DOWN = 'D', LEFT = 'L', RIGHT = 'R' })[k] or k], mock.EVENT.PRESSED) end
  end
  if timer.paused then break end
  timer.cb(timer)
  if R.emu() ~= emu then emu = R.emu(); if emu then hook(emu) end end
  if R.shown() ~= last then last = R.shown(); mock.refresh(); checks = checks + 1; if not T.shown_matches(mock, R) then mism = mism + 1 end end
end
local e = R.emu()
print(string.format('continue %s %s [%s]: frames %d, shown %d, checks %d, mismatches %d, loaded from %s, map %d, path %s, stopped %s, error %s, message "%s", problems %d',
  ENGINE, VIEW, CFGLINE, frames, R.shown(), checks, mism, tostring(R.savedFrom()), e and e._ram[0xD35E - 0x7FFF] or -1, tostring(R.presenter.mode),
  tostring(timer.paused or e == nil), tostring(R.errmsg()), tostring(R.msg().props.text), #mock.problems))
