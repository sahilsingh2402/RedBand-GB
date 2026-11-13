-- Stress test on a simulated band. A virtual clock charges every game frame, drawn frame, shown
-- frame and LVGL refresh with band-like costs (battle frames cost more), timer callbacks come as
-- LVGL schedules them, and the real game is played for a long time through the real watchface:
-- the rival battle, then wild encounters in Route 1 again and again (blackouts included).
-- On top of that, seeded random events (screen off/on, pause, TURBO, view changes, display
-- path switches, BROWSE, POWER off/on), and bursts of allocation failures that hit any code at
-- any moment (Lua's own emergency collection fails too).
-- Checks: nothing ever escapes a callback; the game never stops by itself; the UI thread is
-- never busy all the time (idle share per second, longest busy stretch); every shown frame is
-- drawn exactly; no save file is written (nobody saved in the game).
--   bandhost32 <capKB> tests/stress.lua <app>/ <frames> <seed> [E ms] [burstEvery]
APPDIR = arg[1]
local FRAMES, SEED = tonumber(arg[2] or '60000'), tonumber(arg[3] or '1')
local E, BURST = tonumber(arg[4] or '10'), tonumber(arg[5] or '0')
local wall = 1000
os.clock = function() return wall end
local T = dofile('tests/common.lua')
-- arg[7] = the band's memory left for Lua in KB: /proc/meminfo then reports what the Lua heap
-- has not used of it (memory that really runs out, as on the band)
local CAPKB = tonumber(arg[7] or '')
local MEMFILE = T.meminfo(arg[6] and tonumber(arg[6]) or 8000)
local function update_meminfo()
  if not CAPKB then return end
  local used = heap_usage() // 1024
  local free = CAPKB - used
  if free < 0 then free = 0 end
  local f = io.open(MEMFILE, 'w')
  if f then
    f:write(string.format('%11s%11s%11s%11s%11s%7s%7s%s\n', 'total', 'used', 'free', 'maxused', 'maxfree', 'nused', 'nfree', 'name'))
    f:write(string.format('%11d%11d%11d%11d%11d%7d%7d %s\n', CAPKB * 1024, used * 1024, free * 1024, used * 1024, free * 512, 400, 20, 'Umem'))
    f:close()
  end
end
update_meminfo()
local mock, R = T.load(APPDIR, { meminfo = MEMFILE })
if CAPKB then mock.setCacheMax(0) end      -- the stand-in must not eat the capped memory itself
local seed = SEED
local function rnd(n) seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed % n end
local timer = R.timer()
local frames, ctl, emuSeen = 0, nil, nil
local busy, winStart, winBusy, winFrames, worstIdle, longest, streak = 0, wall, 0, 0, 1, 0, 0
local calmFrames, calmTime, battleFrames, battleTime = 0, 0, 0, 0
local errors, events = 0, {}
local base = 0
local swapsSeen = 0
local function attach()
  local emu = R.emu()
  if not emu or emu == emuSeen then return end
  -- FAST/SAFE switches hand the running game to another engine: same game, keep playing it
  if ctl and R.coreSwaps() ~= swapsSeen then
    swapsSeen = R.coreSwaps()
    emuSeen = emu
    ctl.rebind(emu)
    local run2 = emu.runFrame
    emu.runFrame = function()
      ctl.step(frames - base)
      frames = frames + 1
      wall = wall + (ctl.inBattle and E * 1.4 or E) / 1000
      return run2()
    end
    return
  end
  -- a new emulator instance (POWER, or the engine restarted from the battery save) starts its
  -- game from the beginning: the scripted player starts over with it
  emuSeen = emu
  ctl = dofile('tests/battle_route.lua').new(emu)
  base = frames
  local run = emu.runFrame
  emu.runFrame = function()
    ctl.step(frames - base)
    frames = frames + 1
    wall = wall + (ctl.inBattle and E * 1.4 or E) / 1000
    return run()
  end
end
-- the controller reads RAM from the emulator it was made for: rebuild it after POWER off/on
local function rebuild() ctl = nil emuSeen = nil attach() end
mock.fire(R.power, mock.EVENT.CLICKED); attach()
local Pr = R.presenter
local present = Pr.present
local presented = false
Pr.present = function(fb, bgp)
  wall = wall + ((R.view() == 'big') and 8 or 3) / 1000
  local r = present(fb, bgp)
  if r then presented = true end
  return r
end
if BURST > 0 then inject_alloc_failures(BURST, 4) end
local nextDue, nextEvent, checks, mism = wall, wall + 5, 0, 0
local lastErr = nil
local offUntil, turboUntil, pauseUntil, browseUntil = nil, nil, nil, nil
local evc_power = false
local function event(name) pcall(function() events[#events + 1] = name end) end
local errs = {}
local harnessErr = 0
local function iteration()
  -- random user / system events (harness code: protected from the injected failures)
  if DEBUG and frames % 10000 < 3 and ctl then local e2 = R.emu() if e2 then print('  dbg', frames, e2._ram[0xD35E - 0x7FFF], e2._ram[0xD362 - 0x7FFF], e2._ram[0xD361 - 0x7FFF], e2._ram[0xD163 - 0x7FFF], ctl.battles) end end
  pcall(function()
  if wall >= nextEvent then
    local k = rnd(100)
    if k < 20 and not offUntil then ScreenStateChangedCB('ON', 'OFF', 'stress'); offUntil = wall + 1 + rnd(4); event('screen-off')
    elseif k < 35 and not pauseUntil and R.emu() then mock.fire(R.pause, mock.EVENT.CLICKED); pauseUntil = wall + 1 + rnd(3); event('pause')
    elseif k < 50 and not turboUntil and R.emu() then R.toggleTurbo(); turboUntil = wall + 2 + rnd(4); event('turbo')
    elseif k < 65 then R.toggleView(); event('view')
    elseif k < 72 then mock.fire(R.ledHit, mock.EVENT.LONG_PRESSED); event('path')
    elseif k < 85 and not browseUntil then mock.fire(R.browse, mock.EVENT.CLICKED); browseUntil = wall + 1 + rnd(2); event('browse')
    elseif k < 92 and R.emu() and frames > FRAMES * 0.9 and not evc_power then evc_power = true; mock.fire(R.power, mock.EVENT.CLICKED); wall = wall + 2; mock.fire(R.power, mock.EVENT.CLICKED); rebuild(); event('power')
    end
    nextEvent = wall + 5 + rnd(15)
  end
  if offUntil and wall >= offUntil then ScreenStateChangedCB('OFF', 'ON', 'stress'); offUntil = nil end
  if pauseUntil and wall >= pauseUntil then if R.emu() then mock.fire(R.pause, mock.EVENT.CLICKED) end pauseUntil = nil end
  if turboUntil and wall >= turboUntil then if R.turbo() then R.toggleTurbo() end turboUntil = nil end
  if browseUntil and wall >= browseUntil then mock.fire(R.closeBtn, mock.EVENT.CLICKED); browseUntil = nil end
  if not R.emu() and not offUntil then mock.fire(R.power, mock.EVENT.CLICKED); rebuild(); event('restart') end
  end)
  -- one LVGL timer handler pass
  if CAPKB and frames % 30 == 0 then pcall(update_meminfo) end
  if wall < nextDue then wall = nextDue end           -- the thread sleeps until the next timer
  local t0 = wall
  nextDue = t0 + 0.008
  presented = false
  local before = frames
  if not timer.paused then
    local ok, e = pcall(timer.cb, timer)
    if not ok then errors = errors + 1; print('ESCAPED: ' .. tostring(e)) end
  end
  pcall(attach)
  local em = R.errmsg()
  if em and em ~= lastErr then lastErr = em; pcall(function() errs[em:sub(1, 70)] = (errs[em:sub(1, 70)] or 0) + 1 end) end
  local cb = wall - t0
  if presented then
    wall = wall + 0.003                                -- LVGL draws the new frame
    do                                                  -- LVGL draws every new frame
      local ok = pcall(mock.refresh)
      if ok then
        local ok2, same = pcall(T.shown_matches, mock, R)
        if ok2 then checks = checks + 1; if not same then mism = mism + 1 end end
      end
    end
  end
  local b = wall - t0
  winBusy = winBusy + b
  streak = streak + b
  if wall + 0.001 < nextDue then if streak > longest then longest = streak end streak = 0 end
  local nf = frames - before
  if ctl and ctl.inBattle then battleFrames = battleFrames + nf; battleTime = battleTime + (nextDue > wall and nextDue - t0 or wall - t0)
  else calmFrames = calmFrames + nf; calmTime = calmTime + (nextDue > wall and nextDue - t0 or wall - t0) end
  if wall - winStart >= 1 then
    local idle = 1 - winBusy / (wall - winStart)
    if idle < worstIdle and not timer.paused then worstIdle = idle end
    winStart, winBusy = wall, 0
  end
end
-- the harness itself can be hit by an injected failure: count it, go on (the watchface is the
-- thing under test, its callbacks are pcall'd by luavgl on the band as well)
while frames < FRAMES do
  local ok = pcall(iteration)
  if not ok then harnessErr = harnessErr + 1; if wall < nextDue then wall = nextDue end end
end
local injected = inject_alloc_failures(0)
local evc = {}
for _, e in ipairs(events) do evc[e] = (evc[e] or 0) + 1 end
local evs = {}
for k, v in pairs(evc) do evs[#evs + 1] = k .. ' ' .. v end
table.sort(evs)
local saves = io.open('/data/redbandgb_red.sav', 'rb')
local u, breaths = R.util()
print(string.format('stress seed %d E %gms: frames %d, battles %d | escaped errors %d | worst idle share %.0f%%, longest busy stretch %.0f ms | speed calm %.0f%%, battle %.0f%% | breaths %d | drawn checks %d, mismatches %d | alloc failures injected %d, out-of-memory rescues %d | save file written: %s | events: %s',
  SEED, E, frames, ctl and ctl.battles or 0, errors, worstIdle * 100, longest * 1000,
  calmFrames / math.max(calmTime, 1e-9) / 59.7275 * 100, battleFrames / math.max(battleTime, 1e-9) / 59.7275 * 100,
  breaths, checks, mism, injected, R.lowMem(), tostring(saves ~= nil), table.concat(evs, ', ')))
if saves then saves:close() end
local el = {}
for k, v in pairs(errs) do el[#el + 1] = v .. 'x ' .. k end
local e2 = R.emu()
print('  errors seen by the watchface: ' .. (#el > 0 and table.concat(el, ' | ') or 'none') .. ' | harness steps hit by injected failures: ' .. harnessErr)
if e2 then print(string.format('  game at the end: map %d (x %d, y %d), party %d, battles in this power cycle %d', e2._ram[0xD35E - 0x7FFF], e2._ram[0xD362 - 0x7FFF], e2._ram[0xD361 - 0x7FFF], e2._ram[0xD163 - 0x7FFF], ctl and ctl.battles or -1)) end
local restarts = evc['restart'] or 0
-- SAFE keeps >= 12% idle per second in these runs; with random UNSAFE taps (FAST, 85%) >= 8%
local ok = errors == 0 and mism == 0 and saves == nil and restarts == 0 and worstIdle >= 0.08 and frames >= FRAMES
print(ok and 'STRESS OK' or ('STRESS FAILED: escaped ' .. errors .. ', mismatches ' .. mism .. ', save written ' .. tostring(saves ~= nil) .. ', stopped by itself ' .. restarts .. ', worst idle ' .. string.format('%.0f%%', worstIdle * 100)))
