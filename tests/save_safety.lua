-- Battery save safety: only a finished save (valid game checksum, unchanged for 1 s) is written;
-- writes go through .tmp + read-back + rename with the old save kept as .bak; a truncated or
-- half-written save is never loaded when a good one exists.
APPDIR = arg[1]
local wall = 100
os.clock = function() return wall end
local T = dofile('tests/common.lua')
local MAIN = '/data/redbandgb_red.sav'
local function put(p, s) local f = assert(io.open(p, 'wb')); f:write(s); f:close() end
local function get(p) local f = io.open(p, 'rb'); if not f then return nil end local s = f:read('a'); f:close(); return s end
local function make(seed, valid)
  local t = {}
  local x = seed
  for i = 1, 32768 do x = (x * 1103515245 + 12345) & 0x7fffffff; t[i] = (x >> 16) & 255 end
  local sum = 0
  for i = 0x2599, 0x3523 do sum = sum + t[i] end
  t[0x3524] = ((~sum) & 255) ~ (valid and 0 or 0x5A)
  local parts = {}
  for i = 1, 32768, 4096 do parts[#parts + 1] = string.char(table.unpack(t, i, i + 4095)) end
  return table.concat(parts)
end
local V1, V2, V2b, HALF = make(1, true), make(2, true), make(3, true), make(2, false)
for _, q in ipairs({ MAIN, MAIN .. '.bak', MAIN .. '.tmp' }) do os.remove(q) end
put(MAIN, V1)
local mock, R = T.load(APPDIR, { unthrottled = true, keepSaves = true })
assert(R.savValid(V1) and not R.savValid(HALF), 'checksum check')
mock.fire(R.power, mock.EVENT.CLICKED)
assert(R.savedFrom() == MAIN and R.emu().getSRAM() == V1, 'did not load the good save')
local emu = R.emu()
local data, dirty = HALF, true
emu.getSRAM = function() return data end
emu.sramDirty = function() return dirty end
emu.markSRAMSaved = function() dirty = false end
-- 1. a half-written save (the game is still saving): never written
R.saveRam(false); wall = wall + 1.5; R.saveRam(false); R.saveRam(true)
assert(get(MAIN) == V1 and not get(MAIN .. '.tmp') and dirty, 'a half-written save was written')
-- 2. still changing: not yet
data = V2b; R.saveRam(false); wall = wall + 0.4; data = V2; R.saveRam(false); wall = wall + 0.4; R.saveRam(false)
assert(get(MAIN) == V1, 'written before the save settled')
-- 3. finished and settled: written atomically, the old save kept as .bak
wall = wall + 1.2; R.saveRam(false)
assert(get(MAIN) == V2 and get(MAIN .. '.bak') == V1 and not get(MAIN .. '.tmp') and not dirty, 'atomic save with backup failed')
-- 4. power off in the middle of a save: the good file stays
data, dirty = HALF, true
mock.fire(R.power, mock.EVENT.CLICKED)
assert(get(MAIN) == V2, 'power off wrote a half-written save')
-- 5. after a crash: main truncated -> .bak; main missing but .tmp complete -> .tmp
put(MAIN, V2:sub(1, 100))
local mock2, R2 = T.load(APPDIR, { unthrottled = true, keepSaves = true }); mock2.fire(R2.power, mock2.EVENT.CLICKED)
assert(R2.savedFrom() == MAIN .. '.bak' and R2.emu().getSRAM() == V1, 'truncated save: backup not used')
mock2.fire(R2.power, mock2.EVENT.CLICKED)
os.remove(MAIN); put(MAIN .. '.tmp', V2)
local mock3, R3 = T.load(APPDIR, { unthrottled = true, keepSaves = true }); mock3.fire(R3.power, mock3.EVENT.CLICKED)
assert(R3.savedFrom() == MAIN .. '.tmp' and R3.emu().getSRAM() == V2, 'interrupted rename: .tmp not used')
mock3.fire(R3.power, mock3.EVENT.CLICKED)
for _, q in ipairs({ MAIN, MAIN .. '.bak', MAIN .. '.tmp' }) do os.remove(q) end
print('save safety OK: half-written save never written, waits until settled, .tmp + read-back + rename with .bak, truncated save -> backup, interrupted rename -> .tmp')
