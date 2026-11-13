-- Long session through the 4.0.0 watchface: scripted new game + random play, screen off/on,
-- pause, POWER off/on, all three views, a stretch on the file path. After every shown frame the
-- LVGL stand-in draws it from raw memory (through the address-keyed image cache) and the drawn
-- bytes must be exactly the frame main.lua presented; full garbage collections are forced so a
-- released pixel string would be overwritten (0xDD) before it is drawn. Every 61st shown frame is
-- compared pixel by pixel with the emulator framebuffer.
--   bandhost32 <capKB> tests/drive_long.lua <app dir>/ <frames> [nocache]
local dir, maxFrames, nocache = arg[1], tonumber(arg[2]), arg[3] == 'nocache' or arg[3] == 'mem'
local memrun = arg[3] == 'mem'   -- memory measurement: draw only every 50th frame (the stand-in's copies are garbage too)
local T = dofile('tests/common.lua')
local freeKB = tonumber(arg[4] or '')
local mock, R = T.load(dir, { unthrottled = true, meminfo = freeKB and T.meminfo(freeKB) or nil })
if nocache then mock.setCacheMax(0) end
local timer = R.timer()
local frames, emu = 0, nil
local function hook()
  emu = R.emu()
  local run = emu.runFrame
  emu.runFrame = function() frames = frames + 1; return run() end
end
local Pr = R.presenter
local lastFB, lastBGP
local present = Pr.present
Pr.present = function(fb, bgp) lastFB, lastBGP = fb, bgp; return present(fb, bgp) end
mock.fire(R.power, mock.EVENT.CLICKED); hook()
assert(Pr.mode == 'direct', 'memory path not chosen: ' .. tostring(Pr.why))
local P = { { 'START', 1500, 6 }, { 'A', 1620, 6 } }
for k = 0, 99 do P[#P + 1] = { 'A', 1700 + 40 * k, 5 } end
for k = 0, 7 do P[#P + 1] = { 'B', 5800 + 30 * k, 5 } end
P[#P + 1] = { 'R', 6100, 51 }; P[#P + 1] = { 'D', 6200, 102 }; P[#P + 1] = { 'L', 6340, 68 }
local seed = 99
local function rnd(n) seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n end
local keys = { 'U', 'D', 'L', 'R', 'A', 'B', 'START', 'SELECT', 'U', 'D', 'L', 'R', 'A', 'A' }
local f = 6983
while f < maxFrames do local k = keys[rnd(#keys) + 1]; local h = 4 + rnd(50); P[#P + 1] = { k, f, h }; f = f + h + 3 + rnd(30) end
table.sort(P, function(x, y) return x[2] < y[2] end)
local pi, held, releaseAt = 1, nil, 0
local events, done = {}, {}
local function once(name, cond, fn) if not done[name] and cond then done[name] = true; fn(); events[#events + 1] = name .. '@' .. frames end end
local shownChecked, mismatches, pixChecked, pixBad, gcChecks, viewsSeen, modesSeen = 0, 0, 0, 0, 0, {}, {}
local lastShown = R.shown()
local stuck = 0
local function check_shown(tag)
  local ok = T.shown_matches(mock, R)
  if not ok then mismatches = mismatches + 1; if mismatches <= 3 then print('MISMATCH ' .. tag .. ' at frame ' .. frames .. ' view ' .. R.view() .. ' mode ' .. Pr.mode) end end
  shownChecked = shownChecked + 1
end
while frames < maxFrames do
  if held and frames >= releaseAt then mock.fire(R.buttons[held], mock.EVENT.RELEASED); held = nil end
  if not held and P[pi] and frames >= P[pi][2] then
    held = P[pi][1]; releaseAt = frames + P[pi][3]; pi = pi + 1
    mock.fire(R.buttons[held], mock.EVENT.PRESSED)
  end
  once('screen-off', frames >= 9000, function()
    ScreenStateChangedCB('ON', 'OFF', 'test'); local f0 = frames
    for _ = 1, 20 do if not timer.paused then timer.cb(timer) end end
    assert(frames == f0, 'emulation ran while the screen was off')
    if not memrun then collectgarbage('collect') end; if pcall(mock.refresh) then check_shown('screen-off') end
    ScreenStateChangedCB('OFF', 'ON', 'test') end)
  once('pause-resume', frames >= 12000, function() mock.fire(R.pause, mock.EVENT.CLICKED); assert(timer.paused)
    if not memrun then collectgarbage('collect') end; if pcall(mock.refresh) then check_shown('paused') end; mock.fire(R.pause, mock.EVENT.CLICKED); assert(not timer.paused) end)
  once('power-off-on', frames >= 15000, function()
    if held then mock.fire(R.buttons[held], mock.EVENT.RELEASED); held = nil end
    emu = nil
    mock.fire(R.power, mock.EVENT.CLICKED)
    assert(R.emu() == nil and timer.paused, 'power off did not stop the core')
    collectgarbage('collect'); collectgarbage('collect')
    local okr, drawn = pcall(mock.refresh)
    for _, o in ipairs(okr and drawn or {}) do assert(o ~= R.image(), 'the screen image was drawn after power off') end
    mock.fire(R.power, mock.EVENT.CLICKED); hook()
    assert(R.emu() ~= nil and not timer.paused, 'power on did not restart') end)
  once('view-smooth', frames >= 5000, function() R.toggleView() end)
  once('view-fast', frames >= 7000, function() R.toggleView() end)
  once('view-big', frames >= 8500, function() R.toggleView() end)
  once('file-path', frames >= 18000, function() mock.fire(R.ledHit, mock.EVENT.LONG_PRESSED); assert(Pr.mode == 'file') end)
  once('file-smooth', frames >= 19500, function() R.toggleView() end)
  once('memory-path', frames >= 21000, function() mock.fire(R.ledHit, mock.EVENT.LONG_PRESSED); assert(Pr.mode == 'direct') end)
  once('view-fast2', frames >= 23000, function() R.toggleView() end)
  if timer.paused then print('TIMER PAUSED (error) at frame ' .. frames .. ': ' .. tostring(R.errmsg())); break end
  local before = frames
  timer.cb(timer)
  if R.shown() ~= lastShown then
    lastShown = R.shown()
    viewsSeen[R.view()] = true; modesSeen[Pr.mode] = true
    if not memrun or lastShown % 50 == 0 then
    if lastShown % 37 == 0 then collectgarbage('collect'); gcChecks = gcChecks + 1 end
    -- under a memory cap the test's own copies may not fit: that is the harness, not the face
    if memrun then if pcall(mock.refresh) then check_shown('present') end else mock.refresh(); check_shown('present') end
    if not memrun and lastShown % 3 == 0 then mock.refresh(); check_shown('redraw') end     -- a redraw served by the cache
    if lastShown % 61 == 0 then pixChecked = pixChecked + 1; pixBad = pixBad + T.pixels_ok(mock, R, lastFB, lastBGP) end
    end
  end
  if frames == before then stuck = stuck + 1; if stuck > 200 then print('NO PROGRESS'); break end else stuck = 0 end
end
local errs = {}
for _, o in ipairs(mock.objects) do
  local t = o.props.text
  if o.kind == 'Label' and type(t) == 'string' and (t:find('rror') or t:find('^stopped') or t:find('cannot')) then errs[#errs + 1] = t end
end
local vs, ms = {}, {}
for k in pairs(viewsSeen) do vs[#vs + 1] = k end; for k in pairs(modesSeen) do ms[#ms + 1] = k end
table.sort(vs); table.sort(ms)
local cn, cb = mock.cacheStats()
print(string.format('engine %s | frames %d | shown %d | drawn-frame checks %d, mismatches %d | after forced GC %d | pixel checks %d, wrong pixels %d | views %s | paths %s | LVGL decodes %d, cache hits %d, cache %d entries %.1f MB | rows built %d reused %d | problems %d | lifecycle %s | errors on screen: %s',
  (R.core()), frames, R.shown(), shownChecked, mismatches, gcChecks, pixChecked, pixBad, table.concat(vs, '+'), table.concat(ms, '+'),
  mock.decodes, mock.cacheHits, cn, cb / 1048576, Pr.rowsBuilt, Pr.rowsReused, #mock.problems, table.concat(events, ' '), #errs == 0 and 'none' or table.concat(errs, ' / ')))
for i = 1, math.min(3, #mock.problems) do print('PROBLEM: ' .. mock.problems[i]) end
