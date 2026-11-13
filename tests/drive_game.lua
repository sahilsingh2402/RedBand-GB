-- Drive the 4.0.0 watchface like a user: POWER, scripted new game via the on-screen buttons, then
-- wander. Reaching Red's bedroom (map 38) proves input, timing and banking work end to end.
local dir, maxFrames = arg[1], tonumber(arg[2] or '7000')
local T = dofile('tests/common.lua')
local mock, R = T.load(dir, { unthrottled = true })
mock.setCacheMax(0)
mock.fire(R.power, mock.EVENT.CLICKED)
local timer, emu = R.timer(), R.emu()
assert(emu, 'core did not start')
local frames = 0
local run = emu.runFrame
emu.runFrame = function() frames = frames + 1; return run() end
local P = { { 'START', 1500, 6 }, { 'A', 1620, 6 } }
for k = 0, 99 do P[#P + 1] = { 'A', 1700 + 40 * k, 5 } end
for k = 0, 7 do P[#P + 1] = { 'B', 5800 + 30 * k, 5 } end
P[#P + 1] = { 'R', 6100, 51 }; P[#P + 1] = { 'D', 6200, 102 }; P[#P + 1] = { 'L', 6340, 68 }
table.sort(P, function(x, y) return x[2] < y[2] end)
local pi, held, releaseAt = 1, nil, 0
while frames < maxFrames do
  if held and frames >= releaseAt then mock.fire(R.buttons[held], mock.EVENT.RELEASED); held = nil end
  if not held and P[pi] and frames >= P[pi][2] then
    held = P[pi][1]; releaseAt = frames + P[pi][3]; pi = pi + 1
    mock.fire(R.buttons[held], mock.EVENT.PRESSED)
  end
  if timer.paused then break end
  timer.cb(timer)
end
print(string.format('END frames %d shown %d map %d timer paused: %s error: %s lowMem %d msg %s', frames, R.shown(), R.emu()._ram[0xD35E - 0x7FFF], tostring(timer.paused), tostring(R.errmsg()), R.lowMem(), tostring(R.msg().props.text)))
