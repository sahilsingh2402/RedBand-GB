-- 4.2.0 flow: Poketch clock while off, POWER, game, LED, pause, TURBO, three views, display path
-- switch, BROWSE (list, two-tap delete, close resumes), crash recovery, memory pressure, screen
-- off/on, power off back to the clock.
local dir = arg[1]
local T = dofile('tests/common.lua')
local mock, R = T.load(dir, { unthrottled = true })
local timer, ledTimer = R.timer(), R.ledTimer
local function ledTicks(n) local s = {} for _ = 1, n do ledTimer.cb(ledTimer); s[#s + 1] = R.ledOn() and 1 or 0 end return table.concat(s) end
local function run(n) for _ = 1, n do timer.cb(timer); mock.refresh() end end
local H = mock.FLAG.HIDDEN
assert(ledTicks(4) == '0000', 'LED lit before POWER')
-- clock while off: panel shown with Poketch digits and the trainer
local cp = R.clockPanel
assert(not cp.flags[H], 'clock not shown while off')
mock.refresh()
local drawnFiles = 0
for _, o in ipairs(mock.images) do if o.srcType == 'file' and o.shown and o.parent == cp then drawnFiles = drawnFiles + 1 end end
assert(drawnFiles == 11, 'clock images not all drawn: ' .. drawnFiles)
for k, o in pairs(R.clockImgs) do assert(o.srcKey and o.srcKey:find('clkr?_'), 'clock image ' .. k) end
local t = os.date('*t')
assert(R.clockImgs.m2.srcKey:find('clkr?_b' .. (t.min % 10)), 'minute digit not the current time')
assert(#mock.problems == 0, 'LVGL saw a problem: ' .. table.concat(mock.problems, '; '))
mock.fire(R.power, mock.EVENT.CLICKED)
assert(R.emu(), 'core did not start: ' .. tostring(R.errmsg()))
assert(cp.flags[H], 'clock still shown while the game runs')
local Pr = R.presenter
assert(Pr.mode == 'direct', 'memory display path not chosen: ' .. tostring(Pr.why))
local emu, frames = R.emu(), 0
local runF = emu.runFrame
emu.runFrame = function() frames = frames + 1; return runF() end
run(400)
local img = R.image()
assert(frames >= 1000 and R.shown() > 50, 'game did not run / no frames shown')
assert(not img.flags[H] and ((img.props.w == 212 and img.props.h == 189) or (img.props.w == 224 and img.props.h == 202)) and img.shown.cf == 0x0A, 'BIG view')
local ok, why = T.shown_matches(mock, R); assert(ok, why)
assert(ledTicks(6):find('0') and ledTicks(6):find('1'), 'LED does not blink while running')
-- pause / TURBO
mock.fire(R.pause, mock.EVENT.CLICKED); local f0 = frames; run(50)
assert(timer.paused and frames == f0 and ledTicks(3) == '111', 'pause broken')
mock.fire(R.pause, mock.EVENT.CLICKED); run(100); assert(frames > f0, 'resume broken')
mock.fire(R.turboBtn, mock.EVENT.CLICKED); assert(R.turbo())
local fT = frames; run(100); assert(frames - fT >= 500, 'TURBO not faster')
mock.fire(R.turboBtn, mock.EVENT.CLICKED); assert(not R.turbo())
-- views
mock.fire(R.displayBg, mock.EVENT.LONG_PRESSED); run(40)
assert(R.view() == 'smooth' and (img.props.zoom == 338 or img.props.zoom == 358) and img.shown.cf == 0x08, 'SMOOTH')
mock.fire(R.displayBg, mock.EVENT.LONG_PRESSED); run(40); assert(R.view() == 'fast', 'FAST')
mock.fire(R.displayBg, mock.EVENT.LONG_PRESSED); run(40); assert(R.view() == 'big', 'BIG')
-- display path: files and back
mock.fire(R.ledHit, mock.EVENT.LONG_PRESSED); run(60)
assert(Pr.mode == 'file' and img.srcType == 'file', 'file path'); ok, why = T.shown_matches(mock, R); assert(ok, why)
mock.fire(R.ledHit, mock.EVENT.LONG_PRESSED); run(60); assert(Pr.mode == 'direct', 'memory path back')
-- crash recovery: one failing frame goes back to the recovery point and play continues
run(10)
local snapOk = R.snapshot() ~= nil
local boom = true
local inner = emu.runFrame
emu.runFrame = function() if boom then boom = false; error('injected fault') end return inner() end
run(5)
local after = R.shown(); run(60)
assert(R.emu() and not timer.paused and R.shown() > after and R.msg().props.text == 'recovered', 'did not recover from a fault (snapshot ' .. tostring(snapOk) .. ')')
emu = R.emu()
-- out of memory while building a frame (a real allocation failure): caches go, the frame is
-- skipped, play continues; nothing is ever limited in advance
local lm = R.lowMem()
local pres = R.presenter.present
local fail = true
R.presenter.present = function(...) if fail then fail = false; error('not enough memory') end return pres(...) end
run(30)
R.presenter.present = pres
assert(R.lowMem() > lm and not timer.paused and R.emu(), 'an out-of-memory frame stopped the game')
local sh = R.shown(); run(30); assert(R.shown() > sh, 'no frames after the out-of-memory frame')
-- BROWSE: needs a save file; make one, open, list, delete with two taps, close resumes
local sav = io.open('/data/redbandgb_red.sav', 'wb') or io.open(dir .. 'pokemon_red.sav', 'wb')
sav:write(string.rep('\0', 32768)); sav:close()
local bk = io.open('/data/redbandgb_red.sav.bak', 'wb'); if bk then bk:write(string.rep('\1', 32768)); bk:close() end
-- while playing the top-left button is UNSAFE: FAST mode on and off, the game keeps running
assert(R.browseText().props.text == 'UNSAFE', 'top-left button must read UNSAFE while playing')
mock.fire(R.browse, mock.EVENT.CLICKED); run(30)
assert(R.fast() and R.utilMax() > 0.82 and R.browser.flags[H], 'UNSAFE did not switch to FAST')
local s1 = R.shown(); run(60); assert(R.shown() > s1 and R.emu() and not timer.paused, 'game stopped in FAST mode')
mock.fire(R.browse, mock.EVENT.CLICKED); run(30)
assert(not R.fast() and R.utilMax() < 0.82, 'UNSAFE did not switch back to SAFE')
-- BROWSE works with the game off
mock.fire(R.power, mock.EVENT.CLICKED)
assert(R.browseText().props.text == 'BROWSE', 'top-left button must read BROWSE with the game off')
mock.fire(R.browse, mock.EVENT.CLICKED)
assert(not R.browser.flags[H], 'BROWSE did not open')
local files = R.browseFiles()
assert(#files >= 1 and files[1].label:find('GAME SAVE'), 'save not listed')
assert(R.rows[1].name.props.text:find('32K'), 'size not shown: ' .. tostring(R.rows[1].name.props.text))
local path = files[1].path
mock.fire(R.rows[1].btn, mock.EVENT.CLICKED)
assert(io.open(path, 'rb'), 'deleted on the first tap')
assert(R.rows[1].btext.props.text == 'SURE?', 'no confirmation step')
mock.fire(R.rows[1].btn, mock.EVENT.CLICKED)
assert(io.open(path, 'rb') == nil, 'second tap did not delete')
assert(io.open(path .. '.bak', 'rb') == nil, 'the backup of a deleted save would bring it back')
assert(R.emu() == nil, 'the game must be off')
mock.fire(R.closeBtn, mock.EVENT.CLICKED)
assert(R.browser.flags[H] and not cp.flags[H], 'CLOSE did not close / clock not back')
-- POWER again; screen off/on; power off back to the clock
mock.fire(R.power, mock.EVENT.CLICKED); emu = R.emu(); run(100)
ScreenStateChangedCB('ON', 'OFF', 't'); local f1 = R.shown()
for _ = 1, 20 do if not timer.paused then timer.cb(timer) end end
assert(R.shown() == f1, 'ran while the screen was off')
ScreenStateChangedCB('OFF', 'ON', 't'); run(50)
mock.fire(R.power, mock.EVENT.CLICKED)
local n = 0; local p = io.popen('ls /tmp/rbgb_* 2>/dev/null'); for _ in p:lines() do n = n + 1 end; p:close()
assert(R.emu() == nil and n == 0 and img.flags[H] and not cp.flags[H] and ledTicks(3) == '000', 'power off cleanup broken')
collectgarbage('collect'); mock.refresh()
assert(#mock.problems == 0, 'LVGL saw a problem: ' .. table.concat(mock.problems, '; '))
local allowed = { POWER = 1, PAUSE = 1, TURBO = 1, BROWSE = 1, SELECT = 1, START = 1, ['SAVE FILES'] = 1, ['NO SAVE FILES'] = 1, CLOSE = 1, DELETE = 1, ['SURE?'] = 1, recovered = 1 }
for _, o in ipairs(mock.objects) do
  local t = o.props.text
  if o.kind == 'Label' and t and t ~= '' and not allowed[t] and not t:find('^GAME SAVE') and not t:find('^SAVE ') and not t:find('^SETTINGS') and not t:find('^deleted') then
    error('unexpected text on the watchface: ' .. t)
  end
end
print('flow OK: clock while off, game, LED, pause, TURBO, BIG/SMOOTH/FAST, file path and back, fault recovery, out-of-memory frame, UNSAFE/SAFE while playing, BROWSE list + two-tap delete + close, screen off/on, power off to the clock')
