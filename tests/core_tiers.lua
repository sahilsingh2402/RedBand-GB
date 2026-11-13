-- Engine size and collector follow free system memory; bytecode loads on Lua 5.4.0; broken or
-- missing bytecode falls back to the next size and finally to source.
APPDIR = arg[1]
local T = dofile('tests/common.lua')
local cases = {
  { T.meminfo(8000), 'XL', 'b', 150, 200 }, { T.meminfo(5000, true), 'L', 'b', 110, 200 },
  { T.meminfo(3000), 'S', 'b', 110, 110 }, { T.meminfo(1000), 'S', 'b', 110, 110 }, { '/nonexistent', 'S', 'b', 110, 110 },
}
for _, c in ipairs(cases) do
  local mock, R = T.load(APPDIR, { unthrottled = true, meminfo = c[1] })
  mock.setCacheMax(0)
  mock.fire(R.power, mock.EVENT.CLICKED)
  local tier, form = R.core()
  assert(R.emu(), 'core did not start')
  assert(tier == c[2] and form == c[3] and R.gcPause() >= c[4] and R.gcPause() <= c[5], string.format('memory %s: got %s/%s/%d', c[1], tier, form, R.gcPause()))
  local timer = R.timer(); for _ = 1, 200 do timer.cb(timer) end
  assert(R.shown() > 5 and not R.errmsg(), 'did not run')
  mock.fire(R.power, mock.EVENT.CLICKED)
end
-- broken XL bytecode -> L; no bytecode at all -> source S
local bad = io.open(APPDIR .. 'gbcore_xl.luac', 'rb'):read('a')
io.open(APPDIR .. 'gbcore_xl.luac', 'wb'):write(bad:sub(1, 5000)):close()
local mock, R = T.load(APPDIR, { meminfo = T.meminfo(8000) }); mock.fire(R.power, mock.EVENT.CLICKED)
assert(R.core() == 'L', 'broken XL bytecode did not fall back to L')
mock.fire(R.power, mock.EVENT.CLICKED)
io.open(APPDIR .. 'gbcore_xl.luac', 'wb'):write(bad):close()
for _, n in ipairs({ 'gbcore_xl.luac', 'gbcore_l.luac', 'gbcore_s.luac' }) do os.rename(APPDIR .. n, APPDIR .. n .. '.off') end
mock, R = T.load(APPDIR, { meminfo = T.meminfo(8000) }); mock.fire(R.power, mock.EVENT.CLICKED)
local t, f = R.core()
assert(t == 'S' and f == 's', 'no bytecode: source fallback failed')
for _, n in ipairs({ 'gbcore_xl.luac', 'gbcore_l.luac', 'gbcore_s.luac' }) do os.rename(APPDIR .. n .. '.off', APPDIR .. n) end
print('core tiers OK: XL >= 6 MB, L >= 4 MB free, else S (both meminfo layouts), collector pause from free memory (grows at most 2.5 MB, 3 MB kept for the band), broken bytecode -> next size, no bytecode -> source')
