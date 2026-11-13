-- Display path choice (4.5.1): settings from older builds start clean; the memory path is only
-- given up after 3 sessions in a row ended abruptly in their first frames on a band where it
-- never worked; a display error mid-session switches to files for that session only.
APPDIR = arg[1]
local T = dofile('tests/common.lua')
local VER = (APPDIR and io.open(APPDIR .. 'fontland.lua')) and '460L' or '460'
local mock, R = T.load(APPDIR, { unthrottled = true })
mock.fire(R.power, mock.EVENT.CLICKED)
assert(R.presenter.mode == 'direct' and R.cfg.probe == 'p1', 'first try not marked: ' .. tostring(R.cfg.probe))
local timer = R.timer()
local n = 0 while R.shown() < 25 and n < 5000 do timer.cb(timer) n = n + 1 end
assert(R.cfg.probe == 'ok' and R.cfg.memok == '1', 'not confirmed after 25 shown frames')
mock.fire(R.power, mock.EVENT.CLICKED)
local function start(cfgtext)
  local m, r = T.load(APPDIR, { unthrottled = true, cfg = cfgtext })
  m.fire(r.power, m.EVENT.CLICKED)
  return m, r
end
-- three abrupt ends in a row, memory path never confirmed on this band: files
local m2, R2 = start('view=fast\ndisp=auto\nprobe=p3\nmemok=\nver=' .. VER .. '\n')
assert(R2.presenter.mode == 'file' and R2.view() == 'fast', 'p3 without memok must use files')
-- the same, but the memory path has worked on this band before: memory
local m3, R3 = start('view=big\ndisp=auto\nprobe=p3\nmemok=1\nver=' .. VER .. '\n')
assert(R3.presenter.mode == 'direct', 'a band where memory worked must not be switched to files')
-- settings left by an older build (stuck on files, small engine): start clean, keep the view
local m4, R4 = start('view=smooth\ndisp=file\nprobe=failed\nenginecap=S\nhud=1\n')
assert(R4.presenter.mode == 'direct' and R4.cfg.disp == 'auto' and R4.cfg.enginecap == 'XL' and R4.view() == 'smooth' and R4.cfg.ver == VER, 'old settings not reset')
local f = io.open('/data/redbandgb_cfg40.txt', 'r') or io.open('/data/redbandgb_cfgL.txt', 'r') or io.open(APPDIR .. 'redbandgb_cfg40.txt', 'r')
local saved = f and f:read('a') or ''; if f then f:close() end
assert(saved:find('ver=' .. VER) and saved:find('disp=auto'), 'clean settings not saved')
-- LED long-press: files, then back to memory
m4.fire(R4.ledHit, m4.EVENT.LONG_PRESSED); assert(R4.cfg.disp == 'file' and R4.presenter.mode == 'file')
m4.fire(R4.ledHit, m4.EVENT.LONG_PRESSED); assert(R4.cfg.disp == 'auto' and R4.presenter.mode == 'direct', 'LED long-press did not go back')
-- a display error during play: files for this session, nothing remembered
local timer4 = R4.timer()
local present = R4.presenter.present
local fails = 0
R4.presenter.present = function(...) if fails < 3 then fails = fails + 1 error('display failed') end return present(...) end
for _ = 1, 200 do timer4.cb(timer4) end
R4.presenter.present = present
assert(R4.presenter.mode == 'file' and R4.cfg.disp == 'auto', 'session fallback must not be saved: ' .. R4.cfg.disp)
print('probe states OK: first try p1 -> ok/memok; p3 without memok -> files; with memok -> memory; old settings reset; LED toggles; display error -> files this session only')
