-- Shared helpers for the 4.0.0 watchface tests (run under tests/bandhost32 or bandhost64).
local T = {}
function T.load(dir, opts)
  opts = opts or {}
  SCRIPT_PATH = dir
  RBGB_TEST = true
  if opts.unthrottled then TEST_UNTHROTTLED = true end
  RBGB_MEMINFO = opts.meminfo or '/nonexistent/meminfo'
  RBGB_CORE = opts.core
  local mock = dofile('tests/mock_lvgl_band.lua')
  package.loaded['lvgl'] = mock
  os.execute('rm -f /tmp/rbgb_* /tmp/rbgbtxt_* ' .. dir .. 'redbandgb_cfg40.txt /data/redbandgb_cfg40.txt /data/redbandgb_cfgL.txt 2>/dev/null')
  if not opts.keepSaves then        -- every test starts without a battery save unless it wants one
    os.execute('rm -f /data/redbandgb_red.sav /data/redbandgb_red.sav.bak /data/redbandgb_red.sav.tmp ' .. dir .. 'pokemon_red.sav* 2>/dev/null')
  end
  if opts.cfg then local f = io.open(dir .. 'redbandgb_cfg40.txt', 'w'); f:write(opts.cfg); f:close() end
  dofile(dir .. 'main.lua')
  return mock, RBGB40
end
-- what the presented string must look like on screen: compare the image LVGL would draw with the
-- string main.lua presented last (exact bytes) -> catches stale cache hits and dangling pointers
function T.shown_matches(mock, R)
  local img = R.image()
  local e = img and img.shown
  local cur = R.current()
  if not e or not cur then return false, 'nothing shown' end
  return e.data == cur:sub(1, #e.data) and #e.data == #cur, 'shown bytes differ from the presented frame'
end
-- pixel check against the emulator framebuffer for the current view
local SHADE = { { 0xD0, 0xF8, 0xE0 }, { 0x70, 0xC0, 0x88 }, { 0x56, 0x68, 0x34 }, { 0x20, 0x18, 0x08 } }
function T.pixels_ok(mock, R, fb, bgp)
  local e = R.image().shown
  -- BIG: 212x189 (portrait, 53/40 x 21/16) or 224x202 (landscape, exactly 7/5 x 144/202);
  -- the file path draws BIG as the 160x144 image
  local view = (e.w == 212) and 'big' or ((e.w == 224) and 'bigL' or 'small')
  local W, H = e.w, e.h
  local bad = 0
  for y = 0, H - 1, 1 do
    local sy = (view == 'big') and ((y * 16) // 21) or ((view == 'bigL') and ((y * 144) // 202) or y)
    for x = 0, W - 1 do
      local sx = (view == 'big') and ((x * 40) // 53) or ((view == 'bigL') and ((x * 5) // 7) or x)
      local cn = (fb[sy * 40 + (sx >> 2) + 1] >> (6 - 2 * (sx & 3))) & 3
      local c = SHADE[((bgp >> (cn * 2)) & 3) + 1]
      local b, g, r = mock.pixel(e, x, y)
      if b ~= c[1] or g ~= c[2] or r ~= c[3] then bad = bad + 1 end
    end
  end
  local want = { big = { 212, 189 }, bigL = { 224, 202 }, small = { 160, 144 } }
  if W ~= want[view][1] or H ~= want[view][2] then bad = bad + 1000000 end
  return bad
end
-- fake NuttX /proc/meminfo files (new and old layouts) for the engine-size and collector choices
function T.meminfo(freeKB, old)
  local path = os.tmpname()
  local f = io.open(path, 'w')
  local free = freeKB * 1024
  if old then
    f:write('             total       used       free    largest  nused  nfree\n')
    f:write(string.format('Umem:   %10d %10d %10d %10d %6d %6d\n', 9000000, 9000000 - free, free, free // 2, 400, 20))
  else
    f:write(string.format('%11s%11s%11s%11s%11s%7s%7s%s\n', 'total', 'used', 'free', 'maxused', 'maxfree', 'nused', 'nfree', 'name'))
    f:write(string.format('%11d%11d%11d%11d%11d%7d%7d %s\n', 2000000, 1000000, 1000000, 1200000, 900000, 100, 10, 'Kmem'))
    f:write(string.format('%11d%11d%11d%11d%11d%7d%7d %s\n', 9000000, 9000000 - free, free, 7000000, free // 2, 400, 20, 'Umem'))
  end
  f:close()
  return path
end
return T
