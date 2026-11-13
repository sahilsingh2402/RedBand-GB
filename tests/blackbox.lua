-- Black box: during play a line of figures is kept in /data/redbandgb_last.txt; after a session
-- that ended without POWER off (a crash) the next POWER shows it; LED tap shows live figures.
APPDIR = arg[1]
local T = dofile('tests/common.lua')
os.remove('/data/redbandgb_last.txt')
local mock, R = T.load(APPDIR, { unthrottled = true, meminfo = T.meminfo(7000) })
mock.fire(R.power, mock.EVENT.CLICKED)
local timer = R.timer()
local t = os.clock() while os.clock() - t < 2.5 do timer.cb(timer) end
local line = R.boxRead()
assert(line and line:sub(1, 3) == 'run', 'no black-box line during play: ' .. tostring(line))
-- a crash: the face is gone without POWER off; the next start shows the line
local mock2, R2 = T.load(APPDIR, { unthrottled = true, meminfo = T.meminfo(7000), keepSaves = true })
mock2.fire(R2.power, mock2.EVENT.CLICKED)
local shown = R2.msg().props.text
assert(shown:find('^last run: ') and not R2.msg().flags[mock2.FLAG.HIDDEN], 'last-run line not shown: ' .. tostring(shown))
mock2.fire(R2.power, mock2.EVENT.CLICKED)
assert(R2.boxRead():sub(1, 2) == 'ok', 'clean POWER off not recorded')
mock2.fire(R2.ledHit, mock2.EVENT.SHORT_CLICKED)
print('black box OK: "' .. line .. '" | after a crash: "' .. shown .. '" | LED tap: "' .. R2.msg().props.text .. '"')
