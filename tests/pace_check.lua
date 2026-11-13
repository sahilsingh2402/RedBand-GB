-- Simulated band: a virtual wall clock; every game frame costs E ms (+Rr ms when its picture is
-- drawn), every shown frame costs Pl ms of Lua plus Lv ms of LVGL/GPU/flush work that runs after
-- the callback, in the same thread. Timer callbacks start at most every 8 ms (LVGL measures the period from the start of the last run). The real game is
-- played (intro, then walking), so the picture changes naturally.
--   bandhost64 0 tests/pace_check.lua <app dir>/ E Rr Pl Lv [seconds]
local dir, E, Rr, Pl, Lv, secs = arg[1], tonumber(arg[2]), tonumber(arg[3]), tonumber(arg[4]), tonumber(arg[5]), tonumber(arg[6] or '40')
local wall = 0
os.clock = function() return wall end
os.time = function() return math.floor(wall) end
local T = dofile('tests/common.lua')
local mock, R = T.load(dir, {})
mock.setCacheMax(0)
mock.fire(R.power, mock.EVENT.CLICKED)
if arg[7] == 'fast' then R.setMode(true) end
local timer = R.timer()
local emu = R.emu()
local Pr = R.presenter
local frames, shown = 0, 0
local run = emu.runFrame
-- phase 1 (not measured, no time): scripted intro straight to Red's bedroom
local P = { { 'START', 1500, 6 }, { 'A', 1620, 6 } }
for k = 0, 99 do P[#P + 1] = { 'A', 1700 + 40 * k, 5 } end
for k = 0, 7 do P[#P + 1] = { 'B', 5800 + 30 * k, 5 } end
local at = {}
for _, p in ipairs(P) do at[p[2]] = at[p[2]] or {}; table.insert(at[p[2]], p) end
local hold = {}
for f = 0, 6399 do
  for _, p in ipairs(at[f] or {}) do emu.setButton(p[1], true); hold[#hold + 1] = { p[1], f + p[3] } end
  for i = #hold, 1, -1 do if hold[i][2] <= f then emu.setButton(hold[i][1], false); table.remove(hold, i) end end
  run()
end
-- phase 2 (measured): walk around through the watchface loop
local rendered = false
local present = Pr.present
Pr.present = function(fb, bgp) wall = wall + Pl / 1000; local r = present(fb, bgp); if r then shown = shown + 1 end return r end
emu.runFrame = function() frames = frames + 1; wall = wall + E / 1000; return run() end
local host_fr = nil
-- extra cost of a drawn frame: count rendered frames via the presenter's input
local walk = { 'R', 'D', 'L', 'U', 'R', 'R', 'D', 'D', 'L', 'L', 'U', 'U' }
local held, wi, until_ = nil, 1, 0
local shownAt, gameAt = {}, {}
local lastShown = 0
local t0 = wall
local nextTick = wall
while wall - t0 < secs do
  if not held or frames >= until_ then
    if held then mock.fire(R.buttons[held], mock.EVENT.RELEASED) end
    held = walk[wi]; wi = wi % #walk + 1; until_ = frames + 48
    mock.fire(R.buttons[held], mock.EVENT.PRESSED)
  end
  if wall < nextTick then wall = nextTick end
  local s0 = shown
  local tickStart = wall
  timer.cb(timer)
  if shown > s0 then
    wall = wall + Rr / 1000 + Lv / 1000          -- drawing the picture + LVGL after the callback
    shownAt[#shownAt + 1] = wall; gameAt[#gameAt + 1] = frames
  end
  nextTick = tickStart + 0.008
end
local function stats(v) local s, s2 = 0, 0 for _, x in ipairs(v) do s = s + x; s2 = s2 + x * x end local m = s / #v; return m, math.sqrt(math.max(0, s2 / #v - m * m)) end
local iv, gs = {}, {}
for i = 21, #shownAt do iv[#iv + 1] = (shownAt[i] - shownAt[i - 1]) * 1000; gs[#gs + 1] = gameAt[i] - gameAt[i - 1] end
local mi, si = stats(iv)
local mg, sg = stats(gs)
local span = shownAt[#shownAt] - shownAt[21]
local same, mult = 0, 0
for _, g in ipairs(gs) do if g == R.presentEvery() then same = same + 1 end if g % R.presentEvery() == 0 then mult = mult + 1 end end
print(string.format('E %g+%g Lua %g LVGL %g ms -> game %.1f fps (%.1f%% speed) | shown %.1f fps, every %d game frames (%.0f%% exactly that, %.0f%% a multiple) | %0.f +/- %.0f ms between shown frames',
  E, Rr, Pl, Lv, (gameAt[#gameAt] - gameAt[21]) / span, (gameAt[#gameAt] - gameAt[21]) / span / 59.7275 * 100,
  (#shownAt - 21) / span, R.presentEvery(), 100 * same / #gs, 100 * mult / #gs, mi, si))
