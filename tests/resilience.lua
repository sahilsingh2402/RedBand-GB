-- Faults and memory: recovery point (first after 20 s, then every 2 min), a failing frame goes back to it with the same
-- engine; four faults within a minute stop the game cleanly (clock back, nothing thrown).
APPDIR = arg[1]
local wall = 1000
os.clock = function() return wall end
local T = dofile('tests/common.lua')
local mock, R = T.load(APPDIR, { unthrottled = true })
mock.setCacheMax(0)
mock.fire(R.power, mock.EVENT.CLICKED)
local timer = R.timer()
for _ = 1, 6000 do wall = wall + 0.008; timer.cb(timer) end      -- 48 s of play (first recovery point at 20 s)
assert(R.snapshot(), 'no recovery point after 48 s')
local emu = R.emu()
local inner = emu.runFrame
local faults = 1
emu.runFrame = function() if faults > 0 then faults = faults - 1; error('injected fault') end return inner() end
wall = wall + 0.008; timer.cb(timer)
assert(R.emu() == emu and not timer.paused and R.msg().props.text == 'recovered', 'did not go back to the recovery point')
local s0 = R.shown(); for _ = 1, 300 do wall = wall + 0.008; timer.cb(timer) end
assert(R.shown() > s0, 'no frames after recovery')
faults = 99
for _ = 1, 10 do wall = wall + 0.008; local ok = pcall(timer.cb, timer); assert(ok, 'an error escaped the timer') end
assert(R.emu() == nil and not R.clockPanel.flags[mock.FLAG.HIDDEN], 'repeated faults must stop cleanly and show the clock')
assert(R.msg().props.text:find('^stopped'), 'no stop message')
print('resilience OK: recovery point after 20 s, fault -> same engine restored, repeated faults -> clean stop with the clock')
